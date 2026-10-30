// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @dev The smallest thing that behaves like an ERC-2771 forwarder: it calls the target
 * with the original sender appended to the calldata. Signature verification is a real
 * forwarder's job and is deliberately not modelled here — these tests are about whether
 * the contract credits the appended address, not about how a relayer authenticates.
 */
contract MockForwarder {
    function forward(address target, bytes calldata data, address from) external returns (bytes memory) {
        (bool success, bytes memory returndata) = target.call(abi.encodePacked(data, from));
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }
}
