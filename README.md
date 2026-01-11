# Payouts Contract

An upgradeable smart contract for distributing payouts to investors based on historical token balances at specific block numbers. Features multiple independent distributions, flexible payout methods (claim, automatic, or bank transfer), and scalable batch operations.

## ✨ Features

- ✅ **Proxy Contract Support** - Fully upgradeable using OpenZeppelin's transparent proxy pattern
- 📸 **Snapshot-Based** - Takes snapshots of base token balances at specific block numbers
- 💰 **Single Payout Token per Distribution** - Each distribution uses one payout token (ERC20 or ETH)
- 📊 **Proportional Payouts** - Calculates payouts based on investor's share of total snapshot balance
- 🎯 **Flexible Payout Methods** - Three options: Claim (on-chain), Automatic (on-chain), or Bank (off-chain)
- 🔄 **Multiple Independent Distributions** - Create multiple payout distributions, each with its own snapshot
- 📋 **Optional Whitelisting** - Enable/disable whitelist requirement for payouts
- ⚡ **Scalable Batch Operations** - Supports 10,000+ investors via batch operations (up to 200 per call)
- ⏸️ **Pausable** - Admin can pause/unpause operations
- 🔒 **Access Control** - Role-based access control for admin functions
- 🛡️ **Reentrancy Protection** - Protected against reentrancy attacks
- ⚡ **O(1) Funding Calculation** - Efficient required funding calculation without iteration

## 🏗️ Architecture

The contract uses OpenZeppelin's transparent proxy pattern:
- **Implementation Contract**: Contains the actual logic
- **Proxy Contract**: Points to the implementation and stores state
- **Proxy Admin**: Controls upgrades (has `DEFAULT_ADMIN_ROLE`)

## 🚀 Quick Start

### Prerequisites

1. Install dependencies:
```bash
npm run install:deps
# Or manually:
forge install OpenZeppelin/openzeppelin-contracts-upgradeable OpenZeppelin/openzeppelin-foundry-upgrades OpenZeppelin/openzeppelin-contracts
```

2. Set up environment variables in `.env`:
```bash
BASE_TOKEN=<address_of_base_token>  # The ERC20 token used for snapshots
ADMIN=<admin_address>
```

### Build

```bash
npm run build
```

### Test

```bash
# Run all tests
npm run test

# Run with gas report
npm run test:gas

# Run with verbose output
npm run test:verbose
```

### Deploy

```bash
# Local deployment
npm run deploy:local

# Testnet deployment
npm run deploy:testnet
```

## 📖 Contract Functions

### Distribution Management

#### Create Distribution
- `createDistribution(uint256 blockNumber, address payoutToken)` - Create a new distribution with a snapshot block number and payout token (address(0) for ETH)
  - **Role**: `SNAPSHOT_ROLE`
  - **Returns**: `distributionId`

### Snapshot Functions

#### Set Investor Balances
- `setInvestorBalances(uint256 distributionId, address[] investors, uint256[] balances, PayoutMethod[] methods)` - Set investor balances and payout methods in batch (up to 200 investors)
  - **Role**: `SNAPSHOT_ROLE`
  - **Note**: Balances should be calculated off-chain using archive node or indexer

- `setInvestorBalance(uint256 distributionId, address investor, uint256 balance, PayoutMethod method)` - Set a single investor balance and payout method
  - **Role**: `SNAPSHOT_ROLE`
  - **Note**: Useful for individual updates or small additions

### Payout Token Management

#### Fund Distribution
- `fundPayoutToken(uint256 distributionId, uint256 amount)` - Fund a distribution with payout tokens (ERC20 or ETH)
  - **Role**: `ADMIN_ROLE`
  - **Note**: Only fund amounts for Claim and Automatic investors (exclude Bank investors)
  - **Payable**: Yes (when funding with ETH)

- `getRequiredFundingAmount(uint256 distributionId, uint256 totalPayoutAmount)` - Calculate required funding amount excluding bank transfer investors
  - **View Function**
  - **Returns**: Amount needed for Claim and Automatic investors only (O(1) calculation)

### Investor Functions

#### Claim Payout
- `claimPayout(uint256 distributionId)` - Claim payout directly (for investors who chose Claim method)
  - **Public Function**
  - **Note**: Requires whitelist if `requireWhitelist` is true
  - **Note**: Investor must have `PayoutMethod.Claim` preference

### Admin Functions

#### Automatic Distribution
- `batchDistributeAutomatic(uint256 distributionId, address[] investors)` - Batch distribute payouts to investors with Automatic preference
  - **Role**: `ADMIN_ROLE`
  - **Note**: Processes up to 200 investors per call
  - **Note**: Automatically sends payouts on-chain

#### Bank Transfer Management
- `markPayoutAsPaid(uint256 distributionId, address investor)` - Mark investor as paid out via bank transfer
  - **Role**: `ADMIN_ROLE`
  - **Note**: Bank investors receive payouts off-chain, so no funds are deducted

- `batchMarkPayoutAsPaid(uint256 distributionId, address[] investors)` - Batch mark multiple investors as paid out via bank transfer
  - **Role**: `ADMIN_ROLE`
  - **Note**: Processes up to 200 investors per call

#### Whitelist Management
- `addToWhitelist(address account)` - Add address to whitelist
  - **Role**: `WHITELIST_ROLE`

- `removeFromWhitelist(address account)` - Remove address from whitelist
  - **Role**: `WHITELIST_ROLE`

- `batchAddToWhitelist(address[] accounts)` - Batch add addresses to whitelist
  - **Role**: `WHITELIST_ROLE`
  - **Note**: Processes up to 200 addresses per call

- `batchRemoveFromWhitelist(address[] accounts)` - Batch remove addresses from whitelist
  - **Role**: `WHITELIST_ROLE`
  - **Note**: Processes up to 200 addresses per call

- `updateWhitelistRequirement(bool requireWhitelist)` - Enable/disable whitelist requirement for payouts
  - **Role**: `ADMIN_ROLE`

#### Emergency Functions
- `emergencyWithdraw(address token, address to, uint256 amount)` - Emergency withdrawal of tokens or ETH
  - **Role**: `ADMIN_ROLE`
  - **Note**: Use with extreme caution - can withdraw any token or ETH from contract

- `pause()` - Pause all contract operations
  - **Role**: `ADMIN_ROLE`

- `unpause()` - Unpause contract operations
  - **Role**: `ADMIN_ROLE`

### View Functions

- `getDistribution(uint256 distributionId)` - Get distribution details
  - **Returns**: `(distributionId, snapshotBlockNumber, totalSnapshotBalance, payoutToken, payoutTokenAmount, claimBalance, automaticBalance, bankBalance, initialized, investorCount)`

- `getPayoutAmount(uint256 distributionId, address investor)` - Get payout amount for an investor
  - **Returns**: `payoutAmount`

- `getInvestorCount(uint256 distributionId)` - Get number of investors in a distribution
  - **Returns**: `count`

- `canClaimPayout(uint256 distributionId, address investor)` - Check if investor can claim payout
  - **Returns**: `(bool canClaim, string reason)`

- `snapshotBalances(uint256 distributionId, address investor)` - Get investor's snapshot balance
- `payoutPreferences(uint256 distributionId, address investor)` - Get investor's payout method preference
- `paidOut(uint256 distributionId, address investor)` - Check if investor has been paid out
- `isInvestor(uint256 distributionId, address investor)` - Check if address is an investor in a distribution
- `whitelist(address account)` - Check if address is whitelisted
- `requireWhitelist()` - Check if whitelist is required

## 🔐 Roles

| Role | Description |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Full admin access, can upgrade contract |
| `ADMIN_ROLE` | Can manage distributions, fund payouts, batch operations, whitelist requirement, pause/unpause |
| `SNAPSHOT_ROLE` | Can create distributions and set investor balances |
| `WHITELIST_ROLE` | Can add/remove addresses from whitelist |

## 📝 Setup Process

### 1. Deploy Contract

Deploy the PayoutsContract using the deployment script:

```bash
npm run deploy:local
```

### 2. Create Distribution

Create a new distribution with a snapshot block number and payout token:

```solidity
// Example: Snapshot at block 1000000, payouts in USDC
uint256 distributionId = payouts.createDistribution(1000000, usdcAddress);

// Example: Snapshot at block 1000000, payouts in ETH
uint256 distributionId = payouts.createDistribution(1000000, address(0));
```

### 3. Set Investor Balances

Set investor balances and payout methods (calculated off-chain):

```solidity
address[] memory investors = [investor1, investor2, investor3];
uint256[] memory balances = [1000 * 10**18, 2000 * 10**18, 3000 * 10**18];
PayoutMethod[] memory methods = [PayoutMethod.Claim, PayoutMethod.Automatic, PayoutMethod.Bank];

payouts.setInvestorBalances(distributionId, investors, balances, methods);
```

### 4. Calculate and Fund Distribution

Calculate required funding (excluding bank investors) and fund the distribution:

```solidity
uint256 totalPayoutAmount = 100000 * 10**18; // Total payout for all investors
uint256 requiredAmount = payouts.getRequiredFundingAmount(distributionId, totalPayoutAmount);

// Fund with ERC20 token
usdc.approve(address(payouts), requiredAmount);
payouts.fundPayoutToken(distributionId, requiredAmount);

// Or fund with ETH
payouts.fundPayoutToken{value: requiredAmount}(distributionId, requiredAmount);
```

### 5. Process Payouts

#### For Claim Method Investors
Investors claim directly:
```solidity
payouts.claimPayout(distributionId);
```

#### For Automatic Method Investors
Admin triggers batch distribution:
```solidity
address[] memory automaticInvestors = [investor2, investor4];
payouts.batchDistributeAutomatic(distributionId, automaticInvestors);
```

#### For Bank Method Investors
Admin marks as paid after off-chain transfer:
```solidity
payouts.markPayoutAsPaid(distributionId, investor3);
// Or batch:
address[] memory bankInvestors = [investor3, investor5];
payouts.batchMarkPayoutAsPaid(distributionId, bankInvestors);
```

## 💡 Example Usage

### Complete Workflow

```solidity
// 1. Create distribution
uint256 distributionId = payouts.createDistribution(1000000, usdcAddress);

// 2. Set investor balances (off-chain calculated)
address[] memory investors = [alice, bob, charlie];
uint256[] memory balances = [1000 * 10**18, 2000 * 10**18, 3000 * 10**18];
PayoutMethod[] memory methods = [
    PayoutMethod.Claim,      // Alice claims directly
    PayoutMethod.Automatic,  // Bob receives automatic distribution
    PayoutMethod.Bank        // Charlie receives bank transfer
];
payouts.setInvestorBalances(distributionId, investors, balances, methods);

// 3. Calculate and fund
uint256 totalPayout = 6000 * 10**6; // 6000 USDC total
uint256 required = payouts.getRequiredFundingAmount(distributionId, totalPayout);
// required = 3000 * 10**6 (only Alice + Bob, excluding Charlie)
usdc.approve(address(payouts), required);
payouts.fundPayoutToken(distributionId, required);

// 4. Process payouts
// Alice claims
payouts.claimPayout(distributionId); // From Alice's address

// Bob receives automatic
payouts.batchDistributeAutomatic(distributionId, [bob]);

// Charlie marked as paid (after bank transfer)
payouts.markPayoutAsPaid(distributionId, charlie);
```

### Check Payout Amount

```solidity
uint256 payout = payouts.getPayoutAmount(distributionId, alice);
// Returns: 1000 * 10**6 (proportional to Alice's snapshot balance)
```

### Check Distribution Status

```solidity
(
    uint256 id,
    uint256 blockNumber,
    uint256 totalBalance,
    address token,
    uint256 funded,
    uint256 claimBalance,
    uint256 automaticBalance,
    uint256 bankBalance,
    bool initialized,
    uint256 count
) = payouts.getDistribution(distributionId);
```

## 📊 Payout Calculation

Payouts are calculated proportionally based on snapshot balances:

### Formula
```
payoutAmount = (investorSnapshotBalance / totalSnapshotBalance) * payoutTokenAmount
```

### Example

**Distribution Setup:**
- Total snapshot balance: 6000 tokens
- Total payout amount: 6000 USDC (funded)

**Investor Balances:**
- Alice: 1000 tokens → 1000 USDC
- Bob: 2000 tokens → 2000 USDC
- Charlie: 3000 tokens → 3000 USDC

**Note**: If only Alice and Bob are Claim/Automatic (Charlie is Bank), then:
- Required funding: 3000 USDC (only for Alice + Bob)
- Charlie receives bank transfer off-chain (not funded on-chain)

## ⚠️ Important Notes

1. **Snapshot Block**: Must be a past block number (cannot be future)
2. **Payout Token**: Each distribution uses ONE payout token (ERC20 or ETH via address(0))
3. **Funding**: Only fund amounts for Claim and Automatic investors (exclude Bank investors)
4. **Bank Transfers**: Bank method investors receive payouts off-chain; no funds deducted from contract
5. **Batch Size**: Maximum 200 investors per batch operation to avoid gas/timeout issues
6. **Fee-on-Transfer Tokens**: NOT supported as payout tokens
7. **Whitelist**: Optional and disabled by default
8. **Proportional Payouts**: Each claim/distribution reduces available `payoutTokenAmount`, affecting subsequent calculations

## 🔄 Upgradeability

The contract uses OpenZeppelin's transparent proxy pattern:
- **Proxy Address**: Remains constant (this is the address users interact with)
- **Implementation**: Can be upgraded by `DEFAULT_ADMIN_ROLE`
- **State**: Stored in proxy, persists across upgrades

## ⚠️ Security Considerations

- ✅ **Reentrancy Protection**: All payout functions use `nonReentrant` modifier
- ✅ **Access Control**: Admin functions protected with role checks
- ✅ **Pausable**: Can pause operations in emergencies
- ✅ **Whitelist**: Optional additional security layer
- ✅ **SafeERC20**: Uses SafeERC20 for token transfers
- ✅ **Input Validation**: All inputs are validated
- ✅ **Emergency Withdraw**: Admin can recover funds in emergencies (use with caution)

## 📚 Documentation

Auto-generated API documentation from NatSpec comments is available in the `docs/` directory. Generate it with:

```bash
npm run docgen
```

Or generate and serve it locally (opens in browser automatically):

```bash
npm run docgen:serve
```

## 📄 License

MIT
