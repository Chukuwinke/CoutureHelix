// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "../access/RoleManager.sol";


/// @notice Thrown when caller is neither the DAO multisig nor a backend
error NotAuthorized();
/// @notice Thrown when attempting to attach a TradeableNFT already linked
error AlreadyAttached();
/// @notice Thrown when attempting to attach beyond a LoyaltyNFT’s cap
error MaxTradeableLinksReached();
/// @notice Thrown when there are no tradeables to remove
error NoTradeableLinks();
/// @notice Thrown if the loyalty token doesn't exist
error TokenDoesNotExist();

// =========  Soulbound nft (cannot be traded) ================================//
contract LoyaltyNFT is Initializable,
                        ReentrancyGuardUpgradeable,
                        ERC721Upgradeable,
                        PausableUpgradeable,
                        ERC2981Upgradeable,
                        UUPSUpgradeable,
                        OwnableUpgradeable,
                        AccessControlUpgradeable,
                        ERC721URIStorageUpgradeable {

    RoleManager public roleManager;
    address public custodialWallet;
    uint256 public tokenCount;

    // Mapping to store lock expiration timestamps for each token.
    mapping(uint256 => uint256) public lockExpiration;
    // Mapping to store the loyalty tier for each token.
    mapping(uint256 => uint256) public tokenTier;

    // Tradeable NFT linkage:
    // Mapping from loyalty tokenId to an array of linked tradeable NFT IDs.
    mapping(uint256 => uint256[]) public tradeableNFT_Links;
    // Mapping from loyalty tokenId => (tradeableTokenId => index in tradeableLinks array)
    mapping(uint256 => mapping(uint256 => uint256)) private tradeableNFT_Index;
    // Maximum number of tradeable NFT links allowed per loyalty NFT.
    uint256 public defaultMaxTradeableNFT_Links;
    mapping(uint256 => uint256) public maxTradeableNFT_Links;

    // New state variable to signal emergency recovery mode.
    bool private _recoveryMode;

    event NFTMinted(uint256 indexed tokenId, address indexed initialOwner, uint256 lockUntil, string ipfsCID);
    event NFTClaimed(uint256 indexed tokenId, address indexed newOwner);
    event NFTUpgraded(uint256 indexed tokenId, uint256 newTier);
    event tradeableNFT_LinkAdded(uint256 indexed loyaltyTokenId, uint256 tradeableNFT_TokenId);
    event tradeableNFT_LinkRemoved(uint256 indexed loyaltyTokenId, uint256 tradeableNFT_TokenId);
    event CustodialWalletUpdated(address indexed previousWallet, address indexed newWallet);
    event TokenURIUpdated(uint256 indexed tokenId, string newTokenURI);
    event TokenRecovered(uint256 indexed tokenId, address indexed newOwner);
    event BatchNFTMinted(uint256[] tokenIds, uint256 lockDuration, uint256 initialTier, string[] ipfsCIDs);
    event MaxTradeableNFTLinksUpdated(uint256 indexed tokenId, uint256 newCap);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address multisigAdmin, 
        address custodialWalletAddress, 
        address roleManagerAddress, 
        uint256 initialMaxTradeableNFT_Link
    ) public initializer {
        __ReentrancyGuard_init();
        __ERC721_init("LoyaltyNFT", "FDNA");
        __ERC721URIStorage_init();
        __ERC2981_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __Ownable_init(multisigAdmin);

        roleManager = RoleManager(roleManagerAddress);
        custodialWallet = custodialWalletAddress;
        tokenCount = 1;
        defaultMaxTradeableNFT_Links = initialMaxTradeableNFT_Link;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyUpgrader() {
        require(
            roleManager.hasRole(roleManager.UPGRADER_ROLE(), msg.sender),
            "Not authorized to upgrade"
        );
        _;
    }

    modifier onlyDAOMultisigOrBackend() {
        if (msg.sender != owner() && !roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender)) {
            revert NotAuthorized();
        }
        _;
    }

    /////////////////////////////////
    // Loyalty NFT Core Functions  //
    /////////////////////////////////
    // --- factor out shared mint logic ---
    function _mintOne(
        uint256 initialTier,
        uint256 lockDuration,
        string memory ipfsCID
    ) internal whenNotPaused returns (uint256 tokenId) {
        tokenCount++;
        tokenId = tokenCount;

        // 1) mint to custodial
        _safeMint(custodialWallet, tokenId);

        // 2) set core fields
        tokenTier[tokenId]      = initialTier;
        lockExpiration[tokenId] = block.timestamp + lockDuration;
        _setTokenURI(tokenId, ipfsCID);

        // 3) bake in this token’s cap once and for all
        maxTradeableNFT_Links[tokenId] = defaultMaxTradeableNFT_Links;
    }

     function mintNFT(
        uint256 initialTier,
        uint256 lockDuration,
        string memory ipfsCID
    )
        external
        onlyDAOMultisigOrBackend
        returns (uint256)
    {
        uint256 tokenId = _mintOne(initialTier, lockDuration, ipfsCID);
        emit NFTMinted(tokenId, custodialWallet, lockExpiration[tokenId], ipfsCID);
        return tokenId;
    }


    function batchMintLoyaltyNFT(
        address[] calldata recipients,      // if you still want to record recipients off-chain
        uint256         initialTier,
        uint256         lockDuration,
        string[] calldata ipfsCIDs
    )
        external
        onlyDAOMultisigOrBackend
        returns (uint256[] memory)
    {
        require(recipients.length == ipfsCIDs.length, "Arrays must be equal length");
        uint256[] memory ids = new uint256[](recipients.length);

        for (uint256 i = 0; i < recipients.length; i++) {
            ids[i] = _mintOne(initialTier, lockDuration, ipfsCIDs[i]);
            emit NFTMinted(ids[i], custodialWallet, lockExpiration[ids[i]], ipfsCIDs[i]);
        }
        emit BatchNFTMinted(ids, lockDuration, initialTier, ipfsCIDs);
        return ids;
    }

    function claimNFT(uint256 tokenId) external whenNotPaused {
        if (ownerOf(tokenId) != custodialWallet) revert NotAuthorized();
        _transfer(custodialWallet, msg.sender, tokenId);
        // Once claimed, lock permanently.
        lockExpiration[tokenId] = type(uint256).max;
        emit NFTClaimed(tokenId, msg.sender);
    }

    function upgradeNFT(uint256 tokenId, uint256 newTier) external onlyDAOMultisigOrBackend whenNotPaused {
        tokenTier[tokenId] = newTier;
        emit NFTUpgraded(tokenId, newTier);
    }

    function updateCustodialWallet(address newCustodialWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCustodialWallet != address(0), "Invalid wallet address");
        emit CustodialWalletUpdated(custodialWallet, newCustodialWallet);
        custodialWallet = newCustodialWallet;
    }

    function updateTokenURI(uint256 tokenId, string memory newTokenURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _setTokenURI(tokenId, newTokenURI);
        emit TokenURIUpdated(tokenId, newTokenURI);
    }

    /////////////////////////////////
    // tradeable Linking Functions   //
    /////////////////////////////////
    function addTradeableNFT_Link(uint256 loyaltyTokenId, uint256 tradeableNFT_TokenId)
        external
        nonReentrant
        onlyDAOMultisigOrBackend  
    {
        uint256 cap = maxTradeableNFT_Links[loyaltyTokenId];
        uint256[] storage links = tradeableNFT_Links[loyaltyTokenId];
        if (links.length >= cap) revert MaxTradeableLinksReached();
        if (tradeableNFT_Index[loyaltyTokenId][tradeableNFT_TokenId] != 0) {
            revert AlreadyAttached();
        }

        links.push(tradeableNFT_TokenId);
        tradeableNFT_Index[loyaltyTokenId][tradeableNFT_TokenId] = links.length;
        emit tradeableNFT_LinkAdded(loyaltyTokenId, tradeableNFT_TokenId);
    }

    function removeTradeableNFT_Link(uint256 loyaltyTokenId, uint256 tradeableNFT_TokenId)
        external
        nonReentrant
        onlyDAOMultisigOrBackend
        
    {
        uint256[] storage links = tradeableNFT_Links[loyaltyTokenId];
        if (links.length == 0) revert NoTradeableLinks();

        uint256 stored = tradeableNFT_Index[loyaltyTokenId][tradeableNFT_TokenId];
        if (stored == 0) revert NoTradeableLinks();

        uint256 idx = stored - 1; 
        uint256 lastIndex = links.length - 1;

        if (idx != lastIndex) {
            uint256 swappedId = links[lastIndex];
            links[idx] = swappedId;
            tradeableNFT_Index[loyaltyTokenId][swappedId] = idx + 1;
        }

        links.pop();
        delete tradeableNFT_Index[loyaltyTokenId][tradeableNFT_TokenId];
        emit tradeableNFT_LinkRemoved(loyaltyTokenId, tradeableNFT_TokenId);
    }

    /// @notice Change the maximum number of tradeables allowed to link to a given loyalty token.
    /// @param tokenId  the loyalty NFT whose cap you want to raise (or lower)
    /// @param newCap   the new maximum number of allowed links for *that* token
    function setMaxTradeableNFTLinksForToken(
        uint256 tokenId,
        uint256 newCap
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        maxTradeableNFT_Links[tokenId] = newCap;
        emit MaxTradeableNFTLinksUpdated(tokenId, newCap);
    }

    /////////////////////////////////
    // Emergency Recovery Function //
    /////////////////////////////////
    /// @notice Emergency function to recover a loyalty NFT mistakenly sent to a wrong address.
    /// @dev Temporarily bypass soulbound restrictions by setting _recoveryMode.
    function emergencyRecoverToken(uint256 tokenId, address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newOwner == address(0) || ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        
        _recoveryMode = true;
        // Use standard _transfer, which now will not revert because _recoveryMode is active.
        _transfer(ownerOf(tokenId), newOwner, tokenId);
        _recoveryMode = false;
        
        emit TokenRecovered(tokenId, newOwner);
    }

    /////////////////////////////////
    // Frontend Status Function    //
    /////////////////////////////////
    function getLoyaltyTokenStatus(uint256 tokenId) external view returns (
        uint256 tier,
        uint256 lockUntil,
        uint256[] memory LinkedTradeableNFTs,
        string memory metadataURI
    ) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        tier = tokenTier[tokenId];
        lockUntil = lockExpiration[tokenId];
        LinkedTradeableNFTs = tradeableNFT_Links[tokenId];
        metadataURI = tokenURI(tokenId);
    }

    /////////////////////////////////
    // Administrative and Pausable //
    /////////////////////////////////
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /////////////////////////////////
    // Override Hooks for Soulbound //
    /////////////////////////////////
    /// @dev Override _update to restrict transfers for soulbound tokens.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // During normal operation, allow only minting (from == 0), burning (to == 0), or claiming (from is custodialWallet).
        if (!_recoveryMode && from != address(0) && to != address(0) && from != custodialWallet) {
            revert("SoulBoundNFT: Transfer not allowed");
        }
        return super._update(to, tokenId, auth);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgrader {}

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
