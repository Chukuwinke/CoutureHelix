// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract RoleManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE"); // Define BACKEND_ROLE
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    // Role members storage
    mapping(bytes32 => address[]) private _roleMembers;
    mapping(bytes32 => mapping(address => uint256)) private _roleMemberIndex; // Maps role -> account -> index in the array

    event GrantedRole(bytes32 indexed role, address indexed account, address indexed admin);
    event RevokedRole(bytes32 indexed role, address indexed account, address indexed admin);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Grant DEFAULT_ADMIN_ROLE to the admin
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, admin); // Grant BACKEND_ROLE to admin during initialization
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function grantRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.grantRole(role, account);

        if (_roleMemberIndex[role][account] == 0 && (_roleMembers[role].length == 0 || _roleMembers[role][0] != account)) {
            _roleMembers[role].push(account);
            _roleMemberIndex[role][account] = _roleMembers[role].length; // Store 1-based index
        }

        emit GrantedRole(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.revokeRole(role, account);

        uint256 index = _roleMemberIndex[role][account];
        if (index > 0) {
            uint256 lastIndex = _roleMembers[role].length - 1;
            address lastMember = _roleMembers[role][lastIndex];

            // Swap and remove
            _roleMembers[role][index - 1] = lastMember; // Replace with the last member
            _roleMemberIndex[role][lastMember] = index; // Update the index of the last member
            _roleMembers[role].pop(); // Remove the last member
            delete _roleMemberIndex[role][account];
        }

        emit RevokedRole(role, account, msg.sender);
    }

    // Override renounceRole to block the DEFAULT_ADMIN_ROLE from renouncing
    function renounceRole(bytes32 role, address account) public virtual override {
        require(role != DEFAULT_ADMIN_ROLE, "Default admin cannot renounce its role");
        super.renounceRole(role, account);
    }

    function getRoleMembers(bytes32 role) public view returns (address[] memory) {
        return _roleMembers[role];
    }

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return super.hasRole(role, account);
    }
}
