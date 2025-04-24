// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";


/// @title ERC721 Permit Extension per EIP-4494
/// @dev This contract provides meta-transaction permit functionality for ERC721 tokens.
abstract contract CustomERC721PermitUpgradeable is ERC721Upgradeable, EIP712Upgradeable {
    using ECDSA for bytes32;

    // Mapping from tokenId to nonce (to prevent replay attacks)
    mapping(uint256 => uint256) public nonces;

    // The permit type hash defined by EIP-4494
    // keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)")
    bytes32 public constant PERMIT_TYPEHASH = 0x6c4e0ad6ff0959a60e8b146359888a9df5d8a7ecfe710c0d2ce57dc3e1f08d4f;

    event PermitUsed(
        address indexed owner,
        address indexed spender,
        uint256 indexed tokenId,
        uint256 deadline
    );

    /// @dev Initializes EIP712 with the token's name and version.
    function __ERC721Permit_init(string memory name_) internal onlyInitializing {
        __EIP712_init(name_, "1");
    }

    /**
     * @notice Approves `spender` to manage `tokenId` using an EIP-4494 signature.
     * @param spender Address to be approved.
     * @param tokenId Token identifier.
     * @param deadline Expiration time for the signature.
     * @param v Recovery byte of the signature.
     * @param r Half of the ECDSA signature pair.
     * @param s Half of the ECDSA signature pair.
     */
    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(block.timestamp <= deadline, "Permit: expired");

        address owner = ownerOf(tokenId);
        uint256 currentNonce = nonces[tokenId];

        // Create the digest using EIP712 encoding
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH,
            spender,
            tokenId,
            currentNonce,
            deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredAddress = digest.recover(v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "Permit: invalid signature");

        // Increment the nonce to prevent replay attacks
        nonces[tokenId] = currentNonce + 1;

        // Approve the spender (using _approve from ERC721Upgradeable)
        super.approve(spender, tokenId);
        emit PermitUsed(owner, spender, tokenId, deadline);
    }
}
