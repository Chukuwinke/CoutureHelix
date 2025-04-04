// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol"; 
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../RoleManager.sol";

// Interface for interacting with the Loyalty NFT contract.
interface ILoyaltyNFT {
    function addPremiumLink(uint256 loyaltyTokenId, uint256 premiumTokenId) external;
    function removePremiumLink(uint256 loyaltyTokenId, uint256 premiumTokenId) external;
}

/*
  This contract implements production best practices by:
  - Enforcing immutable supply limits: The first mint for a collection/design locks in the maximum supply.
  - Updating on-chain minted counts via mappings.
  - Providing both singular and batch mint functions.
  - Automatically applying token-specific royalty settings at mint time.
  - Allowing different royalty preferences per token, per batch (e.g. per design) and per singular mint.
  - Restricting mint calls to trusted addresses via onlyAdminOrBackend.
*/

contract PremiumNFTUpgradeable is Initializable, ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 public tokenCount;
    RoleManager public roleManager;
    
    // Mapping linking each premium NFT (by tokenId) to its associated Loyalty NFT's tokenId.
    mapping(uint256 => uint256) public premiumToLoyalty;
    
    // Reference to the deployed Loyalty NFT contract.
    ILoyaltyNFT public loyaltyNFTContract;

    // --- Supply Locking Storage ---
    // Lock in collection max supply on first mint.
    mapping(uint256 => uint256) public storedCollectionMaxSupply;
    // Lock in design max supply for each collection/design.
    mapping(uint256 => mapping(uint256 => uint256)) public storedDesignMaxSupply;

    // Minted counts.
    mapping(uint256 => uint256) public collectionMintedCount;
    mapping(uint256 => mapping(uint256 => uint256)) public designMintedCount;

    event PremiumNFTMinted(uint256 indexed tokenId, address indexed owner, uint256 collectionId, string tokenURI);
    event PremiumNFTTransferred(uint256 indexed tokenId, address from, address to, uint256 loyaltyTokenId);
    event PremiumNFTAttached(uint256 indexed premiumTokenId, uint256 loyaltyTokenId);
    event PremiumNFTDetached(uint256 indexed premiumTokenId, uint256 loyaltyTokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract.
     * @param _loyaltyNFTContractAddress Address of the LoyaltyNFT contract.
     * @param multisigAddress Address used for Ownable and as fallback royalty recipient.
     * @param roleManagerAddress Address of the RoleManager contract.
     */
    function initialize(address _loyaltyNFTContractAddress, address multisigAddress, address roleManagerAddress) public initializer {
        __ERC721_init("PremiumNFT", "PNFT");
        __ERC721URIStorage_init();
        __ERC2981_init();
        __Ownable_init(multisigAddress);
        __UUPSUpgradeable_init();

        require(_loyaltyNFTContractAddress != address(0), "Invalid LoyaltyNFT address");
        loyaltyNFTContract = ILoyaltyNFT(_loyaltyNFTContractAddress);
        roleManager = RoleManager(roleManagerAddress);

        // Optionally, you can set a default royalty here (for tokens that don't override)
        // In our design, every mint call applies its own royalty settings.
        _setDefaultRoyalty(multisigAddress, 0);
    }

    // Restrict mint functions to only the owner or addresses with BACKEND_ROLE.
    modifier onlyAdminOrBackend() {
        require(
            msg.sender == owner() || roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender),
            "Not authorized"
        );
        _;
    }

    // ===== Singular NFT Minting Functions (Not Tied to Any Collection) =====

    /**
     * @notice Mint a singular NFT with automatic token-specific royalty settings.
     * @param to Recipient address.
     * @param tokenURI_ Token URI for metadata.
     * @param royaltyRecipient Address to receive royalties for this token.
     * @param royaltyBps Royalty fee in basis points.
     */
    function mintSingularPremiumNFT(
        address to,
        string memory tokenURI_,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyAdminOrBackend returns (uint256) {
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
        // Automatically set token-specific royalty
        _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
        emit PremiumNFTMinted(tokenId, to, 0, tokenURI_);
        return tokenId;
    }

    /**
     * @notice Batch mint singular NFTs with the same royalty settings.
     * @param recipients Array of recipient addresses.
     * @param tokenURIs Array of token URIs.
     * @param royaltyRecipient Address to receive royalties for these tokens.
     * @param royaltyBps Royalty fee in basis points.
     */
    function batchMintSingularPremiumNFT(
        address[] calldata recipients,
        string[] calldata tokenURIs,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyAdminOrBackend returns (uint256[] memory) {
        require(recipients.length == tokenURIs.length, "Arrays must be equal length");
        uint256 numToMint = recipients.length;
        uint256[] memory mintedTokenIds = new uint256[](numToMint);
        for (uint256 i = 0; i < numToMint; i++) {
            tokenCount++;
            uint256 tokenId = tokenCount;
            _safeMint(recipients[i], tokenId);
            _setTokenURI(tokenId, tokenURIs[i]);
            // Automatically set token-specific royalty for each token in the batch.
            _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
            mintedTokenIds[i] = tokenId;
            emit PremiumNFTMinted(tokenId, recipients[i], 0, tokenURIs[i]);
        }
        return mintedTokenIds;
    }

    // ===== Homogeneous Collection Minting Functions =====

    /**
     * @notice Mint an NFT from a homogeneous collection with automatic royalty settings.
     * @param collectionId Off-chain collection identifier.
     * @param collectionBaseURI The collection’s base URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param tokenSuffixURI Token-specific suffix (e.g., "001.json").
     * @param royaltyRecipient Royalty recipient for this token.
     * @param royaltyBps Royalty fee in basis points.
     */
    function mintCollectionPremiumNFT(
        address to,
        uint256 collectionId,
        string calldata collectionBaseURI,
        uint256 collectionMaxSupply,
        string calldata tokenSuffixURI,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyAdminOrBackend returns (uint256) {
        if (storedCollectionMaxSupply[collectionId] == 0) {
            storedCollectionMaxSupply[collectionId] = collectionMaxSupply;
        }
        require(storedCollectionMaxSupply[collectionId] == collectionMaxSupply, "Mismatched collection max supply");
        require(collectionMintedCount[collectionId] < collectionMaxSupply, "Collection mint limit reached");

        collectionMintedCount[collectionId] += 1;
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        string memory fullTokenURI = string(abi.encodePacked(collectionBaseURI, tokenSuffixURI));
        _setTokenURI(tokenId, fullTokenURI);
        // Automatically apply the provided royalty settings.
        _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
        emit PremiumNFTMinted(tokenId, to, collectionId, fullTokenURI);
        return tokenId;
    }

    /**
     * @notice Batch mint NFTs from a homogeneous collection with automatic royalty settings.
     * @param recipients Array of recipient addresses.
     * @param collectionId Off-chain collection identifier.
     * @param collectionBaseURI The collection’s base URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param tokenSuffixURIs Array of token-specific suffixes.
     * @param royaltyRecipient Royalty recipient for these tokens.
     * @param royaltyBps Royalty fee in basis points.
     */
    function batchMintCollectionPremiumNFT(
        address[] calldata recipients,
        uint256 collectionId,
        string calldata collectionBaseURI,
        uint256 collectionMaxSupply,
        string[] calldata tokenSuffixURIs,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyAdminOrBackend returns (uint256[] memory) {
        require(recipients.length == tokenSuffixURIs.length, "Arrays must be equal length");
        if (storedCollectionMaxSupply[collectionId] == 0) {
            storedCollectionMaxSupply[collectionId] = collectionMaxSupply;
        }
        require(storedCollectionMaxSupply[collectionId] == collectionMaxSupply, "Mismatched collection max supply");
        require(collectionMintedCount[collectionId] + recipients.length <= collectionMaxSupply, "Collection mint limit reached");

        uint256[] memory mintedTokenIds = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            tokenCount++;
            uint256 tokenId = tokenCount;
            _safeMint(recipients[i], tokenId);
            string memory fullTokenURI = string(abi.encodePacked(collectionBaseURI, tokenSuffixURIs[i]));
            _setTokenURI(tokenId, fullTokenURI);
            mintedTokenIds[i] = tokenId;
            collectionMintedCount[collectionId] += 1;
            // Set token-specific royalty for each minted token.
            _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
            emit PremiumNFTMinted(tokenId, recipients[i], collectionId, fullTokenURI);
        }
        return mintedTokenIds;
    }

    // ===== Design-Specific Minting Functions =====

    /**
     * @notice Mint an NFT for a specific design within a collection with automatic royalty settings.
     * @param collectionId Off-chain collection identifier.
     * @param collectionBaseURI The collection’s base URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param designIndex Off-chain design index.
     * @param designBaseSuffixURI The design's base suffix URI.
     * @param designMaxSupply The maximum supply for this design.
     * @param tokenSuffixURI Token-specific suffix (e.g., "001.json").
     * @param royaltyRecipient Royalty recipient for this token.
     * @param royaltyBps Royalty fee in basis points.
     */
    function mintDesignPremiumNFT(
        address to,
        uint256 collectionId,
        string calldata collectionBaseURI,
        uint256 collectionMaxSupply,
        uint256 designIndex,
        string calldata designBaseSuffixURI,
        uint256 designMaxSupply,
        string calldata tokenSuffixURI,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyAdminOrBackend returns (uint256) {
        if (storedCollectionMaxSupply[collectionId] == 0) {
            storedCollectionMaxSupply[collectionId] = collectionMaxSupply;
        }
        require(storedCollectionMaxSupply[collectionId] == collectionMaxSupply, "Mismatched collection max supply");
        require(collectionMintedCount[collectionId] < collectionMaxSupply, "Collection mint limit reached");

        if (storedDesignMaxSupply[collectionId][designIndex] == 0) {
            storedDesignMaxSupply[collectionId][designIndex] = designMaxSupply;
        }
        require(storedDesignMaxSupply[collectionId][designIndex] == designMaxSupply, "Mismatched design max supply");
        require(designMintedCount[collectionId][designIndex] < designMaxSupply, "Design mint limit reached");

        collectionMintedCount[collectionId] += 1;
        designMintedCount[collectionId][designIndex] += 1;
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        string memory fullTokenURI = string(abi.encodePacked(collectionBaseURI, designBaseSuffixURI, tokenSuffixURI));
        _setTokenURI(tokenId, fullTokenURI);
        // Set token-specific royalty automatically.
        _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
        emit PremiumNFTMinted(tokenId, to, collectionId, fullTokenURI);
        return tokenId;
    }

    /**
     * @notice Batch mint NFTs for a specific design with automatic royalty settings.
     * @param recipients Array of recipient addresses.
     * @param collectionId Off-chain collection identifier.
     * @param collectionBaseURI The collection’s base URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param designIndex Off-chain design index.
     * @param designBaseSuffixURI The design's base suffix URI.
     * @param designMaxSupply The maximum supply for this design.
     * @param tokenSuffixURIs Array of token-specific suffixes.
     * @param royaltyRecipient Royalty recipient for these tokens.
     * @param royaltyBps Royalty fee in basis points.
     */
    function batchMintDesignPremiumNFT(
        address[] calldata recipients,
        uint256 collectionId,
        string calldata collectionBaseURI,
        uint256 collectionMaxSupply,
        uint256 designIndex,
        string calldata designBaseSuffixURI,
        uint256 designMaxSupply,
        string[] calldata tokenSuffixURIs,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyAdminOrBackend returns (uint256[] memory) {
        require(recipients.length == tokenSuffixURIs.length, "Arrays must be equal length");
        
        if (storedCollectionMaxSupply[collectionId] == 0) {
            storedCollectionMaxSupply[collectionId] = collectionMaxSupply;
        }
        require(storedCollectionMaxSupply[collectionId] == collectionMaxSupply, "Mismatched collection max supply");
        require(collectionMintedCount[collectionId] + recipients.length <= collectionMaxSupply, "Collection mint limit reached");

        if (storedDesignMaxSupply[collectionId][designIndex] == 0) {
            storedDesignMaxSupply[collectionId][designIndex] = designMaxSupply;
        }
        require(storedDesignMaxSupply[collectionId][designIndex] == designMaxSupply, "Mismatched design max supply");
        require(designMintedCount[collectionId][designIndex] + recipients.length <= designMaxSupply, "Design mint limit reached");

        uint256[] memory mintedTokenIds = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            tokenCount++;
            uint256 tokenId = tokenCount;
            _safeMint(recipients[i], tokenId);
            string memory fullTokenURI = string(abi.encodePacked(collectionBaseURI, designBaseSuffixURI, tokenSuffixURIs[i]));
            _setTokenURI(tokenId, fullTokenURI);
            mintedTokenIds[i] = tokenId;
            collectionMintedCount[collectionId] += 1;
            designMintedCount[collectionId][designIndex] += 1;
            // Set token-specific royalty for each token in the batch.
            _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
            emit PremiumNFTMinted(tokenId, recipients[i], collectionId, fullTokenURI);
        }
        return mintedTokenIds;
    }

    // ===== Attachment/Detachment Functions =====

    function attachPremiumNFT(uint256 premiumTokenId, uint256 loyaltyTokenId) external onlyAdminOrBackend {
        require(premiumToLoyalty[premiumTokenId] == 0, "Premium NFT already attached");
        premiumToLoyalty[premiumTokenId] = loyaltyTokenId;
        loyaltyNFTContract.addPremiumLink(loyaltyTokenId, premiumTokenId);
        emit PremiumNFTAttached(premiumTokenId, loyaltyTokenId);
    }

    function detachPremiumNFT(uint256 premiumTokenId, uint256 loyaltyTokenId) external onlyAdminOrBackend {
        require(premiumToLoyalty[premiumTokenId] == loyaltyTokenId, "Premium NFT not attached to this Loyalty NFT");
        delete premiumToLoyalty[premiumTokenId];
        loyaltyNFTContract.removePremiumLink(loyaltyTokenId, premiumTokenId);
        emit PremiumNFTDetached(premiumTokenId, loyaltyTokenId);
    }

    // ===== Royalty Management Functions =====
    // updateDefaultRoyalty now sets the default for tokens that don't override token-specific royalty.
    function updateDefaultRoyalty(address recipient, uint96 feeNumerator) external onlyAdminOrBackend {
        _setDefaultRoyalty(recipient, feeNumerator);
    }

    // updateTokenRoyalty now becomes a fallback for tokens that need a manual override.
    function updateTokenRoyalty(uint256 tokenId, address recipient, uint96 feeNumerator) external onlyAdminOrBackend {
        _setTokenRoyalty(tokenId, recipient, feeNumerator);
    }

    // ===== Custom _update Hook =====

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && premiumToLoyalty[tokenId] != 0) {
            uint256 loyaltyTokenId = premiumToLoyalty[tokenId];
            delete premiumToLoyalty[tokenId];
            loyaltyNFTContract.removePremiumLink(loyaltyTokenId, tokenId);
            emit PremiumNFTDetached(tokenId, loyaltyTokenId);
            emit PremiumNFTTransferred(tokenId, from, to, loyaltyTokenId);
        }
        return super._update(to, tokenId, auth);
    }

    // ===== Overrides =====

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
