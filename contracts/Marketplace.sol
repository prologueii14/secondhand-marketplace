// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    // --- Events ---
    event ProductListed(uint256 indexed id, address indexed seller, string name, uint256 price);
    event ProductPurchased(uint256 indexed id, address indexed buyer, address escrowContract);
    event ProductCancelled(uint256 indexed id);
    event ProductSold(uint256 indexed id);
    event FeeWithdrawn(address indexed owner, uint256 amount);

    enum Status { Available, Pending, Sold, Cancelled }

    struct Product {
        uint256 id;
        address seller;
        address escrowContract;
        uint256 price;
        uint256 createdAt;
        Status status;
        string name;
        string description;
    }

    address public owner;
    uint256 public productCount;

    mapping(uint256 => Product) public products;
    mapping(address => uint256[]) public sellerProducts;
    mapping(address => uint256[]) public buyerOrders;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // 接收 Escrow 分潤
    receive() external payable {}

    function listProduct(
        string calldata _name,
        string calldata _description,
        uint256 _price
    ) external returns (uint256) {
        if (_price == 0) revert InvalidPrice();
        if (bytes(_name).length == 0) revert EmptyName();
        
        unchecked {
            productCount++;
        }
        uint256 newId = productCount;

        products[newId] = Product({
            id: newId,
            seller: msg.sender,
            escrowContract: address(0),
            price: _price,
            createdAt: block.timestamp,
            status: Status.Available,
            name: _name,
            description: _description
        });

        sellerProducts[msg.sender].push(newId);
        
        emit ProductListed(newId, msg.sender, _name, _price);
        
        return newId;
    }

    function purchaseProduct(uint256 _id) external payable returns (address) {
        Product storage product = products[_id];

        if (product.id == 0) revert ProductNotFound();
        if (product.status != Status.Available) revert ProductNotAvailable();
        // 如果買家是賣家自己
        if (msg.sender == product.seller) revert ProductNotAvailable(); 
        if (msg.value != product.price) revert InvalidPrice();

        // 部署 Escrow
        Escrow escrow = new Escrow(
            msg.sender,
            product.seller,
            _id,
            product.price
        );
        
        address escrowAddr = address(escrow);
        if (escrowAddr == address(0)) revert EscrowDeploymentFailed();

        // 更新狀態
        product.escrowContract = escrowAddr;
        product.status = Status.Pending;
        
        buyerOrders[msg.sender].push(_id);

        try IEscrow(escrowAddr).fund{value: msg.value}() {
            emit ProductPurchased(_id, msg.sender, escrowAddr);
        } catch {
            revert TransferFailed();
        }
        
        return escrowAddr;
    }

    function cancelProduct(uint256 _id) external {
        Product storage product = products[_id];
        
        if (product.id == 0) revert ProductNotFound();
        if (product.seller != msg.sender) revert Unauthorized();
        if (product.status != Status.Available) revert ProductNotAvailable();
        
        product.status = Status.Cancelled;
        
        emit ProductCancelled(_id);
    }

    function markAsSold(uint256 _id) external {
        Product storage product = products[_id];
        
        if (product.id == 0) revert ProductNotFound();
        if (msg.sender != product.escrowContract) revert Unauthorized();
        
        product.status = Status.Sold;
        emit ProductSold(_id);
    }

    function markAsAvailable(uint256 _id) external {
        Product storage product = products[_id];
        
        if (product.id == 0) revert ProductNotFound();
        if (msg.sender != product.escrowContract) revert Unauthorized();
        
        product.status = Status.Available;
        product.escrowContract = address(0);
    }

    // --- View Functions ---

    function getProduct(uint256 _id) external view returns (Product memory) {
        if (products[_id].id == 0) revert ProductNotFound();
        return products[_id];
    }

    function getAvailableProducts() external view returns (Product[] memory) {
        uint256 total = productCount;
        uint256 availableCount = 0;

        for (uint256 i = 1; i <= total;) {
            if (products[i].status == Status.Available) {
                unchecked { availableCount++; }
            }
            unchecked { ++i; }
        }

        Product[] memory results = new Product[](availableCount);
        uint256 idx = 0;

        for (uint256 i = 1; i <= total;) {
            if (products[i].status == Status.Available) {
                results[idx] = products[i];
                unchecked { idx++; }
            }
            unchecked { ++i; }
        }

        return results;
    }

    function getSellerProducts(address _seller) external view returns (uint256[] memory) {
        return sellerProducts[_seller];
    }

    function getBuyerOrders(address _buyer) external view returns (uint256[] memory) {
        return buyerOrders[_buyer];
    }

    function withdrawFee() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert InvalidPrice(); 
        
        (bool success, ) = payable(owner).call{value: balance}("");
        if (!success) revert TransferFailed();

        emit FeeWithdrawn(owner, balance);
    }
}