// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CoutureHelixToken is ERC20, Ownable {
    constructor() ERC20("CoutureHelixToken", "CHTK") Ownable(msg.sender){

        // Minting initial supply to the owner (the deployer of the contract)
        _mint(msg.sender, 1000000 * 10 ** decimals()); // created 1_000_000 tokens
    }

    // !!! marker_red :  only user should be able to create new tokens find a way to make this better
    function mint(address account, uint256 amount) public onlyOwner{
        _mint(account, amount);
    }
}