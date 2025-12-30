// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Escrow.sol";

contract Marketplace {
    
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
    
    // 事件
    event ProductListed(uint256 indexed productId, address indexed seller, string name, uint256 price);
    event ProductPurchased(uint256 indexed productId, address indexed buyer, address escrowContract);
    event ProductCancelled(uint256 indexed productId);
    event ProductSold(uint256 indexed productId);
    
    // 上架商品
    function listProduct(
        string memory _name,
        string memory _description,
        uint256 _price
    ) external returns (uint256) {
        require(_price > 0, "Price must be greater than 0");
        require(bytes(_name).length > 0, "Name cannot be empty");
        
        productCount++;
        
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
        
        require(product.id != 0, "Product does not exist");
        require(product.status == ProductStatus.Available, "Product not available");
        require(msg.sender != product.seller, "Seller cannot buy own product");
        require(msg.value == product.price, "Incorrect payment amount");
        
        // 建立新的 Escrow 合約
        Escrow escrow = new Escrow(
            msg.sender,           // buyer
            product.seller,       // seller
            _productId,
            product.price
        );
        
        // 將資金轉入 Escrow 合約並呼叫 fund
        address escrowAddress = address(escrow);
        product.escrowContract = escrowAddress;
        product.status = ProductStatus.Pending;
        
        // 轉帳到 Escrow 並執行 fund
        (bool success, ) = escrowAddress.call{value: msg.value}(
            abi.encodeWithSignature("fund()")
        );
        require(success, "Escrow funding failed");
        
        buyerOrders[msg.sender].push(_productId);
        
        emit ProductPurchased(_productId, msg.sender, escrowAddress);
        
        return escrowAddress;
    }
    
    // 取消上架（僅限賣家，且商品尚未被購買）
    function cancelProduct(uint256 _productId) external {
        Product storage product = products[_productId];
        
        require(product.id != 0, "Product does not exist");
        require(product.seller == msg.sender, "Only seller can cancel");
        require(product.status == ProductStatus.Available, "Cannot cancel, product not available");
        
        product.status = ProductStatus.Cancelled;
        
        emit ProductCancelled(_productId);
    }
    
    // 標記商品為已售出（由外部呼叫或 Escrow 確認後更新）
    function markAsSold(uint256 _productId) external {
        Product storage product = products[_productId];
        
        require(product.id != 0, "Product does not exist");
        require(product.escrowContract == msg.sender, "Only escrow contract can mark as sold");
        
        product.status = ProductStatus.Sold;
        
        emit ProductSold(_productId);
    }

    // 用於退款後重置商品狀態
    function markAsAvailable(uint256 _productId) external {
        Product storage product = products[_productId];
        require(product.id != 0, "Product does not exist");
        // 安全檢查：只有該商品對應的 Escrow 合約可以呼叫
        require(product.escrowContract == msg.sender, "Only escrow contract can reset status");
        
        // 將狀態改回 Available，讓其他人可以再次購買
        product.status = ProductStatus.Available;
        // 清除舊的 Escrow 地址，因為下次購買會產生新的合約
        product.escrowContract = address(0); 
    }
    
    // 查詢單一商品
    function getProduct(uint256 _productId) external view returns (Product memory) {
        require(products[_productId].id != 0, "Product does not exist");
        return products[_productId];
    }
    
    // 查詢所有可購買的商品
    function getAvailableProducts() external view returns (Product[] memory) {
        uint256 availableCount = 0;
        
        // 計算可用商品數量
        for (uint256 i = 1; i <= productCount; i++) {
            if (products[i].status == ProductStatus.Available) {
                availableCount++;
            }
        }
        
        // 建立陣列
        Product[] memory availableProducts = new Product[](availableCount);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= productCount; i++) {
            if (products[i].status == ProductStatus.Available) {
                availableProducts[index] = products[i];
                index++;
            }
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
}