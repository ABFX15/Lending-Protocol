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
        it("💸 should liquidate collateral and burn lendToken", async () => {
            const depositAmount = ethers.parseEther("1.5");
            await pool.depositCollateral(depositAmount, { value: depositAmount });

            const borrowAmount = ethers.parseEther("1");

        })
    })
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
    describe("🪙 Interest", () => {
        it("💸 should calculate interest based on utilization", async () => {
            const utilization = 50; // 50%
            const expectedInterest = await pool.calculateInterest(utilization);
            expect(expectedInterest).to.equal(4); // BASE_RATE(2) + (50 * SLOPE1(4)) / 100 = 4
        })
    })
    describe("🪙 Interest Rate", () => {
        it("💸 should calculate correct interest for any utilization", async () => {
            for (let i = 0; i < 100; i++) {
                const utilization = Math.floor(Math.random() * 101); // 0 to 100
                const interest = await pool.calculateInterest(utilization);

                // Calculate expected interest with integer math
                let expectedInterest;
                if (utilization <= 80) {
                    expectedInterest = BigInt(2 + Math.floor((utilization * 4) / 100));
                } else {
                    // BASE_RATE + (OPTIMAL_UTIL * SLOPE1) / PRECISION + ((utilization - OPTIMAL_UTIL) * SLOPE2) / PRECISION
                    expectedInterest = BigInt(
                        2 + // BASE_RATE
                        Math.floor((80 * 4) / 100) + // First slope until optimal
                        Math.floor(((utilization - 80) * 75) / 100) // Second slope after optimal
                    );
                }

                expect(interest).to.equal(expectedInterest);
                expect(Number(interest)).to.be.gte(2);
                if (utilization === 0) expect(interest).to.equal(2n);
                if (utilization === 100) expect(interest).to.equal(20n);
            }
        });

        it("❗️ should maintain rate curve properties", async () => {
            const lowUtil = Number(await pool.calculateInterest(10));
            const optimalUtil = Number(await pool.calculateInterest(80));
            const highUtil = Number(await pool.calculateInterest(90));

            // Rate should increase more steeply after optimal utilization
            const lowSlope = (optimalUtil - lowUtil) / 70;
            const highSlope = (highUtil - optimalUtil) / 10;
            expect(highSlope).to.be.gt(lowSlope);
        });
    });
})


