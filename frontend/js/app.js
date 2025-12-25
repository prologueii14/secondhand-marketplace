// app.js
// 二手交易市場前端主程式

// ========== 全域變數 ==========
let web3;
let marketplaceContract;
let currentAccount;

// ========== 初始化 ==========
async function initWeb3() {
    if (typeof window.ethereum !== 'undefined') {
        try {
            // 請求連接錢包
            const accounts = await window.ethereum.request({ 
                method: 'eth_requestAccounts' 
            });
            
            web3 = new Web3(window.ethereum);
            currentAccount = accounts[0];
            
            // 檢查網路
            const chainId = await web3.eth.getChainId();
            if (Number(chainId) !== CHAIN_ID) {
                showNotification(`請切換到 Chain ID: ${CHAIN_ID}`, 'error');
                return false;
            }
            
            // 初始化合約
            if (MARKETPLACE_ADDRESS) {
                marketplaceContract = new web3.eth.Contract(
                    MARKETPLACE_ABI, 
                    MARKETPLACE_ADDRESS
                );
            }
            
            // 更新 UI
            updateWalletUI();
            
            // 監聽帳號切換
            window.ethereum.on('accountsChanged', handleAccountsChanged);
            window.ethereum.on('chainChanged', () => window.location.reload());
            
            return true;
        } catch (error) {
            console.error('連接錢包失敗:', error);
            showNotification('連接錢包失敗', 'error');
            return false;
        }
    } else {
        showNotification('請安裝 MetaMask', 'error');
        return false;
    }
}

// 處理帳號切換
function handleAccountsChanged(accounts) {
    if (accounts.length === 0) {
        currentAccount = null;
        updateWalletUI();
    } else {
        currentAccount = accounts[0];
        updateWalletUI();
        window.location.reload();
    }
}

// 更新錢包 UI
function updateWalletUI() {
    const connectBtn = document.getElementById('connectWallet');
    const addressSpan = document.getElementById('walletAddress');
    
    if (currentAccount) {
        connectBtn.style.display = 'none';
        addressSpan.textContent = shortenAddress(currentAccount);
    } else {
        connectBtn.style.display = 'block';
        addressSpan.textContent = '';
    }
}

// 縮短地址顯示
function shortenAddress(address) {
    return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

// ========== 商品功能 ==========

// 上架商品
async function listProduct(name, description, price) {
    if (!marketplaceContract || !currentAccount) {
        showNotification('請先連接錢包', 'error');
        return;
    }
    
    try {
        const priceWei = web3.utils.toWei(price.toString(), 'ether');
        
        showNotification('交易處理中...', 'info');
        
        const result = await marketplaceContract.methods
            .listProduct(name, description, priceWei)
            .send({ from: currentAccount });
        
        showNotification('商品上架成功！', 'success');
        console.log('Transaction:', result);
        
        // 重新載入商品列表
        await loadProducts();
        
        return result;
    } catch (error) {
        console.error('上架失敗:', error);
        showNotification('上架失敗: ' + error.message, 'error');
    }
}

// 載入所有可購買商品
async function loadProducts() {
    const productList = document.getElementById('productList');
    if (!productList) return;
    
    if (!marketplaceContract) {
        productList.innerHTML = '<div class="empty">請先設定合約地址</div>';
        return;
    }
    
    try {
        const products = await marketplaceContract.methods
            .getAvailableProducts()
            .call();
        
        if (products.length === 0) {
            productList.innerHTML = '<div class="empty">目前沒有上架的商品</div>';
            return;
        }
        
        productList.innerHTML = products.map(product => `
            <div class="product-card">
                <div class="product-card-body">
                    <h3>${escapeHtml(product.name)}</h3>
                    <p class="description">${escapeHtml(product.description)}</p>
                    <p class="price">${web3.utils.fromWei(product.price, 'ether')} ETH</p>
                    <p class="seller">賣家: ${shortenAddress(product.seller)}</p>
                    <span class="status status-available">可購買</span>
                    <br><br>
                    <a href="product.html?id=${product.id}" class="btn btn-primary">查看詳情</a>
                </div>
            </div>
        `).join('');
        
    } catch (error) {
        console.error('載入商品失敗:', error);
        productList.innerHTML = '<div class="error">載入失敗，請確認合約地址是否正確</div>';
    }
}

// 載入商品詳情
async function loadProductDetail(productId) {
    const detailDiv = document.getElementById('productDetail');
    
    if (!marketplaceContract) {
        detailDiv.innerHTML = '<div class="error">請先設定合約地址</div>';
        return;
    }
    
    try {
        const product = await marketplaceContract.methods
            .getProduct(productId)
            .call();
        
        const statusText = PRODUCT_STATUS[product.status] || 'Unknown';
        const statusClass = `status-${statusText.toLowerCase()}`;
        const isSeller = currentAccount && 
            product.seller.toLowerCase() === currentAccount.toLowerCase();
        const canBuy = product.status === '0' && !isSeller;
        
        detailDiv.innerHTML = `
            <h2>${escapeHtml(product.name)}</h2>
            <p class="price">${web3.utils.fromWei(product.price, 'ether')} ETH</p>
            <span class="status ${statusClass}">${getStatusText(product.status)}</span>
            
            <div class="product-info">
                <p><strong>商品 ID:</strong> ${product.id}</p>
                <p><strong>賣家:</strong> ${product.seller}</p>
                <p><strong>上架時間:</strong> ${formatTimestamp(product.createdAt)}</p>
                ${product.escrowContract !== '0x0000000000000000000000000000000000000000' 
                    ? `<p><strong>Escrow 合約:</strong> ${product.escrowContract}</p>` 
                    : ''}
            </div>
            
            <h3>商品描述</h3>
            <p class="description">${escapeHtml(product.description)}</p>
            
            <div style="margin-top: 1.5rem;">
                ${canBuy 
                    ? `<button onclick="purchaseProduct(${product.id}, '${product.price}')" 
                         class="btn btn-success">購買此商品</button>` 
                    : ''}
                ${isSeller && product.status === '0' 
                    ? `<button onclick="cancelProduct(${product.id})" 
                         class="btn btn-danger">取消上架</button>` 
                    : ''}
            </div>
        `;
        
        // 如果有 Escrow，載入 Escrow 資訊
        if (product.escrowContract !== '0x0000000000000000000000000000000000000000') {
            await loadEscrowDetail(product.escrowContract);
        }
        
    } catch (error) {
        console.error('載入商品詳情失敗:', error);
        detailDiv.innerHTML = '<div class="error">載入失敗，商品可能不存在</div>';
    }
}

// 購買商品
async function purchaseProduct(productId, priceWei) {
    if (!currentAccount) {
        showNotification('請先連接錢包', 'error');
        return;
    }
    
    try {
        showNotification('交易處理中...', 'info');
        
        const result = await marketplaceContract.methods
            .purchaseProduct(productId)
            .send({ 
                from: currentAccount,
                value: priceWei
            });
        
        showNotification('購買成功！資金已進入托管', 'success');
        console.log('Transaction:', result);
        
        // 重新載入頁面
        window.location.reload();
        
    } catch (error) {
        console.error('購買失敗:', error);
        showNotification('購買失敗: ' + error.message, 'error');
    }
}

// 取消上架
async function cancelProduct(productId) {
    if (!currentAccount) {
        showNotification('請先連接錢包', 'error');
        return;
    }
    
    if (!confirm('確定要取消上架此商品嗎？')) return;
    
    try {
        showNotification('交易處理中...', 'info');
        
        await marketplaceContract.methods
            .cancelProduct(productId)
            .send({ from: currentAccount });
        
        showNotification('已取消上架', 'success');
        window.location.href = 'index.html';
        
    } catch (error) {
        console.error('取消失敗:', error);
        showNotification('取消失敗: ' + error.message, 'error');
    }
}

// ========== Escrow 功能 ==========

// 載入 Escrow 詳情
async function loadEscrowDetail(escrowAddress) {
    const escrowSection = document.getElementById('escrowSection');
    const escrowDiv = document.getElementById('escrowDetail');
    
    if (!escrowSection || !escrowDiv) return;
    
    try {
        const escrowContract = new web3.eth.Contract(ESCROW_ABI, escrowAddress);
        const details = await escrowContract.methods.getDetails().call();
        
        const isBuyer = currentAccount && 
            details._buyer.toLowerCase() === currentAccount.toLowerCase();
        const isSeller = currentAccount && 
            details._seller.toLowerCase() === currentAccount.toLowerCase();
        const state = Number(details._state);
        
        escrowSection.classList.remove('hidden');
        
        escrowDiv.innerHTML = `
            <p class="state">狀態: ${getEscrowStateText(state)}</p>
            
            <div class="escrow-info">
                <div class="escrow-info-item">
                    <label>買家</label>
                    <span>${shortenAddress(details._buyer)}</span>
                </div>
                <div class="escrow-info-item">
                    <label>賣家</label>
                    <span>${shortenAddress(details._seller)}</span>
                </div>
                <div class="escrow-info-item">
                    <label>金額</label>
                    <span>${web3.utils.fromWei(details._amount, 'ether')} ETH</span>
                </div>
                <div class="escrow-info-item">
                    <label>建立時間</label>
                    <span>${formatTimestamp(details._createdAt)}</span>
                </div>
            </div>
            
            <div class="escrow-actions">
                ${state === 1 && isBuyer 
                    ? `<button onclick="confirmReceived('${escrowAddress}')" 
                         class="btn btn-success">確認收貨</button>
                       <button onclick="raiseDispute('${escrowAddress}')" 
                         class="btn btn-warning">提出爭議</button>` 
                    : ''}
                ${state === 1 && isSeller 
                    ? `<button onclick="refund('${escrowAddress}')" 
                         class="btn btn-danger">同意退款</button>` 
                    : ''}
            </div>
        `;
        
    } catch (error) {
        console.error('載入 Escrow 失敗:', error);
        escrowDiv.innerHTML = '<div class="error">載入托管資訊失敗</div>';
    }
}

// 確認收貨
async function confirmReceived(escrowAddress) {
    if (!currentAccount) {
        showNotification('請先連接錢包', 'error');
        return;
    }
    
    if (!confirm('確認已收到商品？資金將釋放給賣家。')) return;
    
    try {
        showNotification('交易處理中...', 'info');
        
        const escrowContract = new web3.eth.Contract(ESCROW_ABI, escrowAddress);
        await escrowContract.methods
            .confirmReceived()
            .send({ from: currentAccount });
        
        showNotification('已確認收貨！', 'success');
        window.location.reload();
        
    } catch (error) {
        console.error('確認收貨失敗:', error);
        showNotification('操作失敗: ' + error.message, 'error');
    }
}

// 退款
async function refund(escrowAddress) {
    if (!currentAccount) {
        showNotification('請先連接錢包', 'error');
        return;
    }
    
    if (!confirm('確定要退款給買家嗎？')) return;
    
    try {
        showNotification('交易處理中...', 'info');
        
        const escrowContract = new web3.eth.Contract(ESCROW_ABI, escrowAddress);
        await escrowContract.methods
            .refund()
            .send({ from: currentAccount });
        
        showNotification('已退款給買家', 'success');
        window.location.reload();
        
    } catch (error) {
        console.error('退款失敗:', error);
        showNotification('操作失敗: ' + error.message, 'error');
    }
}

// 提出爭議
async function raiseDispute(escrowAddress) {
    if (!currentAccount) {
        showNotification('請先連接錢包', 'error');
        return;
    }
    
    if (!confirm('確定要提出爭議嗎？')) return;
    
    try {
        showNotification('交易處理中...', 'info');
        
        const escrowContract = new web3.eth.Contract(ESCROW_ABI, escrowAddress);
        await escrowContract.methods
            .raiseDispute()
            .send({ from: currentAccount });
        
        showNotification('已提出爭議', 'success');
        window.location.reload();
        
    } catch (error) {
        console.error('提出爭議失敗:', error);
        showNotification('操作失敗: ' + error.message, 'error');
    }
}

// ========== 我的訂單 ==========

async function loadMyOrders() {
    if (!currentAccount || !marketplaceContract) {
        document.getElementById('buyerOrders').innerHTML = 
            '<div class="empty">請先連接錢包</div>';
        document.getElementById('sellerProducts').innerHTML = 
            '<div class="empty">請先連接錢包</div>';
        return;
    }
    
    await loadBuyerOrders();
    await loadSellerProducts();
}

// 載入我購買的商品
async function loadBuyerOrders() {
    const orderList = document.getElementById('buyerOrders');
    
    try {
        const orderIds = await marketplaceContract.methods
            .getBuyerOrders(currentAccount)
            .call();
        
        if (orderIds.length === 0) {
            orderList.innerHTML = '<div class="empty">還沒有購買記錄</div>';
            return;
        }
        
        let html = '';
        for (const id of orderIds) {
            const product = await marketplaceContract.methods.getProduct(id).call();
            const escrowStatus = await getEscrowStatus(product.escrowContract);
            
            html += `
                <div class="order-card">
                    <div class="order-info">
                        <h3>${escapeHtml(product.name)}</h3>
                        <p>價格: ${web3.utils.fromWei(product.price, 'ether')} ETH</p>
                        <p>賣家: ${shortenAddress(product.seller)}</p>
                        <p>托管狀態: ${escrowStatus}</p>
                    </div>
                    <div class="order-actions">
                        <a href="product.html?id=${product.id}" class="btn btn-primary">查看詳情</a>
                    </div>
                </div>
            `;
        }
        
        orderList.innerHTML = html;
        
    } catch (error) {
        console.error('載入訂單失敗:', error);
        orderList.innerHTML = '<div class="error">載入失敗</div>';
    }
}

// 載入我上架的商品
async function loadSellerProducts() {
    const productList = document.getElementById('sellerProducts');
    
    try {
        const productIds = await marketplaceContract.methods
            .getSellerProducts(currentAccount)
            .call();
        
        if (productIds.length === 0) {
            productList.innerHTML = '<div class="empty">還沒有上架商品</div>';
            return;
        }
        
        let html = '';
        for (const id of productIds) {
            const product = await marketplaceContract.methods.getProduct(id).call();
            
            html += `
                <div class="order-card">
                    <div class="order-info">
                        <h3>${escapeHtml(product.name)}</h3>
                        <p>價格: ${web3.utils.fromWei(product.price, 'ether')} ETH</p>
                        <p>狀態: ${getStatusText(product.status)}</p>
                    </div>
                    <div class="order-actions">
                        <a href="product.html?id=${product.id}" class="btn btn-primary">查看詳情</a>
                    </div>
                </div>
            `;
        }
        
        productList.innerHTML = html;
        
    } catch (error) {
        console.error('載入商品失敗:', error);
        productList.innerHTML = '<div class="error">載入失敗</div>';
    }
}

// 取得 Escrow 狀態
async function getEscrowStatus(escrowAddress) {
    if (escrowAddress === '0x0000000000000000000000000000000000000000') {
        return '無';
    }
    
    try {
        const escrowContract = new web3.eth.Contract(ESCROW_ABI, escrowAddress);
        const details = await escrowContract.methods.getDetails().call();
        return getEscrowStateText(Number(details._state));
    } catch {
        return '未知';
    }
}

// ========== 工具函式 ==========

// 取得商品狀態文字
function getStatusText(status) {
    const statusMap = {
        '0': '可購買',
        '1': '交易中',
        '2': '已售出',
        '3': '已取消'
    };
    return statusMap[status] || '未知';
}

// 取得 Escrow 狀態文字
function getEscrowStateText(state) {
    const stateMap = {
        0: '已建立',
        1: '資金鎖定中',
        2: '已完成',
        3: '已退款',
        4: '爭議中'
    };
    return stateMap[state] || '未知';
}

// 格式化時間戳
function formatTimestamp(timestamp) {
    const date = new Date(Number(timestamp) * 1000);
    return date.toLocaleString('zh-TW');
}

// HTML 跳脫
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// ========== 通知功能 ==========

function showNotification(message, type = 'info') {
    const notification = document.getElementById('notification');
    const messageSpan = document.getElementById('notificationMessage');
    
    notification.className = `notification ${type}`;
    messageSpan.textContent = message;
    
    // 5秒後自動隱藏
    setTimeout(hideNotification, 5000);
}

function hideNotification() {
    const notification = document.getElementById('notification');
    notification.classList.add('hidden');
}

// ========== 事件監聽 ==========

document.addEventListener('DOMContentLoaded', async () => {
    // 連接錢包按鈕
    const connectBtn = document.getElementById('connectWallet');
    if (connectBtn) {
        connectBtn.addEventListener('click', async () => {
            await initWeb3();
            if (document.getElementById('productList')) {
                await loadProducts();
            }
        });
    }
    
    // 上架表單
    const listForm = document.getElementById('listProductForm');
    if (listForm) {
        listForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            
            const name = document.getElementById('productName').value;
            const description = document.getElementById('productDescription').value;
            const price = document.getElementById('productPrice').value;
            
            await listProduct(name, description, price);
            
            // 清空表單
            listForm.reset();
        });
    }
    
    // 自動連接（如果之前已授權）
    if (typeof window.ethereum !== 'undefined') {
        const accounts = await window.ethereum.request({ 
            method: 'eth_accounts' 
        });
        
        if (accounts.length > 0) {
            await initWeb3();
            if (document.getElementById('productList')) {
                await loadProducts();
            }
        }
    }
});