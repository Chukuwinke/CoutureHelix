const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy CoutureHelixToken contract
  const CoutureHelixToken = await ethers.getContractFactory("CoutureHelixToken");
  const initialAdminWallet = deployer.address; // Replace with your admin wallet address if needed
  const rewardToken = await CoutureHelixToken.deploy(initialAdminWallet);
  await rewardToken.deployed();

  console.log("CoutureHelixToken deployed to:", rewardToken.address);

  // Mint some initial tokens to the deployer's wallet (optional)
  const initialMintAmount = ethers.utils.parseEther("100000");
  await rewardToken.mintToAdmin(initialMintAmount);
  console.log(`Minted ${ethers.utils.formatEther(initialMintAmount)} CHTK to admin wallet.`);

  // Deploy FashionDNA contract
  const FashionDNA = await ethers.getContractFactory("FashionDNA");
  const backendAddress = deployer.address; // Replace with your backend wallet address if needed
  const fashionDNA = await FashionDNA.deploy(rewardToken.address, backendAddress);
  await fashionDNA.deployed();

  console.log("FashionDNA contract deployed to:", fashionDNA.address);

  // Grant the FashionDNA contract an allowance to distribute rewards (optional for testing)
  const rewardAllowance = ethers.utils.parseEther("100000");
  await rewardToken.approve(fashionDNA.address, rewardAllowance);
  console.log(`Approved ${ethers.utils.formatEther(rewardAllowance)} CHTK for FashionDNA contract.`);

  // Example: Distribute some tokens for testing
  const testRecipient = deployer.address; // Replace with another address if needed
  const testRewardAmount = ethers.utils.parseEther("1000");
  await rewardToken.distributeReward(testRecipient, testRewardAmount);
  console.log(`Distributed ${ethers.utils.formatEther(testRewardAmount)} CHTK to ${testRecipient}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
