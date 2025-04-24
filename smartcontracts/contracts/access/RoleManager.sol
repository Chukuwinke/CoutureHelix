// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title RoleManager
 * @notice Centralized role-based access control contract with role enumeration.
 */
contract RoleManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant DAO_ADMIN_ROLE = keccak256("DAO_ADMIN_ROLE");
    bytes32 public constant GOVERNANCE_EXECUTOR_ROLE = keccak256("GOVERNANCE_EXECUTOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    mapping(bytes32 => address[]) private _roleMembers;
    mapping(bytes32 => mapping(address => uint256)) private _roleMemberIndex; // 1-indexed

    event GrantedRole(bytes32 indexed role, address indexed account, address indexed sender);
    event RevokedRole(bytes32 indexed role, address indexed account, address indexed sender);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the RoleManager with a single DAO admin.
     * @param daoAdmin Address to be assigned DAO admin and default admin roles.
     */
    function initializeRoleManager(address daoAdmin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Assign daoAdmin as default admin and DAO admin.
        _grantRole(DEFAULT_ADMIN_ROLE, daoAdmin);
        _grantRole(DAO_ADMIN_ROLE, daoAdmin);

        _roleMembers[DAO_ADMIN_ROLE].push(daoAdmin);
        _roleMemberIndex[DAO_ADMIN_ROLE][daoAdmin] = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DAO_ADMIN_ROLE) {}

    /**
     * @notice Grants a role and updates enumeration.
     * @dev Restricts additional grants of DAO_ADMIN_ROLE.
     * @param role Role identifier.
     * @param account Address to receive the role.
     */
    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (role == DAO_ADMIN_ROLE) {
            require(_roleMembers[DAO_ADMIN_ROLE].length == 0, "DAO admin already exists");
        }
        super.grantRole(role, account);
        if (_roleMemberIndex[role][account] == 0) {
            _roleMembers[role].push(account);
            _roleMemberIndex[role][account] = _roleMembers[role].length;
        }
        emit GrantedRole(role, account, msg.sender);
    }

    /**
     * @notice Revokes a role and updates enumeration.
     * @param role Role identifier.
     * @param account Address to revoke.
     */
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        super.revokeRole(role, account);
        uint256 index = _roleMemberIndex[role][account];
        if (index > 0) {
            uint256 lastIndex = _roleMembers[role].length - 1;
            address lastMember = _roleMembers[role][lastIndex];
            _roleMembers[role][index - 1] = lastMember;
            _roleMemberIndex[role][lastMember] = index;
            _roleMembers[role].pop();
            delete _roleMemberIndex[role][account];
        }
        emit RevokedRole(role, account, msg.sender);
    }

    /**
     * @notice Prevents DAO admin from renouncing their own role.
     */
    function renounceRole(bytes32 role, address account) public override {
        require(role != DAO_ADMIN_ROLE, "DAO admin cannot renounce");
        super.renounceRole(role, account);
    }

    /**
     * @notice Transfers the DAO admin role to a new DAO admin in case of emergency or ownership transfers .
     * @dev Ensures only one DAO admin exists at any time.
     * @param newAdmin Address of the new DAO admin.
     */
    function transferDAOAdmin(address newAdmin) external onlyRole(DAO_ADMIN_ROLE) {
        require(newAdmin != address(0), "New admin is zero address");
        require(newAdmin != msg.sender, "New admin is the current admin");

        // Revoke DAO_ADMIN_ROLE from the current admin.
        revokeRole(DAO_ADMIN_ROLE, msg.sender);
        // Grant DAO_ADMIN_ROLE to the new admin.
        // Since _roleMembers[DAO_ADMIN_ROLE] is now empty, this call succeeds.
        grantRole(DAO_ADMIN_ROLE, newAdmin);
    }

    /**
     * @notice Returns all members holding a specific role.
     * @param role Role identifier.
     * @return Array of addresses.
     */
    function getRoleMembers(bytes32 role) public view returns (address[] memory) {
        return _roleMembers[role];
    }
}
