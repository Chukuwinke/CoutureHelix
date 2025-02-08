const { ethers, upgrades } = require("hardhat");

async function main() {
  const Token = await ethers.getContractFactory("Token");

  // Addresses
  const multisigAdminAddress = "0xB71aD5938e315182c25dfE87F636594a00f03e1e"; // Replace with your multisig wallet address
  const minterAddress = "0xD9e2d04435b2c12B5bDA262328A58C98aacc2672";          // Replace with MetaMask Account 1
  const upgraderAddress = "0xaF8D2D801A16576A1b3470836642b2499DC4ffA7";        // Replace with MetaMask Account 2

  // Initial Supply: 100 billion tokens (10^18 decimals)
  const initialSupply = ethers.parseUnits("100000000000", 18);

  // Cap: 100 billion tokens
  const cap = ethers.parseUnits("100000000000", 18);

  console.log("Deploying Token contract...");

  const token = await upgrades.deployProxy(
    Token,
    [
      "FashionDNA",  // Name
      "FDNA",            // Symbol
      initialSupply,    // Initial Supply
      cap,              // Cap
      multisigAdminAddress,
      minterAddress,
      upgraderAddress
    ],
    { initializer: "initialize" }
  );

  await token.waitForDeployment();
  console.log("Token deployed to:", await token.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
