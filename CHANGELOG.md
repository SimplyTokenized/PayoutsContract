# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `finalizeDistribution(distributionId)` to advance a distribution from `Payout`
  to the terminal `Done` state, closing all further payout activity while
  leaving residual funds recoverable via `emergencyWithdraw`.
- Regression test suite covering batch balance corrections, whitelist
  enforcement on all payout paths, and the `Done` lifecycle transition.

### Fixed
- **Batch balance corrections no longer revert (arithmetic underflow).**
  `setInvestorBalances` previously accumulated a running unsigned delta that
  underflowed whenever a batch lowered or removed an existing investor's
  balance, depending on array ordering. Totals are now applied directly to
  `totalSnapshotBalance`, matching the single-investor setter.
- **Whitelist is now enforced on all payout methods.** `batchDistributeAutomatic`,
  `markPayoutAsPaid`, and `batchMarkPayoutAsPaid` previously ignored the
  whitelist requirement, allowing payouts to non-whitelisted addresses while
  `requireWhitelist` was enabled. All payout paths now honor the whitelist.

### Removed
- Redundant no-op self-assignments of `payoutAmounts` in `claimPayout` and
  `batchDistributeAutomatic`.

## [1.0.0]

### Added
- Initial release of PayoutsContract.
- Upgradeable (OpenZeppelin transparent proxy) payout distribution contract.
- Snapshot-based proportional payouts and manual exact-amount payouts.
- Claim, Automatic (on-chain), and Bank (off-chain) payout methods.
- Multiple independent distributions with a `Setup → Compute → Payout → Done`
  lifecycle.
- Role-based access control, pausability, reentrancy protection, and optional
  whitelisting.
- Batch operations (up to 200 entries per call) for scalable investor handling.

[Unreleased]: https://github.com/SimplyTokenized/PayoutsContract/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/SimplyTokenized/PayoutsContract/releases/tag/v1.0.0
