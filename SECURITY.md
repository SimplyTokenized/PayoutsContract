# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 1.x     | ✅        |

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

- **Privileged roles are trusted.** `ADMIN_ROLE`, `SNAPSHOT_ROLE`, and
  `WHITELIST_ROLE` holders can set balances, compute payouts, fund, pause, and
  withdraw funds. Compromise of these keys can lead to loss of funds.
- **`emergencyWithdraw` can move any balance held by the contract**, including
  funds already committed to unclaimed payouts. Restrict `ADMIN_ROLE` to a
  multisig and/or timelock.
- **Upgrade authority is separate from operational roles.** The proxy is a
  transparent proxy; upgrades are controlled by the **ProxyAdmin owner** set at
  deployment — not by `DEFAULT_ADMIN_ROLE` on the implementation. Secure the
  ProxyAdmin owner with a multisig/timelock.
- **Snapshot balances are set by a trusted off-chain process.** Correctness of
  allocations depends on the honesty and accuracy of the `SNAPSHOT_ROLE`
  operator's off-chain computation.
- **Fee-on-transfer and rebasing tokens are not supported** as payout tokens.
- **A Cancun-capable chain is required.** Reentrancy protection uses OpenZeppelin's
  `ReentrancyGuardTransient` (EIP-1153 transient storage). Deploying to a chain
  without EIP-1153 support will cause `nonReentrant` functions to behave
  incorrectly. All current target chains (Ethereum mainnet/Sepolia, Avalanche
  C-Chain/Fuji, and major L2s) support it.

## Best Practices for Deployment

1. Assign `ADMIN_ROLE` and the ProxyAdmin owner to a multisig (e.g. Safe),
   ideally behind a timelock.
2. Use separate accounts for `SNAPSHOT_ROLE` (operational) and `ADMIN_ROLE`
   (treasury) where feasible.
3. Verify the deployed implementation and proxy on the block explorer.
4. Fund distributions using `getRequiredFundingAmount` to avoid over- or
   under-funding.
5. Keep the contract paused during configuration where appropriate.
