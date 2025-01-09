//SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./Token.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IValidator.sol";

contract Staking is Ownable {
    Token public token;
    IValidator public validatorContract;

    struct StakerInfo{
        uint256 stakedAmount;
        uint256 lastStakeTime;
    }

    mapping(address => StakerInfo) public stakers;

    event TokenStaked(address indexed staker, uint256 amount);
    event TokenUnStaked(address indexed staker, uint256 amount);

    constructor(address tokenAddress) Ownable(msg.sender) {
        token = Token(tokenAddress);
        
    }

    function setValidatorContract(address validatorContractAddress) external onlyOwner {
        validatorContract = IValidator(validatorContractAddress);
    }

    function stakeTokens (uint256 amount) public {
        require(amount > 0, "Amount must be greater than 0");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        stakers[msg.sender].stakedAmount += amount;
        stakers[msg.sender].lastStakeTime = block.timestamp;

        emit TokenStaked(msg.sender, amount);

        if (address(validatorContract) != address(0)  && validatorContract.isValidator(msg.sender)) {
            validatorContract.updateCombinedReputation(msg.sender); // update validators reputation
        }

    }

    function unstakeTokens (uint256 amount) public {
        require(stakers[msg.sender].stakedAmount >= amount, "Insufficient staked amount");

        stakers[msg.sender].stakedAmount -= amount;
        require(token.transfer(msg.sender, amount), "Transfer failed");

        emit TokenUnStaked(msg.sender, amount);

        // !!! user does not need to be a validator to unstake incase they themselves or admin revokes their validator
        // status before unstaking
        if (address(validatorContract) != address(0)) {
            validatorContract.updateCombinedReputation(msg.sender); // update validators reputation
        }

    }

    function getStakedAmount(address staker) public view returns (uint256){
        return stakers[staker].stakedAmount;
    }
}