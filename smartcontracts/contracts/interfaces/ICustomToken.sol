// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICustomToken {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
    function transfer(address recepient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function isBlacklisted(address account)external view returns (bool);
}
