// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title IEligibilityRegistry
 * @notice The one question a compliance gate answers: may this address be paid?
 *
 * @dev A distribution may name a registry; when it does, `claimPayout` and
 * `batchDistributeAutomatic` refuse recipients the registry does not vouch for. The
 * payout contract deliberately knows nothing about *why* — KYC status, jurisdiction,
 * a manually kept list — that is the registry's business. Anything can stand behind
 * this interface: `WhitelistRegistry` for an operator-kept list, or
 * `ERC3643EligibilityAdapter` to defer to a permissioned token's own identity registry.
 */
interface IEligibilityRegistry {
    /// @notice Whether `account` may currently receive payouts.
    function isEligible(address account) external view returns (bool);
}
