// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ILoyaltyNFT {
    function addPremiumLink(uint256 loyaltyTokenId, uint256 premiumTokenId) external;
    function removePremiumLink(uint256 loyaltyTokenId, uint256 premiumTokenId) external;
}