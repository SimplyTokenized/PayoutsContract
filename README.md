# PayoutsContract

[![CI](https://github.com/SimplyTokenized/PayoutsContract/actions/workflows/test.yml/badge.svg)](https://github.com/SimplyTokenized/PayoutsContract/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.27-363636.svg)](https://soliditylang.org/)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

**One upgradeable payout contract per tenant.** Each payout run becomes one
on-chain *distribution*: a list of `(recipient, amount)` entries and the money to
cover them. Recipients either collect what they are owed, or the operator sends
it to them — the tenant decides which, per run.

> ⚠️ **Not audited.** An independent audit covering 2.x is a precondition for
> handling real money. See [`SECURITY.md`](SECURITY.md).

> **Upgrading from 1.x?** There is no upgrade path — the storage layout and most
> of the API changed. 2.0.0 is deployed fresh; 1.x instances keep serving their
> own distributions. See [`CHANGELOG.md`](CHANGELOG.md) for the full diff.

## Table of Contents

- [What it does](#what-it-does)
- [What it does not do](#what-it-does-not-do)
- [How the list gets on-chain](#how-the-list-gets-on-chain)
- [Compliance](#compliance)
- [Distribution lifecycle](#distribution-lifecycle)
- [The two guarantees](#the-two-guarantees)
- [Quick start](#quick-start)
- [Walkthrough](#walkthrough)
- [Who pays the gas](#who-pays-the-gas)
- [Roles](#roles)
- [API reference](#api-reference)
- [Upgradeability](#upgradeability)
- [Security](#security)
- [Testing](#testing)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## What it does

- **One contract per tenant, many runs.** The payout asset is chosen per
  distribution, so one deployment covers every offering and every token the
  tenant pays in — ERC-20 or the chain's native asset.
- **A distribution is a payout run**, carrying a `runRef` that ties it back to
  the run that produced it. The list reaches the chain one of two ways — entry
  by entry, or as a single Merkle root for a list of any size. See
  [How the list gets on-chain](#how-the-list-gets-on-chain).
- **Claim or send, chosen per run.** `Claim` means recipients collect it
  themselves — one funding transaction instead of one transfer per person, which
  is what makes a list of two thousand feasible. `Auto` means the operator pushes
  it, in any subset: one row, one page, or the whole list.
- **Settled elsewhere is recorded too.** `markPayoutAsPaid` writes the receipt
  for a payment made another way (a bank transfer) without moving funds here.
- **Expiry and sweep.** Money nobody collects can be returned to the tenant after
  a stated date — and only after it.
- **Governance in code.** Duties split across four roles (operator ≠ funder ≠
  guardian ≠ approver), and every irreversible action — going live, sweeping,
  withdrawing surplus, changing the forwarder — is a propose/approve pair where
  the approver must be a different person. See [Governance](#roles).
- **Compliance is pluggable, per distribution.** No gate, an operator-kept
  whitelist, or an ERC-3643 adapter that lets the security token's own identity
  registry decide — checked when money moves, failing closed. See
  [Compliance](#compliance).
- **Gas is selectable.** Recipients pay their own claim gas by default; setting
  an ERC-2771 forwarder lets a relayer pay instead.
- **Pausable**, **reentrancy-protected** (`ReentrancyGuardTransient`, EIP-1153),
  role-gated, and `SafeERC20` throughout.

> **Chain requirement:** transient-storage reentrancy protection (EIP-1153) means
> a **Cancun-capable chain** — Ethereum mainnet/Sepolia, Avalanche C-Chain/Fuji
> and the major L2s all qualify. Builds and tests target `cancun`.

## What it does not do

Deliberate omissions, because each one is handled better elsewhere:

- **It does not compute what anyone is owed.** Amounts are supplied by the
  caller. A payout run works out each recipient's gross, deductions and net
  off-chain, where the tax rules live; the contract enforces the arithmetic
  around those amounts, not the amounts themselves.
- **It does not snapshot balances.** v1 did, and derived amounts proportionally.
  That formula stops being the authority the moment any per-recipient
  withholding exists, so it is gone.
- **It does not keep its own compliance list.** An entry with an amount *is*
  the entitlement; when a distribution needs an on-chain gate, it names one —
  see [Compliance](#compliance) — rather than the payout contract keeping a
  second copy of somebody else's facts.
- **It does not mint.** Funding is a transfer in; the tokens must already exist.

## Distribution lifecycle

```
    createDistribution (mode, entryMode, expiry, runRef, eligibility registry)
                |
                v
         +-------------+  Direct: setPayoutAmounts (batches of <=200)
         |    Setup    |  Merkle: propose + approveSetMerkleRoot (four eyes)
         +-------------+  both:   fundPayoutToken (FUNDER, up to totalOwed)
                |
                |  propose + approveFinalizeDistribution   -- four eyes,
                v                                             funded == totalOwed
         +-------------+   claimPayout([amount, proof])  (Claim mode, recipient)
         |   Payout    |   batchDistributeAutomatic      (Auto mode, operator)
         +-------------+   markPayoutAsPaid              (settled off-chain)
                |
                |  closeDistribution                (nothing left reserved)
                |  propose + approveSweepUnclaimed  (four eyes, after expiry)
                v
         +-------------+
         |    Done     |
         +-------------+
```

## How the list gets on-chain

Chosen per distribution at creation, immutable afterwards.

| | `Direct` | `Merkle` | `Code` |
|---|---|---|---|
| Committed to | Each recipient, one storage entry | The whole list, one root | Redeemable **codes**, one root |
| Recipients known… | at funding | at funding | **only when someone redeems** |
| `totalOwed` | **Computed** from the entries | **Declared**, checked by the approver | **Declared** (the campaign budget) |
| Amounts | On-chain, self-sufficient | Off-chain — the list must stay published | Off-chain, per code |
| Paying | Claim **or** push | **Claim only** | **Redeem only** |
| Good for | Up to a few thousand recipients | Tens of thousands and up | Giveaways |

**Direct** is the default and is what most runs should use: everything is on-chain,
nothing external has to survive, and the funding guarantee is airtight because the
contract sums the entries itself.

**Merkle** exists for the case Direct cannot reach. Commit the root with
`proposeSetMerkleRoot` / `approveSetMerkleRoot`, fund it, take it live; recipients then
call `claimPayout(id, amount, proof)`. Leaves are
`keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))))` — the double-hashed
form [OpenZeppelin's `merkle-tree`](https://github.com/OpenZeppelin/merkle-tree) library
produces, which is what stops an internal node being replayed as a forged leaf.

> ⚠️ **Two obligations come with Merkle mode.**
>
> 1. **The list must stay published** (your API, S3, IPFS) for as long as anyone can
>    claim. Lose it and nobody can build a proof. The file is *verifiable*, not trusted —
>    anyone can recompute the root and compare — so a compromised host can withhold a
>    proof but never forge one.
> 2. **`totalOwed` is an assertion, not a sum.** The contract cannot add up leaves it
>    cannot see, so under-declaring the total leaves the last claimants facing an empty
>    reserve. That is precisely why committing a root takes four eyes: **the approver's
>    job is to recompute the root *and* the total from the published list before
>    approving.** `MerkleRootSet` records the root, the total and the leaf count, so the
>    check stays reproducible by anyone afterwards.
>
> The reserve invariant holds either way — a mis-declared total can strand a claimant,
> but it can never overspend a run or touch another run's money.

### `Code` — giveaways, where the recipients are not known yet

A giveaway inverts the usual order: you fund a campaign budget, hand out codes, and only
learn who is being paid when somebody redeems one. `Code` mode commits the tree to the
**codes** instead of to people. Whoever holds a code names the address it should pay.

```solidity
// The operator: commit the codes and prefund the budget. Nobody is named.
payouts.proposeSetMerkleRoot(id, codeRoot, campaignBudget, codeCount);
payouts.approveSetMerkleRoot(id, codeRoot, campaignBudget, codeCount);
payouts.fundPayoutToken(id, campaignBudget);
// ...propose + approveFinalizeDistribution...

// The holder: sign the address you want paid, and redeem.
bytes32 digest = payouts.codeRedemptionDigest(id, receiver);   // sign with the CODE's key
payouts.claimWithCode(id, amount, receiver, proof, signature);
```

**A code is a private key, not a password** — the redemption link carries the secret, and
the tree commits to the address derived from it. That is not decoration; it is the only
shape that survives contact with a public mempool:

> ⚠️ If a code were a secret *string* passed in calldata, the first bot to see a
> redemption would copy it into a higher-gas transaction and take the money. Because the
> holder instead **signs the receiving address**, a signature lifted from the mempool
> pays the person it already names. There is no ordering of those transactions in which
> the thief is paid — `test_frontRunnerCannotStealARedemption` asserts exactly this.

Consequences worth knowing:

- **Anyone may submit the transaction**, so the platform can pay gas for a recipient who
  has none. The signature, not the sender, decides who is paid.
- **A code is spent once** — `paidOut` is keyed by the code, so one person may hold
  several codes and one wallet may receive from all of them.
- **Unredeemed budget comes back** on the sweep after expiry, which is the normal end of
  a campaign since most codes are never redeemed. Set an expiry.
- **A giveaway can still be compliance-gated**: the code proves entitlement, the
  registry proves the person may be paid at all.

## Compliance

One mechanism, three postures. A distribution names its gate at creation —
immutable for its life — and `claimPayout` / `batchDistributeAutomatic` refuse
anyone the gate does not vouch for, **at payment time** (a verification revoked
between entry and claim blocks the claim) and **failing closed** (an
unreachable registry blocks payment rather than waving it through).

| Registry | Posture | For whom |
|---|---|---|
| `address(0)` | No gate — the operator-curated entry list is the entitlement | Platforms whose KYC lives off-chain, in the process that writes the entries |
| [`WhitelistRegistry`](src/compliance/WhitelistRegistry.sol) | An on-chain list the tenant keeps, shared by every distribution that names it | Tenants who want an on-chain record of eligibility they control |
| [`ERC3643EligibilityAdapter`](src/compliance/ERC3643EligibilityAdapter.sol) | The security token's **own identity registry** decides (`isVerified`), followed through registry swaps | Regulated issuers — eligibility is enforced by an independent compliance layer, not by the payer attesting twice |

Anything implementing
[`IEligibilityRegistry`](src/compliance/IEligibilityRegistry.sol) —
`isEligible(address) → bool` — can stand behind a distribution.
`markPayoutAsPaid` is ungated on purpose: it moves no funds here, and the
off-chain settlement it records carries its own compliance.

## The two guarantees

Two properties are enforced on-chain rather than trusted to the caller. They are
the reason a single contract can safely hold a tenant's entire payout history.

**1. A distribution cannot go live under-funded.** `finalizeDistribution`
requires `funded == totalOwed`. Once recipients are told they can claim, the
money for every one of them is already in the contract. (In 1.x, funding
correctness lived entirely off-chain.)

**2. One run can never spend another run's money.** Every distribution's unspent
balance is *reserved* — tracked per distribution and summed per asset in
`reservedByToken`. `emergencyWithdraw` is limited to the surplus above it, so
even the emergency path cannot touch money owed to someone. Money becomes
surplus only when a recipient is settled off-chain, when a distribution is swept
after expiry, or when tokens arrive without going through `fundPayoutToken`.

Both are covered by stateful invariant tests (`test/Reserve.t.sol`).

## Quick start

```bash
git clone https://github.com/SimplyTokenized/PayoutsContract.git
cd PayoutsContract
forge install
npm test          # clean build + full suite
```

`npm test` cleans before building on purpose: the OpenZeppelin Upgrades plugin
validates upgrade safety from a **full** compilation and refuses to run against
build info produced by an incremental rebuild.

Deploy locally:

```bash
npm run anvil     # in another terminal
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 npm run deploy:local
```

Deployment environment variables:

| Variable | Meaning |
|---|---|
| `ADMIN` | Operates payouts and manages roles (required) |
| `PROXY_ADMIN_OWNER` | Upgrade authority; defaults to `ADMIN` |
| `TRUSTED_FORWARDER` | ERC-2771 forwarder for gasless claims; omit for recipient-pays |

## Walkthrough

Paying a run of two people, in claim mode, with a 30-day window:

```solidity
// 1. OPERATOR opens a distribution for this run.
uint256 id = payouts.createDistribution(
    address(usdc),                       // the asset
    PayoutsContract.PayoutMode.Claim,    // recipients collect
    uint64(block.timestamp + 30 days),   // expiry (0 = never)
    runRef,                              // the payout run's id
    address(0)                           // eligibility gate (see Compliance)
);

// 2. OPERATOR writes the statements. Repeat in batches of up to 200.
payouts.setPayoutAmounts(id, [alice, bob], [100e6, 50e6]);

// 3. FUNDER puts the money in. May be split over several transactions.
usdc.approve(address(payouts), 150e6);
payouts.fundPayoutToken(id, 150e6);
// payouts.remainingFunding(id) == 0

// 4. Four eyes take it live: refuses unless every entry is covered, and the
//    approval binds the run's exact content — edit it, and it must be re-seen.
payouts.proposeFinalizeDistribution(id);   // OPERATOR
payouts.approveFinalizeDistribution(id);   // APPROVER (a different person)

// 5a. Recipients collect (Claim mode).
payouts.claimPayout(id);                   // called by alice

// 5b. Or the OPERATOR sends (Auto mode) — any subset.
payouts.batchDistributeAutomatic(id, [alice, bob]);

// 5c. Or record a payment made elsewhere, moving nothing here.
payouts.markPayoutAsPaid(id, carol);

// 6. Close it: either everything settled...
payouts.closeDistribution(id);
// ...or, once the window has passed, four eyes return what nobody collected.
payouts.proposeSweepUnclaimed(id, treasury);   // OPERATOR
payouts.approveSweepUnclaimed(id, treasury);   // APPROVER
```

## Who pays the gas

| `trustedForwarder` | Claiming |
|---|---|
| `address(0)` (default) | The recipient signs and pays their own gas |
| An ERC-2771 forwarder | A relayer submits and pays; the recipient still receives |

Set it at initialize, or later via the four-eyes pair
`proposeSetTrustedForwarder` / `approveSetTrustedForwarder`. Because it lives
in storage rather than an immutable, one implementation serves both choices and
a tenant can change their mind without redeploying.

> ⚠️ A trusted forwarder can act as **any** recipient — that is what makes
> relaying work. Point it only at a forwarder that verifies signatures, such as
> OpenZeppelin's `ERC2771Forwarder`.

Claiming costs the claimer gas, so a payout can in principle be worth less than
collecting it. Integrators should warn on dust rather than let someone spend
more than they receive.

## Roles

Duties are split so that no single key can invent a payout, fund it, and take
it live. One address may hold several roles, but each function demands exactly
the role whose job it is — and the four-eyes actions demand a second person
besides.

| Role | Job | What it can do |
|---|---|---|
| `OPERATOR_ROLE` | Day-to-day | Create distributions, write amounts, push payments, record receipts, close; **propose** finalize and sweep |
| `FUNDER_ROLE` | Treasury | `fundPayoutToken` — the only way money comes in |
| `ADMIN_ROLE` | Guardian | `pause`/`unpause`; **propose** withdraw and forwarder changes; cancel proposals |
| `APPROVER_ROLE` | Second pair of eyes | **Approve** any proposal — never their own |
| `DEFAULT_ADMIN_ROLE` | Root | Schedule/grant/revoke roles. Still the most powerful key — put it on a multisig behind a timelock |
| ProxyAdmin owner | Upgrade authority | Upgrade the implementation — **outside** the role system; the deploy script can put it behind a `TimelockController` |

`initialize(admin, approver, forwarder)` refuses `approver == admin`: the
four-eyes split exists from the first block, not from a policy document.
Recipients need no role: being written into a distribution is the entitlement.

**The four-eyes actions** — each is `proposeX` (by its owning role) then
`approveX` (by an approver who is not the proposer). Proposals lapse after
`PROPOSAL_TTL` (7 days), bind their exact parameters, and finalization binds
the run's exact content — edit the run after proposing and the pending approval
dies with the edit. Every step is evented (`ActionProposed` / `ActionApproved`
/ `ActionCancelled`).

**Granting a role waits; revoking does not.** A grant must be announced with
`scheduleRoleGrant` and only takes effect after `ROLE_GRANT_DELAY` (2 days).
That closes the obvious way around four eyes: without it, the root key could
grant `APPROVER_ROLE` to a second address it controls and approve its own
proposal in the next call — two signatures, one person. Revocation stays
immediate, because a compromised key has to be removable *now*. Either the
role's admin or the guardian (`ADMIN_ROLE`) can cancel a pending grant, so the
veto does not need the key that scheduled it, and an unused announcement lapses
rather than lingering.

> The root key still ultimately controls the role graph — the delay buys the
> time to notice and react, and the timelocked upgrade path is the backstop if
> the root itself is the problem. Custody of that key remains the foundation.

## API reference

**Setup**

| Function | Notes |
|---|---|
| `createDistribution(address payoutToken, PayoutMode mode, EntryMode entryMode, uint64 expiry, bytes32 runRef, address eligibilityRegistry)` | OPERATOR. `payoutToken = address(0)` for native; `expiry = 0` never expires; `Auto`+`Merkle` refused |
| `setPayoutAmounts(uint256 id, address[] recipients, uint256[] amounts)` | OPERATOR, **Direct only**. Setup, ≤ 200 per call. Writing the same recipient twice reverts |
| `proposeSetMerkleRoot(id, root, declaredTotal, recipientCount)` → `approveSetMerkleRoot(...)` | OPERATOR + APPROVER, **Merkle only**. Setup, before funding. Binds all three values |
| `fundPayoutToken(uint256 id, uint256 amount)` | FUNDER. `payable` for native. Refuses to exceed `totalOwed` |
| `proposeFinalizeDistribution(id)` → `approveFinalizeDistribution(id)` | OPERATOR proposes, APPROVER approves. Requires `funded == totalOwed`; binds the run's content |

**Paying**

| Function | Notes |
|---|---|
| `claimPayout(uint256 id)` | Recipient, **Direct only**. `Claim` mode, before expiry, gate-checked. ERC-2771 aware |
| `claimPayout(uint256 id, uint256 amount, bytes32[] proof)` | Recipient, **Merkle only**. Same checks, plus proof verification |
| `claimWithCode(id, amount, receiver, proof, signature)` | Anyone, **Code only**. The signature names the receiver; the code is spent once |
| `batchDistributeAutomatic(uint256 id, address[] recipients)` | OPERATOR. `Auto` mode, any subset. Skips already-settled, reverts for strangers and the ineligible |
| `markPayoutAsPaid(id, recipient)` / `batchMarkPayoutAsPaid` | OPERATOR, **Direct only**. Off-chain receipt; releases that share from the reserve; ungated |
| `markPayoutAsPaid(id, recipient, amount, proof)` | OPERATOR, **Merkle only**. Same, proven. Single recipient — at merkle scale this is the exception, not bulk work |
| `proposeSweepUnclaimed(id, to)` → `approveSweepUnclaimed(id, to)` | OPERATOR + APPROVER. After expiry only; returns the remainder and closes the run |
| `closeDistribution(uint256 id)` | OPERATOR. Requires nothing left reserved |

**Guarding**

`proposeSetTrustedForwarder(addr)` → `approveSetTrustedForwarder(addr)` (ADMIN + APPROVER) ·
`proposeEmergencyWithdraw(token, to, amount)` → `approveEmergencyWithdraw(...)` (ADMIN + APPROVER, surplus only) ·
`cancelProposal(bytes32)` (proposer or ADMIN) · `pause()` / `unpause()` (ADMIN)

**Roles**

`scheduleRoleGrant(role, account)` → `grantRole(role, account)` after `ROLE_GRANT_DELAY` (role admin) ·
`cancelRoleGrant(role, account)` (role admin or ADMIN) · `revokeRole(role, account)` — immediate ·
`roleGrantWindow(role, account)` · `roleGrantId(role, account)`

**Views**

`getDistribution(id)` · `getPayoutAmount(id, recipient)` (0 in Merkle mode — nothing is stored per recipient) · `canClaimPayout(id, recipient)` · `canClaimPayout(id, recipient, amount, proof)` · `verifyEntry(id, recipient, amount, proof)` · `remainingFunding(id)` · `getRecipientCount(id)` · `payoutAmounts(id, recipient)` · `paidOut(id, recipient)` · `reservedByToken(token)` · `proposals(bytes32)` · `finalizeProposalId(id)` · `merkleRootProposalId(id, root, total, count)` · `sweepProposalId(id, to)` · `withdrawProposalId(token, to, amount)` · `forwarderProposalId(addr)` · `trustedForwarder()` · `isTrustedForwarder(address)`

**Events**

`DistributionCreated` · `PayoutAmountsSet` · `MerkleRootSet` · `PayoutTokenFunded` · `DistributionStateAdvanced` · `PayoutClaimed` (recipient collected) · `PayoutSent` (operator pushed) · `CodeRedeemed` (a giveaway code was spent) · `PayoutMarkedAsPaid` (settled elsewhere) · `UnclaimedSwept` · `ActionProposed` · `ActionApproved` · `ActionCancelled` · `TrustedForwarderUpdated` · `EmergencyWithdrawal`

## Upgradeability

Deployed behind an OpenZeppelin **transparent proxy**:

- **Implementation** — the logic (`src/PayoutsContract.sol`).
- **Proxy** — holds state, delegates to the implementation; the address everyone
  interacts with.
- **ProxyAdmin** — controls upgrades. Its **owner** is the sole upgrade
  authority and is distinct from `ADMIN_ROLE`.

Reentrancy protection uses `ReentrancyGuardTransient`, whose guard lives in a
fixed EIP-1153 transient slot and holds **zero** persistent storage — it can
never collide with or shift contract storage across an upgrade.

## Security

Read [`SECURITY.md`](SECURITY.md) before deploying: it states the trust
assumptions, the blast radius of a tenant-wide contract and what bounds it, the
forwarder warning, and how to report a vulnerability.

The contract is **unaudited**.

## Testing

```bash
npm test                # full suite (clean build first)
npm run test:quick      # fast feedback, unoptimised, fewer fuzz runs
npm run test:invariant  # stateful invariants only
npm run test:gas        # gas report
npm run coverage        # coverage summary
```

Suites map one-to-one onto behaviour:

| File | Covers |
|---|---|
| `test/Lifecycle.t.sol` | States and transitions, initialization, pausing, and that v1's removed surface is really gone |
| `test/Amounts.t.sol` | Writing entries, duplicates, batch limits, `totalOwed` (incl. fuzz) |
| `test/Funding.t.sol` | Over/under-funding, the finalize gate, native vs ERC-20 (incl. fuzz) |
| `test/Payment.t.sol` | Claim, push, off-chain receipt, and the double-payment race between them |
| `test/Reserve.t.sol` | Expiry, sweeping, surplus vs reserved — plus **stateful invariants** |
| `test/Governance.t.sol` | Role granularity (operator ≠ funder ≠ guardian) and four-eyes: self-approval blocked, TTL lapse, content binding, one-shot approvals, cancelling |
| `test/Compliance.t.sol` | All three gate postures, revocation at claim time, failing closed, the ERC-3643 adapter following a registry swap |
| `test/Merkle.t.sol` | Committing a list in one transaction, forged and borrowed proofs, the **second-preimage attack**, the declared-total trade-off, both modes coexisting |
| `test/Code.t.sol` | Giveaways: prefunding with nobody named, **front-running resistance**, one-shot codes, cross-distribution replay, gated campaigns, sweeping the unredeemed budget |
| `test/Forwarder.t.sol` | ERC-2771: relayed claims, untrusted and revoked forwarders, role checks, four-eyes on the forwarder change |

## Documentation

```bash
npm run docgen          # generate into docs/
npm run docgen:serve    # generate and serve
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT — see [`LICENSE`](LICENSE).
