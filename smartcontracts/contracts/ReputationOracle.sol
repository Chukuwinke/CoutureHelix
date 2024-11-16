// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";

contract ReputationOracle is Ownable {
    mapping(address => uint256) public offChainReputation;
    mapping(address => uint256) public lastUpdated;

    event ReputationUpdated(address indexed validator, uint256 reputationScore);

    // Only authorized oracles can update reputation scores
    mapping(address => bool) public authorizedOracles;

    modifier onlyOracle(){
        require(authorizedOracles[msg.sender], "Caller is not an authorized Oracle");
        _;
    }

    // Empty constructor to avoid VS Code error
    constructor() Ownable(msg.sender) {}


    function authorizeOracle(address oracle) public onlyOwner{
        authorizedOracles[oracle] = true;
    }
    function revokeOracle(address oracle) public onlyOwner{
        authorizedOracles[oracle] = false;
    }

    function updateReputation(address validator, uint256 reputationScore) public onlyOracle{
        offChainReputation[validator] = reputationScore;
        lastUpdated[validator] = block.timestamp;
        emit ReputationUpdated(validator, reputationScore);
    }

}