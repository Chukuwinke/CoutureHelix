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

contract PremiumNFTUpgradeable is Initializable, ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 public tokenCount;
    RoleManager public roleManager;
    
    // Mapping linking each premium NFT (by its tokenId) to the associated Loyalty NFT's tokenId (if attached)
    mapping(uint256 => uint256) public premiumToLoyalty;
    
    // Reference to the deployed Loyalty NFT contract.
    ILoyaltyNFT public loyaltyNFTContract;

    // ===== Collection Management =====
    struct Collection {
        string name;
        string collectionBaseURI;    // Base URI for tokens in the collection
        uint256 maxSupply;           // Maximum number of tokens in the collection
        uint256 mintedCount;         // Number of tokens minted in this collection
    }
    uint256 public collectionCount;
    mapping(uint256 => Collection) public collections;

    event CollectionCreated(uint256 indexed collectionId, string name, string collectionBaseURI, uint256 maxSupply);
    // ==================================

    event PremiumNFTMinted(uint256 indexed tokenId, address indexed owner, uint256 collectionId, string tokenURI);
    event PremiumNFTTransferred(uint256 indexed tokenId, address from, address to, uint256 loyaltyTokenId);
    event PremiumNFTAttached(uint256 indexed premiumTokenId, uint256 loyaltyTokenId);
    event PremiumNFTDetached(uint256 indexed premiumTokenId, uint256 loyaltyTokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _loyaltyNFTContractAddress, address multisigAddress, address roleManagerAddress) public initializer {
        __ERC721_init("PremiumNFT", "PNFT");
        __ERC721URIStorage_init();
        __ERC2981_init();
        __Ownable_init(multisigAddress);
        __UUPSUpgradeable_init();

        require(_loyaltyNFTContractAddress != address(0), "Invalid LoyaltyNFT address");
        loyaltyNFTContract = ILoyaltyNFT(_loyaltyNFTContractAddress);

        roleManager = RoleManager(roleManagerAddress);

        // Set default royalty of 5% (500 basis points) to multisig.
        _setDefaultRoyalty(multisigAddress, 500);
    }

    // Custom modifier: allows calls from the owner or the backend.
    modifier onlyAdminOrBackend() {
        require(
            msg.sender == owner() || roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender),
            "Not authorized"
        );
        _;
    }

    // ===== Collection Management Functions =====
    function createCollection(string memory name, string memory collectionBaseURI, uint256 maxSupply) external onlyAdminOrBackend returns (uint256) {
        require(maxSupply > 0, "Max supply must be > 0");
        collectionCount++;
        collections[collectionCount] = Collection({
            name: name,
            collectionBaseURI: collectionBaseURI,
            maxSupply: maxSupply,
            mintedCount: 0
        });
        emit CollectionCreated(collectionCount, name, collectionBaseURI, maxSupply);
        return collectionCount;
    }

    // ===== Single Minting Functions =====

    function mintSingularPremiumNFT(address to, string memory tokenURI_) external onlyAdminOrBackend returns (uint256) {
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
        emit PremiumNFTMinted(tokenId, to, 0, tokenURI_); // Collection ID 0 indicates singular mint.
        return tokenId;
    }

    function mintCollectionPremiumNFT(address to, uint256 collectionId, string memory tokenSuffixURI) external onlyAdminOrBackend returns (uint256) {
        require(collectionId > 0 && collectionId <= collectionCount, "Invalid collection ID");
        Collection storage coll = collections[collectionId];
        require(coll.mintedCount < coll.maxSupply, "Collection mint limit reached");

        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        // Construct full token URI: collectionBaseURI + tokenSuffixURI.
        string memory fullTokenURI = bytes(coll.collectionBaseURI).length > 0 ? string(abi.encodePacked(coll.collectionBaseURI, tokenSuffixURI)) : tokenSuffixURI;
        _setTokenURI(tokenId, fullTokenURI);
        coll.mintedCount++;
        emit PremiumNFTMinted(tokenId, to, collectionId, fullTokenURI);
        return tokenId;
    }

    // ===== Batch Minting Functions =====

    // Batch mint singular premium NFTs.
    function batchMintSingularPremiumNFT(address[] calldata recipients, string[] calldata tokenURIs) external onlyAdminOrBackend returns (uint256[] memory) {
        require(recipients.length == tokenURIs.length, "Arrays must be equal length");
        uint256 numToMint = recipients.length;
        uint256[] memory mintedTokenIds = new uint256[](numToMint);
        for (uint256 i = 0; i < numToMint; i++) {
            tokenCount++;
            uint256 tokenId = tokenCount;
            _safeMint(recipients[i], tokenId);
            _setTokenURI(tokenId, tokenURIs[i]);
            mintedTokenIds[i] = tokenId;
            emit PremiumNFTMinted(tokenId, recipients[i], 0, tokenURIs[i]);
        }
        return mintedTokenIds;
    }

    // Batch mint NFTs from a specific collection.
    function batchMintCollectionPremiumNFT(address[] calldata recipients, uint256 collectionId, string[] calldata tokenSuffixURIs) external onlyAdminOrBackend returns (uint256[] memory) {
        require(recipients.length == tokenSuffixURIs.length, "Arrays must be equal length");
        require(collectionId > 0 && collectionId <= collectionCount, "Invalid collection ID");
        Collection storage coll = collections[collectionId];
        uint256 numToMint = recipients.length;
        require(coll.mintedCount + numToMint <= coll.maxSupply, "Collection mint limit reached");

        uint256[] memory mintedTokenIds = new uint256[](numToMint);
        for (uint256 i = 0; i < numToMint; i++) {
            tokenCount++;
            uint256 tokenId = tokenCount;
            _safeMint(recipients[i], tokenId);
            string memory fullTokenURI = bytes(coll.collectionBaseURI).length > 0
                ? string(abi.encodePacked(coll.collectionBaseURI, tokenSuffixURIs[i]))
                : tokenSuffixURIs[i];
            _setTokenURI(tokenId, fullTokenURI);
            mintedTokenIds[i] = tokenId;
            coll.mintedCount++;
            emit PremiumNFTMinted(tokenId, recipients[i], collectionId, fullTokenURI);
        }
        return mintedTokenIds;
    }

    // ===== Manual Attachment/Detachment Functions =====
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
    function updateDefaultRoyalty(address recipient, uint96 feeNumerator) external onlyAdminOrBackend {
        _setDefaultRoyalty(recipient, feeNumerator);
    }

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
