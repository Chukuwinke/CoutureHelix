require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

// Load the forwarder artifact and extract its ABI.
const forwarderArtifact = require("../artifacts/contracts/cMetatx/CustomERC2771ForwarderUpgradeable.sol/CustomERC2771ForwarderUpgradeable.json");
const forwarderABI = forwarderArtifact.abi;
const forwarderInterface = new ethers.Interface(forwarderABI);

// Load the token artifact and extract its ABI.
const tokenArtifact = require("../artifacts/contracts/Token.sol/Token.json");
const tokenABI = tokenArtifact.abi;
const tokenInterface = new ethers.Interface(tokenABI);

async function main() {
  // -------------------------------
  // 1. Generate Inner Call Data
  // -------------------------------
  const recipientAddress = process.env.TEST_RECEIVER || "0xRecipientAddress";
  const transferAmount = ethers.parseUnits("10", 18); // Transfer 10 tokens
  const innerData = tokenInterface.encodeFunctionData("transfer", [recipientAddress, transferAmount]);
  console.log("Inner Call Data:", innerData);

  // -------------------------------
  // 2. Build the Meta-Transaction Request Object as an Object
  // -------------------------------
  // Our Solidity struct (inside executeWithReimbursment) is:
  // struct ForwardRequestData {
  //   address from;
  //   address to;
  //   uint256 value;
  //   uint256 gas;
  //   uint256 nonce;
  //   uint48 deadline;
  //   bytes data;
  //   bytes signature;
  // }
  const forwardRequestObj = {
    from: process.env.TEST_SENDER || ethers.constants.AddressZero,
    to: process.env.TOKEN_ADDRESS || ethers.constants.AddressZero,
    value: 0n,
    gas: 50000n,
    nonce: 1n, // Use a BigInt for nonce
    deadline: Math.floor(Date.now() / 1000) + 3600, // Pass as a plain number
    data: innerData,
    signature: "0x" // Empty signature
  };
  console.log("Forward Request Object:", forwardRequestObj);

  // -------------------------------
  // 3. Define Reimbursement Parameters
  // -------------------------------
  const gasUsed = 50000n; // as BigInt
  const gasPriceInMatic = ethers.parseUnits("1", "gwei"); // as BigInt
  const tokenToMaticRate = ethers.parseUnits("1", 30);     // as BigInt

  // -------------------------------
  // 4. Outer Encoding: Encode the Forwarder's executeWithReimbursment Call
  // -------------------------------
  const functionName = "executeWithReimbursment"; // Must match ABI exactly
  const outerData = forwarderInterface.encodeFunctionData(functionName, [
    forwardRequestObj,
    gasUsed,
    gasPriceInMatic,
    tokenToMaticRate
  ]);
  console.log("Outer Encoded Data:", outerData);

  // -------------------------------
  // 5. Build the JSON-RPC Payload for Postman
  // -------------------------------
  const defenderRelayerAddress = process.env.DEFENDER_RELAYER_ADDRESS || ethers.constants.AddressZero;
  const forwarderContractAddress = process.env.FORWARDER_ADDRESS || ethers.constants.AddressZero;
  
  const payload = {
    jsonrpc: "2.0",
    method: "eth_sendTransaction",
    params: [{
      from: defenderRelayerAddress,
      to: forwarderContractAddress,
      data: outerData,
      gas: "0xC350",         // Hex for 50000
      gasPrice: "0x3B9ACA00", // Hex for 1 gwei
      value: "0x0"
    }],
    id: 1
  };

  console.log("Generated JSON-RPC Payload:\n", JSON.stringify(payload, null, 2));
  
  const filePath = path.join(__dirname, "../payload.json");
  fs.writeFileSync(
    filePath,
    JSON.stringify(payload, (_, value) => typeof value === "bigint" ? value.toString() : value, 2)
  );
  console.log("Payload saved to", filePath);
}

main().catch(console.error);
