import { ethers } from "hardhat";

const ETH_AMOUNT = ethers.parseEther("10");
// Adjust to a more conservative amount: 10 ETH collateral should allow ~6.66 ETH borrow at 150%
const BORROW_AMOUNT = ethers.parseEther("5"); // Try borrowing less to ensure health factor stays good

async function main() {
    const [deployer] = await ethers.getSigners();

    const lendToken = await ethers.deployContract("LendToken");
    await lendToken.waitForDeployment();
    console.log(` 💰 LendToken deployed to: ${await lendToken.getAddress()}`);

    const mintTx = await lendToken.mint(deployer.address, ETH_AMOUNT);
    await mintTx.wait()
    console.log(` 💰 Minted ${ETH_AMOUNT} to ${deployer.address}`);

    const pool = await ethers.deployContract("Pool", [await lendToken.getAddress()]);
    await pool.waitForDeployment();
    console.log(` 💰 Pool deployed to: ${await pool.getAddress()}`);

    await lendToken.transferOwnership(await pool.getAddress());
    console.log(" 🔑 LendToken ownership transferred to Pool");

    const depositCollateralTx = await pool.depositCollateral(ETH_AMOUNT, {
        value: ETH_AMOUNT
    });
    await depositCollateralTx.wait();
    console.log(` 💰 Deposited ${ETH_AMOUNT} collateral to Pool`);

    const borrowTx = await pool.borrow(BORROW_AMOUNT);
    await borrowTx.wait();
    console.log(` 💸 Borrowed ${BORROW_AMOUNT} from Pool`);


    const utilization = Math.floor((Number(BORROW_AMOUNT) * 100) / Number(ETH_AMOUNT));
    const interest = await pool.calculateInterest(utilization);
    console.log(` 📈 Calculated interest rate for ${utilization}% utilization: ${interest}%`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
