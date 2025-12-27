// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Escrow {
    
    // 托管狀態
    enum State { Created, Funded, Confirmed, Refunded, Disputed }
    
    address public buyer;
    address public seller;
    uint256 public amount;
    uint256 public productId;
    State public state;
    uint256 public createdAt;
    address public marketplace; // 【零件：記錄授權秘書的身分證】
    receive() external payable {}
    // 事件
    event Funded(address indexed buyer, uint256 amount);
    event Confirmed(address indexed buyer, address indexed seller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event DisputeRaised(address indexed raiser);
    
    // 修飾器
    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only buyer can call this");
        _;
    }
    
    modifier onlySeller() {
        require(msg.sender == seller, "Only seller can call this");
        _;
    }
    
    modifier inState(State _state) {
        require(state == _state, "Invalid state for this action");
        _;
    }
    
    // 建構函式：由 Marketplace 合約呼叫建立
    constructor(
        address _buyer,
        address _seller,
        uint256 _productId,
        uint256 _amount
    ) payable {
        buyer = _buyer;
        seller = _seller;
        marketplace = msg.sender;
        productId = _productId;
        amount = _amount;
        state = State.Created;
        createdAt = block.timestamp;
    }
    
    // Escrow.sol
    // 移除 onlyBuyer，否則 Marketplace 呼叫時會被拒絕
    function fund() external payable inState(State.Created) {
        require(msg.value == amount, "Incorrect payment amount");
        state = State.Funded;
        emit Funded(msg.sender, msg.value);
    }
    
    // 買家確認收貨 → 資金轉給賣家
    function confirmReceived() external onlyBuyer inState(State.Funded) {
        state = State.Confirmed;
        (bool success, ) = payable(seller).call{value: amount}("");
        require(success, "Transfer to seller failed");
        
        emit Confirmed(buyer, seller, amount);
    }
    
    // 賣家同意退款
    function refund() external onlySeller inState(State.Funded) {
        state = State.Refunded;
        
        (bool success, ) = payable(buyer).call{value: amount}("");
        require(success, "Refund to buyer failed");
        
        emit Refunded(buyer, amount);
    }
    
    // 買家提出爭議
    function raiseDispute() external onlyBuyer inState(State.Funded) {
        state = State.Disputed;
        emit DisputeRaised(msg.sender);
    }
    
    // 查詢托管詳情
    function getDetails() external view returns (
        address _buyer,
        address _seller,
        uint256 _amount,
        uint256 _productId,
        State _state,
        uint256 _createdAt
    ) {
        return (buyer, seller, amount, productId, state, createdAt);
    }
    
    // 查詢合約餘額
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}