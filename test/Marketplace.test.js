const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("Marketplace Integration", function () {
    let marketplace, escrowFactory;
    let deployer, seller, buyer, maliciousUser;
    
    // Constants & Enums to avoid magic numbers
    const PRICE = ethers.parseEther("1.0");
    const FEE_PERCENT = 1n;
    const LOCK_PERIOD = 7 * 24 * 60 * 60;
    
    const STATUS = {
        AVAILABLE: 0n,
        PENDING: 1n,
        SOLD: 2n,
        CANCELLED: 3n
    };

    beforeEach(async function () {
        [deployer, seller, buyer, maliciousUser] = await ethers.getSigners();

        const Marketplace = await ethers.getContractFactory("Marketplace");
        marketplace = await Marketplace.deploy();

        escrowFactory = await ethers.getContractFactory("Escrow");
    });

    describe("Core Listing Flow", function () {
        it("Should emit event and update state upon listing", async function () {
            const tx = await marketplace.connect(seller).listProduct("MacBook Pro", "M3 Max", PRICE);
            
            await expect(tx)
                .to.emit(marketplace, "ProductListed")
                .withArgs(1, seller.address, "MacBook Pro", PRICE);

            const product = await marketplace.products(1);
            expect(product.seller).to.equal(seller.address);
            expect(product.status).to.equal(STATUS.AVAILABLE);
        });

        it("Should revert when listing with invalid price", async function () {
            await expect(
                marketplace.connect(seller).listProduct("Bad Item", "Desc", 0)
            ).to.be.revertedWithCustomError(marketplace, "InvalidPrice");
        });
    });

    describe("Purchasing Logic", function () {
        beforeEach(async function () {
            await marketplace.connect(seller).listProduct("Gaming Laptop", "RTX 4090", PRICE);
        });

        it("Should deploy escrow and lock funds", async function () {
            const tx = await marketplace.connect(buyer).purchaseProduct(1, { value: PRICE });
            
            // Validate balance change
            await expect(tx).to.changeEtherBalance(buyer, -PRICE);

            // Fetch updated product state
            const product = await marketplace.products(1);
            expect(product.status).to.equal(STATUS.PENDING);
            expect(product.escrowContract).to.not.equal(ethers.ZeroAddress);

            // Verify Escrow initialization
            const escrow = await escrowFactory.attach(product.escrowContract);
            expect(await escrow.buyer()).to.equal(buyer.address);
            expect(await escrow.amount()).to.equal(PRICE);
        });

        it("Should prevent double purchase", async function () {
            await marketplace.connect(buyer).purchaseProduct(1, { value: PRICE });
            
            await expect(
                marketplace.connect(maliciousUser).purchaseProduct(1, { value: PRICE })
            ).to.be.revertedWithCustomError(marketplace, "ProductNotAvailable");
        });
    });

    describe("Escrow Lifecycle & Settlement", function () {
        let escrow;

        beforeEach(async function () {
            // Setup: List -> Buy -> Get Escrow Instance
            await marketplace.connect(seller).listProduct("DSLR Camera", "Sony A7IV", PRICE);
            await marketplace.connect(buyer).purchaseProduct(1, { value: PRICE });
            
            const product = await marketplace.products(1);
            escrow = await escrowFactory.attach(product.escrowContract);
        });

        it("Happy Path: Buyer confirms receipt", async function () {
            const fee = (PRICE * FEE_PERCENT) / 100n;
            const sellerRevenue = PRICE - fee;

            // Expect multiple balance changes in one assertion
            await expect(escrow.connect(buyer).confirmReceived())
                .to.changeEtherBalances(
                    [seller, marketplace, buyer], 
                    [sellerRevenue, fee, 0]
                );

            expect(await escrow.state()).to.equal(2n); // Confirmed
            
            const product = await marketplace.products(1);
            expect(product.status).to.equal(STATUS.SOLD);
        });

        it("Refund Path: Seller refunds buyer", async function () {
            await expect(escrow.connect(seller).refund())
                .to.changeEtherBalance(buyer, PRICE);

            const product = await marketplace.products(1);
            expect(product.status).to.equal(STATUS.AVAILABLE);
            expect(product.escrowContract).to.equal(ethers.ZeroAddress);
        });

        it("Time Lock: Seller claims after timeout", async function () {
            // Attempt claim too early
            await expect(escrow.connect(seller).claimTimeout())
                .to.be.revertedWith("Too early to claim timeout");

            // Fast forward time
            await time.increase(LOCK_PERIOD + 100);

            const fee = (PRICE * FEE_PERCENT) / 100n;
            const sellerRevenue = PRICE - fee;

            await expect(escrow.connect(seller).claimTimeout())
                .to.changeEtherBalance(seller, sellerRevenue);
        });
    });

    describe("Access Control & Security", function () {
        it("Should prevent unauthorized cancellation", async function () {
            await marketplace.connect(seller).listProduct("Test Item", "Desc", PRICE);
            
            await expect(
                marketplace.connect(maliciousUser).cancelProduct(1)
            ).to.be.revertedWithCustomError(marketplace, "Unauthorized");
        });

        it("Should prevent unauthorized escrow interaction", async function () {
            await marketplace.connect(seller).listProduct("Test Item", "Desc", PRICE);
            await marketplace.connect(buyer).purchaseProduct(1, { value: PRICE });
            
            const product = await marketplace.products(1);
            const escrow = await escrowFactory.attach(product.escrowContract);

            await expect(
                escrow.connect(maliciousUser).confirmReceived()
            ).to.be.revertedWith("Only buyer can call this");
        });
    });

    describe("Admin Functions", function () {
        it("Should accumulate and withdraw platform fees", async function () {
            // Complete a trade to generate fees
            await marketplace.connect(seller).listProduct("Item", "Desc", PRICE);
            await marketplace.connect(buyer).purchaseProduct(1, { value: PRICE });
            
            const product = await marketplace.products(1);
            const escrow = await escrowFactory.attach(product.escrowContract);
            await escrow.connect(buyer).confirmReceived();

            const expectedFee = (PRICE * FEE_PERCENT) / 100n;

            await expect(marketplace.connect(deployer).withdrawFee())
                .to.changeEtherBalance(deployer, expectedFee);
        });
    });
});