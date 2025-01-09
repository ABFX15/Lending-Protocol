import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-deploy";
import "solidity-coverage";

const config: HardhatUserConfig = {
  solidity: "0.8.28",
};

export default config;
