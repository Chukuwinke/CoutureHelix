// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../interfaces/ICustomToken.sol";
import "hardhat/console.sol";

contract MyForwarder is ERC2771ForwarderUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public burnPercentage;
    uint256 public constant SCALE = 10000;
    address public tokenAddress;
    
    function initialize(
        string memory name,
        address _tokenAddress,
        uint256 _burnPercentage
    ) public virtual initializer {
        __ERC2771Forwarder_init(name);
        __ReentrancyGuard_init();
        tokenAddress = _tokenAddress;
        burnPercentage = _burnPercentage;
    }

    // Setter to update the token address if needed.
    function setTokenAddress(address _tokenAddress) public {
        require(_tokenAddress != address(0), "Token address cannot be zero");
        tokenAddress = _tokenAddress;
    }
    
    function executeWithReimbursment (
        ForwardRequestData calldata request,
        uint256 gasUsed,
        uint256 gasPriceInMatic,
        uint256 tokenToMaticRate
    ) public payable virtual nonReentrant{
        // Check that the provided msg.value matches the request's value.
        if (msg.value != request.value) {
            revert ERC2771ForwarderMismatchedValue(request.value, msg.value);
        }
        
        // Execute the forwarded call externally.
        // Use "this" to force an external call, so we can pass call options.

        console.log("works 1");
        this.execute{ value: request.value }(request);
        console.log("works 2");
        
        uint256 gasCostInMatic = gasUsed * gasPriceInMatic;
        uint256 reimbursementInTokens = ((gasCostInMatic * 1e18) / tokenToMaticRate) * 1e18;
        uint256 burnAmount = (reimbursementInTokens * burnPercentage) / SCALE;
        uint256 totalCost = reimbursementInTokens + burnAmount;

        console.log("total cost: ", totalCost);
        console.log("burn amount: ", burnAmount);
        
        // Instead of calling transferFrom directly,
        // prepare the call data and append the original sender.
        bytes memory callData = abi.encodeWithSelector(
            ICustomToken.transferFrom.selector,
            request.from,
            address(this),
            totalCost
        );
        // Append the original sender (20 bytes) to the calldata.
        bytes memory metaTxCallData = abi.encodePacked(callData, abi.encodePacked(address(this)));
        
        console.log("works 3");
        (bool transferSuccess, ) = tokenAddress.call(metaTxCallData);
        require(transferSuccess, "Token transfer failed");
        console.log("works 4");
    
        // Burn the tokens.
        if (burnAmount > 0) {
            bytes memory burnCallData = abi.encodeWithSelector(ICustomToken.burn.selector, burnAmount);
            bytes memory metaBurnCallData = abi.encodePacked(burnCallData, abi.encodePacked(address(this)));
            (bool burnSuccess, ) = tokenAddress.call(metaBurnCallData);
            require(burnSuccess, "Token burn failed");
        }

        console.log("works 5");
        
        // Burn a portion of the tokens, if any.
        //if (burnAmount > 0) {
           // ICustomToken(tokenAddress).burn(burnAmount);
        //}
    }
}
