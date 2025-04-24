// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../cMetatx/CustomERC2771ContextUpgradeable.sol";
import "../access/AccessControlledUpgradeable.sol";
import "../access/RoleManager.sol";

/**
 * @title Token
 * @notice ERC20 token with burnable, pausable, permit, and voting extensions.
 * @dev Supports meta-transactions via a custom context and integrates with DAO governance.
 */
contract Token is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    UUPSUpgradeable,
    CustomERC2771ContextUpgradeable,
    AccessControlledUpgradeable
{
    uint256 private _cap;
    mapping(address => bool) private _blacklisted;

    // Governance contract addresses.
    address public governorContract;
    address public timelockController;

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event TokensMinted(address indexed recipient, uint256 amount);
    event TokensBurned(address indexed account, uint256 amount);
    event RoutineActionExecuted(string action, address indexed executor);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the token.
     * @param name Token name.
     * @param symbol Token symbol.
     * @param initialSupply Initial supply minted to the first DAO admin.
     * @param cap_ Maximum token supply.
     * @param roleManagerAddress Address of the RoleManager.
     * @param trustedForwarder Trusted forwarder for meta-transactions.
     */
    function initializeToken(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 cap_,
        address roleManagerAddress,
        address trustedForwarder
    ) public initializer {
        require(cap_ > 0, "Cap must be > 0");
        _cap = cap_;
        require(initialSupply <= cap_, "Initial supply exceeds cap");

        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Permit_init(name);
        __ERC20Votes_init();
        __UUPSUpgradeable_init();
        __CustomERC2771ContextUpgradeable_init(trustedForwarder);
        __AccessControlled_init(roleManagerAddress);

        // Mint initial supply to the first DAO admin.
        address daoAdmin = RoleManager(roleManagerAddress).getRoleMembers(DAO_ADMIN_ROLE)[0];
        _mint(daoAdmin, initialSupply);
    }

    /**
     * @notice Sets the governor contract address.
     * @param _governorContract Address of the governor contract.
     */
    function setGovernorContract(address _governorContract) external onlyDAOAdmin {
        require(_governorContract != address(0), "Governor address cannot be zero");
        governorContract = _governorContract;
    }

    /**
     * @notice Sets the timelock controller address.
     * @param _timelockController Address of the timelock controller.
     */
    function setTimelockController(address _timelockController) external onlyDAOAdmin {
        require(_timelockController != address(0), "Timelock address cannot be zero");
        timelockController = _timelockController;
    }

    modifier onlyGovernanceExecutor() override {
        require(
            roleManager.hasRole(GOVERNANCE_EXECUTOR_ROLE, msg.sender) || msg.sender == timelockController,
            "Not authorized as governance executor"
        );
        _;
    }

    /**
     * @notice Mints new tokens.
     * @param to Recipient address.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) public onlyGovernanceExecutor {
        emit RoutineActionExecuted("mint", msg.sender);
        require(totalSupply() + amount <= cap(), "Cap exceeded");
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Updates the token cap.
     * @param newCap New cap value; must exceed current total supply.
     */
    function setCap(uint256 newCap) public onlyGovernanceExecutor {
        emit RoutineActionExecuted("setCap", msg.sender);
        require(newCap > totalSupply(), "New cap must exceed total supply");
        _cap = newCap;
    }

    /**
     * @notice Blacklists an address to restrict transfers.
     * @param account Address to blacklist.
     */
    function blacklist(address account) public onlyDAOAdmin {
        require(account != address(0), "Cannot blacklist zero address");
        require(!_blacklisted[account], "Already blacklisted");
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Removes an address from the blacklist.
     * @param account Address to unblacklist.
     */
    function unblacklist(address account) public onlyDAOAdmin {
        require(_blacklisted[account], "Not blacklisted");
        _blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    /**
     * @notice Checks whether an address is blacklisted.
     * @param account Address to query.
     * @return True if blacklisted, false otherwise.
     */
    function isBlacklisted(address account) public view returns (bool) {
        return _blacklisted[account];
    }

    /**
     * @notice Burns tokens from the caller.
     * @dev Prevents blacklisted accounts from burning tokens.
     */
    function burn(uint256 amount) public override {
        require(!_blacklisted[_msgSender()], "Caller is blacklisted");
        super.burn(amount);
        emit TokensBurned(_msgSender(), amount);
    }

    function pause() public onlyDAOAdmin {
        _pause();
    }

    function unpause() public onlyDAOAdmin {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgrader {}

    /**
     * @notice Returns the current token cap.
     * @return The maximum supply.
     */
    function cap() public view returns (uint256) {
        return _cap;
    }

    /**
     * @dev Overrides _update to prevent transfers involving blacklisted addresses.
     */
    function _update(address from, address to, uint256 amount)
        internal override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable)
    {
        require(!_blacklisted[from] && !_blacklisted[to], "Blacklisted address involved");
        super._update(from, to, amount);
    }

    function _msgSender()
        internal view override(ContextUpgradeable, CustomERC2771ContextUpgradeable)
        returns (address)
    {
        return CustomERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal view override(ContextUpgradeable, CustomERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return CustomERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Updates the trusted forwarder address.
     * @param forwarder New forwarder address.
     */
    function setTrustedForwarder(address forwarder) public onlyDAOAdmin override {
        super.setTrustedForwarder(forwarder);
    }

    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return ERC20PermitUpgradeable.nonces(owner);
    }
}
