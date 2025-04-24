// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../nft/tradeableNFT.sol";

/// @title TradeableNFT V2
/// @notice Simple upgrade that exposes a version() endpoint for testing
contract TradeableNFTV2 is TradeableNFT {
    /// @notice Returns the current implementation version
    function version() external pure returns (string memory) {
        return "TradeableNFT V2";
    }
    
    // _authorizeUpgrade is inherited from TradeableNFT (uses ADMIN or UPGRADER_ROLE)
}
