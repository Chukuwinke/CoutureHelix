// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title CustomERC2771ContextUpgradeable
 * @dev Extends OpenZeppelin's ContextUpgradeable to support ERC-2771 and dynamic trusted forwarder updates.
 */
abstract contract CustomERC2771ContextUpgradeable is Initializable, ContextUpgradeable {
    address private _trustedForwarder;

    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);

    /**
     * @dev Initializes the contract, setting the initial trusted forwarder.
     * @param initialForwarder The address of the initial trusted forwarder.
     */
    function __CustomERC2771ContextUpgradeable_init(address initialForwarder) internal onlyInitializing {
        __Context_init_unchained();
        _trustedForwarder = initialForwarder;
    }

    /**
     * @dev Returns the current trusted forwarder address.
     */
    function trustedForwarder() public view virtual returns (address) {
        return _trustedForwarder;
    }

    /**
     * @dev Updates the trusted forwarder address.
     * Can only be called by the owner or an authorized role in your implementation.
     * Emits a `TrustedForwarderUpdated` event.
     * @param newForwarder The address of the new trusted forwarder.
     */
    function setTrustedForwarder(address newForwarder) public virtual {
        require(newForwarder != address(0), "CustomERC2771ContextUpgradeable: forwarder address cannot be zero");
        address oldForwarder = _trustedForwarder;
        _trustedForwarder = newForwarder;
        emit TrustedForwarderUpdated(oldForwarder, newForwarder);
    }

    /**
     * @dev Checks if a given address is the trusted forwarder.
     * @param forwarder The address to check.
     * @return True if the address is the trusted forwarder, false otherwise.
     */
    function isTrustedForwarder(address forwarder) public view virtual returns (bool) {
        return forwarder == _trustedForwarder;
    }

    /**
     * @dev Overrides `_msgSender` from ContextUpgradeable to use the dynamic trusted forwarder.
     */
    function _msgSender() internal view virtual override returns (address sender) {
        uint256 calldataLength = msg.data.length;
        uint256 contextSuffixLength = 20; // Length of an address in bytes
        if (isTrustedForwarder(msg.sender) && calldataLength >= contextSuffixLength) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = super._msgSender();
        }
    }

    /**
     * @dev Overrides `_msgData` from ContextUpgradeable to use the dynamic trusted forwarder.
     */
    function _msgData() internal view virtual override returns (bytes calldata) {
        uint256 calldataLength = msg.data.length;
        uint256 contextSuffixLength = 20; // Length of an address in bytes
        if (isTrustedForwarder(msg.sender) && calldataLength >= contextSuffixLength) {
            return msg.data[:calldataLength - contextSuffixLength];
        } else {
            return super._msgData();
        }
    }

    /**
     * @dev Reserved storage space to allow for layout changes in the future.
     */
    uint256[49] private __gap;
}
