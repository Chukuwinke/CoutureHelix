// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title MyTimelockController
 * @notice A minimal extension of OpenZeppelin's TimelockControllerUpgradeable.
 */
contract MyTimelockController is Initializable, TimelockControllerUpgradeable {
    /**
     * @notice Initializes the timelock controller.
     * @param minDelay Minimum delay (in seconds) before execution of queued operations.
     * @param proposers Addresses allowed to propose operations.
     * @param executors Addresses allowed to execute operations.
     * @param daoAdmin Address to be granted admin roles.
     */
    function initialize(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address daoAdmin
    ) public override initializer {
        __TimelockController_init(minDelay, proposers, executors, daoAdmin);
    }
}
