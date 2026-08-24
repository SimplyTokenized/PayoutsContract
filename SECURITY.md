# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 2.x     | ✅        |
| 1.x     | ❌ superseded by 2.x; not maintained |

## Reporting a Vulnerability

We take the security of PayoutsContract seriously. If you discover a
vulnerability, please report it **privately** — do not open a public issue or
disclose it publicly until it has been addressed.

- **Email:** hello@simplytokenized.com
- **Backup contact:** open a [GitHub Security Advisory](https://github.com/SimplyTokenized/PayoutsContract/security/advisories/new)

Please include:

- A description of the issue and its potential impact.
- Steps to reproduce (a failing Foundry test or PoC is ideal).
- Any suggested remediation.

We aim to acknowledge reports within **3 business days** and to provide a
remediation timeline after triage. We are happy to credit reporters in the
release notes unless you prefer to remain anonymous.

## Audit Status

> **This contract has not yet undergone a formal third-party security audit.**
> An independent audit is strongly recommended before deploying to mainnet or
> managing production funds.

An internal security review has been performed covering reentrancy, access
control, arithmetic safety, upgrade safety, and payout accounting. See
[`CHANGELOG.md`](CHANGELOG.md) for the resolved findings.

## Security Model & Trust Assumptions

Operators integrating this contract should understand the following:

- **No single key can run the payout process end to end.** Duties are split by
  role (OPERATOR writes and pushes, FUNDER moves money in, ADMIN guards,
  APPROVER approves) and the irreversible actions — going live, sweeping,
  withdrawing surplus, changing the forwarder — each require a proposal and an
  approval **from a different address**, bound to exact parameters (and, for
  finalization, to the run's exact content), lapsing after `PROPOSAL_TTL`.
  Compromise of one key can therefore disrupt, but not by itself misdirect,
  the money.
- **Role grants are delayed; revocations are not.** Adding anyone to a role must
  be announced (`scheduleRoleGrant`) and takes effect only after
  `ROLE_GRANT_DELAY` (2 days). This is what stops four-eyes being defeated in a
  single transaction — granting `APPROVER_ROLE` to a second controlled address
  and approving one's own proposal in the next call. Removal stays immediate so
  a compromised key can be cut off at once, and either the role's admin or the
  guardian may cancel a pending grant.
- **The root still controls the role graph, and the delay is time, not a veto.**
  `DEFAULT_ADMIN_ROLE` can eventually grant anything; what it can no longer do
  is do it *silently and instantly*. If the root key itself is compromised, the
  two days are the window in which to pause the contract and use the timelocked
  upgrade path — which means those mitigations must be operationally ready, not
  theoretical. Put the root on a multisig behind a timelock; the operational
  roles can then live on faster, narrower keys.
- **One contract holds one tenant's payouts — every run at once.** That is the
  point of v2, and it enlarges the blast radius of a mistake. Two things bound
  it: unspent money is *reserved* per distribution, so no function can spend one
  run's balance on another (`reservedByToken`, enforced on every path including
  the withdraw pair); and `pause()` stops every payout path at once.
- **The compliance gate is only as strong as the registry behind it.** A
  distribution's eligibility registry is immutable for its life and the check
  fails closed — but `WhitelistRegistry` is still the operator attesting, on
  chain. For independent enforcement use the `ERC3643EligibilityAdapter`, whose
  answer comes from the security token's own identity registry. Note the
  adapter follows the token: whoever governs the token's registry governs
  payout eligibility too.
- **Emergency withdrawal cannot take reserved money, and takes four eyes.** The
  `proposeEmergencyWithdraw`/`approveEmergencyWithdraw` pair is limited to the
  surplus — the balance above what is still owed to unpaid recipients. Money
  becomes surplus when a recipient is settled off-chain
  (`markPayoutAsPaid`), when a distribution is swept after expiry, or when
  tokens arrive without going through `fundPayoutToken`.
- **Amounts are set by a trusted off-chain process.** The contract enforces
  arithmetic (nothing goes live under-funded, nobody is paid twice, no run
  overspends) but not fairness: whether a recipient's amount is *correct* is a
  property of the payout run that produced it. Verify amounts off-chain.
- **Merkle mode moves two things off-chain, and both need an owner.**
  A `Merkle` distribution stores only a root, so:
  (a) **the published list is an availability dependency** — if it is lost, no
  proof can be built and nobody can claim, which for a dividend is an
  obligation you still owe. Keep it as long as the claim window, mirrored.
  It is *verifiable, not trusted*: anyone can recompute the root, so a
  compromised host can withhold a proof but never forge one.
  (b) **`totalOwed` is declared, not computed.** Under-declaring it does not
  overspend anything — the reserve invariant holds — but it leaves the last
  claimants unable to collect. The approver MUST recompute both the root and
  the sum from the published list before approving `setMerkleRoot`; that is
  the whole reason the action takes four eyes, and `MerkleRootSet` records all
  three figures so the check remains reproducible afterwards.
  `Direct` mode has neither property: use it unless the list is too large.
- **A giveaway code is a bearer instrument.** In `Code` mode the code's private
  key *is* the entitlement: whoever holds it can direct the payment to any
  address. Distribute codes over channels you would trust with the money
  itself, and treat a leaked code as spent. The contract binds each redemption
  to the receiver, the chain id and this contract, so a redemption cannot be
  front-run, replayed on a twin deployment, or spent against another
  distribution — but it cannot tell a rightful holder from a thief who has the
  same secret. Set an expiry so an unclaimed budget does not sit exposed
  indefinitely.
- **Recipients are whoever the operator wrote in**, unless the distribution
  names an eligibility registry. The contract keeps no list of its own: on an
  ungated distribution an entry with an amount *is* the entitlement, and
  eligibility is enforced before the entry is written. Gate the distribution
  (see above) wherever that off-chain step is not sufficient evidence.
- **Expiry decides whether money can come back.** A distribution created with
  `expiry = 0` can never be swept: unclaimed funds stay claimable forever. With
  an expiry, `ADMIN_ROLE` can reclaim whatever is left *after* that time. Note
  that sweeping an `Auto` distribution reclaims amounts that were never pushed.
- **Upgrade authority is separate from operational roles.** The proxy is a
  transparent proxy; upgrades are controlled by the **ProxyAdmin owner** set at
  deployment — not by `DEFAULT_ADMIN_ROLE` on the implementation. Secure the
  ProxyAdmin owner with a multisig/timelock.
- **A trusted forwarder can act as any recipient.** When one is set, whatever
  address it appends to calldata is treated as the caller — which is exactly why
  changing it is a four-eyes action (`proposeSetTrustedForwarder` /
  `approveSetTrustedForwarder`). Only approve a forwarder that verifies
  signatures — an ERC-2771 forwarder such as OpenZeppelin's `ERC2771Forwarder`.
  `address(0)` disables relaying entirely and is the default.
- **Fee-on-transfer and rebasing tokens are not supported** as payout tokens: a
  fee on funding would credit more than arrived and break the guarantee that a
  live distribution is fully funded.
- **A Cancun-capable chain is required.** Reentrancy protection uses OpenZeppelin's
  `ReentrancyGuardTransient` (EIP-1153 transient storage). Deploying to a chain
  without EIP-1153 support will cause `nonReentrant` functions to behave
  incorrectly. All current target chains (Ethereum mainnet/Sepolia, Avalanche
  C-Chain/Fuji, and major L2s) support it.

## Best Practices for Deployment

1. Put `DEFAULT_ADMIN_ROLE` on a multisig (e.g. Safe) behind a timelock; give
   `OPERATOR_ROLE`, `FUNDER_ROLE` and `APPROVER_ROLE` to separate keys held by
   different people. The contract enforces proposer ≠ approver; the
   organisation should make them different humans, not two keys in one drawer.
2. Deploy with `UPGRADE_TIMELOCK_DELAY` set, so the upgrade authority is a
   `TimelockController` and every upgrade is publicly scheduled on-chain before
   it executes.
3. Verify the deployed implementation and proxy on the block explorer.
4. Choose each distribution's eligibility registry deliberately: `address(0)`
   only where off-chain curation is the compliance story; the ERC-3643 adapter
   for regulated instruments.
5. Prefer `Direct` entry mode. Reach for `Merkle` when the list is genuinely
   too large to write, and only with the published-list hosting and the
   approver's recompute step actually in place — not as a default.
6. Check `remainingFunding(distributionId)` before proposing finalization —
   though the contract refuses to go live under-funded regardless.
7. Set an `expiry` on claim distributions unless the obligation is genuinely
   perpetual, and decide the sweep policy before recipients are told to claim.
8. Leave `trustedForwarder` unset unless gasless claiming is deliberately in
   use, and approve only an audited forwarder.
9. Keep the contract paused during configuration where appropriate.
