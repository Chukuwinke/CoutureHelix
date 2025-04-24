// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../token/Token.sol";

contract TokenV2 is Token {
    
    function version() public pure returns (string memory) {
        return "v2";
    }
}
