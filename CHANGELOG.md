# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0]

**A rewrite, and a smaller contract than 1.x.** The platform computes what each
recipient is owed off-chain — one payout run produces one statement per person,
with its own arithmetic — so the contract no longer needs a snapshot, a
proportional formula, or a compute phase. It holds a list of
`(recipient, amount)` entries, the money to cover them, and the record of who
has been paid.

**Breaking: there is no upgrade path from 1.x.** The storage layout, the
constructor arguments, and most of the external API changed. 2.0.0 is deployed
fresh; existing 1.x instances keep serving their own distributions.

### Added
- **`EntryMode` — two ways the recipient list reaches the chain, chosen per
  distribution.**
  - `Direct` is v2.0's behaviour, unchanged: one storage entry per recipient,
    written in batches of 200, every amount on-chain, `totalOwed` computed by
    the contract, and push available as well as claim.
  - `Merkle` commits the whole list as one 32-byte root —
    `proposeSetMerkleRoot` / `approveSetMerkleRoot`, four-eyes-bound to the
    root, the declared total *and* the leaf count. One transaction regardless
    of list size, which is what makes tens of thousands of recipients
    feasible; recipients then collect with
    `claimPayout(id, amount, proof)`, and an off-chain settlement is recorded
    with `markPayoutAsPaid(id, recipient, amount, proof)`.
  - Leaves are **double-hashed** (`keccak256(bytes.concat(keccak256(abi.encode(
    recipient, amount))))`), matching OpenZeppelin's `merkle-tree` library, so
    an internal node cannot be replayed as a forged leaf.
  - `Auto` + `Merkle` is **refused at creation**: a push needs an on-chain list
    to read amounts from, so the combination is rejected rather than
    half-supported and discovered at hand-over.
  - `verifyEntry(id, recipient, amount, proof)` and a proof-bearing
    `canClaimPayout` overload let a wallet check an entry before spending gas.
  - Two costs are inherent and stated rather than hidden: the amounts live
    off-chain, so **the list must stay published** or nobody can build a proof;
    and `totalOwed` is *declared* rather than summed, so under-declaring it
    leaves the last claimants with an empty reserve. Both are why committing a
    root takes four eyes, and `MerkleRootSet` records all three figures so the
    approver's check stays reproducible afterwards. The reserve invariant holds
    regardless — no run can overspend, whatever is declared.
  - `Code` is the giveaway shape: the tree commits to redeemable **codes**
    instead of to people, so a campaign budget can be prefunded before anyone
    knows who will be paid. Whoever holds a code names the address it pays,
    via `claimWithCode(id, amount, receiver, proof, signature)`; unredeemed
    budget returns on the sweep after expiry.
    **A code is a private key, not a password**, and that is a security
    requirement rather than a stylistic one: a secret string passed in calldata
    would be copied out of the mempool into a higher-gas transaction and
    stolen. Because the holder signs the *receiving address*
    (`codeRedemptionDigest`, bound to the chain id and this contract), a
    signature an attacker lifts already names its beneficiary. `paidOut` is
    keyed by the code, so one person may hold several and one wallet may
    receive from all of them; anyone may submit the transaction, which lets the
    platform pay gas for a recipient who has none.
- **Governance in code, not key policy.**
  - Duties split by role: `OPERATOR_ROLE` (open runs, write entries, push
    payments, record receipts, close), `FUNDER_ROLE` (the only role that moves
    money in), `ADMIN_ROLE` (pause, and proposing the riskiest changes),
    `APPROVER_ROLE` (the second pair of eyes).
  - **Four-eyes on every irreversible action**: taking a run live, sweeping
    unclaimed money, withdrawing surplus, and changing the trusted forwarder
    are each a propose/approve pair — the approver must not be the proposer,
    proposals lapse after `PROPOSAL_TTL` (7 days), bind their exact
    parameters, and finalization additionally binds the run's exact content,
    so a run edited after proposing must be seen again.
  - `initialize` now takes a distinct approver and refuses `approver == admin`
    — the split exists from the first block.
  - **Role grants are delayed, revocations are not.** `scheduleRoleGrant` must
    precede `grantRole` by `ROLE_GRANT_DELAY` (2 days); an unused announcement
    lapses after a further `PROPOSAL_TTL`; either the role's admin or the
    guardian can cancel one. This closes the standing way around four eyes —
    the root granting `APPROVER_ROLE` to a second address it controls and
    approving its own proposal in the next call. `revokeRole` stays immediate,
    because a compromised key must be removable at once.
  - Proposals are fully evented (`ActionProposed` / `ActionApproved` /
    `ActionCancelled`) and cancellable by their proposer or an admin.
  - The deploy script can place upgrade authority behind an OpenZeppelin
    `TimelockController` (`UPGRADE_TIMELOCK_DELAY`), making every upgrade
    publicly visible on-chain before it can execute.
- **A pluggable compliance gate: one mechanism, three postures.** Each
  distribution may name an eligibility registry at creation (immutable for its
  life); `claimPayout` and `batchDistributeAutomatic` then refuse recipients
  the registry does not vouch for, checked at payment time and failing
  closed (an unreachable registry blocks payment). The postures:
  `address(0)` (no gate — the curated entry list is the entitlement), the
  `WhitelistRegistry` companion (an operator-kept on-chain list), or the
  `ERC3643EligibilityAdapter` companion, which defers to a permissioned
  security token's own identity registry — an independent compliance layer.
  `markPayoutAsPaid` stays ungated: it moves no funds, and the off-chain
  settlement it records carries its own compliance.
- **One contract per tenant, not per offering.** `baseToken` is gone, so a
  single deployment serves every offering and every asset the tenant pays in.
  The payout asset is a property of each distribution, which it already was.
- **`PayoutMode` per distribution** — `Claim` (recipients collect) or `Auto`
  (the operator pushes) — replacing the per-recipient `PayoutMethod` that was
  frozen at write time and had no setter.
- **`runRef`** (`bytes32`) on each distribution, tying it to the payout run that
  produced it, so a payment can be traced back to its statements without
  trusting an off-chain index.
- **A funding guarantee.** `fundPayoutToken` refuses to exceed what is owed, and
  `finalizeDistribution` refuses to take a distribution live unless
  `funded == totalOwed`. Once anyone can claim, the money for everyone is here.
  In 1.x, funding correctness lived entirely off-chain
  (`getRequiredFundingAmount` reverted in Manual mode).
- **A reserve, so one run cannot spend another's money.** Unspent funds are
  reserved per distribution and summed per asset in `reservedByToken`.
  `emergencyWithdraw` is now limited to the surplus above it. This is what makes
  a tenant-wide contract safe to operate; in 1.x it could drain funds committed
  to unclaimed payouts.
- **`expiry` + `sweepUnclaimed(distributionId, to)`** — money nobody collects
  can be returned to the tenant after a stated date, and only after it. A
  distribution created with `expiry = 0` can never be swept.
- **`setTrustedForwarder(address)` and ERC-2771 support**, so a tenant can
  choose whether recipients pay their own claim gas or a relayer pays it. The
  forwarder is held in storage rather than an immutable, so one implementation
  serves both choices.
- **`closeDistribution(distributionId)`** to close a run once nothing is left
  reserved.
- **`remainingFunding(distributionId)`** — what still has to be paid in.
- **`PayoutSent`** event, distinct from `PayoutClaimed`, so an operator push and
  a recipient claim are distinguishable on-chain.
- **`PayoutAmountsSet`** and **`UnclaimedSwept`** events.
- Test suites per behaviour (lifecycle, amounts, funding, payment, reserve,
  forwarder), including fuzz tests and **stateful invariants** asserting that
  the contract never holds less of an asset than it has promised.

### Changed
- `initialize(address _admin, address _trustedForwarder)` — `baseToken` removed
  (it was write-only in 1.x: assigned at initialize and never read again).
- `setManualPayoutAmounts` → **`setPayoutAmounts`**, and it no longer requires
  the recipient to hold a token balance. In 1.x, paying someone an exact amount
  meant first inventing a snapshot balance for them.
- Writing the same recipient twice now reverts instead of overwriting: the
  entries are the on-chain copy of a set of statements, and a silent second
  write would make the two disagree.
- Lifecycle is `Setup → Payout → Done`; `finalizeDistribution` now performs
  `Setup → Payout` (closing is `closeDistribution` or `sweepUnclaimed`).
- `batchDistributeAutomatic` skips recipients already settled — so a batch
  retried after a partial failure finishes the job — but reverts for an address
  that is not on the list, which is an operator mistake rather than a retry.
- `markPayoutAsPaid` works on any distribution (not only "bank" recipients) and
  releases that recipient's share from the reserve, so money delivered by
  another route is not stranded here forever.
- `createDistribution` takes an `EntryMode` and an eligibility registry; its
  `DistributionCreated` event carries both.
- **Revert strings replaced by custom errors** throughout (54 of them). Four
  bytes at the revert site instead of a stored literal, which cut the runtime
  size by ~3.9KB and is what keeps the contract comfortably inside the 24KB
  limit with room for an audit to add to it. Integrators matching on revert
  reasons must switch to the error selectors; the names carry the same meaning
  the strings did.
- `optimizer_runs` raised from 1 to 500: recipients pay the runtime cost when
  they claim, and the contract has ample headroom against the size limit.

### Removed
- `baseToken`, and with it the need for one deployment per offering.
- Proportional mode in full: `DistributionMode`, `setDistributionTotalAmount`,
  `startCompute`, `computePayoutAmounts`, `finalizeCompute`, the `Compute`
  state, `snapshotBalances`, `isInvestor`, `snapshotBlockNumber`, and the
  `_blockNumber` argument. A per-recipient tax deduction cannot be expressed as
  `balance x total / totalBalance`, so the on-chain formula could never be the
  authority once withholding existed.
- `getRequiredFundingAmount` (replaced by `remainingFunding`, which works in
  every mode rather than reverting).
- The whitelist in full: `requireWhitelist`, `whitelist`, `WHITELIST_ROLE`,
  `updateWhitelistRequirement`, `addToWhitelist`, `removeFromWhitelist`,
  `batchAddToWhitelist`, `batchRemoveFromWhitelist`. An entry with an amount is
  the entitlement; eligibility is enforced before an entry is written.
- `SNAPSHOT_ROLE` (there is no snapshot) and `WHITELIST_ROLE`; the new role set
  is `ADMIN_ROLE` / `OPERATOR_ROLE` / `FUNDER_ROLE` / `APPROVER_ROLE`.
- `PayoutPreferenceSet`, which was declared but never emitted.

### Security
- Still **unaudited**. An independent audit covering 2.0.0 is a precondition for
  handling real money — see [`SECURITY.md`](SECURITY.md).

## [1.1.0]

### Added
- `finalizeDistribution(distributionId)` to advance a distribution from `Payout`
  to the terminal `Done` state, closing all further payout activity while
  leaving residual funds recoverable via `emergencyWithdraw`.
- Regression test suite covering batch balance corrections, whitelist
  enforcement on all payout paths, and the `Done` lifecycle transition.

### Changed
- **Reentrancy protection now uses OpenZeppelin `ReentrancyGuardTransient`**
  (EIP-1153 transient storage) instead of the hand-maintained local
  `ReentrancyGuardUpgradeable`. The transient guard holds zero persistent
  storage, so it cannot shift or collide with contract storage. The local guard
  file was removed and the build/tests now target the `cancun` EVM version.
  **Deployment requires a Cancun-capable chain.**

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
- Local `src/ReentrancyGuardUpgradeable.sol` copy (replaced by OpenZeppelin's
  `ReentrancyGuardTransient`).
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

[Unreleased]: https://github.com/SimplyTokenized/PayoutsContract/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/SimplyTokenized/PayoutsContract/compare/v1.0.0...v2.0.0
[1.1.0]: https://github.com/SimplyTokenized/PayoutsContract/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/SimplyTokenized/PayoutsContract/releases/tag/v1.0.0
