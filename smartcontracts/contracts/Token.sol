// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./cMetatx/CustomERC2771ContextUpgradeable.sol";
import "./RoleManager.sol";

contract Token is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    CustomERC2771ContextUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    RoleManager public roleManager;

    uint256 private _cap;

    mapping(address => bool) private _blacklist;

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event Granted(bytes32 indexed role, address indexed account, address indexed admin);
    event Revoked(bytes32 indexed role, address indexed account, address indexed admin);

    function initialize(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 cap_,
        address multisigAdmin,
        //address minter,
        //address upgrader,
        address trustedForwarder
    ) public initializer {
        require(cap_ > 0, "Cap must be greater than 0");
        _cap = cap_;

        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Permit_init(name);
        __AccessControl_init();
        __Ownable_init(multisigAdmin);
        __UUPSUpgradeable_init();
        __CustomERC2771ContextUpgradeable_init(trustedForwarder);

        _grantRole(DEFAULT_ADMIN_ROLE, multisigAdmin);
        //_grantRole(MINTER_ROLE, minter);
        //_grantRole(UPGRADER_ROLE, upgrader);

        _mint(multisigAdmin, initialSupply);
        transferOwnership(multisigAdmin); // Transfer ownership to multisig admin
    }

    // Setters
    function setRoleManager(address _roleManager) external onlyOwner {
        require(_roleManager !=address(0), "role manager address cannot be zero");
        roleManager = RoleManager(_roleManager);
    }

    function setCap(uint256 newCap) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCap > totalSupply(), "New cap must exceed current supply");
        _cap = newCap;
    }

    // modifiers
    // Modifier for Backend Role
    modifier onlyBackendRole() {
        require(roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender), "Token: Caller does not have BACKEND_ROLE");
        _;
    }
    // Modifier for Backend Role
    modifier onlyMinterRole() {
        require(roleManager.hasRole(roleManager.MINTER_ROLE(), msg.sender), "Token: Caller does not have MINTER_ROLE");
        _;
    }

    modifier onlyUpgraderRole() {
        require(roleManager.hasRole(roleManager.UPGRADER_ROLE(), msg.sender), "Token: Caller does not have UPGRADER_ROLE");
        _;
    }

    function cap() public view returns (uint256) {
        return _cap;
    }

    function blacklist(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!_blacklist[account], "Address is already blacklisted");
        _blacklist[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_blacklist[account], "Address is not blacklisted");
        _blacklist[account] = false;
        emit Unblacklisted(account);
    }

    function isBlacklisted(address account) public view returns (bool) {
        return _blacklist[account];
    }

    function mint(address to, uint256 amount) public onlyMinterRole {
        require(totalSupply() + amount <= cap(), "Cap exceeded");
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(uint256 amount) public override {
        require(!_blacklist[_msgSender()], "Caller is blacklisted");
        super.burn(amount);
        emit Burned(_msgSender(), amount);
    }

    function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function grantRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.grantRole(role, account);
        emit Granted(role, account, _msgSender());
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.revokeRole(role, account);
        emit Revoked(role, account, _msgSender());
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        return super.approve(spender, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual override {
        super._spendAllowance(owner, spender, amount);
    }

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        require(!_blacklist[from], "Sender is blacklisted");
        require(!_blacklist[to], "Recipient is blacklisted");
        super._update(from, to, amount);
    }

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, CustomERC2771ContextUpgradeable)
        returns (address)
    {
        return CustomERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, CustomERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return CustomERC2771ContextUpgradeable._msgData();
    }

    function setTrustedForwarder(address forwarder) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.setTrustedForwarder(forwarder);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgraderRole {}
}
