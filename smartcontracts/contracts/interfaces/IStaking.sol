// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IStaking {
    function getStakedAmount(address staker) external view returns (uint256);
}