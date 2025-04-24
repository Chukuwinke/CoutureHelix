// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @dev Interface for the external RoleManager.
 */

 /// @notice Thrown when caller is not authorized for DAO operations
error NotAuthorized();

interface IRoleManager {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @title AccessControlledUpgradeable
 * @notice Provides simple role-based access control using an external RoleManager.
 */
contract AccessControlledUpgradeable is Initializable {
    IRoleManager public roleManager;

    bytes32 public constant DAO_ADMIN_ROLE = keccak256("DAO_ADMIN_ROLE");
    bytes32 public constant GOVERNANCE_EXECUTOR_ROLE = keccak256("GOVERNANCE_EXECUTOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @dev Initializes the access control module.
     * @param _roleManager Address of the RoleManager.
     */
    function __AccessControlled_init(address _roleManager) internal onlyInitializing {
        require(_roleManager != address(0), "Role manager cannot be zero");
        roleManager = IRoleManager(_roleManager);
    }

    modifier onlyDAOAdmin() {
        if (!roleManager.hasRole(DAO_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }
    modifier onlyGovernanceExecutor() virtual {
        if (!roleManager.hasRole(GOVERNANCE_EXECUTOR_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }
    modifier onlyUpgrader() {
        if (!roleManager.hasRole(UPGRADER_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    
}
