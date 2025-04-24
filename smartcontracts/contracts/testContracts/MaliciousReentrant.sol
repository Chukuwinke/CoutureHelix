// contracts/test/MaliciousReentrant.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ILoyaltyNFT {
  function addTradeableNFT_Link(uint256 loyaltyTokenId, uint256 tradeableNFT_TokenId) external;
}

contract MaliciousReentrant {
  ILoyaltyNFT public loyalty;

  constructor(address _loyalty) {
    loyalty = ILoyaltyNFT(_loyalty);
  }

  // attack entrypoint: first call will succeed, sending us control into fallback
  function attackLink(uint256 lid, uint256 tid) external {
    loyalty.addTradeableNFT_Link(lid, tid);
  }

  // fallback gets triggered by any call with empty data or by sending ETH
  fallback() external {
    // try to re-enter addTradeableNFT_Link
    loyalty.addTradeableNFT_Link(0, 0);
  }
}
