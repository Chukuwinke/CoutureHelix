// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "./Token.sol";
import "./RoleManager.sol";

contract FashionDNA is ReentrancyGuardUpgradeable, PausableUpgradeable, ERC721Upgradeable, ERC2981Upgradeable, UUPSUpgradeable, AccessControlUpgradeable {
    Token public rewardToken;
    RoleManager public roleManager;

    uint256 public tokenCounter;
    uint256 public requestCounter;
    string public baseURI; // Base URI for all token URIs

    struct ModificationRequest {
        address requester;
        string metadataURI; // Metadata URI instead of tokenURI mapping
        uint256 rewardAmount;
        bytes32 immutableMetadataHash;
        bool finalized;
        bool approved;
    }

    struct Provenance {
        address originalDesigner;
        bool valid;
    }

    mapping(uint256 => ModificationRequest) public modificationRequests;
    mapping(uint256 => Provenance) public provenance;
    mapping(uint256 => address[]) public provenanceHistory;
    mapping(uint256 => string) public tokenMetadataURI; // Store metadata for finalized NFTs
    mapping(uint256 => bytes32) public rewardMerkleRoots;
    mapping(uint256 => mapping(address => bool)) public claimedRewards;
    mapping(uint256 => uint256) public rewardExpiry;
    mapping(uint256 => uint256) public finalizedRewards; // Store total reward amounts for finalized requests
    mapping(uint256 => uint256) public claimedRewardsTotal; // Store the total claimed rewards for each request


    event ModificationRequested(uint256 indexed requestId, address indexed requester, string metadataURI, uint256 rewardAmount, bytes32 immutableMetadataHash);
    event ModificationFinalized(uint256 indexed requestId, bool approved);
    event RewardClaimed(address indexed validator, uint256 amount);
    event NFTMinted(uint256 indexed tokenId, address indexed owner, string metadataURI);
    event ProvenanceFlagged(uint256 indexed tokenId, bool valid);
    event RewardBurned(uint256 indexed requestId, uint256 unclaimedAmount);
    event MetadataUpdated(uint256 indexed tokenId, string newMetadataURI);
    event RoyaltyUpdated(uint256 indexed tokenId, address indexed recipient, uint96 feeNumerator);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address tokenAddress, address roleManagerAddress, string memory initialBaseURI) public initializer {
         __ReentrancyGuard_init();
        __ERC721_init("FashionDNA", "FDNA");
        __ERC2981_init(); // Initialize ERC2981
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
       

        rewardToken = Token(tokenAddress);
        roleManager = RoleManager(roleManagerAddress);
        baseURI = initialBaseURI;

        tokenCounter = 1;
        requestCounter = 1;

        // Default royalty (e.g., 5%) applied to the original designer
        _setDefaultRoyalty(msg.sender, 500); // 500 = 5%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // Modifier for Backend Role
    modifier onlyBackendRole() {
        require(roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender), "FashionDNA: Caller does not have BACKEND_ROLE");
        _;
    }

    // Authorization for upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE){
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE){
        _unpause();
    }

    function batchRequestValidation(
        string[] memory metadataURIs,
        uint256[] memory rewardAmounts,
        bytes32[] memory immutableMetadataHashes
    ) public whenNotPaused {
        require(
            metadataURIs.length == rewardAmounts.length && 
            rewardAmounts.length == immutableMetadataHashes.length,
            "Input length mismatch"
        );

        for (uint256 i = 0; i < metadataURIs.length; i++) {
            requestValidation(metadataURIs[i], rewardAmounts[i], immutableMetadataHashes[i]);
        }
    }



    // Request Validation
    function requestValidation(
        string memory metadataURI,
        uint256 rewardAmount,
        bytes32 immutableMetadataHash
    ) public whenNotPaused {
        require(rewardAmount > 0, "Must provide a reward amount");
        require(immutableMetadataHash != bytes32(0), "Invalid metadata hash");
        require(rewardToken.transferFrom(msg.sender, address(this), rewardAmount), "Reward transfer failed");

        uint256 requestId = requestCounter++;
        modificationRequests[requestId] = ModificationRequest({
            requester: msg.sender,
            metadataURI: metadataURI,
            rewardAmount: rewardAmount,
            immutableMetadataHash: immutableMetadataHash,
            finalized: false,
            approved: false
        });

        emit ModificationRequested(requestId, msg.sender, metadataURI, rewardAmount, immutableMetadataHash);
    }

    function finalizeModification(uint256 requestId, bool approved) external onlyBackendRole whenNotPaused {
        ModificationRequest storage request = modificationRequests[requestId];
        require(!request.finalized, "Request already finalized");

        request.finalized = true;
        request.approved = approved;

        if (approved) {
             _mintNFT(request.requester, request.metadataURI, request.immutableMetadataHash);
        }

        emit ModificationFinalized(requestId, approved);
        delete modificationRequests[requestId];
        //delete requestToTokenId[requestId]; // Clean up if tokenId was stored
    }

    // Internal Function to Mint NFT
    function _mintNFT(address to, string memory metadataURI, bytes32 immutableMetadataHash) internal {
        require(immutableMetadataHash != bytes32(0), "FashionDNA: Metadata hash cannot be empty");

        uint256 tokenId = tokenCounter++;
        _safeMint(to, tokenId);

        tokenMetadataURI[tokenId] = metadataURI; // Store finalized metadata
        provenance[tokenId] = Provenance({ originalDesigner: to, valid: true });

        // Set a specific royalty for this token (e.g., 5%)
        _setTokenRoyalty(tokenId, to, 500); // 500 basis points = 5%

        emit NFTMinted(tokenId, to, metadataURI);
    }


    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address previousOwner = super._update(to, tokenId, auth);
        if (previousOwner != address(0) && to != address(0)) {
            require(provenance[tokenId].valid, "FashionDNA: Provenance is invalid");
            provenanceHistory[tokenId].push(to);
        }
        return previousOwner;
    }

    // Override tokenURI to support metadataURI
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(ownerOf(tokenId) != address(0), "FashionDNA: Token does not exist");

       string memory metadataURI = tokenMetadataURI[tokenId]; // Fetch from finalized mapping

        return bytes(baseURI).length > 0 && bytes(metadataURI).length > 0
            ? string(abi.encodePacked(baseURI, metadataURI))
            : "";
    }

    // Set Reward Distribution for Validators
    function setRewardDistribution(uint256 requestId, bytes32 merkleRoot, uint256 expiryTimestamp) external onlyBackendRole {
        require(rewardMerkleRoots[requestId] == bytes32(0), "Reward distribution already set");
        require(expiryTimestamp > block.timestamp, "Expiry must be in the future");
        rewardMerkleRoots[requestId] = merkleRoot;
        rewardExpiry[requestId] = expiryTimestamp;
    }


    // Claim Rewards
    function claimReward(uint256 requestId, uint256 rewardAmount, bytes32[] calldata merkleProof) public nonReentrant whenNotPaused {
        require(block.timestamp <= rewardExpiry[requestId], "Reward expired");
        require(!claimedRewards[requestId][msg.sender], "Reward already claimed");

        bytes32 node = keccak256(abi.encodePacked(msg.sender, rewardAmount));
        require(_verifyMerkleProof(merkleProof, rewardMerkleRoots[requestId], node), "Invalid proof");

        claimedRewards[requestId][msg.sender] = true;
        claimedRewardsTotal[requestId] += rewardAmount; // Track the total claimed rewards
        require(rewardToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");

        emit RewardClaimed(msg.sender, rewardAmount);
    }

    function burnExpiredRewards(uint256 requestId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(block.timestamp > rewardExpiry[requestId], "Reward not expired");
        require(rewardMerkleRoots[requestId] != bytes32(0), "No rewards to burn");

        uint256 unclaimedAmount = calculateUnclaimedRewards(requestId);
        if (unclaimedAmount > 0) {
            rewardToken.burn(unclaimedAmount); // Burn unclaimed tokens
        }

        // Cleanup data after burning rewards
        rewardMerkleRoots[requestId] = bytes32(0);
        rewardExpiry[requestId] = 0;
        finalizedRewards[requestId] = 0; // Clear finalized reward data
        claimedRewardsTotal[requestId] = 0; // Clear claimed rewards tracking

        emit RewardBurned(requestId, unclaimedAmount);
    }


    function calculateUnclaimedRewards(uint256 requestId) internal view returns (uint256) {
        uint256 totalReward = finalizedRewards[requestId];
        uint256 claimedTotal = claimedRewardsTotal[requestId];

        // Return the difference between total rewards and claimed rewards
        return totalReward - claimedTotal;
    }

    function BatchClaimRewards(
    uint256[] calldata requestIds,
    uint256[] calldata rewardAmounts,
    bytes32[][] calldata merkleProofs
        ) external whenNotPaused {
            require(requestIds.length == rewardAmounts.length, "Input length mismatch");
            require(rewardAmounts.length == merkleProofs.length, "Input length mismatch");

            for (uint256 i = 0; i < requestIds.length; i++) {
                claimReward(requestIds[i], rewardAmounts[i], merkleProofs[i]);
            }
    }

    // Merkle Proof Verification
    function _verifyMerkleProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return MerkleProof.verify(proof, root, leaf);
    }

    // Override _baseURI to Support Metadata URI
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    // Update Base URI
    function updateBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = newBaseURI;
    }

    function updateTokenMetadata(uint256 tokenId, string memory newMetadataURI) external onlyRole(DEFAULT_ADMIN_ROLE){
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not authorized");
        tokenMetadataURI[tokenId] = newMetadataURI;
    }


    // Provenance Getter
    function getProvenance(uint256 tokenId) external view returns (address, bool) {
        require(ownerOf(tokenId) != address(0), "FashionDNA: Token does not exist");
        Provenance memory prov = provenance[tokenId];
        return (prov.originalDesigner, prov.valid);
    }

    // Flag Provenance as Invalid
    function flagProvenanceInvalid(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(ownerOf(tokenId) != address(0), "FashionDNA: Token does not exist");
        provenance[tokenId].valid = false;

        emit ProvenanceFlagged(tokenId, false);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice) public view override returns (address, uint256) {
        // Call the parent implementation
        return super.royaltyInfo(tokenId, salePrice);
    }

    function updateDefaultRoyalty(address recipient, uint96 feeNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(recipient, feeNumerator);
    }

    function updateTokenRoyalty(uint256 tokenId, address recipient, uint96 feeNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTokenRoyalty(tokenId, recipient, feeNumerator);
        emit RoyaltyUpdated(tokenId, recipient, feeNumerator);
    }



    // Override supportsInterface
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC2981Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}






///////// ol /////////////////////////////////////
// pragma solidity ^0.8.27;

// import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
// import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
// import "./Token.sol";
// import "./RoleManager.sol";

// contract FashionDNA is ReentrancyGuardUpgradeable, PausableUpgradeable, ERC721Upgradeable, UUPSUpgradeable, AccessControlUpgradeable {
//     Token public rewardToken;
//     RoleManager public roleManager;

//     uint256 public tokenCounter;
//     uint256 public requestCounter;
//     string public baseURI; // Base URI for all token URIs

//     struct ModificationRequest {
//         address requester;
//         string metadataURI; // Metadata URI instead of tokenURI mapping
//         uint256 rewardAmount;
//         bytes32 immutableMetadataHash;
//         bool finalized;
//         bool approved;
//     }

//     struct Provenance {
//         address originalDesigner;
//         bool valid;
//     }

//     mapping(uint256 => ModificationRequest) public modificationRequests;
//     mapping(uint256 => Provenance) public provenance;
//     mapping(uint256 => address[]) public provenanceHistory;
//     mapping(uint256 => string) public tokenMetadataURI; // Store metadata for finalized NFTs
//     mapping(uint256 => bytes32) public rewardMerkleRoots;
//     mapping(uint256 => mapping(address => bool)) public claimedRewards;
//     mapping(uint256 => uint256) public rewardExpiry;
//     mapping(uint256 => uint256) public finalizedRewards; // Store total reward amounts for finalized requests
//     mapping(uint256 => uint256) public claimedRewardsTotal; // Store the total claimed rewards for each request
//     //mapping(uint256 => uint256) public requestToTokenId;


//     event ModificationRequested(uint256 indexed requestId, address indexed requester, string metadataURI, uint256 rewardAmount, bytes32 immutableMetadataHash);
//     event ModificationFinalized(uint256 indexed requestId, bool approved);
//     event RewardClaimed(address indexed validator, uint256 amount);
//     event NFTMinted(uint256 indexed tokenId, address indexed owner, string metadataURI);
//     event ProvenanceFlagged(uint256 indexed tokenId, bool valid);
//     event RewardBurned(uint256 indexed requestId, uint256 unclaimedAmount);
//     event MetadataUpdated(uint256 indexed tokenId, string newMetadataURI);

//     /// @custom:oz-upgrades-unsafe-allow constructor
//     constructor() {
//         _disableInitializers();
//     }

//     function initialize(address tokenAddress, address roleManagerAddress, string memory initialBaseURI) public initializer {
//          __ReentrancyGuard_init();
//         __ERC721_init("FashionDNA", "FDNA");
//         __UUPSUpgradeable_init();
//         __AccessControl_init();
//         __Pausable_init();
       

//         rewardToken = Token(tokenAddress);
//         roleManager = RoleManager(roleManagerAddress);
//         baseURI = initialBaseURI;

//         tokenCounter = 1;
//         requestCounter = 1;

//         _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
//     }

//     // Modifier for Backend Role
//     modifier onlyBackendRole() {
//         require(roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender), "FashionDNA: Caller does not have BACKEND_ROLE");
//         _;
//     }

//     // Authorization for upgrades
//     function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

//     function pause() external onlyRole(DEFAULT_ADMIN_ROLE){
//         _pause();
//     }

//     function unpause() external onlyRole(DEFAULT_ADMIN_ROLE){
//         _unpause();
//     }

//     function batchRequestValidation(
//         string[] memory metadataURIs,
//         uint256[] memory rewardAmounts,
//         bytes32[] memory immutableMetadataHashes
//     ) public whenNotPaused {
//         require(
//             metadataURIs.length == rewardAmounts.length && 
//             rewardAmounts.length == immutableMetadataHashes.length,
//             "Input length mismatch"
//         );

//         for (uint256 i = 0; i < metadataURIs.length; i++) {
//             requestValidation(metadataURIs[i], rewardAmounts[i], immutableMetadataHashes[i]);
//         }
//     }



//     // Request Validation
//     function requestValidation(
//         string memory metadataURI,
//         uint256 rewardAmount,
//         bytes32 immutableMetadataHash
//     ) public whenNotPaused {
//         require(rewardAmount > 0, "Must provide a reward amount");
//         require(immutableMetadataHash != bytes32(0), "Invalid metadata hash");
//         require(rewardToken.transferFrom(msg.sender, address(this), rewardAmount), "Reward transfer failed");

//         uint256 requestId = requestCounter++;
//         modificationRequests[requestId] = ModificationRequest({
//             requester: msg.sender,
//             metadataURI: metadataURI,
//             rewardAmount: rewardAmount,
//             immutableMetadataHash: immutableMetadataHash,
//             finalized: false,
//             approved: false
//         });

//         emit ModificationRequested(requestId, msg.sender, metadataURI, rewardAmount, immutableMetadataHash);
//     }

//     function finalizeModification(uint256 requestId, bool approved) external onlyBackendRole whenNotPaused {
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(!request.finalized, "Request already finalized");

//         request.finalized = true;
//         request.approved = approved;

//         if (approved) {
//              _mintNFT(request.requester, request.metadataURI, request.immutableMetadataHash);
//             // Check if the request has an associated tokenId
//             // uint256 tokenId = requestToTokenId[requestId];
//             // if (tokenId > 0) {
//             //     // Handle metadata updates
//             //     _updateTokenMetadata(tokenId, request.metadataURI);
//             // } else {
//             //     // Handle other request types (e.g., minting)
//             //     _mintNFT(request.requester, request.metadataURI, request.immutableMetadataHash);
//             // }
//         }

//         emit ModificationFinalized(requestId, approved);
//         delete modificationRequests[requestId];
//         //delete requestToTokenId[requestId]; // Clean up if tokenId was stored
//     }

//     function _updateTokenMetadata(uint256 tokenId, string memory newMetadataURI) internal {
//         require(bytes(newMetadataURI).length > 0, "Metadata URI cannot be empty");
//         tokenMetadataURI[tokenId] = newMetadataURI;

//         emit MetadataUpdated(tokenId, newMetadataURI);
//     }


//     // Internal Function to Mint NFT
//     function _mintNFT(address to, string memory metadataURI, bytes32 immutableMetadataHash) internal {
//         require(immutableMetadataHash != bytes32(0), "FashionDNA: Metadata hash cannot be empty");

//         uint256 tokenId = tokenCounter++;
//         _safeMint(to, tokenId);

//         tokenMetadataURI[tokenId] = metadataURI; // Store finalized metadata
//         provenance[tokenId] = Provenance({ originalDesigner: to, valid: true });

//         emit NFTMinted(tokenId, to, metadataURI);
//     }


//     function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
//         address previousOwner = super._update(to, tokenId, auth);
//         if (previousOwner != address(0) && to != address(0)) {
//             require(provenance[tokenId].valid, "FashionDNA: Provenance is invalid");
//             provenanceHistory[tokenId].push(to);
//         }
//         return previousOwner;
//     }

//     // Override tokenURI to support metadataURI
//     function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
//         require(ownerOf(tokenId) != address(0), "FashionDNA: Token does not exist");

//        string memory metadataURI = tokenMetadataURI[tokenId]; // Fetch from finalized mapping

//         return bytes(baseURI).length > 0 && bytes(metadataURI).length > 0
//             ? string(abi.encodePacked(baseURI, metadataURI))
//             : "";
//     }

//     // Set Reward Distribution for Validators
//     function setRewardDistribution(uint256 requestId, bytes32 merkleRoot, uint256 expiryTimestamp) external onlyBackendRole {
//         require(rewardMerkleRoots[requestId] == bytes32(0), "Reward distribution already set");
//         require(expiryTimestamp > block.timestamp, "Expiry must be in the future");
//         rewardMerkleRoots[requestId] = merkleRoot;
//         rewardExpiry[requestId] = expiryTimestamp;
//     }


//     // Claim Rewards
//     function claimReward(uint256 requestId, uint256 rewardAmount, bytes32[] calldata merkleProof) public nonReentrant whenNotPaused {
//         require(block.timestamp <= rewardExpiry[requestId], "Reward expired");
//         require(!claimedRewards[requestId][msg.sender], "Reward already claimed");

//         bytes32 node = keccak256(abi.encodePacked(msg.sender, rewardAmount));
//         require(_verifyMerkleProof(merkleProof, rewardMerkleRoots[requestId], node), "Invalid proof");

//         claimedRewards[requestId][msg.sender] = true;
//         claimedRewardsTotal[requestId] += rewardAmount; // Track the total claimed rewards
//         require(rewardToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");

//         emit RewardClaimed(msg.sender, rewardAmount);
//     }

//     function burnExpiredRewards(uint256 requestId) external onlyRole(DEFAULT_ADMIN_ROLE) {
//         require(block.timestamp > rewardExpiry[requestId], "Reward not expired");
//         require(rewardMerkleRoots[requestId] != bytes32(0), "No rewards to burn");

//         uint256 unclaimedAmount = calculateUnclaimedRewards(requestId);
//         if (unclaimedAmount > 0) {
//             rewardToken.burn(unclaimedAmount); // Burn unclaimed tokens
//         }

//         // Cleanup data after burning rewards
//         rewardMerkleRoots[requestId] = bytes32(0);
//         rewardExpiry[requestId] = 0;
//         finalizedRewards[requestId] = 0; // Clear finalized reward data
//         claimedRewardsTotal[requestId] = 0; // Clear claimed rewards tracking

//         emit RewardBurned(requestId, unclaimedAmount);
//     }


//     function calculateUnclaimedRewards(uint256 requestId) internal view returns (uint256) {
//         uint256 totalReward = finalizedRewards[requestId];
//         uint256 claimedTotal = claimedRewardsTotal[requestId];

//         // Return the difference between total rewards and claimed rewards
//         return totalReward - claimedTotal;
//     }

//     function BatchClaimRewards(
//     uint256[] calldata requestIds,
//     uint256[] calldata rewardAmounts,
//     bytes32[][] calldata merkleProofs
//         ) external whenNotPaused {
//             require(requestIds.length == rewardAmounts.length, "Input length mismatch");
//             require(rewardAmounts.length == merkleProofs.length, "Input length mismatch");

//             for (uint256 i = 0; i < requestIds.length; i++) {
//                 claimReward(requestIds[i], rewardAmounts[i], merkleProofs[i]);
//             }
//     }

//     // Merkle Proof Verification
//     function _verifyMerkleProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
//         return MerkleProof.verify(proof, root, leaf);
//     }

//     // Override _baseURI to Support Metadata URI
//     function _baseURI() internal view override returns (string memory) {
//         return baseURI;
//     }

//     // Update Base URI
//     function updateBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
//         baseURI = newBaseURI;
//     }

//     function updateTokenMetadata(uint256 tokenId, string memory newMetadataURI) external {
//         require(ownerOf(tokenId) == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not authorized");
//         tokenMetadataURI[tokenId] = newMetadataURI;
//     }


//     // Provenance Getter
//     function getProvenance(uint256 tokenId) external view returns (address, bool) {
//         require(ownerOf(tokenId) != address(0), "FashionDNA: Token does not exist");
//         Provenance memory prov = provenance[tokenId];
//         return (prov.originalDesigner, prov.valid);
//     }

//     // Flag Provenance as Invalid
//     function flagProvenanceInvalid(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
//         require(ownerOf(tokenId) != address(0), "FashionDNA: Token does not exist");
//         provenance[tokenId].valid = false;

//         emit ProvenanceFlagged(tokenId, false);
//     }

//     // Override supportsInterface
//     function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
//         return super.supportsInterface(interfaceId);
//     }
// }


//////////////////// ol ////////////////////////////

// Finalize Modification
    // function finalizeModification(uint256 requestId, bool approved) external onlyBackendRole whenNotPaused {
    //     ModificationRequest storage request = modificationRequests[requestId];
    //     require(!request.finalized, "Request already finalized");

    //     //!! find a way to make finalized bool async like a try catch so that it only 
    //     // becomes finalized after the mint process is succesfull
    //     request.finalized = true;
    //     request.approved = approved;

    //     if (approved) {
    //         _mintNFT(request.requester, request.metadataURI, request.immutableMetadataHash);

    //         // Store finalized reward amount before deleting the request
    //         finalizedRewards[requestId] = request.rewardAmount;

    //         // Clean up modification request after successful minting
    //         delete modificationRequests[requestId];
    //     }

    //     emit ModificationFinalized(requestId, approved);
    // }

// import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
// import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// import "./Token.sol";
// import "./RoleManager.sol"; // Import the RoleManager contract

// contract FashionDNA is Initializable, ERC721URIStorageUpgradeable, UUPSUpgradeable, AccessControlUpgradeable {

//     Token public rewardToken;
//     RoleManager public roleManager;

//     uint256 public tokenCounter;
//     uint256 public requestCounter;

//     struct ModificationRequest {
//         address requester;
//         string tokenURI;
//         uint256 rewardAmount;
//         bool finalized;
//         bool approved;
//     }

//     mapping(uint256 => ModificationRequest) public modificationRequests;
//     mapping(uint256 => bytes32) public rewardMerkleRoots; // Store Merkle roots for rewards
//     mapping(uint256 => mapping(address => bool)) public claimedRewards; // Track claimed rewards
    

//     event ModificationRequested(uint256 indexed requestId, address indexed requester, string tokenURI, uint256 rewardAmount);
//     event ModificationFinalized(uint256 indexed requestId, bool approved);
//     event RewardClaimed(address indexed validator, uint256 amount);
//     event NFTMinted(uint256 indexed tokenId, address indexed owner, string tokenURI);

//     /// @custom:oz-upgrades-unsafe-allow constructor
//     constructor() {
//         _disableInitializers();
//     }

//     function initialize(address tokenAddress, address roleManagerAddress) public initializer {
//         __ERC721_init("FashionDNA", "FDNA");
//         __ERC721URIStorage_init();
//         __UUPSUpgradeable_init();
//         __AccessControl_init();

//         rewardToken = Token(tokenAddress);
//         roleManager = RoleManager(roleManagerAddress);

//         tokenCounter = 1;
//         requestCounter = 1;

//         _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
//     }

//     modifier onlyBackendRole() {
//         require(roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender), "FashionDNA: Caller does not have BACKEND_ROLE");
//         _;
//     }

//     // Authorization for upgrades
//     function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

//     // Request Validation
//     function requestValidation(string memory _tokenURI, uint256 rewardAmount) public {
//         require(rewardAmount > 0, "Must provide a reward amount");
//         require(rewardToken.transferFrom(msg.sender, address(this), rewardAmount), "Reward transfer failed");

//         uint256 requestId = requestCounter++;
//         modificationRequests[requestId] = ModificationRequest({
//             requester: msg.sender,
//             tokenURI: _tokenURI,
//             rewardAmount: rewardAmount,
//             finalized: false,
//             approved: false
//         });

//         emit ModificationRequested(requestId, msg.sender, _tokenURI, rewardAmount);
//     }

//     // Finalize Modification
//     function finalizeModification(uint256 requestId, bool approved) external onlyBackendRole {
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(!request.finalized, "Request already finalized");

//         request.finalized = true;
//         request.approved = approved;

//         if (approved) {
//             _mintNFT(request.requester, request.tokenURI);
//         }
//         // !!! add else statement to handle unapproved functionality

//         emit ModificationFinalized(requestId, approved);
//     }

//     // Backend Sets Reward Distribution
//     function setRewardDistribution(uint256 requestId, bytes32 merkleRoot) external onlyBackendRole {
//         require(rewardMerkleRoots[requestId] == bytes32(0), "Reward distribution already set");
//         rewardMerkleRoots[requestId] = merkleRoot;
//     }

//     // Claim Rewards
//     function claimReward(
//         uint256 requestId,
//         uint256 rewardAmount,
//         bytes32[] calldata merkleProof
//     ) external {
//         require(!claimedRewards[requestId][msg.sender], "Reward already claimed");

//         bytes32 node = keccak256(abi.encodePacked(msg.sender, rewardAmount));
//         require(MerkleProof.verify(merkleProof, rewardMerkleRoots[requestId], node), "Invalid proof");

//         claimedRewards[requestId][msg.sender] = true;
//         require(rewardToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");

//         emit RewardClaimed(msg.sender, rewardAmount);
//     }

//     // Internal Function to Mint NFT
//     function _mintNFT(address to, string memory _tokenURI) internal {
//         uint256 tokenId = tokenCounter++;
//         _safeMint(to, tokenId);
//         _setTokenURI(tokenId, _tokenURI);
//         emit NFTMinted(tokenId, to, _tokenURI);
//     }

//     // Override supportsInterface
//     function supportsInterface(bytes4 interfaceId)
//         public
//         view
//         override(ERC721URIStorageUpgradeable, AccessControlUpgradeable)
//         returns (bool)
//     {
//         return super.supportsInterface(interfaceId);
//     }
// }


// import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
// import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// import "./Token.sol";
// import "./RoleManager.sol"; // Import the RoleManager contract

// contract FashionDNA is ERC721URIStorage {
//     bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
//     bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

//     Token public rewardToken;
//     RoleManager public roleManager; // Reference to RoleManager contract

//     uint256 public tokenCounter;
//     uint256 public requestCounter;

//     struct ModificationRequest {
//         address requester;
//         string tokenURI;
//         uint256 rewardAmount;
//         bool finalized;
//         bool approved;
//     }

//     mapping(uint256 => ModificationRequest) public modificationRequests;
//     mapping(uint256 => bytes32) public rewardMerkleRoots; // Store Merkle roots for rewards
//     mapping(uint256 => mapping(address => bool)) public claimedRewards; // Track claimed rewards

//     event ModificationRequested(uint256 indexed requestId, address indexed requester, string tokenURI, uint256 rewardAmount);
//     event ModificationFinalized(uint256 indexed requestId, bool approved);
//     event RewardClaimed(address indexed validator, uint256 amount);
//     event NFTMinted(uint256 indexed tokenId, address indexed owner, string tokenURI);

//     constructor(address tokenAddress, address roleManagerAddress) ERC721("FashionDNA", "FDNA") {
//         rewardToken = Token(tokenAddress);
//         roleManager = RoleManager(roleManagerAddress); // Set the RoleManager reference

//         tokenCounter = 1;
//         requestCounter = 1;
//     }

//     modifier onlyBackendRole() {
//         require(roleManager.hasRole(roleManager.BACKEND_ROLE(), msg.sender), "FashionDNA: Caller does not have BACKEND_ROLE");
//         _;
//     }

//     // Request Validation
//     function requestValidation(string memory _tokenURI, uint256 rewardAmount) public {
//         require(rewardAmount > 0, "Must provide a reward amount");
//         require(rewardToken.transferFrom(msg.sender, address(this), rewardAmount), "Reward transfer failed");

//         uint256 requestId = requestCounter++;
//         modificationRequests[requestId] = ModificationRequest({
//             requester: msg.sender,
//             tokenURI: _tokenURI,
//             rewardAmount: rewardAmount,
//             finalized: false,
//             approved: false
//         });

//         emit ModificationRequested(requestId, msg.sender, _tokenURI, rewardAmount);
//     }

//     // Finalize Modification
//     function finalizeModification(uint256 requestId, bool approved) external onlyBackendRole {
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(!request.finalized, "Request already finalized");

//         request.finalized = true;
//         request.approved = approved;

//         if (approved) {
//             _mintNFT(request.requester, request.tokenURI);
//         }

//         emit ModificationFinalized(requestId, approved);
//     }

//     // Backend Sets Reward Distribution
//     function setRewardDistribution(uint256 requestId, bytes32 merkleRoot) external onlyBackendRole {
//         require(rewardMerkleRoots[requestId] == bytes32(0), "Reward distribution already set");
//         rewardMerkleRoots[requestId] = merkleRoot;
//     }

//     // Claim Rewards
//     function claimReward(
//         uint256 requestId,
//         uint256 rewardAmount,
//         bytes32[] calldata merkleProof
//     ) external {
//         require(!claimedRewards[requestId][msg.sender], "Reward already claimed");

//         bytes32 node = keccak256(abi.encodePacked(msg.sender, rewardAmount));
//         require(MerkleProof.verify(merkleProof, rewardMerkleRoots[requestId], node), "Invalid proof");

//         claimedRewards[requestId][msg.sender] = true;
//         require(rewardToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");

//         emit RewardClaimed(msg.sender, rewardAmount);
//     }

//     // Internal Function to Mint NFT
//     function _mintNFT(address to, string memory _tokenURI) internal {
//         uint256 tokenId = tokenCounter++;
//         _safeMint(to, tokenId);
//         _setTokenURI(tokenId, _tokenURI);
//         emit NFTMinted(tokenId, to, _tokenURI);
//     }

//     // Override tokenURI and supportsInterface
//     function supportsInterface(bytes4 interfaceId)
//         public
//         view
//         override(ERC721URIStorage)
//         returns (bool)
//     {
//         return super.supportsInterface(interfaceId);
//     }
// }

// import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
// import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
// import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// import "./Token.sol";

// contract FashionDNA is ERC721URIStorage, AccessControlEnumerable {
//     bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
//     bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

//     Token public rewardToken;

//     uint256 public tokenCounter;
//     uint256 public requestCounter;

//     struct ModificationRequest {
//         address requester;
//         string tokenURI;
//         uint256 rewardAmount;
//         bool finalized;
//         bool approved;
//     }

//     mapping(uint256 => ModificationRequest) public modificationRequests;
//     mapping(uint256 => bytes32) public rewardMerkleRoots; // Store Merkle roots for rewards
//     mapping(uint256 => mapping(address => bool)) public claimedRewards; // Track claimed rewards

//     event ModificationRequested(uint256 indexed requestId, address indexed requester, string tokenURI, uint256 rewardAmount);
//     event ModificationFinalized(uint256 indexed requestId, bool approved);
//     event RewardClaimed(address indexed validator, uint256 amount);
//     event NFTMinted(uint256 indexed tokenId, address indexed owner, string tokenURI);

//     constructor(address tokenAddress, address backendAddress) ERC721("FashionDNA", "FDNA") {
//         rewardToken = Token(tokenAddress);

//         _grantRole(ADMIN_ROLE, msg.sender);
//         _grantRole(BACKEND_ROLE, backendAddress);

//         tokenCounter = 1;
//         requestCounter = 1;
//     }

//     // Request Validation
//     function requestValidation(string memory _tokenURI, uint256 rewardAmount) public {
//         require(rewardAmount > 0, "Must provide a reward amount");
//         require(rewardToken.transferFrom(msg.sender, address(this), rewardAmount), "Reward transfer failed");

//         uint256 requestId = requestCounter++;
//         modificationRequests[requestId] = ModificationRequest({
//             requester: msg.sender,
//             tokenURI: _tokenURI,
//             rewardAmount: rewardAmount,
//             finalized: false,
//             approved: false
//         });

//         emit ModificationRequested(requestId, msg.sender, _tokenURI, rewardAmount);
//     }

//     // Finalize Modification
//     function finalizeModification(uint256 requestId, bool approved) external onlyRole(BACKEND_ROLE) {
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(!request.finalized, "Request already finalized");

//         request.finalized = true;
//         request.approved = approved;

//         if (approved) {
//             _mintNFT(request.requester, request.tokenURI);
//         }

//         emit ModificationFinalized(requestId, approved);
//     }

//     // Backend Sets Reward Distribution
//     function setRewardDistribution(uint256 requestId, bytes32 merkleRoot) external onlyRole(BACKEND_ROLE) {
//         require(rewardMerkleRoots[requestId] == bytes32(0), "Reward distribution already set");
//         rewardMerkleRoots[requestId] = merkleRoot;
//     }

//     // Claim Rewards
//     function claimReward(
//         uint256 requestId,
//         uint256 rewardAmount,
//         bytes32[] calldata merkleProof
//     ) external {
//         require(!claimedRewards[requestId][msg.sender], "Reward already claimed");

//         bytes32 node = keccak256(abi.encodePacked(msg.sender, rewardAmount));
//         require(MerkleProof.verify(merkleProof, rewardMerkleRoots[requestId], node), "Invalid proof");

//         claimedRewards[requestId][msg.sender] = true;
//         require(rewardToken.transfer(msg.sender, rewardAmount), "Reward transfer failed");

//         emit RewardClaimed(msg.sender, rewardAmount);
//     }

//     // Internal Function to Mint NFT
//     function _mintNFT(address to, string memory _tokenURI) internal {
//         uint256 tokenId = tokenCounter++;
//         _safeMint(to, tokenId);
//         _setTokenURI(tokenId, _tokenURI);
//         emit NFTMinted(tokenId, to, _tokenURI);
//     }
//     // Override tokenURI and supportsInterface
//     function supportsInterface(bytes4 interfaceId)
//         public
//         view
//         override(ERC721URIStorage, AccessControlEnumerable)
//         returns (bool)
//     {
//         return super.supportsInterface(interfaceId);
//     }
// }
