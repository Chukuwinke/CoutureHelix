require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { ethers } = require("hardhat");

// Load the forwarder artifact and extract its ABI.
const forwarderArtifact = require("../artifacts/contracts/cMetatx/CustomERC2771ForwarderUpgradeable.sol/CustomERC2771ForwarderUpgradeable.json");
const forwarderABI = forwarderArtifact.abi;
const forwarderInterface = new ethers.Interface(forwarderABI);

// Load the token artifact and extract its ABI.
const tokenArtifact = require("../artifacts/contracts/Token.sol/Token.json");
const tokenABI = tokenArtifact.abi;
const tokenInterface = new ethers.Interface(tokenABI);

async function main() {
  // --- 1. Generate Inner Call Data ---
  const recipientAddress = process.env.TEST_RECEIVER || "0xRecipientAddress";
  const transferAmount = ethers.parseUnits("10", 18); // Transfer 10 tokens
  const innerData = tokenInterface.encodeFunctionData("transfer", [recipientAddress, transferAmount]);
  console.log("Inner Call Data:", innerData);

  // --- 2. Retrieve the current nonce from the deployed forwarder ---
  const forwarderAddress = process.env.FORWARDER_ADDRESS;
  if (!forwarderAddress) {
    throw new Error("FORWARDER_ADDRESS must be defined in .env");
  }
  const forwarderContract = new ethers.Contract(forwarderAddress, forwarderABI, ethers.provider);
  const currentNonce = await forwarderContract.nonces(process.env.TEST_SENDER);
  console.log("Current nonce for TEST_SENDER:", currentNonce.toString());

  // --- 3. Build the Meta-Transaction Request Object ---
  const forwardRequest = {
    from: process.env.TEST_SENDER || ethers.constants.AddressZero,
    to: process.env.TOKEN_ADDRESS || ethers.constants.AddressZero,
    value: 0,
    gas: 50000,
    nonce: currentNonce.toString(), // use the fetched nonce
    deadline: Math.floor(Date.now() / 1000) + 3600, // Valid for 1 hour
    data: innerData
    // signature will be added below
  };
  console.log("Forward Request Object (without signature):", forwardRequest);

  // --- 4. Define the EIP‑712 Domain and Types ---
  const network = await ethers.provider.getNetwork();
  const chainId = network.chainId;
  const domain = {
    name: "CustomERC2771ForwarderUpgradeable",
    version: "1",
    chainId: chainId,
    verifyingContract: forwarderAddress
  };

  const types = {
    ForwardRequest: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "gas", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint48" },
      { name: "data", type: "bytes" }
    ]
  };

  // --- 5. Generate the Signature using ethers v6 method ---
  const testSenderSigner = await ethers.getSigner(process.env.TEST_SENDER);
  const signature = await testSenderSigner.signTypedData(domain, types, forwardRequest);
  console.log("Generated Signature:", signature);
  forwardRequest.signature = signature;
  console.log("Forward Request Object (with signature):", forwardRequest);

  // --- 6. Define Reimbursement Parameters ---
  const gasUsed = 50000;
  const gasPriceInMatic = ethers.parseUnits("1", "gwei");
  const tokenToMaticRate = ethers.parseUnits("1", 30);

  // --- 7. Outer Encoding: Encode the Forwarder's executeWithReimbursment Call ---
  const outerData = forwarderInterface.encodeFunctionData("executeWithReimbursment", [
    forwardRequest,
    gasUsed,
    gasPriceInMatic,
    tokenToMaticRate
  ]);
  console.log("Outer Encoded Data:", outerData);

  // --- 8. Build the JSON-RPC Payload for Postman/Defender Relayer ---
  const defenderRelayerAddress = process.env.DEFENDER_RELAYER_ADDRESS || ethers.constants.AddressZero;
  const payload = {
    jsonrpc: "2.0",
    method: "eth_sendTransaction",
    params: [{
      from: defenderRelayerAddress,
      to: forwarderAddress,
      data: outerData,
      gas: "0xC350",         // Hex for 50000
      gasPrice: "0x3B9ACA00", // Hex for 1 gwei
      value: "0x0"
    }],
    id: 1
  };

  console.log("Generated JSON-RPC Payload:\n", JSON.stringify(payload, null, 2));

  // --- 9. Optionally, Save the Payload to a File ---
  const filePath = path.join(__dirname, "../payload.json");
  fs.writeFileSync(filePath, JSON.stringify(payload, null, 2));
  console.log("Payload saved to", filePath);
}

main().catch(console.error);
