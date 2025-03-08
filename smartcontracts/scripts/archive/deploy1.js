const fs = require("fs");
const path = require("path");
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  // Get signers and use .getAddress() to obtain the actual addresses.
  const admin = process.env.ADMIN_ADDRESS;
  const minter = process.env.MINTER_ADDRESS;
  const upgrader = process.env.UPGRADER_ADDRESS;
  const backend = process.env.BACKEND_ADDRESS;
  const defenderRelayer = process.env.DEFENDER_RELAYER_ADDRESS;

  // ----------------------------
  // 1. Deploy RoleManager
  // ----------------------------
  const RoleManagerFactory = await ethers.getContractFactory("RoleManager");
  const roleManager = await upgrades.deployProxy(RoleManagerFactory, [admin], { initializer: "initialize" });
  await roleManager.waitForDeployment()
  console.log("RoleManager deployed to:", await roleManager.getAddress());

  // Grant roles to designated accounts via RoleManager.
  await roleManager.connect(await ethers.getSigner(admin)).grantRole(await roleManager.MINTER_ROLE(), minter);
  await roleManager.connect(await ethers.getSigner(admin)).grantRole(await roleManager.UPGRADER_ROLE(), upgrader);
  await roleManager.connect(await ethers.getSigner(admin)).grantRole(await roleManager.BACKEND_ROLE(), backend);
  console.log("Roles granted in RoleManager.");

  // ----------------------------
  // 2. Deploy CustomERC2771ForwarderUpgradeable
  // ----------------------------
  const burnPercentage = 1000; // 10% fee when SCALE is 10000.
  const ForwarderFactory = await ethers.getContractFactory("CustomERC2771ForwarderUpgradeable");
  // Here we pass a dummy token address (ethers.constants.AddressZero) since token isn't deployed yet.
  // The initializer signature is: initialize(string,address,uint256,address)
  const forwarder = await upgrades.deployProxy(
    ForwarderFactory,
    ["CustomERC2771ForwarderUpgradeable", ethers.ZeroAddress, burnPercentage, defenderRelayer],
    { initializer: "initialize(string,address,uint256,address)" }
  );
  await forwarder.waitForDeployment();
  console.log("CustomERC2771ForwarderUpgradeable deployed to:", await forwarder.getAddress());

  // ----------------------------
  // 3. Deploy Token Contract
  // ----------------------------
  // Token initializer: initialize(string, string, uint256, uint256, address, address)
  const tokenName = "MTestToken";
  const tokenSymbol = "MTST";
  const initialSupply = ethers.parseUnits("1000000", 18); // 1,000,000 tokens
  const cap = ethers.parseUnits("2000000", 18); // 2,000,000 tokens
  const TokenFactory = await ethers.getContractFactory("Token");
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
  // Set the trusted forwarder in the Token contract.
  await token.connect(await ethers.getSigner(admin)).setTrustedForwarder(await forwarder.getAddress());
  // Update the forwarder with the token address.
  await forwarder.connect(await ethers.getSigner(admin)).setTokenAddress(await token.getAddress());
  // Set the RoleManager in the Token contract.
  await token.connect(await ethers.getSigner(admin)).setRoleManager(await roleManager.getAddress());
  console.log("Contracts wired together (trusted forwarder and role manager set).");

  // ----------------------------
  // 6. Save Deployment Data to File
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
      // Defender Relayer credentials (ID, API key, secret) are managed off-chain.
      defenderRelayer: {
        note: "Use your Defender Relayer API endpoint with your API key/secret. These credentials are set in Defender’s dashboard and are not part of the contract parameters."
      },
      frontend: {
        tokenAddress: (await token.getAddress()),
        forwarderAddress: (await forwarder.getAddress()),
        roleManagerAddress: (await roleManager.getAddress()),
        chainId: network.chainId,
        note: "Use the ABIs from the build artifacts for interacting with these contracts."
      },
      postman: {
        note: "For testing via JSON-RPC, use the Defender Relayer API endpoint (provided in Defender’s dashboard) with your API key/secret for eth_sendTransaction calls. See Defender documentation."
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
