// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Escrow.sol";

interface IEscrow {
    function fund() external payable;
}

contract Marketplace {
    // --- Custom Errors ---
    error NotOwner();
    error InvalidPrice();
    error EmptyName();
    error ProductNotFound();
    error ProductNotAvailable();
    error Unauthorized();
    error TransferFailed();
    error EscrowDeploymentFailed();

    address public owner;

    // 設定合約擁有者
    constructor() {
        owner = msg.sender;
    }
    
    // 商品狀態
    enum ProductStatus { Available, Pending, Sold, Cancelled }
    
    // 商品結構
    struct Product {
        uint256 id;
        address seller;
        string name;
        string description;
        uint256 price;
        ProductStatus status;
        address escrowContract;
        uint256 createdAt;
    }
    
    // 狀態變數
    uint256 public productCount;
    mapping(uint256 => Product) public products;
    mapping(address => uint256[]) public sellerProducts;
    mapping(address => uint256[]) public buyerOrders;
    // 允許合約接收手續費
    receive() external payable {}

    // 事件
    event ProductListed(uint256 indexed productId, address indexed seller, string name, uint256 price);
    event ProductPurchased(uint256 indexed productId, address indexed buyer, address escrowContract);
    event ProductCancelled(uint256 indexed productId);
    event ProductSold(uint256 indexed productId);
    event FeeWithdrawn(address indexed owner, uint256 amount); // 新增事件以配合測試

    // 上架商品
    function listProduct(
        string memory _name,
        string memory _description,
        uint256 _price
    ) external returns (uint256) {
        if (_price == 0) revert InvalidPrice();
        
        if (bytes(_name).length == 0) revert EmptyName();
        
        // 使用 unchecked 節省 Gas
        unchecked {
            productCount++;
        }
        
        products[productCount] = Product({
            id: productCount,
            seller: msg.sender,
            name: _name,
            description: _description,
            price: _price,
            status: ProductStatus.Available,
            
            escrowContract: address(0),
            createdAt: block.timestamp
        });
        sellerProducts[msg.sender].push(productCount);
        
        emit ProductListed(productCount, msg.sender, _name, _price);
        
        return productCount;
    }
    
    // 購買商品（建立 Escrow 合約）
    function purchaseProduct(uint256 _productId) external payable returns (address) {
        Product storage product = products[_productId];
        if (product.id == 0) revert ProductNotFound();

        if (product.status != ProductStatus.Available) revert ProductNotAvailable();

        // 配合測試腳本：賣家購買自己商品視為 "ProductNotAvailable" 或 "Unauthorized"
        if (msg.sender == product.seller) revert ProductNotAvailable();

        if (msg.value != product.price) revert InvalidPrice();

        // 建立新的 Escrow 合約
        Escrow escrow = new Escrow(
            msg.sender,           // buyer
            product.seller,       // seller
            _productId,
            product.price
        );
        // 將資金轉入 Escrow 合約並呼叫 fund
        address escrowAddress = address(escrow);
        
        if (escrowAddress == address(0)) revert EscrowDeploymentFailed();

        product.escrowContract = escrowAddress;
        product.status = ProductStatus.Pending;
        
        // 轉帳到 Escrow 並執行 fund
        try IEscrow(escrowAddress).fund{value: msg.value}() {
            // Success
        } catch {
            revert TransferFailed();
        }
        
        buyerOrders[msg.sender].push(_productId);
        
        emit ProductPurchased(_productId, msg.sender, escrowAddress);
        
        return escrowAddress;
    }
    
    // 取消上架（僅限賣家，且商品尚未被購買）
    function cancelProduct(uint256 _productId) external {
        Product storage product = products[_productId];
        if (product.id == 0) revert ProductNotFound();

        if (product.seller != msg.sender) revert Unauthorized();

        if (product.status != ProductStatus.Available) revert ProductNotAvailable();
        
        product.status = ProductStatus.Cancelled;
        
        emit ProductCancelled(_productId);
    }
    
    // 標記商品為已售出（由外部呼叫或 Escrow 確認後更新）
    function markAsSold(uint256 _productId) external {
        Product storage product = products[_productId];
        if (product.id == 0) revert ProductNotFound();

        if (product.escrowContract != msg.sender) revert Unauthorized();
        
        product.status = ProductStatus.Sold;
        emit ProductSold(_productId);
    }

    // 用於退款後重置商品狀態
    function markAsAvailable(uint256 _productId) external {
        Product storage product = products[_productId];
        if (product.id == 0) revert ProductNotFound();

        // 安全檢查：只有該商品對應的 Escrow 合約可以呼叫
        if (product.escrowContract != msg.sender) revert Unauthorized();

        // 將狀態改回 Available，讓其他人可以再次購買
        product.status = ProductStatus.Available;
        // 清除舊的 Escrow 地址，因為下次購買會產生新的合約
        product.escrowContract = address(0);
    }
    
    // 查詢單一商品
    function getProduct(uint256 _productId) external view returns (Product memory) {
        if (products[_productId].id == 0) revert ProductNotFound();
        return products[_productId];
    }
    
    // 查詢所有可購買的商品
    function getAvailableProducts() external view returns (Product[] memory) {
        uint256 availableCount = 0;
        // 計算可用商品數量
        for (uint256 i = 1; i <= productCount; ) {
            if (products[i].status == ProductStatus.Available) {
                availableCount++;
            }
            unchecked { ++i; } // Gas 優化
        }
        
        // 建立陣列
        Product[] memory availableProducts = new Product[](availableCount);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= productCount; ) {
            if (products[i].status == ProductStatus.Available) {
                availableProducts[index] = products[i];
                index++;
            }
            unchecked { ++i; } // Gas 優化
        }
        
        return availableProducts;
    }
    
    // 查詢賣家的所有商品
    function getSellerProducts(address _seller) external view returns (uint256[] memory) {
        return sellerProducts[_seller];
    }
    
    // 查詢買家的所有訂單
    function getBuyerOrders(address _buyer) external view returns (uint256[] memory) {
        return buyerOrders[_buyer];
    }

    // 提款功能 (只有 owner 能領出手續費)
    function withdrawFee() external {
        if (msg.sender != owner) revert NotOwner();

        uint256 balance = address(this).balance;
        if (balance == 0) revert InvalidPrice();
        
        (bool success, ) = payable(owner).call{value: balance}("");
        if (!success) revert TransferFailed();
        
        emit FeeWithdrawn(owner, balance);
    }
}