// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../access/RoleManager.sol";

contract RoleManagerV2 is RoleManager {
    function version() public pure returns (string memory) {
        return "v2";
    }
}
