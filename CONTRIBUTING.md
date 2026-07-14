# Contributing to PayoutsContract

Thank you for your interest in contributing. This document describes how to set
up your environment, our coding standards, and the pull-request process.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Node.js 20+ (for the npm script wrappers)
- Git

## Getting Started

```bash
git clone https://github.com/SimplyTokenized/PayoutsContract.git
cd PayoutsContract
npm run setup      # installs library submodules via forge
npm run build      # compiles the contracts
npm test           # runs the test suite
```

Copy the environment template before running any deployment scripts:

```bash
cp .env.example .env
```

## Development Workflow

1. **Branch** off `main` using a descriptive name (`fix/...`, `feat/...`, `docs/...`).
2. **Make your change** with accompanying tests.
3. **Format** your code: `npm run format` (CI enforces `forge fmt --check`).
4. **Build and test:**
   ```bash
   forge clean && forge test
   ```
   > Always run `forge clean` before the final test run. The OpenZeppelin
   > upgrade-safety validator requires a full compilation and will fail on an
   > incremental build.
5. **Open a pull request** against `main` and fill out the description.

## Coding Standards

- Solidity `0.8.27`, formatted with `forge fmt` (config in `foundry.toml`).
- Follow checks-effects-interactions; update state before external calls.
- Use `SafeERC20` for all token transfers.
- Add NatSpec (`@dev`, `@param`, `@notice`) to all public/external functions.
- Preserve storage layout — this is an upgradeable contract. Do not reorder,
  remove, or change the type of existing state variables; only append.
- Every new external function or branch must be covered by a test.

## Testing Expectations

- New features require positive and negative (revert) test cases.
- Bug fixes require a regression test that fails before the fix.
- Keep the suite green: `forge clean && forge test` must pass with 0 failures.

## Commit & PR Guidelines

- Write clear, imperative commit messages ("Add manual-mode funding guard").
- Keep PRs focused; unrelated changes belong in separate PRs.
- Reference any related issues in the PR description.
- Note any storage-layout or interface changes explicitly — these affect
  upgrade safety and downstream integrators.

## Reporting Security Issues

Do **not** open public issues for security vulnerabilities. Follow the process
in [`SECURITY.md`](SECURITY.md).

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
