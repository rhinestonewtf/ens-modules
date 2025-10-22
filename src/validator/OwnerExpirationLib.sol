// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

library OwnerExpirationLib {
    /**
     * @dev Packs an address and expiration time into a single bytes32 value.
     * This is used as the element in the EnumerableSet.
     * Layout: [address (160 bits)][expiration (48 bits)][unused (48 bits)]
     * @param owner The owner address to pack
     * @param expirationTime The expiration timestamp (uint48)
     * @return packed The packed bytes32 value
     */
    function toSetElement(address owner, uint48 expirationTime) internal pure returns (bytes32 packed) {
        assembly {
            // Shift address left by 96 bits (48 bits expiration + 48 bits unused)
            // Then OR with expiration shifted left by 48 bits
            packed := or(shl(96, owner), shl(48, expirationTime))
        }
    }

    /**
     * @dev Packs an address (160 bits) and expiration time (48 bits) into a single bytes32.
     * Layout: [address (160 bits)][expiration (48 bits)][unused (48 bits)]
     * @param owner The owner address to pack
     * @param expirationTime The expiration timestamp (uint48)
     * @return packed The packed bytes32 value
     */
    function packWithExpiration(address owner, uint48 expirationTime) internal pure returns (bytes32 packed) {
        return toSetElement(owner, expirationTime);
    }

    /**
     * @dev Unpacks only the owner address from a packed bytes32.
     * @param packed The packed bytes32 value
     * @return owner The extracted owner address
     */
    function unpackOwner(bytes32 packed) internal pure returns (address owner) {
        assembly {
            // Shift right by 96 bits to get the address
            owner := shr(96, packed)
        }
    }

    /**
     * @dev Unpacks both owner address and expiration time from a packed bytes32.
     * @param packed The packed bytes32 value
     * @return owner The extracted owner address
     * @return expirationTime The extracted expiration timestamp
     */
    function unpackOwnerAndExpiration(bytes32 packed) internal pure returns (address owner, uint48 expirationTime) {
        assembly {
            // Extract owner: shift right by 96 bits
            owner := shr(96, packed)

            // Extract expiration: shift right by 48 bits, then mask to get only 48 bits
            // Mask: 0xFFFFFFFFFFFF (48 bits of 1s)
            expirationTime := and(shr(48, packed), 0xFFFFFFFFFFFF)
        }
    }
}
