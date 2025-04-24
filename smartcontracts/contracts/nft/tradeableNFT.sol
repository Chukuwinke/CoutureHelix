// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol"; 
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721PausableUpgradeable.sol";
import "../cUtils/cryptography/nfts/CustomERC721PermitUpgradeable.sol";
import "../access/AccessControlledUpgradeable.sol";
import "../access/RoleManager.sol";
import "hardhat/console.sol";


/// @notice Thrown when attempting to attach a TradeableNFT already linked
error AlreadyAttached();
/// @notice Thrown when attempting to attach beyond a LoyaltyNFT’s cap
error MaxTradeableLinksReached();
/// @notice Thrown if the EIP-712 signature deadline has passed
error SignatureExpired();
/// @notice Thrown if recovered signer ≠ expected user
error InvalidSignature();
/// @notice Thrown in metaDetach if the linkage doesn’t match
error DetachMismatch();
/// @notice Thrown when burn is blocked due to an existing link
error BurnBlocked();

// Interface for interacting with the Loyalty NFT contract.
interface ILoyaltyNFT {
    function addTradeableNFT_Link(uint256 loyaltyTokenId, uint256 TradeableNFT_TokenId) external;
    function removeTradeableNFT_Link(uint256 loyaltyTokenId, uint256 TradeableNFT_TokenId) external;
}

/*
  This contract implements production best practices by:
  - Enforcing immutable supply limits: The first mint for a collection/design locks in the maximum supply.
  - Updating on-chain minted counts via mappings.
  - Providing both singular and batch mint functions.
  - Automatically applying token-specific royalty settings at mint time.
  - Allowing different royalty preferences per token, per batch (e.g. per design) and per singular mint.
  - Restricting mint calls to trusted addresses via onlyDAOMultisigOrBackend.
*/

contract TradeableNFT is Initializable, ERC721Upgradeable, ERC721URIStorageUpgradeable, ReentrancyGuardUpgradeable, ERC2981Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ERC721PausableUpgradeable,AccessControlledUpgradeable, CustomERC721PermitUpgradeable {
    
    using ECDSA for bytes32;
    uint256 public tokenCount;

   /// @notice `keccak256("BACKEND_ROLE")`
       bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    
    
    // Mapping linking each Tradeable NFT (by tokenId) to its associated Loyalty NFT's tokenId.
    mapping(uint256 => uint256) public TradeableNFT_ToLoyaltyNFT;
    // Reference to the deployed Loyalty NFT contract.
    ILoyaltyNFT public loyaltyNFTContract;



    // EIP-712 type hashes & nonces
    bytes32 public constant ATTACH_TYPEHASH = keccak256(
        "Attach(address user,uint256 tradeableId,uint256 loyaltyId,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant DETACH_TYPEHASH = keccak256(
        "Detach(address user,uint256 tradeableId,uint256 loyaltyId,uint256 nonce,uint256 deadline)"
    );
    mapping(address => uint256) public sigNonces;

    // --- Supply Locking Storage ---
    // Lock in collection max supply on first mint.
    mapping(uint256 => uint256) public storedCollectionMaxSupply;
    // Lock in design max supply for each collection/design.
    mapping(uint256 => mapping(uint256 => uint256)) public storedDesignMaxSupply;

    // Minted counts.
    mapping(uint256 => uint256) public collectionMintedCount;
    mapping(uint256 => mapping(uint256 => uint256)) public designMintedCount;
    mapping(uint256 => bool) public isRedeemed;

    event TradeableNFTMinted(uint256 indexed tokenId, address indexed owner, uint256 collectionId, string tokenURI);
    event TradeableNFTTransferred(uint256 indexed tokenId, address from, address to, uint256 loyaltyTokenId);
    event TradeableNFTAttached(uint256 indexed TradeableNFT_TokenId, uint256 loyaltyTokenId);
    event TradeableNFTDetached(uint256 indexed TradeableNFT_TokenId, uint256 loyaltyTokenId);
    event TradeableNFTBurned(uint256 indexed tokenId);
    event TradeableNFTRedeemed(uint256 indexed tokenId);
    event TokenURIUpdated(uint256 indexed tokenId, string newTokenURI);


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract.
     * @param _loyaltyNFTContractAddress Address of the LoyaltyNFT contract.
     * @param daoMultisig Address used for Ownable and as fallback royalty recipient.
     * @param roleManagerAddress Address of the RoleManager contract.
     */
    function initialize(address _loyaltyNFTContractAddress, address daoMultisig, address roleManagerAddress) public initializer {
        __ERC721_init("TradeableNFT", "PNFT");
        __ERC721URIStorage_init();
        //__EIP712_init("TradeableNFT", "1");
        __ReentrancyGuard_init();
        __ERC2981_init();
        __Ownable_init(daoMultisig);
        __UUPSUpgradeable_init();
        __ERC721Permit_init("TradeableNFT"); // Initialize permit functionality
        __ERC721Pausable_init();
        __AccessControlled_init(roleManagerAddress);

        require(_loyaltyNFTContractAddress != address(0), "Invalid LoyaltyNFT address");
        loyaltyNFTContract = ILoyaltyNFT(_loyaltyNFTContractAddress);

        // Optionally, you can set a default royalty here (for tokens that don't override)
        // In our design, every mint call applies its own royalty settings.
        _setDefaultRoyalty(daoMultisig, 0);
    }

    // Restrict mint functions to only the owner or addresses with BACKEND_ROLE.
    modifier onlyDAOMultisigOrBackend() {
         if (msg.sender != owner() && !roleManager.hasRole(BACKEND_ROLE, msg.sender))
             revert NotAuthorized();
         _;
    }

    modifier onlyDAOMultisig() {
         if (msg.sender != owner())
             revert NotAuthorized();
         _;
    }

    // ===== Singular NFT Minting Functions for physical to digital 1:1, Events and challenges etc.. (Not Tied to Any Collection) =====

    /**
     * @notice Mint a singular NFT with automatic token-specific royalty settings.
     * @param to Recipient address.
     * @param tokenURI_ Token URI for metadata.
     * @param royaltyRecipient Address to receive royalties for this token.
     * @param royaltyBps Royalty fee in basis points.
     */
    function mintSingularTradeableNFT(
        address to,
        string memory tokenURI_,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyDAOMultisigOrBackend whenNotPaused returns (uint256) {
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
        // Automatically set token-specific royalty
        _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
        emit TradeableNFTMinted(tokenId, to, 0, tokenURI_);
        return tokenId;
    }

    /**
     * @notice Batch mint singular NFTs with the same royalty settings.
     * @param recipients Array of recipient addresses.
     * @param tokenURIs Array of token URIs.
     * @param royaltyRecipient Address to receive royalties for these tokens.
     * @param royaltyBps Royalty fee in basis points.
     */
    function batchMintSingularTradeableNFT(
        address[] calldata recipients,
        string[] calldata tokenURIs,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyDAOMultisigOrBackend whenNotPaused returns (uint256[] memory) {
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
            emit TradeableNFTMinted(tokenId, recipients[i], 0, tokenURIs[i]);
        }
        return mintedTokenIds;
    }

    // ===== Homogeneous Collection Minting Functions 
    //(for example a hoodie can have the same form but different colors,styles or fabrics
    // but are all considered the same collection) =====

    /**
     * @notice Mint an NFT from a homogeneous collection with automatic royalty settings.
     * @param collectionId Off-chain collection identifier.
     * @param fullTokenURI The token itself URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param royaltyRecipient Royalty recipient for this token.
     * @param royaltyBps Royalty fee in basis points.
     */
    function mintCollectionTradeableNFT(
        address to,
        uint256 collectionId,
        string calldata fullTokenURI,
        uint256 collectionMaxSupply,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyDAOMultisigOrBackend whenNotPaused returns (uint256) {
        if (storedCollectionMaxSupply[collectionId] == 0) {
            storedCollectionMaxSupply[collectionId] = collectionMaxSupply;
        }
        require(storedCollectionMaxSupply[collectionId] == collectionMaxSupply, "Mismatched collection max supply");
        require(collectionMintedCount[collectionId] < collectionMaxSupply, "Collection mint limit reached");

        collectionMintedCount[collectionId] += 1;
        tokenCount++;
        uint256 tokenId = tokenCount;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, fullTokenURI);
        // Automatically apply the provided royalty settings.
        _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
        emit TradeableNFTMinted(tokenId, to, collectionId, fullTokenURI);
        return tokenId;
    }

    /**
     * @notice Batch mint NFTs from a homogeneous collection with automatic royalty settings.
     * @param recipients Array of recipient addresses.
     * @param collectionId Off-chain collection identifier.
     * @param fullTokenURIs an array of token URIs.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param royaltyRecipient Royalty recipient for these tokens.
     * @param royaltyBps Royalty fee in basis points.
     */
    function batchMintCollectionTradeableNFT(
        address[] calldata recipients,
        uint256 collectionId,
        string[] calldata fullTokenURIs,
        uint256 collectionMaxSupply,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyDAOMultisigOrBackend whenNotPaused returns (uint256[] memory) {
        require(recipients.length == fullTokenURIs.length, "Arrays must be equal length");
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
            _setTokenURI(tokenId, fullTokenURIs[i]);
            mintedTokenIds[i] = tokenId;
            collectionMintedCount[collectionId] += 1;
            // Set token-specific royalty for each minted token.
            _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
            emit TradeableNFTMinted(tokenId, recipients[i], collectionId, fullTokenURIs[i]);
        }
        return mintedTokenIds;
    }

    // ===== Design-Specific Minting Functions =====

    /**
     * @notice Mint an NFT for a specific design within a collection with automatic royalty settings.
     * @param collectionId Off-chain collection identifier.
     * @param fullTokenURI The token URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param designIndex Off-chain design index.
     * @param designMaxSupply The maximum supply for this design.
     * @param royaltyRecipient Royalty recipient for this token.
     * @param royaltyBps Royalty fee in basis points.
     */
    function mintDesignTradeableNFT(
        address to,
        uint256 collectionId,
        string calldata fullTokenURI,
        uint256 collectionMaxSupply,
        uint256 designIndex,
        uint256 designMaxSupply,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyDAOMultisigOrBackend whenNotPaused returns (uint256) {
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
        _setTokenURI(tokenId, fullTokenURI);
        // Set token-specific royalty automatically.
        _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
        emit TradeableNFTMinted(tokenId, to, collectionId, fullTokenURI);
        return tokenId;
    }

    /**
     * @notice Batch mint NFTs for a specific design with automatic royalty settings.
     * @param recipients Array of recipient addresses.
     * @param collectionId Off-chain collection identifier.
     * @param fullTokenURIs The collection’s base URI.
     * @param collectionMaxSupply The maximum supply for the collection.
     * @param designIndex Off-chain design index.
     * @param designMaxSupply The maximum supply for this design.
     * @param royaltyRecipient Royalty recipient for these tokens.
     * @param royaltyBps Royalty fee in basis points.
     */
    function batchMintDesignTradeableNFT(
        address[] calldata recipients,
        uint256 collectionId,
        string[] calldata fullTokenURIs,
        uint256 collectionMaxSupply,
        uint256 designIndex,
        uint256 designMaxSupply,
        address royaltyRecipient,
        uint96 royaltyBps
    ) external onlyDAOMultisigOrBackend whenNotPaused returns (uint256[] memory) {
        require(recipients.length == fullTokenURIs.length, "Arrays must be equal length");
        
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
            _setTokenURI(tokenId, fullTokenURIs[i]);
            mintedTokenIds[i] = tokenId;
            collectionMintedCount[collectionId] += 1;
            designMintedCount[collectionId][designIndex] += 1;
            // Set token-specific royalty for each token in the batch.
            _setTokenRoyalty(tokenId, royaltyRecipient, royaltyBps);
            emit TradeableNFTMinted(tokenId, recipients[i], collectionId, fullTokenURIs[i]);
        }
        return mintedTokenIds;
    }

    // ===== Attachment/Detachment Functions =====

    function _verifySignature(
        address user,
        bytes32 structHash,
        //bytes memory encodedData,
        bytes calldata signature
    ) internal view returns (bytes32 digest) {
        // 2. Compute EIP‑712 digest
        digest = _hashTypedDataV4(structHash);
        // 3. Recover and check
        address signer = ECDSA.recover(digest, signature);
        if (signer != user) revert InvalidSignature(); 
        return digest;
    }


    // ===== Meta‑Attach Function =====
    function metaAttach(
        address user,
        uint256 tradeableId,
        uint256 loyaltyId,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant onlyDAOMultisigOrBackend whenNotPaused {
        if (block.timestamp > deadline) revert SignatureExpired();
        uint256 nonce = sigNonces[user];
        sigNonces[user] = nonce + 1;
        bytes32 structHash = keccak256(
            abi.encode(
                ATTACH_TYPEHASH,
                user,
                tradeableId,
                loyaltyId,
                nonce,
                deadline
            )
        );
        _verifySignature(user, structHash, signature);
        //console.log("in contract signer: ", signer);
        if (TradeableNFT_ToLoyaltyNFT[tradeableId] != 0) revert AlreadyAttached();
        TradeableNFT_ToLoyaltyNFT[tradeableId] = loyaltyId;
        loyaltyNFTContract.addTradeableNFT_Link(loyaltyId, tradeableId);
        emit TradeableNFTAttached(tradeableId, loyaltyId);
    }

    // ===== Meta‑Detach Function =====
    function metaDetach(
        address user,
        uint256 tradeableId,
        uint256 loyaltyId,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant onlyDAOMultisigOrBackend  whenNotPaused {
        if (block.timestamp > deadline) revert SignatureExpired();
        uint256 nonce = sigNonces[user];
        sigNonces[user] = nonce + 1;
        bytes32 structHash = keccak256(
            abi.encode(
                DETACH_TYPEHASH,
                user,
                tradeableId,
                loyaltyId,
                nonce,
                deadline
            )
        );
        _verifySignature(user, structHash, signature);

        if (TradeableNFT_ToLoyaltyNFT[tradeableId] != loyaltyId) revert DetachMismatch();
        delete TradeableNFT_ToLoyaltyNFT[tradeableId];
        loyaltyNFTContract.removeTradeableNFT_Link(loyaltyId, tradeableId);
        emit TradeableNFTDetached(tradeableId, loyaltyId);
    }

    /**
    * @notice Update the token URI for metadata correction.
    * @dev Only callable by a DAO multisig or backend address.
    *      This function can be used to point to a new IPFS hash if metadata needs to be corrected.
    * @param tokenId The token identifier.
    * @param newTokenURI The new URI (pointing to metadata on IPFS).
    */
    function updateTokenURI(uint256 tokenId, string memory newTokenURI)
        external
        onlyDAOMultisigOrBackend
        whenNotPaused
    {
        // Ensure that the token exists by checking the current owner.
        // Using _ownerOf(tokenId) != address(0) instead of a now-deprecated _exists().
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        // Update token metadata by setting the new URI.
        _setTokenURI(tokenId, newTokenURI);
        emit TokenURIUpdated(tokenId, newTokenURI);
    }


    // ===== Royalty Management Functions =====
    // updateDefaultRoyalty now sets the default for tokens that don't override token-specific royalty.
    function updateDefaultRoyalty(address recipient, uint96 feeNumerator) external onlyDAOMultisigOrBackend {
        _setDefaultRoyalty(recipient, feeNumerator);
    }

    // updateTokenRoyalty now becomes a fallback for tokens that need a manual override.
    function updateTokenRoyalty(uint256 tokenId, address recipient, uint96 feeNumerator) external onlyDAOMultisigOrBackend {
        _setTokenRoyalty(tokenId, recipient, feeNumerator);
    }

    function markAsRedeemed(uint256 tokenId) external onlyDAOMultisigOrBackend whenNotPaused {
        // This function can be called when the linked physical product is redeemed.
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        // It might also check other conditions such as if token is not already marked redeemed.
        isRedeemed[tokenId] = true;
        emit TradeableNFTRedeemed(tokenId);
    }


    function burnTradeableNFT(uint256 tokenId) external onlyDAOMultisigOrBackend whenNotPaused {
        // Confirm token exists and additional conditions are met (see below)
        if (_ownerOf(tokenId) == address(0)) revert NotAuthorized();  // or custom “TokenNotExist”
        // Perform any additional checks here (e.g., token is not attached to a loyalty NFT)
        if (TradeableNFT_ToLoyaltyNFT[tokenId] != 0) revert BurnBlocked();
        
        // Remove token-specific settings if needed: clear royalty info, token URI, etc.
        _burn(tokenId);
        emit TradeableNFTBurned(tokenId);
    }


    // ===== Custom _update Hook =====

    function _update(address to, uint256 tokenId, address auth) internal override(ERC721PausableUpgradeable, ERC721Upgradeable) whenNotPaused returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && TradeableNFT_ToLoyaltyNFT[tokenId] != 0) {
            uint256 loyaltyTokenId = TradeableNFT_ToLoyaltyNFT[tokenId];
            delete TradeableNFT_ToLoyaltyNFT[tokenId];
            loyaltyNFTContract.removeTradeableNFT_Link(loyaltyTokenId, tokenId);
            emit TradeableNFTDetached(tokenId, loyaltyTokenId);
            emit TradeableNFTTransferred(tokenId, from, to, loyaltyTokenId);
        }
        return super._update(to, tokenId, auth);
    }

    // Emergency pause functions: allow admin (DAOMultisig) to pause/unpause the contract.
    function pause() external onlyDAOMultisig{
        _pause();
    }

    function unpause() external onlyDAOMultisig {
        _unpause();
    }

    // ===== Overrides =====

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgrader {}
}
