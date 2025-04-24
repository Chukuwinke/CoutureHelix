// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../nft/loyaltyNFT.sol";

/// @title LoyaltyNFT V2
/// @notice Simple upgrade that exposes a version() endpoint for testing
contract LoyaltyNFTV2 is LoyaltyNFT {
    /// @notice Returns the current implementation version
    function version() external pure returns (string memory) {
        return "LoyaltyNFT V2";
    }
    
    // _authorizeUpgrade is inherited from LoyaltyNFT (uses DEFAULT_ADMIN_ROLE)
}
