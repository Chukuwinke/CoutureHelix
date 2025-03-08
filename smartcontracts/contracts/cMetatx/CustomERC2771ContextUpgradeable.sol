// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title CustomERC2771ContextUpgradeable
 * @dev Extends OpenZeppelin's ContextUpgradeable to support a dynamic trusted forwarder.
 * When a call is forwarded via the trusted forwarder with appended extra data (the original sender),
 * the calldata length will be: 4 + 32×N + 20. This implementation checks for that pattern.
 */
abstract contract CustomERC2771ContextUpgradeable is Initializable, ContextUpgradeable {
    address private _trustedForwarder;

    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);

    /**
     * @dev Initializes the contract with the initial trusted forwarder.
     * @param initialForwarder The address of the trusted forwarder.
     */
    function __CustomERC2771ContextUpgradeable_init(address initialForwarder) internal onlyInitializing {
        __Context_init_unchained();
        _trustedForwarder = initialForwarder;
    }

    /**
     * @dev Returns the current trusted forwarder.
     */
    function trustedForwarder() public view virtual returns (address) {
        return _trustedForwarder;
    }

    /**
     * @dev Updates the trusted forwarder address.
     */
    function setTrustedForwarder(address newForwarder) public virtual {
        require(newForwarder != address(0), "CustomERC2771ContextUpgradeable: forwarder address cannot be zero");
        address oldForwarder = _trustedForwarder;
        _trustedForwarder = newForwarder;
        emit TrustedForwarderUpdated(oldForwarder, newForwarder);
    }

    /**
     * @dev Returns true if the given address is the trusted forwarder.
     */
    function isTrustedForwarder(address forwarder) public view virtual returns (bool) {
        return forwarder == _trustedForwarder;
    }

    /**
     * @dev Overridden _msgSender() that extracts the original sender when the call is forwarded.
     *
     * If the call comes from the trusted forwarder and the calldata length is not the standard
     * ABI-encoded length (i.e. (msg.data.length - 4) % 32 == 20), then we assume the extra 20 bytes
     * at the end are the appended original sender's address.
     *
     * For example, for a function with N parameters the normal calldata length is:
     *     4 + (32 * N)
     * If the call was forwarded with an appended sender, the calldata length becomes:
     *     4 + (32 * N) + 20
     */
    function _msgSender() internal view virtual override returns (address sender) {
        // If the call came through the trusted forwarder...
        if (isTrustedForwarder(msg.sender)) {
            uint256 dataLength = msg.data.length;
            // Check if extra 20 bytes were appended.
            if ((dataLength - 4) % 32 == 20) {
                // Extract sender from the last 20 bytes of calldata.
                assembly {
                    sender := shr(96, calldataload(sub(calldatasize(), 20)))
                }
                return sender;
            }
        }
        return msg.sender;
    }

    /**
     * @dev Overridden _msgData() that removes the appended sender when present.
     */
    function _msgData() internal view virtual override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender)) {
            uint256 dataLength = msg.data.length;
            if ((dataLength - 4) % 32 == 20) {
                return msg.data[:dataLength - 20];
            }
        }
        return msg.data;
    }

    // Reserved storage space for future upgrades.
    uint256[49] private __gap;
}
