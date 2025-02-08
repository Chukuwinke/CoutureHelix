// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ForwarderUpgradeable.sol";

contract MyForwarder is ERC2771ForwarderUpgradeable {
    function initialize(string memory name) public virtual override initializer {
        __ERC2771Forwarder_init(name);
    }
}
