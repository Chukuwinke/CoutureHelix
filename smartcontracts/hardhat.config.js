require("@nomicfoundation/hardhat-toolbox");
require("hardhat-gas-reporter");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.27",
  gasReporter: {
    enabled: true,
    currency: "USD",
    gasPrice: 100, // Adjust this to your desired gas price in gwei
    coinmarketcap: process.env.CMC, // Optional for USD conversion
    outputFile: "./gasTest/gas-report.txt", // Optional: Save results to a file
    noColors: true, // Disable colors in report output
 },
  networks: {
    hardhat: {},
    sepolia: {
      url: process.env.ALCHEMY_SEPOLIA_URL,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 11155111,
    },
  },
};
