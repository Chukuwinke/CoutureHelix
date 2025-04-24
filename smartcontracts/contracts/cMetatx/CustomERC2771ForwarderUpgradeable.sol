// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../access/AccessControlledUpgradeable.sol";
import "../interfaces/ICustomToken.sol";

/**
 * @title CustomERC2771ForwarderUpgradeable
 * @notice Enables meta-transaction execution with off-chain permit approval and token reimbursement.
 * @dev Inherits from ERC2771ForwarderUpgradeable, ReentrancyGuardUpgradeable, and AccessControlledUpgradeable.
 */
contract CustomERC2771ForwarderUpgradeable is ERC2771ForwarderUpgradeable, ReentrancyGuardUpgradeable, AccessControlledUpgradeable {
    uint256 public burnPercentage;
    uint256 public constant SCALE = 10000;
    address public tokenAddress;
    address public relayerAddress;

    event RelayerChanged(address indexed oldRelayer, address indexed newRelayer);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initializes the forwarder.
     * @param name Forwarder identifier.
     * @param _tokenAddress Address of the token used for reimbursements.
     * @param _burnPercentage Percentage (scaled by SCALE) of reimbursed tokens to burn.
     * @param roleManagerAddress Address of the RoleManager.
     * @param _relayer Authorized relayer address.
     */
    function initializeForwarder(
        string memory name,
        address _tokenAddress,
        uint256 _burnPercentage,
        address roleManagerAddress,
        address _relayer
    ) public initializer {
        __ERC2771Forwarder_init(name);
        __ReentrancyGuard_init();
        __AccessControlled_init(roleManagerAddress);
        require(_burnPercentage <= SCALE, "Burn percentage cannot exceed 100%");
        tokenAddress = _tokenAddress;
        burnPercentage = _burnPercentage;
        relayerAddress = _relayer;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayerAddress, "Not authorized: relayer only");
        _;
    }
    
    /**
     * @notice Updates the token contract address.
     * @param _tokenAddress New token address.
     */
    function setTokenAddress(address _tokenAddress) public onlyDAOAdmin {
        require(_tokenAddress != address(0), "Invalid token address");
        tokenAddress = _tokenAddress;
    }
    
    /**
     * @notice Changes the authorized relayer.
     * @param _newRelayer New relayer address.
     */
    function setRelayerAddress(address _newRelayer) public onlyDAOAdmin {
        require(_newRelayer != address(0), "Invalid relayer address");
        address oldRelayer = relayerAddress;
        relayerAddress = _newRelayer;
        emit RelayerChanged(oldRelayer, _newRelayer);
    }
    
    /**
     * @notice Executes a meta-transaction using a permit and processes token reimbursement.
     * @dev Callable only by the relayer. Reimburses gas costs and burns a percentage as configured.
     */
    function executeWithPermitAndReimbursement(
        ForwardRequestData calldata request,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable nonReentrant onlyRelayer {
        if (msg.value != request.value) {
            revert ERC2771ForwarderMismatchedValue(request.value, msg.value);
        }
        uint256 gasCostInMatic = gasUsed * gasPriceInMatic;
        uint256 reimbursementInTokens = (gasCostInMatic * tokenToMaticRate) / 1e18;
        uint256 burnAmount = (reimbursementInTokens * burnPercentage) / SCALE;
        uint256 totalCost = reimbursementInTokens + burnAmount;
        
        ICustomToken(tokenAddress).permit(
            request.from,
            address(this),
            totalCost,
            permitDeadline,
            v,
            r,
            s
        );
        
        // Forward the meta-transaction.
        bytes memory execCalldata = abi.encodeWithSelector(this.execute.selector, request);
        execCalldata = abi.encodePacked(execCalldata, request.from);
        (bool execSuccess, ) = address(this).call{ value: request.value }(execCalldata);
        require(execSuccess, "Forwarded call failed");
        
        require(
            ICustomToken(tokenAddress).transferFrom(request.from, address(this), totalCost),
            "Token transfer failed"
        );
        if (burnAmount > 0) {
            ICustomToken(tokenAddress).burn(burnAmount);
        }
        if (reimbursementInTokens > 0) {
            require(
                ICustomToken(tokenAddress).transfer(relayerAddress, reimbursementInTokens),
                "Transfer to relayer failed"
            );
        }
    }
    
    /**
     * @notice Withdraws tokens accumulated within the forwarder.
     * @param recipient Address to receive tokens.
     * @param amount Amount to withdraw.
     */
    function withdrawReimbursementTokens(address recipient, uint256 amount) public onlyDAOAdmin {
        uint256 forwarderBalance = ICustomToken(tokenAddress).balanceOf(address(this));
        require(forwarderBalance >= amount, "Insufficient balance");
        require(
            ICustomToken(tokenAddress).transfer(recipient, amount),
            "Transfer failed"
        );
    }
}
