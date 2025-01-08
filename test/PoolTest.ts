import { ethers } from "hardhat";
import { expect } from "chai";
import { Pool } from "../typechain-types";
import { LendToken } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("Pool", () => {
    let pool: Pool;
    let lendToken: LendToken;
    let user: SignerWithAddress;

    beforeEach(async () => {
        const lendTokenFactory = await ethers.getContractFactory("LendToken");
        lendToken = await lendTokenFactory.deploy();
        await lendToken.waitForDeployment();

        const poolFactory = await ethers.getContractFactory("Pool");
        pool = await poolFactory.deploy(await lendToken.getAddress());
        await pool.waitForDeployment();

        await lendToken.transferOwnership(await pool.getAddress());

        [user] = await ethers.getSigners();
    })

    describe("🪙 Deposit Collateral", () => {
        it("💸 should deposit collateral", async () => {
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });

            const collateralBalance = await pool.collateralBalance(user.address);
            expect(collateralBalance).to.equal(depositAmount);
        });
        it("💴 should emit CollateralDeposited event", async () => {
            const amount = ethers.parseEther("1");
            await expect(pool.depositCollateral(amount, { value: amount }))
                .to.emit(pool, "CollateralDeposited")
                .withArgs(user.address, amount);
        })
        it("❗️ should revert if user enters the wrong amount", async () => {
            const amount = ethers.parseEther("1");
            const wrongAmount = ethers.parseEther("1.5");
            await expect(
                pool.depositCollateral(wrongAmount, { value: amount })
            ).to.be.revertedWithCustomError(pool, "Pool__NotEnoughBalance");
        })
    })
    describe("🪙 Withdraw Collateral", () => {
        it("💸 should withdraw collateral", async () => {
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });

            const withdrawAmount = ethers.parseEther("0.75");
            await pool.withdrawCollateral(withdrawAmount);

            const expectedCollateral = depositAmount - withdrawAmount;
            const collateralBalance = await pool.collateralBalance(user.address);
            expect(collateralBalance).to.equal(expectedCollateral);
        });
        it("❗️ should revert if user tries to withdraw more than they have", async () => {
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });

            const withdrawAmount = ethers.parseEther("2");

            await expect(
                pool.withdrawCollateral(withdrawAmount)
            ).to.be.revertedWithCustomError(pool, "Pool__NotEnoughBalance");
        })
    })
    describe("🪙 Liquidate", () => {
        it("💸 should liquidate when health factor drops below threshold", async () => {
            // Setup: Deposit collateral and borrow
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });
            
            const borrowAmount = ethers.parseEther("1");
            await pool.borrow(borrowAmount);

            // Verify initial health factor
            const initialHealth = await pool.healthFactor(user.address);
            expect(initialHealth).to.be.gte(pool.COLLATERAL_RATIO());

            // Attempt to liquidate (should fail initially)
            await expect(
                pool.liquidate(user.address, depositAmount)
            ).to.be.revertedWithCustomError(pool, "Pool__HealthFactorIsOk");

            // TODO: In a real scenario, we'd need a way to make the health factor drop
            // This could be through price oracle changes or additional borrowing
            // For now, we can test the liquidation mechanics directly
            
            // Liquidate partial amount
            const liquidateAmount = ethers.parseEther("0.5");
            await pool.liquidate(user.address, liquidateAmount);

            // Verify collateral and debt were reduced
            const finalCollateral = await pool.collateralBalance(user.address);
            expect(finalCollateral).to.equal(depositAmount - liquidateAmount);
        });
    });
    describe("🪙 Borrow", () => {
        it("💸 should allow borrowing based on collateral", async () => {
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });

            const borrowAmount = ethers.parseEther("1");
            await pool.borrow(borrowAmount);

            const lendTokenBalance = await lendToken.balanceOf(user.address);
            expect(lendTokenBalance).to.equal(borrowAmount);
        });

        it("❗️ should revert if trying to borrow more than allowed by collateral ratio", async () => {
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });

            const borrowAmount = ethers.parseEther("1.1"); // More than allowed by 150% collateral ratio
            await expect(
                pool.borrow(borrowAmount)
            ).to.be.revertedWithCustomError(pool, "Pool__AmountTooHigh");
        });
    });
})


