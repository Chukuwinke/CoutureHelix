require("dotenv").config();
const { ethers } = require("hardhat");
const { DefenderRelayProvider, DefenderRelaySigner } = require("@openzeppelin/defender-relay-client/lib/ethers");

// Load ABIs
const forwarderArtifact = require("../artifacts/contracts/cMetatx/CustomERC2771ForwarderUpgradeable.sol/CustomERC2771ForwarderUpgradeable.json");
const forwarderABI = forwarderArtifact.abi;

const tokenArtifact = require("../artifacts/contracts/Token.sol/Token.json");
const tokenABI = tokenArtifact.abi;
const tokenInterface = new ethers.Interface(tokenABI);

async function main() {
  // 1. Set Up Defender
  const credentials = {
    apiKey: process.env.DEFENDER_API_KEY,
    apiSecret: process.env.DEFENDER_API_SECRET,
  };
  const defenderProvider = new DefenderRelayProvider(credentials);
  const relayerSigner = new DefenderRelaySigner(credentials, defenderProvider, { speed: "fast" });

  // 2. Contract Instances
  const forwarderAddress = process.env.FORWARDER_ADDRESS;
  const tokenAddress = process.env.TOKEN_ADDRESS;
  if (!forwarderAddress || !tokenAddress) {
    throw new Error("Missing contract addresses in .env");
  }
  const tokenContract = new ethers.Contract(tokenAddress, tokenABI, relayerSigner);
  const forwarderContract = new ethers.Contract(forwarderAddress, forwarderABI, defenderProvider).connect(relayerSigner);

  // 3. Verify Setup
  console.log("Relayer Address:", await relayerSigner.getAddress());
  console.log("Forwarder Relayer:", await forwarderContract.relayerAddress());

  // 4. Prepare Forward Request Data
  const testSender = process.env.TEST_SENDER;
  const recipientAddress = process.env.TEST_RECEIVER;
  const transferAmount = ethers.parseUnits("10", 18);
  const currentNonce = await forwarderContract.nonces(testSender);
  const innerData = tokenInterface.encodeFunctionData("transfer", [recipientAddress, transferAmount]);

  // 5. Calculate Reimbursement Costs
  // Create a JSON-RPC provider instance for estimation using testSender's context
  const jsonRpcProvider = new ethers.JsonRpcProvider(process.env.ALCHEMY_POLYGON_AMOY_URL);
  const network = await jsonRpcProvider.getNetwork();
  const feeData = await jsonRpcProvider.getFeeData();
  const gasPrice = feeData.gasPrice;
  const tokenToMaticRate = ethers.parseUnits("93870", 18);  // 1 token = 0.0001 MATIC

  // IMPORTANT: Use a new contract instance (without relayerSigner) for gas estimation
  const tokenForEstimation = new ethers.Contract(tokenAddress, tokenABI, jsonRpcProvider);
  let innerGasEstimateBN;
  try {
    innerGasEstimateBN = await tokenForEstimation.transfer.estimateGas(
      recipientAddress,
      transferAmount,
      { from: testSender }
    );
  } catch (error) {
    console.error("Inner transfer gas estimation failed, using fallback");
    innerGasEstimateBN = 50000n;
  }
  console.log("Inner gas estimate:", innerGasEstimateBN.toString());

  const gasCostInMatic = innerGasEstimateBN * gasPrice;
  // ccorrect calculation handle must match that in the solidity contract
  const reimbursementInTokens = (gasCostInMatic * tokenToMaticRate) / ethers.parseUnits("1", 18);
  const burnAmount = (reimbursementInTokens * 200n) / 10000n; // 2% burn
  const totalCost = reimbursementInTokens + burnAmount;

  console.log("Reimbursement Details:", {
    gasEstimate: innerGasEstimateBN.toString(),
    gasCostInMatic: ethers.formatUnits(gasCostInMatic),
    reimbursementInTokens: ethers.formatUnits(reimbursementInTokens),
    totalCost: ethers.formatUnits(totalCost),
  });

  // 6. EIP-712 Forward Request Signature
  const forwardRequest = {
    from: testSender,
    to: tokenAddress,
    value: 0,
    gas: innerGasEstimateBN.toString(),
    nonce: currentNonce.toString(),
    deadline: Math.floor(Date.now() / 1000) + 3600,
    data: innerData,
  };

  const domain = {
    name: "CustomERC2771ForwarderUpgradeable",
    version: "1",
    chainId: network.chainId,
    verifyingContract: forwarderAddress,
  };

  const types = {
    ForwardRequest: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "gas", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint48" },
      { name: "data", type: "bytes" },
    ],
  };

  const testSenderWallet = new ethers.Wallet(process.env.TEST_SENDER_PRIVATE_KEY, jsonRpcProvider);
  const metaSignature = await testSenderWallet.signTypedData(domain, types, forwardRequest);

  // 7. ERC-2612 Permit Signature
  const permitDeadline = Math.floor(Date.now() / 1000) + 4600;
  const permitNonce = await tokenContract.nonces(testSender);
  const tokenDomain = {
    name: "JTestToken", // MUST match token.name()
    version: "1",
    chainId: network.chainId,
    verifyingContract: tokenAddress,
  };

  const permitTypes = {
    Permit: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };

  const permitMessage = {
    owner: testSender,
    spender: forwarderAddress,
    value: totalCost.toString(),
    nonce: Number(permitNonce),
    deadline: permitDeadline,
  };

  const permitSignature = await testSenderWallet.signTypedData(tokenDomain, permitTypes, permitMessage);
  const { v, r, s } = ethers.Signature.from(permitSignature);

  // 8. Final Gas Estimation for the Full Transaction
  try {
    const fullGasEstimateBN = await forwarderContract
      .getFunction("executeWithPermitAndReimbursement")
      .estimateGas(
        [
          forwardRequest.from,
          forwardRequest.to,
          forwardRequest.value.toString(),
          forwardRequest.gas,
          forwardRequest.deadline,
          forwardRequest.data,
          metaSignature,
        ],
        innerGasEstimateBN.toString(),
        gasPrice.toString(),
        tokenToMaticRate.toString(),
        permitDeadline,
        v,
        r,
        s,
        {
          gasLimit: 500000, // Buffer for complex logic
          from: await relayerSigner.getAddress(),
        }
      );
    console.log("Final Gas Estimate:", fullGasEstimateBN.toString());
  } catch (error) {
    console.error("Final gas estimation failed:", error);
    if (error?.error?.data) {
      const revertData = error.error.data;
      try {
        const reason = ethers.AbiCoder.defaultAbiCoder().decode(
          ["string"],
          "0x" + revertData.slice(10)
        );
        console.log("Revert Reason:", reason[0]);
      } catch {
        console.log("Raw Revert Data:", revertData);
      }
    }
    process.exit(1);
  }
}

main().catch(console.error);
