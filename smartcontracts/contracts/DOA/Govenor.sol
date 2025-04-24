// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../access/AccessControlledUpgradeable.sol";

/**
 * @title Governor
 * @notice Governance contract combining OpenZeppelin modules.
 * @dev Proposals can only be created by DAO admin accounts.
 */
contract Governor is
    Initializable,
    GovernorUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    AccessControlledUpgradeable
{
    /**
     * @notice Initializes the Governor contract.
     * @param token Voting token contract.
     * @param timelock Timelock controller contract.
     * @param roleManagerAddress Address of the RoleManager.
     */
    function initializeGovernor(
        VotesUpgradeable token,
        TimelockControllerUpgradeable timelock,
        address roleManagerAddress
    ) public initializer {
        __Governor_init("Governor");
        __GovernorVotes_init(token);
        __GovernorVotesQuorumFraction_init(4);
        __GovernorCountingSimple_init();
        __GovernorTimelockControl_init(timelock);
        __AccessControlled_init(roleManagerAddress);
    }

    /**
     * @notice Returns the version of the governor.
     */
    function version() public pure override returns (string memory) {
        return "1";
    }

    // Governance parameters.
    function votingDelay() public pure override returns (uint256) {
        return 1;
    }
    function votingPeriod() public pure override returns (uint256) {
        return 45818;
    }
    function proposalThreshold() public pure override returns (uint256) {
        return 0;
    }

    function clock() public view override(GovernorUpgradeable, GovernorVotesUpgradeable) returns (uint48) {
        return uint48(block.number);
    }
    function CLOCK_MODE() public pure override(GovernorUpgradeable, GovernorVotesUpgradeable) returns (string memory) {
        return "mode=blocknumber";
    }

    /**
     * @notice Proposes a new governance action.
     * @dev Restricted to DAO admin accounts.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override onlyDAOAdmin returns (uint256) {
        return super.propose(targets, values, calldatas, description);
    }

    // --- Inheritance Overrides ---
    function state(uint256 proposalId)
        public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }
    function supportsInterface(bytes4 interfaceId)
        public view override(GovernorUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    function _executor()
        internal view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
    function proposalNeedsQueuing(uint256 proposalId)
        public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
    {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }
}
