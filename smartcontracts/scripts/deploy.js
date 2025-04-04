const fs = require("fs");
const path = require("path");
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  // Retrieve environment variables.
  const admin = process.env.ADMIN_ADDRESS;
  const minter = process.env.MINTER_ADDRESS;
  const upgrader = process.env.UPGRADER_ADDRESS;
  const backend = process.env.BACKEND_ADDRESS;
  const relayer = process.env.DEFENDER_RELAYER_ADDRESS; // dedicated relayer address

  if (!admin || !minter || !upgrader || !backend || !relayer) {
    throw new Error("One or more required environment variables are missing.");
  }

  // ----------------------------
  // 1. Deploy RoleManager
  // ----------------------------
  const RoleManagerFactory = await ethers.getContractFactory("RoleManager");
  const roleManager = await upgrades.deployProxy(RoleManagerFactory, [admin], { initializer: "initialize" });
  await roleManager.waitForDeployment();
  console.log("RoleManager deployed to:", await roleManager.getAddress());

  // Grant roles via RoleManager.
  await roleManager.connect(await ethers.getSigner(admin)).grantRole(await roleManager.MINTER_ROLE(), minter);
  await roleManager.connect(await ethers.getSigner(admin)).grantRole(await roleManager.UPGRADER_ROLE(), upgrader);
  await roleManager.connect(await ethers.getSigner(admin)).grantRole(await roleManager.BACKEND_ROLE(), backend);
  console.log("Roles granted in RoleManager.");

  // ----------------------------
  // 2. Deploy the Forwarder Contract
  // ----------------------------
  // We deploy the forwarder with a dummy token address (ZeroAddress) first.
  // The initializer now takes two addresses: _admin and _relayer.
  const burnPercentage = 200; // 2% fee with SCALE = 10000 = 100%.
  const ForwarderFactory = await ethers.getContractFactory("CustomERC2771ForwarderUpgradeable");
  const forwarder = await upgrades.deployProxy(
    ForwarderFactory,
    ["CustomERC2771ForwarderUpgradeable", ethers.ZeroAddress, burnPercentage, admin, relayer],
    { initializer: "initialize(string,address,uint256,address,address)" }
  );
  await forwarder.waitForDeployment();
  console.log("CustomERC2771ForwarderUpgradeable deployed to:", await forwarder.getAddress());

  // ----------------------------
  // 3. Deploy the Token Contract
  // ----------------------------
  const tokenName = "JTestToken";
  const tokenSymbol = "JTST";
  const initialSupply = ethers.parseUnits("1000000", 18); // 1,000,000 tokens
  const cap = ethers.parseUnits("2000000", 18); // 2,000,000 tokens
  const TokenFactory = await ethers.getContractFactory("Token");
  // Pass the forwarder's proxy address as the trusted forwarder.
  const token = await upgrades.deployProxy(
    TokenFactory,
    [tokenName, tokenSymbol, initialSupply, cap, admin, await forwarder.getAddress()],
    { initializer: "initialize" }
  );
  await token.waitForDeployment();
  console.log("Token deployed to:", await token.getAddress());

  // ----------------------------
  // 4. Wire Contracts Together
  // ----------------------------
  // Set the trusted forwarder in the token contract.
  await token.connect(await ethers.getSigner(admin)).setTrustedForwarder(await forwarder.getAddress());
  // Update the forwarder with the token address.
  await forwarder.connect(await ethers.getSigner(admin)).setTokenAddress(await token.getAddress());
  // Set the RoleManager in the token contract.
  await token.connect(await ethers.getSigner(admin)).setRoleManager(await roleManager.getAddress());
  console.log("Contracts wired together (trusted forwarder and role manager set).");

  // ----------------------------
  // 5. Save Deployment Data to File
  // ----------------------------
  const network = await ethers.provider.getNetwork();
  const deploymentData = {
    chainId: network.chainId,
    network: network.name,
    roleManager: await roleManager.getAddress(),
    token: await token.getAddress(),
    forwarder: await forwarder.getAddress(),
    trustedForwarder: (await token.trustedForwarder()) || (await forwarder.getAddress()),
    instructions: {
      defenderRelayer: {
        note: "Use your Defender Relayer API endpoint with your API key/secret. These credentials are managed off-chain."
      },
      frontend: {
        tokenAddress: await token.getAddress(),
        forwarderAddress: await forwarder.getAddress(),
        roleManagerAddress: await roleManager.getAddress(),
        chainId: network.chainId,
        note: "Use the ABIs from the build artifacts for interacting with these contracts."
      },
      postman: {
        note: "For JSON-RPC testing, use the Defender Relayer API endpoint with your API key/secret."
      }
    }
  };

  const filePath = path.join(__dirname, "../deployed_contracts.json");
  fs.writeFileSync(
    filePath,
    JSON.stringify(
      deploymentData,
      (_, value) => typeof value === 'bigint' ? value.toString() : value,
      2
    )
  );
  
  console.log("Deployment data saved to", filePath);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
