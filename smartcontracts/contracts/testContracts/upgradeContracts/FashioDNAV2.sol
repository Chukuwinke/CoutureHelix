// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../archive/FashionDNA.sol";

contract FashionDNAV2 is FashionDNA {
    function version() external pure returns (string memory) {
        return "v2";
    }
}
