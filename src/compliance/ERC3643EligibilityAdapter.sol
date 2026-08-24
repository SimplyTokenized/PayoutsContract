// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IEligibilityRegistry} from "./IEligibilityRegistry.sol";

/// @dev The two calls this adapter needs from an ERC-3643 (T-REX) security token.
interface IERC3643Token {
    function identityRegistry() external view returns (address);
}

interface IERC3643IdentityRegistry {
    function isVerified(address account) external view returns (bool);
}

/**
 * @title ERC3643EligibilityAdapter
 * @notice The institutional compliance option: payout eligibility is answered by the
 * security token's OWN identity registry, not by anything the payout operator keeps.
 *
 * @dev This is the difference lawyers care about. A whitelist kept by the operator is
 * the same party attesting twice; an ERC-3643 identity registry is an independent,
 * on-chain compliance layer (the same one that gates the token's own transfers), so
 * "only verified investors were paid" becomes a property the chain enforced rather
 * than a claim about an off-chain process.
 *
 * The adapter holds the TOKEN, not the registry: ERC-3643 tokens can swap their
 * identity registry, and following the token means eligibility always reflects the
 * registry currently in force.
 */
contract ERC3643EligibilityAdapter is IEligibilityRegistry {
    IERC3643Token public immutable TOKEN;

    constructor(address token_) {
        require(token_ != address(0), "ERC3643EligibilityAdapter: invalid token");
        // Fail at deployment, not at the first claim, if this is not an ERC-3643 token.
        require(
            IERC3643Token(token_).identityRegistry() != address(0), "ERC3643EligibilityAdapter: no identity registry"
        );
        TOKEN = IERC3643Token(token_);
    }

    /// @inheritdoc IEligibilityRegistry
    function isEligible(address account) external view override returns (bool) {
        return IERC3643IdentityRegistry(TOKEN.identityRegistry()).isVerified(account);
    }
}
