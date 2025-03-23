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
import "../RoleManager.sol";

contract SoulBoundNFT is Initializable,
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
    string public baseURI;
    uint256 public tokenCount;

    // Mapping to store lock expiration timestamps for each token.
    mapping(uint256 => uint256) public lockExpiration;
    // Mapping to store the loyalty tier for each token.
    mapping(uint256 => uint256) public tokenTier;

    // Premium NFT linkage:
    // Mapping from loyalty tokenId to an array of linked premium NFT IDs.
    mapping(uint256 => uint256[]) public premiumLinks;
    // Mapping from loyalty tokenId => (premiumTokenId => index in premiumLinks array)
    mapping(uint256 => mapping(uint256 => uint256)) private premiumIndex;
    // Maximum number of premium NFT links allowed per loyalty NFT.
    uint256 public maxPremiumLinks;

    event NFTMinted(uint256 indexed tokenId, address indexed initialOwner, uint256 lockUntil, string ipfsCID);
    event NFTClaimed(uint256 indexed tokenId, address indexed newOwner);
    event NFTUpgraded(uint256 indexed tokenId, uint256 newTier);
    event PremiumLinkAdded(uint256 indexed loyaltyTokenId, uint256 premiumTokenId);
    event PremiumLinkRemoved(uint256 indexed loyaltyTokenId, uint256 premiumTokenId);
    event CustodialWalletUpdated(address indexed previousWallet, address indexed newWallet);
    event TokenURIUpdated(uint256 indexed tokenId, string newTokenURI);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address multisigAdmin, 
        address custodialWalletAddress, 
        address roleManagerAddress, 
        string memory initialBaseURI,
        uint256 initialMaxPremiumLinks
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
        baseURI = initialBaseURI;
        tokenCount = 1;
        maxPremiumLinks = initialMaxPremiumLinks;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyAdminOrBackend() {
        require(
            msg.sender == owner() || roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender),
            "Not authorized"
        );
        _;
    }

    /// @notice Returns the array of premium links for a given token.
    function getPremiumLinks(uint256 tokenId) external view returns (uint256[] memory) {
        return premiumLinks[tokenId];
    }

    /// @notice Mint a new Loyalty NFT.
    /// @param initialTier The starting loyalty tier.
    /// @param lockDuration The duration (in seconds) for which the NFT remains non-transferable.
    /// @param ipfsCID The IPFS CID for the token metadata.
    function mintNFT(uint256 initialTier, uint256 lockDuration, string memory ipfsCID)
        external
        onlyAdminOrBackend
        whenNotPaused
        returns (uint256)
    {
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(custodialWallet, tokenId);
        tokenTier[tokenId] = initialTier;
        lockExpiration[tokenId] = block.timestamp + lockDuration;
        _setTokenURI(tokenId, ipfsCID);
        emit NFTMinted(tokenId, custodialWallet, lockExpiration[tokenId], ipfsCID);
        return tokenId;
    }

    /// @notice Claim the NFT from the custodial wallet.
    function claimNFT(uint256 tokenId) external whenNotPaused {
        require(ownerOf(tokenId) == custodialWallet, "NFT already claimed");
        _transfer(custodialWallet, msg.sender, tokenId);
        // Once claimed, lock permanently.
        lockExpiration[tokenId] = type(uint256).max;
        emit NFTClaimed(tokenId, msg.sender);
    }

    /// @notice Upgrade the NFT's tier.
    function upgradeNFT(uint256 tokenId, uint256 newTier) external onlyAdminOrBackend whenNotPaused {
        tokenTier[tokenId] = newTier;
        emit NFTUpgraded(tokenId, newTier);
    }

    /// @notice Update the custodial wallet address.
    function updateCustodialWallet(address newCustodialWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCustodialWallet != address(0), "Invalid wallet address");
        emit CustodialWalletUpdated(custodialWallet, newCustodialWallet);
        custodialWallet = newCustodialWallet;
    }

    /// @notice Update the token URI for a given token.
    function updateTokenURI(uint256 tokenId, string memory newTokenURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");
        _setTokenURI(tokenId, newTokenURI);
        emit TokenURIUpdated(tokenId, newTokenURI);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Override _update to restrict transfers for soulbound tokens.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // Allow minting (from == address(0)), burning (to == address(0)), or claiming (from is the custodial wallet).
        if (from != address(0) && to != address(0) && from != custodialWallet) {
            revert("SoulBoundNFT: Transfer not allowed");
        }
        return super._update(to, tokenId, auth);
    }

    /// @notice Link a premium NFT to a loyalty NFT.
    function addPremiumLink(uint256 loyaltyTokenId, uint256 premiumTokenId) external {
        uint256[] storage links = premiumLinks[loyaltyTokenId];
        require(links.length < maxPremiumLinks, "Max premium links reached");
        links.push(premiumTokenId);
        premiumIndex[loyaltyTokenId][premiumTokenId] = links.length - 1;
        emit PremiumLinkAdded(loyaltyTokenId, premiumTokenId);
    }

    /// @notice Remove a premium NFT link from a loyalty NFT.
    function removePremiumLink(uint256 loyaltyTokenId, uint256 premiumTokenId) external {
        uint256[] storage links = premiumLinks[loyaltyTokenId];
        require(links.length > 0, "No premium links to remove");
        uint256 index = premiumIndex[loyaltyTokenId][premiumTokenId];
        uint256 lastIndex = links.length - 1;
        if (index != lastIndex) {
            uint256 lastPremiumId = links[lastIndex];
            links[index] = lastPremiumId;
            premiumIndex[loyaltyTokenId][lastPremiumId] = index;
        }
        links.pop();
        delete premiumIndex[loyaltyTokenId][premiumTokenId];
        emit PremiumLinkRemoved(loyaltyTokenId, premiumTokenId);
    }

    /// @notice Allows admin to update the maximum number of premium NFT links per Loyalty NFT.
    function setMaxPremiumLinks(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxPremiumLinks = newMax;
    }

    /// @dev Override _baseURI to return the baseURI.
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /// @dev Authorization for upgrades (UUPS pattern).
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
