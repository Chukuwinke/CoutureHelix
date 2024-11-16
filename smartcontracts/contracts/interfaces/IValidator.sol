// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IValidator {
    function updateCombinedReputation(address validator) external;
    function isValidator(address account) external view returns (bool);
    function getValidatorReputation(address validator) external view returns (uint256);
}