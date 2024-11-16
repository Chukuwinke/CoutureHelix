// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IValidator.sol";

contract FashionDNA is ERC721URIStorage, AccessControlEnumerable, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    IValidator public validatorContract;

    uint256 public tokenCounter;

    struct ModificationRequest {
        address requester;
        string tokenURI;
        mapping(address => bool) hasVoted;
        uint256 totalApprovalWeight;
        uint256 totalRejectionWeight;
        uint256 totalPossibleReputation;
        uint256 requiredApprovalWeight;
        bool validated;
        bool finalized;
        uint256 reward;
        uint256 votingDeadline;
        address[] assignedValidators;
        uint256 votesReceived;
    }

    mapping(uint256 => ModificationRequest) public modificationRequests;
    mapping(uint256 => uint256) public requestTimestamps;

    uint256 public requestCounter;

    uint256 public minimumTotalPossibleReputation;

    uint256 public votingDuration = 3 days; // Configurable voting duration

    mapping(address => uint256) public pendingRewards;

    event ModificationRequested(
        uint256 indexed requestId,
        address indexed requester,
        string tokenURI,
        uint256 reward
    );
    event ModificationApproved(
        uint256 indexed requestId,
        address indexed validator,
        uint256 weight
    );
    event ModificationRejected(
        uint256 indexed requestId,
        address indexed validator,
        uint256 weight
    );
    event NFTMinted(
        uint256 indexed tokenId,
        address indexed owner,
        string tokenURI
    );
    event ModificationFinalized(
        uint256 indexed requestId,
        bool approved
    );
    event RewardsDistributed(
        uint256 indexed requestId,
        uint256 totalReward
    );
    event RewardClaimed(address indexed validator, uint256 amount);


    constructor(address validatorContractAddress, address backendAddress) ERC721("FashionDNA", "FDNA") {
        // DEFAULT_ADMIN_ROLE is assigned to msg.sender by default
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(BACKEND_ROLE, backendAddress); // Grant BACKEND_ROLE to the backend address

        validatorContract = IValidator(validatorContractAddress);
        tokenCounter = 1; // Start token IDs from 1
        requestCounter = 1; // Start request IDs from 1

        minimumTotalPossibleReputation = 100; // Example initial value
    }

    function setMinimumTotalPossibleReputation(uint256 minReputation)
        external
        onlyRole(ADMIN_ROLE)
    {
        minimumTotalPossibleReputation = minReputation;
    }

    function setValidatorContract(address validatorContractAddress)
        external
        onlyRole(ADMIN_ROLE)
    {
        validatorContract = IValidator(validatorContractAddress);
    }

    function setVotingDuration(uint256 duration)
        external
        onlyRole(ADMIN_ROLE)
    {
        votingDuration = duration;
    }

    function requestValidation(string memory _tokenURI) public payable {
        require(msg.value > 0, "Must send reward amount");
        uint256 requestId = requestCounter;
        ModificationRequest storage request = modificationRequests[requestId];
        request.requester = msg.sender;
        request.tokenURI = _tokenURI;
        request.reward = msg.value;

        emit ModificationRequested(requestId, msg.sender, _tokenURI, msg.value);

        requestCounter++;

        // Record the timestamp of the request
        requestTimestamps[requestId] = block.timestamp;
    }

    // Function for the backend to register selected validators
    function registerSelectedValidators(
        uint256 requestId,
        address[] memory validators
    ) public onlyRole(BACKEND_ROLE) {
        ModificationRequest storage request = modificationRequests[requestId];
        require(
            request.requester != address(0),
            "Modification request does not exist"
        );
        require(
            request.assignedValidators.length == 0,
            "Validators already registered"
        );
        uint256 totalReputation = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];
            require(
                validatorContract.isValidator(validator),
                "Address is not a validator"
            );
            require(
                !isValidatorAssigned(requestId, validator),
                "Validator already assigned"
            );
            request.assignedValidators.push(validator);
            uint256 reputation = validatorContract.getValidatorReputation(
                validator
            );
            totalReputation += reputation;
        }
        require(
            totalReputation >= minimumTotalPossibleReputation,
            "Total possible reputation is too low"
        );
        request.totalPossibleReputation = totalReputation;

        // Set requiredApprovalWeight to 50% of totalPossibleReputation
        request.requiredApprovalWeight = totalReputation / 2;

        // Set the voting deadline
        request.votingDeadline = block.timestamp + votingDuration;
    }

    function approveModification(uint256 requestId) public {
        ModificationRequest storage request = modificationRequests[requestId];
        require(block.timestamp <= request.votingDeadline, "Voting period has ended");
        require(
            validatorContract.isValidator(msg.sender),
            "Caller is not a validator"
        );
        require(!request.finalized, "Modification already finalized");
        require(!request.hasVoted[msg.sender], "Validator has already voted");
        require(
            isValidatorAssigned(requestId, msg.sender),
            "Validator not assigned to this request"
        );

        uint256 validatorReputation = validatorContract.getValidatorReputation(
            msg.sender
        );
        request.totalApprovalWeight += validatorReputation;
        request.hasVoted[msg.sender] = true;
        request.votesReceived++;

        emit ModificationApproved(requestId, msg.sender, validatorReputation);

        // Check if all validators have voted
        if (request.votesReceived == request.assignedValidators.length) {
            finalizeModification(requestId);
        }
    }

    function rejectModification(uint256 requestId) public {
        ModificationRequest storage request = modificationRequests[requestId];
        require(block.timestamp <= request.votingDeadline, "Voting period has ended");
        require(
            validatorContract.isValidator(msg.sender),
            "Caller is not a validator"
        );
        require(!request.finalized, "Modification already finalized");
        require(!request.hasVoted[msg.sender], "Validator has already voted");
        require(
            isValidatorAssigned(requestId, msg.sender),
            "Validator not assigned to this request"
        );

        uint256 validatorReputation = validatorContract.getValidatorReputation(
            msg.sender
        );
        request.totalRejectionWeight += validatorReputation;
        request.hasVoted[msg.sender] = true;
        request.votesReceived++;

        emit ModificationRejected(requestId, msg.sender, validatorReputation);

        // Check if all validators have voted
        if (request.votesReceived == request.assignedValidators.length) {
            finalizeModification(requestId);
        }
    }

    // Function to finalize after deadline
    function finalizeAfterDeadline(uint256 requestId) public {
        ModificationRequest storage request = modificationRequests[requestId];
        require(!request.finalized, "Modification already finalized");
        require(block.timestamp > request.votingDeadline, "Voting deadline not reached");
        finalizeModification(requestId);
    }

    function finalizeModification(uint256 requestId) internal {
        ModificationRequest storage request = modificationRequests[requestId];
        require(!request.finalized, "Modification already finalized");
        request.finalized = true;
        // Decide outcome based on votes received
        if (request.totalApprovalWeight >= request.requiredApprovalWeight) {
            request.validated = true;
            _mintNFT(request.requester, request.tokenURI);
            emit ModificationFinalized(requestId, true);
        } else {
            request.validated = false;
            emit ModificationFinalized(requestId, false);
            // Additional actions on rejection if needed
        }
        distributeRewards(requestId);
    }

    function distributeRewards(uint256 requestId) internal {
        ModificationRequest storage request = modificationRequests[requestId];
        uint256 totalReward = request.reward;
        uint256 majorityShare = (totalReward * 70) / 100;
        uint256 minorityShare = totalReward - majorityShare;

        uint256 totalMajorityWeight;
        uint256 totalMinorityWeight;

        bool approversAreMajority = request.totalApprovalWeight >= request.totalRejectionWeight;

        if (approversAreMajority) {
            // Approvers are majority
            totalMajorityWeight = request.totalApprovalWeight;
            totalMinorityWeight = request.totalRejectionWeight;
        } else {
            // Rejecters are majority
            totalMajorityWeight = request.totalRejectionWeight;
            totalMinorityWeight = request.totalApprovalWeight;
        }

        // Distribute to majority
        distributeToValidators(
            requestId,
            approversAreMajority,
            totalMajorityWeight,
            majorityShare
        );

        // Distribute to minority
        distributeToValidators(
            requestId,
            !approversAreMajority,
            totalMinorityWeight,
            minorityShare
        );

        emit RewardsDistributed(requestId, totalReward);
    }

    function distributeToValidators(
        uint256 requestId,
        bool toApprovers,
        uint256 totalWeight,
        uint256 rewardShare
    ) internal {
        if (totalWeight == 0) {
            return;
        }
        ModificationRequest storage request = modificationRequests[requestId];
        for (uint256 i = 0; i < request.assignedValidators.length; i++) {
            address validator = request.assignedValidators[i];
            if (request.hasVoted[validator]) {
                bool approved = request.totalApprovalWeight >= request.requiredApprovalWeight;
                if ((toApprovers && approved) || (!toApprovers && !approved)) {
                    uint256 validatorReputation = validatorContract.getValidatorReputation(validator);
                    uint256 validatorReward = (rewardShare * validatorReputation) / totalWeight;
                    pendingRewards[validator] += validatorReward;
                }
            }
        }
    }

    function claimReward() public nonReentrant {
        uint256 reward = pendingRewards[msg.sender];
        require(reward > 0, "No rewards to claim");
        pendingRewards[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: reward}("");
        require(success, "Transfer failed");
        emit RewardClaimed(msg.sender, reward); // remove later cos of gas fees
    }
    // chage back to internal
    function isValidatorAssigned(uint256 requestId, address validator) 
        public
        view
        returns (bool)
    {
        ModificationRequest storage request = modificationRequests[requestId];
        for (uint256 i = 0; i < request.assignedValidators.length; i++) {
            if (request.assignedValidators[i] == validator) {
                return true;
            }
        }
        return false;
    }
    // change back to internal
    function _mintNFT(address to, string memory _tokenURI) public {
        uint256 tokenId = tokenCounter;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, _tokenURI);

        emit NFTMinted(tokenId, to, _tokenURI);

        tokenCounter++;
    }

    // Override supportsInterface to resolve inheritance conflict
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // Override tokenURI to return the correct URI
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
}


// pragma solidity ^0.8.27;

// import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
// import "@openzeppelin/contracts/access/AccessControl.sol";
// import "./interfaces/IValidator.sol";

// contract FashionDNA is ERC721URIStorage, AccessControl {
//     bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
//     bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

//     IValidator public validatorContract;

//     uint256 public tokenCounter;

//     struct ModificationRequest {
//         address requester;
//         string tokenURI;
//         mapping(address => bool) hasVoted;
//         uint256 totalApprovalWeight;
//         uint256 totalRejectionWeight;
//         uint256 totalPossibleReputation;
//         uint256 requiredApprovalWeight;
//         bool validated;
//         bool minted;
//         address[] selectedValidators;
//     }

//     mapping(uint256 => ModificationRequest) public modificationRequests;
//     mapping(uint256 => uint256) public requestTimestamps;

//     uint256 public requestCounter;

//     uint256 public minimumTotalPossibleReputation;

//     event ModificationRequested(
//         uint256 indexed requestId,
//         address indexed requester,
//         string tokenURI
//     );
//     event ModificationApproved(
//         uint256 indexed requestId,
//         address indexed validator,
//         uint256 weight
//     );
//     event ModificationRejected(
//         uint256 indexed requestId,
//         address indexed validator,
//         uint256 weight
//     );
//     event NFTMinted(
//         uint256 indexed tokenId,
//         address indexed owner,
//         string tokenURI
//     );

//     constructor(address validatorContractAddress, address backendAddress) ERC721("FashionDNA", "FDNA") {
//         grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
//         grantRole(ADMIN_ROLE, msg.sender);
//         grantRole(BACKEND_ROLE, backendAddress); // Grant BACKEND_ROLE to the backend address

//         validatorContract = IValidator(validatorContractAddress);
//         tokenCounter = 1; // Start token IDs from 1
//         requestCounter = 1; // Start request IDs from 1

//         minimumTotalPossibleReputation = 100; // Example initial value
//     }

//     function setMinimumTotalPossibleReputation(uint256 minReputation)
//         external
//         onlyRole(ADMIN_ROLE)
//     {
//         minimumTotalPossibleReputation = minReputation;
//     }

//     function setValidatorContract(address validatorContractAddress)
//         external
//         onlyRole(ADMIN_ROLE)
//     {
//         validatorContract = IValidator(validatorContractAddress);
//     }

//     function requestValidation(string memory _tokenURI) public {
//         uint256 requestId = requestCounter;
//         ModificationRequest storage request = modificationRequests[requestId];
//         request.requester = msg.sender;
//         request.tokenURI = _tokenURI;

//         emit ModificationRequested(requestId, msg.sender, _tokenURI);

//         requestCounter++;

//         // Record the timestamp of the request
//         requestTimestamps[requestId] = block.timestamp;
//     }

//     // Function for the backend to register selected validators
//     function registerSelectedValidators(
//         uint256 requestId,
//         address[] memory validators
//     ) public onlyRole(BACKEND_ROLE) {
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(
//             request.requester != address(0),
//             "Modification request does not exist"
//         );
//         require(
//             request.selectedValidators.length == 0,
//             "Validators already registered"
//         );
//         request.selectedValidators = validators;

//         // Calculate totalPossibleReputation and enforce minimum
//         uint256 totalReputation = 0;
//         for (uint256 i = 0; i < validators.length; i++) {
//             require(
//                 validatorContract.isValidator(validators[i]),
//                 "Address is not a validator"
//             );
//             uint256 reputation = validatorContract.getValidatorReputation(
//                 validators[i]
//             );
//             totalReputation += reputation;
//         }
//         require(
//             totalReputation >= minimumTotalPossibleReputation,
//             "Total possible reputation is too low"
//         );
//         request.totalPossibleReputation = totalReputation;

//         // Set requiredApprovalWeight to 50% of totalPossibleReputation
//         request.requiredApprovalWeight = totalReputation / 2;
//     }

//     function approveModification(uint256 requestId) public {
//         require(
//             validatorContract.isValidator(msg.sender),
//             "Caller is not a validator"
//         );
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(!request.validated, "Modification already validated");
//         require(!request.hasVoted[msg.sender], "Validator has already voted");
//         require(
//             isValidatorAssigned(requestId, msg.sender),
//             "Validator not assigned to this request"
//         );

//         uint256 validatorReputation = validatorContract.getValidatorReputation(
//             msg.sender
//         );
//         request.totalApprovalWeight += validatorReputation;
//         request.hasVoted[msg.sender] = true;

//         emit ModificationApproved(requestId, msg.sender, validatorReputation);

//         if (request.totalApprovalWeight > request.requiredApprovalWeight) {
//             request.validated = true;
//             _mintNFT(request.requester, request.tokenURI);
//         }
//     }

//     function rejectModification(uint256 requestId) public {
//         require(
//             validatorContract.isValidator(msg.sender),
//             "Caller is not a validator"
//         );
//         ModificationRequest storage request = modificationRequests[requestId];
//         require(!request.validated, "Modification already validated");
//         require(!request.hasVoted[msg.sender], "Validator has already voted");
//         require(
//             isValidatorAssigned(requestId, msg.sender),
//             "Validator not assigned to this request"
//         );

//         uint256 validatorReputation = validatorContract.getValidatorReputation(
//             msg.sender
//         );
//         request.totalRejectionWeight += validatorReputation;
//         request.hasVoted[msg.sender] = true;

//         emit ModificationRejected(requestId, msg.sender, validatorReputation);

//         if (
//             request.totalRejectionWeight >= request.totalPossibleReputation / 2
//         ) {
//             request.validated = false;
//             // Optionally, take additional actions upon rejection
//         }
//     }

//     function isValidatorAssigned(uint256 requestId, address validator)
//         internal
//         view
//         returns (bool)
//     {
//         ModificationRequest storage request = modificationRequests[requestId];
//         for (uint256 i = 0; i < request.selectedValidators.length; i++) {
//             if (request.selectedValidators[i] == validator) {
//                 return true;
//             }
//         }
//         return false;
//     }

//     function _mintNFT(address to, string memory _tokenURI) internal {
//         uint256 tokenId = tokenCounter;
//         _safeMint(to, tokenId);
//         _setTokenURI(tokenId, _tokenURI);

//         emit NFTMinted(tokenId, to, _tokenURI);

//         tokenCounter++;
//     }

//     // **Override supportsInterface to resolve inheritance conflict**
//     function supportsInterface(bytes4 interfaceId)
//         public
//         view
//         override(ERC721URIStorage, AccessControl)
//         returns (bool)
//     {
//         return super.supportsInterface(interfaceId);
//     }

//     // Override tokenURI to return the correct URI
//     function tokenURI(uint256 tokenId)
//         public
//         view
//         override
//         returns (string memory)
//     {
//         return super.tokenURI(tokenId);
//     }
// }
