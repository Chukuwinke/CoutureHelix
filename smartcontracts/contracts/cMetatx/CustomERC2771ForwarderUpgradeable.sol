// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../interfaces/ICustomToken.sol";
import "hardhat/console.sol";

contract CustomERC2771ForwarderUpgradeable is ERC2771ForwarderUpgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
    uint256 public burnPercentage;
    uint256 public constant SCALE = 10000;
    address public tokenAddress;
    // Separate relayer address for reimbursement.
    address public relayerAddress;

    // Modifier to restrict calls to the designated relayer.
    modifier onlyRelayer() {
        require(msg.sender == relayerAddress, "Not authorized: relayer only");
        _;
    }
    
    /**
     * @dev Initializes the contract.
     * @param name The name for ERC2771Forwarder.
     * @param _tokenAddress The token address (should be set to the proxy address).
     * @param _burnPercentage The burn fee percentage (with SCALE=10000).
     * @param _admin The multisig admin (owner) who controls administrative functions.
     * @param _relayer The relayer address that will receive reimbursements.
     */
    function initialize(
        string memory name,
        address _tokenAddress,
        uint256 _burnPercentage,
        address _admin,
        address _relayer
    ) public virtual initializer {
        __ERC2771Forwarder_init(name);
        __ReentrancyGuard_init();
        __Ownable_init(_admin);
        tokenAddress = _tokenAddress;
        burnPercentage = _burnPercentage;
        relayerAddress = _relayer;
    }

    // Setter to update the token address if needed.
    function setTokenAddress(address _tokenAddress) public onlyOwner {
        require(_tokenAddress != address(0), "Token address cannot be zero");
        tokenAddress = _tokenAddress;
    }
    
    // Setter to update the relayer address.
    function setRelayerAddress(address _relayer) public onlyOwner {
        require(_relayer != address(0), "Relayer address cannot be zero");
        relayerAddress = _relayer;
    }
    
    /**
     * @dev Executes a meta-transaction with an off-chain permit for reimbursement.
     * The permit is used to approve the forwarder to transfer the reimbursement amount from the user.
     * After executing the meta-transaction, the forwarder deducts the reimbursement (plus burn fee)
     * from the user via transferFrom and transfers the reimbursement amount to the relayer.
     * This function is callable only by the designated relayer.
     */
    function executeWithPermitAndReimbursment(
        ForwardRequestData calldata request,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable nonReentrant onlyRelayer {
        // Check that the attached value matches what is expected.
        if (msg.value != request.value) {
            revert ERC2771ForwarderMismatchedValue(request.value, msg.value);
        }
        
        // --- Compute reimbursement values ---
        uint256 gasCostInMatic = gasUsed * gasPriceInMatic;
        uint256 reimbursementInTokens = (gasCostInMatic * 1e18) / tokenToMaticRate;
        uint256 burnAmount = (reimbursementInTokens * burnPercentage) / SCALE;
        uint256 totalCost = reimbursementInTokens + burnAmount;
        
        console.log("reached start !");
        
        // --- Approve spending via permit ---
        // This call gives the forwarder (this contract) the approval to spend totalCost tokens on behalf of request.from.
        ICustomToken(tokenAddress).permit(
            request.from,
            address(this),
            totalCost,
            permitDeadline,
            v,
            r,
            s
        );
        console.log("reached 1 !");
        
        // --- Execute the forwarded meta-transaction ---
        // Here we encode the call to execute() (which is inherited from ERC2771ForwarderUpgradeable)
        // and explicitly append the original sender (request.from) so that the target contract’s custom _msgSender()
        // returns the correct user address.
        bytes memory execCalldata = abi.encodeWithSelector(this.execute.selector, request);
        execCalldata = abi.encodePacked(execCalldata, request.from);
        (bool execSuccess, ) = address(this).call{ value: request.value }(execCalldata);
        require(execSuccess, "Forwarded call failed");
        
        // --- Perform reimbursement transfer ---
        // Since the token contract’s trusted forwarder is set to this contract and the permit approved spending,
        // we now call transferFrom in a standard way to pull totalCost tokens from request.from.
        require(
            ICustomToken(tokenAddress).transferFrom(request.from, address(this), totalCost),
            "Token transfer failed"
        );
        console.log("reached 2 !");
        
        // --- Burn tokens ---
        if (burnAmount > 0) {
            ICustomToken(tokenAddress).burn(burnAmount);
        }
        console.log("reached 3 !");
        
        // --- Reimburse the relayer ---
        if (reimbursementInTokens > 0) {
            require(
                ICustomToken(tokenAddress).transfer(relayerAddress, reimbursementInTokens),
                "Transfer to relayer failed"
            );
        }
        console.log("finished !");

    }

    



    
    // Withdraw function remains unchanged.
    function withdrawReimbursementTokens(address recipient, uint256 amount) public onlyOwner {
        uint256 forwarderBalance = ICustomToken(tokenAddress).balanceOf(address(this));
        require(forwarderBalance >= amount, "Insufficient forwarder balance for withdrawal");
        
        require(
            ICustomToken(tokenAddress).transfer(recipient, amount),
            "Transfer to recipient failed"
        );
    }
}
