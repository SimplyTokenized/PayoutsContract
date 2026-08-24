// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/**
 * @dev Builds the same trees OpenZeppelin's `@openzeppelin/merkle-tree` JS library
 * builds, so a proof produced here verifies exactly as one produced by the backend.
 *
 * Two properties matter and are easy to get wrong:
 *  - **Leaves are hashed twice** (`keccak256(bytes.concat(keccak256(abi.encode(...))))`).
 *    Hashing once would let an internal node — public, readable straight off the
 *    published tree — be presented as a leaf and claimed.
 *  - **Pairs are hashed commutatively** (sorted), which is what lets `MerkleProof.verify`
 *    work without carrying left/right index bits in the proof.
 */
library MerkleTreeLib {
    /// @dev The leaf for one `(recipient, amount)` entry.
    function leafOf(address recipient, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))));
    }

    /// @dev Leaves for a whole list, in order.
    function leaves(address[] memory recipients, uint256[] memory amounts)
        internal
        pure
        returns (bytes32[] memory out)
    {
        out = new bytes32[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            out[i] = leafOf(recipients[i], amounts[i]);
        }
    }

    /**
     * @dev The root of a tree over `items`.
     * @notice An odd node at any level is promoted unchanged to the next level, which is
     * the standard treatment for an unbalanced tree and matches the JS library.
     */
    function root(bytes32[] memory items) internal pure returns (bytes32) {
        require(items.length > 0, "MerkleTreeLib: empty tree");

        bytes32[] memory level = items;
        while (level.length > 1) {
            level = _parents(level);
        }
        return level[0];
    }

    /// @dev The proof for `index` — its sibling at every level up to the root.
    function proof(bytes32[] memory items, uint256 index) internal pure returns (bytes32[] memory out) {
        require(index < items.length, "MerkleTreeLib: index out of range");

        bytes32[] memory level = items;
        uint256 position = index;

        // Depth is bounded by log2(n); size it generously and trim at the end.
        bytes32[] memory buffer = new bytes32[](256);
        uint256 depth;

        while (level.length > 1) {
            bool hasSibling = position ^ 1 < level.length;
            if (hasSibling) {
                buffer[depth] = level[position ^ 1];
                depth++;
            }
            level = _parents(level);
            position /= 2;
        }

        out = new bytes32[](depth);
        for (uint256 i = 0; i < depth; i++) {
            out[i] = buffer[i];
        }
    }

    /// @dev One level up: pairs hashed commutatively, a lone node promoted as-is.
    function _parents(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        uint256 width = (level.length + 1) / 2;
        next = new bytes32[](width);

        for (uint256 i = 0; i < width; i++) {
            uint256 left = i * 2;
            uint256 right = left + 1;
            next[i] = right < level.length ? Hashes.commutativeKeccak256(level[left], level[right]) : level[left];
        }
    }
}
