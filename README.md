# PayoutsContract

[![CI](https://github.com/SimplyTokenized/PayoutsContract/actions/workflows/test.yml/badge.svg)](https://github.com/SimplyTokenized/PayoutsContract/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.27-363636.svg)](https://soliditylang.org/)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

An upgradeable smart contract for distributing payouts to investors based on
historical token balances captured at specific block numbers. It supports
multiple independent distributions, proportional or manual allocation, three
payout methods (on-chain claim, on-chain automatic, and off-chain bank
transfer), and scalable batch operations.

> ⚠️ **Not yet audited.** An independent third-party audit is recommended before
> mainnet deployment. See [`SECURITY.md`](SECURITY.md).

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Distribution Lifecycle](#distribution-lifecycle)
- [Quick Start](#quick-start)
- [Usage Walkthrough](#usage-walkthrough)
- [Payout Calculation](#payout-calculation)
- [Roles & Access Control](#roles--access-control)
- [API Reference](#api-reference)
- [Upgradeability](#upgradeability)
- [Security](#security)
- [Testing](#testing)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Upgradeable** — OpenZeppelin transparent proxy pattern; state persists across upgrades.
- **Snapshot-based** — allocations derived from base-token balances at a chosen block.
- **Two allocation modes** — `Proportional` (share of snapshot) or `Manual` (exact admin-set amounts).
- **Three payout methods** — `Claim` (investor pulls), `Automatic` (admin pushes on-chain), `Bank` (off-chain, marked on-chain).
- **Multiple independent distributions** — each with its own snapshot block and single payout token (ERC20 or ETH).
- **Optional whitelisting** — enforced across all payout methods when enabled.
- **Scalable batches** — up to `MAX_BATCH_SIZE` (200) entries per call.
- **Pausable** and **reentrancy-protected**, with role-based access control and `SafeERC20` transfers.

## Architecture

The contract is deployed behind an OpenZeppelin **transparent proxy**:

- **Implementation** — holds the logic (`src/PayoutsContract.sol`).
- **Proxy** — holds state and delegates calls to the implementation; this is the address users interact with.
- **ProxyAdmin** — a separate contract that controls upgrades. Its **owner** is set at deployment and is the sole upgrade authority. This is distinct from the on-chain roles below.

Built on OpenZeppelin Contracts / Contracts-Upgradeable `5.5.0`, Solidity `0.8.27`.

## Distribution Lifecycle

Each distribution advances through four states. Payout functions only work in the `Payout` state.

```
Setup ──▶ Compute ──▶ Payout ──▶ Done
  │          │           │          │
  │          │           │          └─ finalizeDistribution()  (no further payouts)
  │          │           └───────────  fund + claim / auto / bank
  │          └───────────────────────  startCompute() → computePayoutAmounts() → finalizeCompute()
  └──────────────────────────────────  createDistribution() → set balances / amounts
```

| State | What happens | How to advance |
| ----- | ------------ | -------------- |
| `Setup` | Configure investor balances, methods, and the total/manual amounts. | `startCompute()` |
| `Compute` | Pre-compute per-investor payout amounts (Proportional only; Manual skips computation). | `finalizeCompute()` |
| `Payout` | Fund the contract and process claims, automatic distributions, and bank markings. | `finalizeDistribution()` |
| `Done` | Terminal. No further payouts; residual funds recoverable via `emergencyWithdraw`. | — |

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 20+ (for the npm script wrappers)

### Install

```bash
git clone https://github.com/SimplyTokenized/PayoutsContract.git
cd PayoutsContract
npm run setup      # installs library submodules via forge
```

### Configure

```bash
cp .env.example .env
# then edit .env — at minimum set BASE_TOKEN and ADMIN
```

### Build & Test

```bash
npm run build
forge clean && npm test    # clean build required for OZ upgrade-safety validation
```

### Deploy

```bash
npm run deploy:local       # Anvil (uses a well-known local test key)
npm run deploy:sepolia     # Ethereum Sepolia
npm run deploy:fuji        # Avalanche Fuji
npm run deploy:testnet     # generic testnet via $TESTNET_RPC
```

## Usage Walkthrough

### Proportional distribution (typical)

```solidity
// 1. Create a distribution: snapshot at block 1_000_000, payouts in USDC.
uint256 id = payouts.createDistribution(1_000_000, usdcAddress);
// (Pass address(0) as the token to pay out in ETH.)

// 2. Set investor snapshot balances and their chosen payout methods.
address[] memory investors = [alice, bob, charlie];
uint256[] memory balances  = [uint256(1000e18), 2000e18, 3000e18];
PayoutsContract.PayoutMethod[] memory methods = [
    PayoutsContract.PayoutMethod.Claim,      // Alice pulls
    PayoutsContract.PayoutMethod.Automatic,  // Bob is pushed on-chain
    PayoutsContract.PayoutMethod.Bank        // Charlie is paid off-chain
];
payouts.setInvestorBalances(id, investors, balances, methods);

// 3. Set the full intended distribution amount (Claim + Automatic + Bank).
payouts.setDistributionTotalAmount(id, 6000e6); // e.g. 6000 USDC

// 4. Compute per-investor amounts (batched), then finalize into Payout.
payouts.startCompute(id);
payouts.computePayoutAmounts(id, investors);   // up to 200 per call
payouts.finalizeCompute(id);

// 5. Fund ONLY the on-chain portion (Claim + Automatic; excludes Bank).
uint256 required = payouts.getRequiredFundingAmount(id); // O(1), excludes Bank
usdc.approve(address(payouts), required);
payouts.fundPayoutToken(id, required);
// For ETH distributions: payouts.fundPayoutToken{value: required}(id, required);

// 6. Process payouts.
payouts.claimPayout(id);                         // called by Alice
payouts.batchDistributeAutomatic(id, [bob]);     // admin pushes to Bob
payouts.markPayoutAsPaid(id, charlie);           // admin marks Charlie paid off-chain

// 7. Close the distribution.
payouts.finalizeDistribution(id);
```

### Manual distribution (exact amounts)

```solidity
// 1. Create in Manual mode.
uint256 id = payouts.createDistribution(
    1_000_000, usdcAddress, PayoutsContract.DistributionMode.Manual
);

// 2. Set balances/methods (balances still gate eligibility & method categories).
payouts.setInvestorBalances(id, investors, balances, methods);

// 3. Set exact per-investor payout amounts (no proportional computation).
payouts.setManualPayoutAmounts(id, investors, exactAmounts);

// 4. Advance to Payout (computePayoutAmounts is NOT used in Manual mode).
payouts.startCompute(id);
payouts.finalizeCompute(id);

// 5. Fund the on-chain portion, then process payouts as above.
//    In Manual mode, compute required funding off-chain from the per-investor
//    amounts of Claim + Automatic investors (getRequiredFundingAmount reverts
//    in Manual mode).

// 6. payouts.finalizeDistribution(id);
```

## Payout Calculation

In **Proportional** mode, each investor's amount is their share of the snapshot
applied to the full intended distribution amount:

```
payoutAmount = (investorSnapshotBalance * totalDistributionAmount) / totalSnapshotBalance
```

Integer division truncates, so the sum of per-investor amounts never exceeds
`totalDistributionAmount`. `getRequiredFundingAmount` returns the aggregate for
`Claim + Automatic` investors only — `Bank` investors are paid off-chain and are
never funded on-chain.

**Example** — total snapshot 6000 tokens, total distribution 6000 USDC:

| Investor | Snapshot | Method | On-chain payout |
| -------- | -------- | ------ | --------------- |
| Alice    | 1000     | Claim     | 1000 USDC |
| Bob      | 2000     | Automatic | 2000 USDC |
| Charlie  | 3000     | Bank      | 3000 USDC (off-chain) |

Required on-chain funding here is **3000 USDC** (Alice + Bob only).

## Roles & Access Control

| Role | Capabilities |
| ---- | ------------ |
| `DEFAULT_ADMIN_ROLE` | Root role admin — grants and revokes all roles. |
| `ADMIN_ROLE` | Manage distribution amounts, compute/finalize, fund, batch payouts, whitelist requirement, pause/unpause, emergency withdraw. |
| `SNAPSHOT_ROLE` | Create distributions and set investor balances/methods. |
| `WHITELIST_ROLE` | Add/remove addresses from the whitelist. |

> **Upgrade authority is not a role.** Contract upgrades are controlled by the
> **ProxyAdmin owner** set at deployment, independently of the roles above.

All four roles are granted to the `_admin` address at initialization. For
production, split them across dedicated operational and treasury accounts and
place `ADMIN_ROLE` / the ProxyAdmin owner behind a multisig and/or timelock.

## API Reference

### Distribution management
- `createDistribution(uint256 blockNumber, address payoutToken) → uint256` — Proportional mode. *(SNAPSHOT_ROLE)*
- `createDistribution(uint256 blockNumber, address payoutToken, DistributionMode mode) → uint256` *(SNAPSHOT_ROLE)*

### Snapshot configuration *(state: Setup)*
- `setInvestorBalances(uint256 id, address[] investors, uint256[] balances, PayoutMethod[] methods)` *(SNAPSHOT_ROLE)*
- `setInvestorBalance(uint256 id, address investor, uint256 balance, PayoutMethod method)` *(SNAPSHOT_ROLE)*

### Amounts & funding
- `setDistributionTotalAmount(uint256 id, uint256 amount)` — Proportional only, set once, state Setup. *(ADMIN_ROLE)*
- `setManualPayoutAmounts(uint256 id, address[] investors, uint256[] amounts)` — Manual only, state Setup. *(ADMIN_ROLE)*
- `getRequiredFundingAmount(uint256 id) → uint256` — view, Proportional only (reverts in Manual mode).
- `fundPayoutToken(uint256 id, uint256 amount)` — payable; state Payout. *(ADMIN_ROLE)*

### Compute pipeline
- `startCompute(uint256 id)` — Setup → Compute. *(ADMIN_ROLE)*
- `computePayoutAmounts(uint256 id, address[] investors)` — Proportional only, state Compute. *(ADMIN_ROLE)*
- `finalizeCompute(uint256 id)` — Compute → Payout. *(ADMIN_ROLE)*
- `finalizeDistribution(uint256 id)` — Payout → Done. *(ADMIN_ROLE)*

### Payouts *(state: Payout)*
- `claimPayout(uint256 id)` — investor pulls their Claim payout. *(public, nonReentrant)*
- `batchDistributeAutomatic(uint256 id, address[] investors)` — push to Automatic investors. *(ADMIN_ROLE, nonReentrant)*
- `markPayoutAsPaid(uint256 id, address investor)` — mark a Bank investor paid off-chain. *(ADMIN_ROLE)*
- `batchMarkPayoutAsPaid(uint256 id, address[] investors)` *(ADMIN_ROLE)*

### Whitelist
- `updateWhitelistRequirement(bool requireWhitelist)` *(ADMIN_ROLE)*
- `addToWhitelist(address)` / `removeFromWhitelist(address)` *(WHITELIST_ROLE)*
- `batchAddToWhitelist(address[])` / `batchRemoveFromWhitelist(address[])` *(WHITELIST_ROLE)*

### Emergency & lifecycle
- `emergencyWithdraw(address token, address to, uint256 amount)` — withdraw any token/ETH held by the contract. *(ADMIN_ROLE)*
- `pause()` / `unpause()` *(ADMIN_ROLE)*

### Views
- `getDistribution(uint256 id) → Distribution` — full distribution struct.
- `getPayoutAmount(uint256 id, address investor) → uint256`
- `getInvestorCount(uint256 id) → uint256`
- `canClaimPayout(uint256 id, address investor) → (bool canClaim, uint256 payoutAmount)`
- Public mappings/vars: `distributions`, `snapshotBalances`, `isInvestor`, `payoutPreferences`, `paidOut`, `payoutAmounts`, `whitelist`, `requireWhitelist`, `baseToken`, `nextDistributionId`, and the role/`MAX_BATCH_SIZE` constants.

## Upgradeability

- The **proxy address is stable** — always interact with it, not the implementation.
- **Upgrades** are performed by the ProxyAdmin owner using OpenZeppelin's upgrade tooling.
- **Storage layout is append-only.** Never reorder, remove, or retype existing
  state variables; the CI suite runs OpenZeppelin's upgrade-safety validation.

## Security

- Checks-effects-interactions ordering on every fund-moving path; `paidOut` set before transfer.
- `nonReentrant` on `claimPayout` and `batchDistributeAutomatic`.
- `SafeERC20` for all token transfers; explicit `msg.value` handling for ETH.
- Role-based access control and pausability.
- Optional whitelist enforced across **all** payout methods.

**Trust assumptions and known operational risks** (privileged roles,
`emergencyWithdraw` scope, off-chain snapshot correctness, unsupported
fee-on-transfer tokens) are documented in [`SECURITY.md`](SECURITY.md). Report
vulnerabilities privately per that policy.

## Testing

```bash
forge clean && forge test        # full suite (clean build required)
npm run test:gas                 # with gas report
npm run test:verbose             # verbose traces
```

> The OpenZeppelin upgrade-safety validator requires a full compilation. If you
> see "Build info file … is not from a full compilation", run `forge clean`
> first. CI already performs a clean build.

## Documentation

Auto-generated API docs from NatSpec:

```bash
npm run docgen         # writes to docs/
npm run docgen:serve   # build and serve locally
```

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup,
coding standards, and the PR process.

## License

Released under the [MIT License](LICENSE).
