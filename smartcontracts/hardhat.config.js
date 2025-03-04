require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades"); // Remove this line
require("hardhat-gas-reporter");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.27", // Match your Solidity version
    settings: {
      optimizer: {
        enabled: true,
        runs: 200, // Adjust this value based on your use case
      },
      viaIR: true,
    },
  },
  gasReporter: {
    enabled: true,
    currency: "USD",
    gasPrice: 200, // Adjust this to your desired gas price in gwei
    token: "pol",
    coinmarketcap: process.env.CMC, // Optional for USD conversion
    outputFile: "./gasTest/gas-report.txt", // Optional: Save results to a file
    noColors: true, // Disable colors in report output
 },
  networks: {
    hardhat: {},
    polygonAmoy: {
      url: process.env.ALCHEMY_POLYGON_AMOY_URL,
      accounts: [
        process.env.ALCHEMY_PRIVATE_KEY,
        process.env.TEST_SENDER_PRIVATE_KEY
      ],
    },
    sepolia: {
      url: process.env.ALCHEMY_SEPOLIA_URL,
      accounts: [process.env.ALCHEMY_PRIVATE_KEY],
      chainId: 11155111,
    },
  },
};
