// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

//import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "./ReputationOracle.sol";
import "./interfaces/IStaking.sol";

contract Validator is AccessControlEnumerable {
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    ReputationOracle public reputationOracle;
    IStaking public stakingContract;

    struct ValidatorInfo {
        uint256 onChainReputation;
        uint256 combinedReputation;
    }

    mapping(address => ValidatorInfo) public validators;

    // !!! must find a better way to handle maxStaked amount also consider handling this on the frontend
    uint256 public minimumStakeForValidator = 100 * (10 ** 18); // Example threshold
    uint256 public maxStakedAmount = 1000 * (10 ** 18); // Example maximum staked amount

    // Events for reputation updates
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event OnChainReputationAdjusted(address indexed validator, uint256 newReputation);
    event CombinedReputationUpdated(address indexed validator, uint256 combinedReputation);

    constructor(address reputationOracleAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        reputationOracle = ReputationOracle(reputationOracleAddress);
        
    }

    // Function to set the Reputation Oracle address maybe in the future after upgrades
    function setReputationOracle(address reputationOracleAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        reputationOracle = ReputationOracle(reputationOracleAddress);
    }
    
    function setMinimumStakeForValidator(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE){
        minimumStakeForValidator = amount;
    }

    function setMaximumStakeForValidator(uint amount) external onlyRole(DEFAULT_ADMIN_ROLE){
        maxStakedAmount = amount;
    }

    function setStakingContract(address stakingContractAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingContract = IStaking(stakingContractAddress);
    }

    // Function to grant validator role based on staking amount
    function grantValidatorRoleBasedOnStake(address validator) public onlyRole(DEFAULT_ADMIN_ROLE) {
        // !!! must find a better way to handle minumstakeforvalidator amount also consider handling this on the frontend
        require(address(stakingContract) != address(0), "Staking contract not set");
        require(stakingContract.getStakedAmount(validator) >= minimumStakeForValidator, "Insufficient stake to become a validator");
        _grantValidatorRole(validator);
    }

    // Function to allow admin to directly grant validator role without staking
    function grantValidatorRoleDirectly(address validator) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantValidatorRole(validator);
    }

    function _grantValidatorRole(address validator) internal {
        grantRole(VALIDATOR_ROLE, validator);
        // !!! check if i can use staking percentage of the validator in determining onchain reputation
        validators[validator].onChainReputation = 100; //set the initial on-chain reputation to hundred
        updateCombinedReputation(validator);
        emit ValidatorAdded(validator);
    }

    function revokeValidatorRole(address validator) public onlyRole(DEFAULT_ADMIN_ROLE){
        revokeRole(VALIDATOR_ROLE, validator);
        delete validators[validator];
        emit ValidatorRemoved(validator);
    }

    function isValidator(address validator) public view returns (bool){
        return hasRole(VALIDATOR_ROLE, validator);
    }

    // can you explain delta ? and how it affects the reputaion and what the value looks like
    function adjustOnChainReputation(address validator, int256 delta) public onlyRole(DEFAULT_ADMIN_ROLE){
        require(isValidator(validator), "Not a validator");
        int256 newReputation = int256(validators[validator].onChainReputation) + delta;
        validators[validator].onChainReputation = newReputation < 0 ? 0: uint256(newReputation);
        updateCombinedReputation(validator);
        emit OnChainReputationAdjusted(validator, validators[validator].onChainReputation);
    }

    // remove before deployment
    function setReputation(address validator, uint256 reputation) external onlyRole(DEFAULT_ADMIN_ROLE) {
    validators[validator].combinedReputation = reputation;
    }


    //! why is there no onlyRole(DEFAULT_ADMIN_ROLE) in this function? because no appernt risk it is public information anyways and tampering is easily detected
    function updateCombinedReputation(address validator) public {
        require(isValidator(validator), "Not a validator");

        uint256 offChainRep = reputationOracle.offChainReputation(validator);
        uint256 onChainRep = validators[validator].onChainReputation;

        uint256 stakedAmount = 0;
        if (address(stakingContract) != address(0)) {
            stakedAmount = stakingContract.getStakedAmount(validator);
        }
        uint256 stakingScore = calculateStakingScore(stakedAmount);

        // Example weighting: 50% on-chain reputation, 30% off-chain, 20% staking score
        validators[validator].combinedReputation = (onChainRep * 50 + offChainRep * 30 + stakingScore * 20) / 100;

        emit CombinedReputationUpdated(validator, validators[validator].combinedReputation);

    }

    function calculateStakingScore(uint256 stakedAmount) internal view returns (uint256) {

        if (maxStakedAmount == 0) {
            return 0;
        }
        //normalize staked amount to a score between 0 and 100 
        return stakedAmount >= maxStakedAmount ? 100 : (stakedAmount * 100) / maxStakedAmount;
        
    }

    // Functions to get all validators and reputations
    function getAllValidators() external view returns (address[] memory) {
        uint256 validatorCount = getRoleMemberCount(VALIDATOR_ROLE);
        address[] memory validatorsList = new address[](validatorCount);
        for (uint256 i = 0; i < validatorCount; i++) {
            validatorsList[i] = getRoleMember(VALIDATOR_ROLE, i);
        }
        return validatorsList;
    }

    function getValidatorReputation(address validator) public view returns (uint256) {
        return validators[validator].combinedReputation;
    }
}





// pragma solidity ^0.8.27;

// import "@openzeppelin/contracts/access/AccessControl.sol";
// import "./ReputationOracle.sol";
// import "./Staking.sol"; // remove

// contract Validator is AccessControl {
//     bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

//     ReputationOracle public reputationOracle;
//     Staking public stakingContract;

//     struct ValidatorInfo {
//         uint256 onChainReputation;
//         uint256 combinedReputation;
//     }

//     mapping(address => ValidatorInfo) public validators;

//     constructor(address reputationOracleAddress, address stakingContractAddress) {
//         _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
//         reputationOracle = ReputationOracle(reputationOracleAddress);
//         stakingContract = Staking(stakingContractAddress); //remove
//     }

//     function grantValidatorRole(address validator) public onlyRole(DEFAULT_ADMIN_ROLE){
//         grantRole(VALIDATOR_ROLE, validator);
//         // !!! check if i can use staking percentage of the validator in determining onchain reputation
//         validators[validator].onChainReputation = 100; //set the initial on-chain reputation to hundred
//         updateCombinedReputation(validator);
//     }

//     function revokeValidatorRole(address validator) public onlyRole(DEFAULT_ADMIN_ROLE){
//         revokeRole(VALIDATOR_ROLE, validator);
//         delete validators[validator];
//     }

//     function isValidator(address validator) public view returns (bool){
//         return hasRole(VALIDATOR_ROLE, validator);
//     }

//     // can you explain delta ? and how it affects the reputaion and what the value looks like
//     function adjustOnChainReputation(address validator, int256 delta) public onlyRole(DEFAULT_ADMIN_ROLE){
//         require(isValidator(validator), "Not a validator");
//         int256 newReputation = int256(validators[validator].onChainReputation) + delta;
//         validators[validator].onChainReputation = newReputation < 0 ? 0: uint256(newReputation);
//         updateCombinedReputation(validator);
//     }

//     //! why is there no onlyRole(DEFAULT_ADMIN_ROLE) in this function? because no appernt risk it is public information anyways and tampering is easily detected
//     function updateCombinedReputation(address validator) public {
//         require(isValidator(validator), "Not a validator");

//         uint256 offChainRep = reputationOracle.offChainReputation(validator);
//         uint256 onChainRep = validators[validator].onChainReputation;

//         // Include staking amount if desired
//         uint256 stakedAmount = stakingContract.getStakedAmount(validator);
//         uint256 stakingScore = calculateStakingScore(stakedAmount);

//         // Example weighting: 50% on-chain reputation, 30% off-chain, 20% staking score
//         validators[validator].combinedReputation = (onChainRep * 50 + offChainRep * 30 + stakingScore * 20) / 100;

//     }

//     function calculateStakingScore(uint256 stakedAmount) internal pure returns (uint256) {
//         //normalize staked amount to a score between 0 and 100 

//         // !!! must find a better way to handle maxStaked amount
//         uint256 maxStakedAmount = 1000 * (10 ** 18); // Example maximum staked amount
//         if (stakedAmount >= maxStakedAmount) {
//             return 100;
//         } else {
//             return (stakedAmount * 100) / maxStakedAmount;
//         }
//     }

//     function getValidatorReputation(address validator) public view returns (uint256) {
//         return validators[validator].combinedReputation;
//     }
// }
