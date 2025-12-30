// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 定義介面：讓 Escrow 知道 Marketplace 有這些功能可以呼叫
interface IMarketplace {
    function markAsSold(uint256 _productId) external;
    function markAsAvailable(uint256 _productId) external; // 用於退款時重置狀態
}

contract Escrow {
    
    // 托管狀態
    enum State { Created, Funded, Confirmed, Refunded, Disputed }
    
    address public buyer;
    address public seller;
    uint256 public amount;
    uint256 public productId;
    State public state;
    uint256 public createdAt;
    address public marketplace; // 記錄 Marketplace 合約地址
    uint256 public constant TIMEOUT = 7 days; // 超時退款機制 (Time Lock): 設定 7 天期限
    
    receive() external payable {} // 接收以太幣的 fallback 函式

    // Events
    event Funded(address indexed buyer, uint256 amount);
    event Confirmed(address indexed buyer, address indexed seller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event DisputeRaised(address indexed raiser);
    
    // Modifiers
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
        marketplace = msg.sender; // 這裡記錄了是誰創造了這個 Escrow (即 Marketplace)
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
        
        // 計算手續費 (假設 1%)
        uint256 fee = amount * 1 / 100;
        uint256 sellerProceeds = amount - fee;
        
        // 1. 扣除手續費後轉給賣家
        (bool successSeller, ) = payable(seller).call{value: sellerProceeds}("");
        require(successSeller, "Transfer to seller failed");
        
        // 2. 直接轉給 Marketplace 合約 (Marketplace 要有 owner 領錢機制)
        (bool successFee, ) = payable(marketplace).call{value: fee}(""); 
        require(successFee, "Transfer fee failed");
        
        // 3. 通知 Marketplace 將商品標記為「已售出」
        IMarketplace(marketplace).markAsSold(productId);
        
        emit Confirmed(buyer, seller, amount);
    }
    
    // 賣家同意退款
    function refund() external onlySeller inState(State.Funded) {
        state = State.Refunded;
        
        // 1. 先退款
        (bool success, ) = payable(buyer).call{value: amount}("");
        require(success, "Refund to buyer failed");
        
        // 2. 通知 Marketplace 將商品重置為「可購買」(Available) 這樣賣家才能再次賣這個商品，否則它會永遠卡在 Pending
        IMarketplace(marketplace).markAsAvailable(productId);
        
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

    // 超時領回，賣家可在買家長時間未確認收貨後強制完成交易
    function claimTimeout() external onlySeller inState(State.Funded) {
        // 如果買家 7 天都沒反應，視為交易完成，賣家可以強行領錢
        require(block.timestamp > createdAt + TIMEOUT, "Too early to claim timeout");
        state = State.Confirmed;
        
        // 計算手續費 (假設 1%)
        uint256 fee = amount * 1 / 100;
        uint256 sellerProceeds = amount - fee;

        // 1. 轉給賣家 (扣除手續費)
        (bool success, ) = payable(seller).call{value: sellerProceeds}("");
        require(success, "Transfer to seller failed");
        
        // 2. 轉手續費給平台
        (bool successFee, ) = payable(marketplace).call{value: fee}("");
        require(successFee, "Transfer fee failed");
        
        // 通知 Marketplace 將商品標記為「已售出」
        IMarketplace(marketplace).markAsSold(productId);
        
        emit Confirmed(buyer, seller, amount);
    }
}