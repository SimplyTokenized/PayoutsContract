// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "./ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PayoutsContract
 * @dev Smart contract for distributing payouts to investors based on historical token balances at specific blocks
 * 
 * Features:
 * - Multiple independent distributions: Create multiple payout distributions, each with its own snapshot
 * - Snapshot-based: Takes snapshot of base token (ERC20) balances at specific block numbers
 * - Proportional payouts: Calculates payouts based on investor's share of total snapshot balance
 * - Flexible payment: Investors can choose to claim directly, automatic distribution, or bank transfer
 * - Multi-token support: Supports payouts in any ERC20 token or ETH
 * - Scalable: Supports 10,000+ investors via batch operations
 * 
 * @notice IMPORTANT: This contract does NOT support fee-on-transfer tokens as payout tokens.
 * @notice Balances are typically calculated off-chain and set on-chain in batches to avoid gas/timeout issues.
 */
contract PayoutsContract is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");
    bytes32 public constant WHITELIST_ROLE = keccak256("WHITELIST_ROLE");

    // Maximum batch size for operations to prevent gas/timeout issues
    uint256 public constant MAX_BATCH_SIZE = 200;

    // The ERC20 token used to determine investor allocations (from ERC20 folder)
    address public baseToken;
    
    // Distribution counter
    uint256 public nextDistributionId;
    
    // Distribution structure
    struct Distribution {
        uint256 distributionId;
        uint256 snapshotBlockNumber;
        uint256 totalSnapshotBalance;
        address payoutToken; // Single payout token for this distribution (address(0) for ETH)
        uint256 payoutTokenAmount; // Total payout amount allocated
        uint256 claimBalance; // Total snapshot balance for Claim method investors
        uint256 automaticBalance; // Total snapshot balance for Automatic method investors
        uint256 bankBalance; // Total snapshot balance for Bank method investors
        bool initialized;
        uint256 investorCount;
    }
    
    // Distribution data: distributionId => Distribution
    mapping(uint256 => Distribution) public distributions;
    
    // Investor snapshot data: distributionId => investor => balance
    mapping(uint256 => mapping(address => uint256)) public snapshotBalances;
    mapping(uint256 => mapping(address => bool)) public isInvestor; // Quick check if address is an investor
    
    // Whitelist configuration
    bool public requireWhitelist; // Whether whitelist is required for payouts
    mapping(address => bool) public whitelist; // Whitelist mapping
    
    // Payout preferences and status
    enum PayoutMethod {
        None,        // 0 - Not set
        Claim,       // 1 - Investor wants to claim directly
        Automatic,   // 2 - Automatic distribution (sent automatically when preference is set or payout is funded)
        Bank         // 3 - Investor wants bank transfer
    }
    
    // distributionId => investor => payout method preference
    mapping(uint256 => mapping(address => PayoutMethod)) public payoutPreferences;
    
    // distributionId => investor => whether payout has been claimed/processed
    mapping(uint256 => mapping(address => bool)) public paidOut;
    
    // distributionId => investor => payout amount (cached calculation)
    mapping(uint256 => mapping(address => uint256)) public payoutAmounts;

    // Events
    event DistributionCreated(uint256 indexed distributionId, uint256 blockNumber, address indexed payoutToken);
    event InvestorBalancesSet(uint256 indexed distributionId, address[] investors, uint256[] balances, uint256 totalBalance);
    event InvestorBalanceAdded(uint256 indexed distributionId, address indexed investor, uint256 balance, uint256 newTotalBalance);
    event PayoutTokenFunded(uint256 indexed distributionId, uint256 amount);
    event PayoutPreferenceSet(uint256 indexed distributionId, address indexed investor, PayoutMethod method);
    event PayoutClaimed(uint256 indexed distributionId, address indexed investor, uint256 amount);
    event PayoutMarkedAsPaid(uint256 indexed distributionId, address indexed investor, uint256 amount);
    event WhitelistRequirementUpdated(bool requireWhitelist);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the PayoutsContract
     * @param _baseToken Address of the ERC20 token used to determine allocations
     * @param _admin Admin address
     */
    function initialize(address _baseToken, address _admin) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_baseToken != address(0), "PayoutsContract: invalid base token");
        require(_admin != address(0), "PayoutsContract: invalid admin");

        baseToken = _baseToken;
        nextDistributionId = 1;

        // Initialize whitelist requirement (default: false, whitelist not required)
        requireWhitelist = false;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(SNAPSHOT_ROLE, _admin);
        _grantRole(WHITELIST_ROLE, _admin);
    }

    // ============ Distribution Management ============

    /**
     * @dev Create a new distribution with a snapshot block number and payout token
     * @param _blockNumber Block number to snapshot balances at
     * @param _payoutToken Address of the payout token (address(0) for ETH) - only one token per distribution
     * @return distributionId The ID of the newly created distribution
     * @notice Each distribution is independent and has its own snapshot block and single payout token
     */
    function createDistribution(uint256 _blockNumber, address _payoutToken) 
        external 
        onlyRole(SNAPSHOT_ROLE) 
        whenNotPaused 
        returns (uint256 distributionId)
    {
        require(_blockNumber > 0 && _blockNumber <= block.number, "PayoutsContract: invalid block number");
        
        distributionId = nextDistributionId;
        nextDistributionId++;
        
        distributions[distributionId] = Distribution({
            distributionId: distributionId,
            snapshotBlockNumber: _blockNumber,
            totalSnapshotBalance: 0,
            payoutToken: _payoutToken,
            payoutTokenAmount: 0,
            claimBalance: 0,
            automaticBalance: 0,
            bankBalance: 0,
            initialized: true,
            investorCount: 0
        });
        
        emit DistributionCreated(distributionId, _blockNumber, _payoutToken);
        return distributionId;
    }

    // ============ Snapshot Functions ============

    /**
     * @dev Set investor balances and payout methods in batch for a specific distribution
     * @param distributionId The distribution ID
     * @param investors Array of investor addresses
     * @param balances Array of corresponding balances at snapshot block
     * @param methods Array of payout methods for each investor
     * @notice Balances should be calculated off-chain using archive node or indexer
     * @notice This function supports up to MAX_BATCH_SIZE investors per call to avoid gas/timeout issues
     * @notice Can be called multiple times to add more investors to the same distribution
     * @notice Admin sets the payout method for each investor when setting balances
     */
    function setInvestorBalances(
        uint256 distributionId,
        address[] calldata investors,
        uint256[] calldata balances,
        PayoutMethod[] calldata methods
    ) 
        external 
        onlyRole(SNAPSHOT_ROLE) 
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        require(investors.length == balances.length, "PayoutsContract: investors and balances length mismatch");
        require(investors.length == methods.length, "PayoutsContract: investors and methods length mismatch");
        require(investors.length > 0 && investors.length <= MAX_BATCH_SIZE, "PayoutsContract: invalid batch size");

        uint256 balanceDelta = 0;
        
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 balance = balances[i];
            PayoutMethod method = methods[i];
            
            require(investor != address(0), "PayoutsContract: invalid investor address");
            require(method != PayoutMethod.None, "PayoutsContract: payout method must be set");
            
            uint256 oldBalance = snapshotBalances[distributionId][investor];
            PayoutMethod oldMethod = payoutPreferences[distributionId][investor];
            
            // Update balances per payout method tracking
            if (oldBalance > 0 && oldMethod != PayoutMethod.None) {
                // Remove from old method category
                if (oldMethod == PayoutMethod.Claim) {
                    dist.claimBalance -= oldBalance;
                } else if (oldMethod == PayoutMethod.Automatic) {
                    dist.automaticBalance -= oldBalance;
                } else if (oldMethod == PayoutMethod.Bank) {
                    dist.bankBalance -= oldBalance;
                }
            }
            
            if (balance > 0) {
                if (oldBalance == 0) {
                    // New investor in this distribution
                    isInvestor[distributionId][investor] = true;
                    dist.investorCount++;
                    balanceDelta += balance;
                } else {
                    // Update existing investor - adjust delta
                    balanceDelta = balanceDelta + balance - oldBalance;
                }
                
                snapshotBalances[distributionId][investor] = balance;
                payoutPreferences[distributionId][investor] = method;
                
                // Add to new method category
                if (method == PayoutMethod.Claim) {
                    dist.claimBalance += balance;
                } else if (method == PayoutMethod.Automatic) {
                    dist.automaticBalance += balance;
                } else if (method == PayoutMethod.Bank) {
                    dist.bankBalance += balance;
                }
            } else if (oldBalance > 0) {
                // Remove investor balance (should rarely be needed)
                isInvestor[distributionId][investor] = false;
                dist.investorCount--;
                balanceDelta -= oldBalance;
                snapshotBalances[distributionId][investor] = 0;
                payoutPreferences[distributionId][investor] = PayoutMethod.None;
            }
        }

        // Update total snapshot balance
        if (balanceDelta != 0) {
            dist.totalSnapshotBalance = dist.totalSnapshotBalance + balanceDelta;
        }

        emit InvestorBalancesSet(distributionId, investors, balances, dist.totalSnapshotBalance);
    }

    /**
     * @dev Add or update a single investor balance and payout method for a distribution
     * @param distributionId The distribution ID
     * @param investor Investor address
     * @param balance Balance at snapshot block
     * @param method Payout method for the investor
     * @notice Useful for individual updates or small additions
     * @notice Admin sets the payout method when setting balance
     */
    function setInvestorBalance(
        uint256 distributionId,
        address investor,
        uint256 balance,
        PayoutMethod method
    ) 
        external 
        onlyRole(SNAPSHOT_ROLE) 
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        require(investor != address(0), "PayoutsContract: invalid investor address");
        require(method != PayoutMethod.None, "PayoutsContract: payout method must be set");

        uint256 oldBalance = snapshotBalances[distributionId][investor];
        PayoutMethod oldMethod = payoutPreferences[distributionId][investor];
        
        // Update balances per payout method tracking
        if (oldBalance > 0 && oldMethod != PayoutMethod.None) {
            // Remove from old method category
            if (oldMethod == PayoutMethod.Claim) {
                dist.claimBalance -= oldBalance;
            } else if (oldMethod == PayoutMethod.Automatic) {
                dist.automaticBalance -= oldBalance;
            } else if (oldMethod == PayoutMethod.Bank) {
                dist.bankBalance -= oldBalance;
            }
        }
        
        if (balance > 0) {
            if (oldBalance == 0) {
                // New investor
                isInvestor[distributionId][investor] = true;
                dist.investorCount++;
                dist.totalSnapshotBalance += balance;
            } else {
                // Update existing investor
                dist.totalSnapshotBalance = dist.totalSnapshotBalance + balance - oldBalance;
            }
            
            snapshotBalances[distributionId][investor] = balance;
            payoutPreferences[distributionId][investor] = method;
            
            // Add to new method category
            if (method == PayoutMethod.Claim) {
                dist.claimBalance += balance;
            } else if (method == PayoutMethod.Automatic) {
                dist.automaticBalance += balance;
            } else if (method == PayoutMethod.Bank) {
                dist.bankBalance += balance;
            }
            
            emit InvestorBalanceAdded(distributionId, investor, balance, dist.totalSnapshotBalance);
        } else if (oldBalance > 0) {
            // Remove investor balance (should rarely be needed)
            dist.totalSnapshotBalance -= oldBalance;
            snapshotBalances[distributionId][investor] = 0;
            payoutPreferences[distributionId][investor] = PayoutMethod.None;
            isInvestor[distributionId][investor] = false;
            dist.investorCount--;
        }
    }

    // ============ Payout Token Management ============

    /**
     * @dev Fund a specific distribution with payout tokens
     * @param distributionId The distribution ID
     * @param amount Amount to fund (should only include amounts for Claim and Automatic investors)
     * @notice Only fund the portion for Claim and Automatic investors
     * @notice Bank transfer investors receive payouts off-chain, so their portion should NOT be funded
     * @notice Use getRequiredFundingAmount() to calculate the correct funding amount excluding bank investors
     */
    function fundPayoutToken(uint256 distributionId, uint256 amount) 
        external 
        payable 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        
        address payoutToken = dist.payoutToken;
        
        if (payoutToken == address(0)) {
            // ETH funding
            require(msg.value == amount, "PayoutsContract: ETH amount mismatch");
        } else {
            // ERC20 token funding
            require(msg.value == 0, "PayoutsContract: use fundPayoutToken with token address");
            IERC20(payoutToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        dist.payoutTokenAmount += amount;
        emit PayoutTokenFunded(distributionId, amount);
    }

    /**
     * @dev Calculate required funding amount excluding bank transfer investors
     * @param distributionId The distribution ID
     * @param totalPayoutAmount Total payout amount for all investors (including bank investors)
     * @return requiredAmount Total amount needed for Claim and Automatic investors only
     * @notice Bank transfer investors are excluded as they receive payouts off-chain
     * @notice Uses pre-calculated balances per payout method for O(1) calculation (no iteration)
     * @notice Use this to determine how much to fund before calling fundPayoutToken
     */
    function getRequiredFundingAmount(
        uint256 distributionId,
        uint256 totalPayoutAmount
    )
        external
        view
        returns (uint256 requiredAmount)
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        
        if (dist.totalSnapshotBalance == 0) {
            return 0;
        }

        // Get total balances for Claim and Automatic investors (excludes Bank)
        uint256 onChainBalance = dist.claimBalance + dist.automaticBalance;

        // Calculate required funding: (on-chain balance / total balance) * total payout
        requiredAmount = (onChainBalance * totalPayoutAmount) / dist.totalSnapshotBalance;

        return requiredAmount;
    }

    // ============ Investor Functions ============

    /**
     * @dev Claim payout directly (for investors who chose Claim)
     * @param distributionId The distribution ID
     */
    function claimPayout(uint256 distributionId) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        require(!requireWhitelist || whitelist[msg.sender], "PayoutsContract: not whitelisted");
        require(
            payoutPreferences[distributionId][msg.sender] == PayoutMethod.Claim,
            "PayoutsContract: not set for claim"
        );
        require(!paidOut[distributionId][msg.sender], "PayoutsContract: already paid out");
        require(snapshotBalances[distributionId][msg.sender] > 0, "PayoutsContract: not an investor");

        uint256 payoutAmount = _calculatePayoutAmount(distributionId, msg.sender);
        require(payoutAmount > 0, "PayoutsContract: no payout available");
        require(dist.payoutTokenAmount >= payoutAmount, "PayoutsContract: insufficient funds");

        // Mark as paid out before transfer (reentrancy protection)
        paidOut[distributionId][msg.sender] = true;
        dist.payoutTokenAmount -= payoutAmount;

        // Transfer payout
        address payoutToken = dist.payoutToken;
        if (payoutToken == address(0)) {
            // ETH transfer
            (bool success, ) = payable(msg.sender).call{value: payoutAmount}("");
            require(success, "PayoutsContract: ETH transfer failed");
        } else {
            // ERC20 transfer
            IERC20(payoutToken).safeTransfer(msg.sender, payoutAmount);
        }

        emit PayoutClaimed(distributionId, msg.sender, payoutAmount);
    }

    /**
     * @dev Calculate payout amount for an investor based on their snapshot balance
     * @param distributionId The distribution ID
     * @param investor Investor address
     * @return payoutAmount Amount the investor should receive
     */
    function _calculatePayoutAmount(uint256 distributionId, address investor) 
        internal 
        returns (uint256 payoutAmount) 
    {
        Distribution storage dist = distributions[distributionId];
        
        if (dist.totalSnapshotBalance == 0) {
            return 0;
        }

        uint256 investorSnapshotBalance = snapshotBalances[distributionId][investor];
        uint256 totalPayoutAmount = dist.payoutTokenAmount;

        // Calculate proportional payout: (investor_balance / total_snapshot_balance) * total_payout
        payoutAmount = (investorSnapshotBalance * totalPayoutAmount) / dist.totalSnapshotBalance;
        
        // Cache the calculated amount
        payoutAmounts[distributionId][investor] = payoutAmount;
        
        return payoutAmount;
    }

    /**
     * @dev Get payout amount for an investor (view function)
     * @param distributionId The distribution ID
     * @param investor Investor address
     * @return payoutAmount Amount the investor would receive
     */
    function getPayoutAmount(uint256 distributionId, address investor) 
        external 
        view 
        returns (uint256 payoutAmount) 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        
        if (dist.totalSnapshotBalance == 0 || snapshotBalances[distributionId][investor] == 0) {
            return 0;
        }

        uint256 investorSnapshotBalance = snapshotBalances[distributionId][investor];
        uint256 totalPayoutAmount = dist.payoutTokenAmount;

        // Calculate proportional payout
        payoutAmount = (investorSnapshotBalance * totalPayoutAmount) / dist.totalSnapshotBalance;
        
        return payoutAmount;
    }

    // ============ Admin Functions ============

    /**
     * @dev Mark investor as paid out via bank transfer
     * @param distributionId The distribution ID
     * @param investor Investor address
     * @notice Only callable by admin after bank transfer is confirmed
     * @notice Bank investors receive payouts off-chain, so no funds are deducted from contract
     * @notice This function only marks payment status for tracking purposes
     */
    function markPayoutAsPaid(uint256 distributionId, address investor) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        require(snapshotBalances[distributionId][investor] > 0, "PayoutsContract: not an investor");
        require(
            payoutPreferences[distributionId][investor] == PayoutMethod.Bank,
            "PayoutsContract: not set for bank transfer"
        );
        require(!paidOut[distributionId][investor], "PayoutsContract: already paid out");

        uint256 payoutAmount = _calculatePayoutAmount(distributionId, investor);
        require(payoutAmount > 0, "PayoutsContract: no payout available");

        // Mark as paid out (no funds deducted since bank transfer is off-chain)
        paidOut[distributionId][investor] = true;

        emit PayoutMarkedAsPaid(distributionId, investor, payoutAmount);
    }

    /**
     * @dev Batch mark multiple investors as paid out via bank transfer
     * @param distributionId The distribution ID
     * @param investors Array of investor addresses
     * @notice Processes up to MAX_BATCH_SIZE investors per call
     * @notice Bank investors receive payouts off-chain, so no funds are deducted from contract
     */
    function batchMarkPayoutAsPaid(uint256 distributionId, address[] calldata investors) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        require(investors.length > 0 && investors.length <= MAX_BATCH_SIZE, "PayoutsContract: invalid batch size");

        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            if (
                snapshotBalances[distributionId][investor] > 0 &&
                payoutPreferences[distributionId][investor] == PayoutMethod.Bank &&
                !paidOut[distributionId][investor]
            ) {
                uint256 payoutAmount = _calculatePayoutAmount(distributionId, investor);
                if (payoutAmount > 0) {
                    paidOut[distributionId][investor] = true;
                    emit PayoutMarkedAsPaid(distributionId, investor, payoutAmount);
                }
            }
        }
    }

    /**
     * @dev Batch distribute payouts to investors with Automatic preference
     * @param distributionId The distribution ID
     * @param investors Array of investor addresses to process
     * @notice Processes up to MAX_BATCH_SIZE investors per call
     * @notice Automatically sends payouts to investors who selected Automatic method
     */
    function batchDistributeAutomatic(uint256 distributionId, address[] calldata investors) 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant
        whenNotPaused 
    {
        Distribution storage dist = distributions[distributionId];
        require(dist.initialized, "PayoutsContract: distribution not found");
        require(investors.length > 0 && investors.length <= MAX_BATCH_SIZE, "PayoutsContract: invalid batch size");

        address payoutToken = dist.payoutToken;

        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            if (
                snapshotBalances[distributionId][investor] > 0 &&
                payoutPreferences[distributionId][investor] == PayoutMethod.Automatic &&
                !paidOut[distributionId][investor]
            ) {
                uint256 payoutAmount = _calculatePayoutAmount(distributionId, investor);
                if (payoutAmount > 0 && dist.payoutTokenAmount >= payoutAmount) {
                    // Mark as paid out before transfer (reentrancy protection)
                    paidOut[distributionId][investor] = true;
                    dist.payoutTokenAmount -= payoutAmount;
                    
                    // Transfer payout
                    if (payoutToken == address(0)) {
                        // ETH transfer
                        (bool success, ) = payable(investor).call{value: payoutAmount}("");
                        require(success, "PayoutsContract: ETH transfer failed");
                    } else {
                        // ERC20 transfer
                        IERC20(payoutToken).safeTransfer(investor, payoutAmount);
                    }
                    
                    emit PayoutClaimed(distributionId, investor, payoutAmount);
                }
            }
        }
    }

    /**
     * @dev Emergency withdrawal function
     * @param token Address of the token to withdraw (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(to != address(0), "PayoutsContract: invalid recipient");
        
        if (token == address(0)) {
            // ETH withdrawal
            require(address(this).balance >= amount, "PayoutsContract: insufficient ETH");
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "PayoutsContract: ETH transfer failed");
        } else {
            // ERC20 withdrawal
            IERC20(token).safeTransfer(to, amount);
        }
        
        emit EmergencyWithdrawal(token, to, amount);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ Whitelist Functions ============

    /**
     * @dev Update whitelist requirement
     * @param _requireWhitelist Whether whitelist is required for payouts
     */
    function updateWhitelistRequirement(bool _requireWhitelist) external onlyRole(ADMIN_ROLE) {
        requireWhitelist = _requireWhitelist;
        emit WhitelistRequirementUpdated(_requireWhitelist);
    }

    /**
     * @dev Add address to whitelist
     * @param account Address to add
     */
    function addToWhitelist(address account) external onlyRole(WHITELIST_ROLE) {
        require(account != address(0), "PayoutsContract: invalid account");
        require(!whitelist[account], "PayoutsContract: already whitelisted");
        whitelist[account] = true;
        emit WhitelistAdded(account);
    }

    /**
     * @dev Remove address from whitelist
     * @param account Address to remove
     */
    function removeFromWhitelist(address account) external onlyRole(WHITELIST_ROLE) {
        require(whitelist[account], "PayoutsContract: not whitelisted");
        whitelist[account] = false;
        emit WhitelistRemoved(account);
    }

    /**
     * @dev Batch add addresses to whitelist
     * @param accounts Array of addresses to add
     */
    function batchAddToWhitelist(address[] calldata accounts) external onlyRole(WHITELIST_ROLE) {
        require(accounts.length > 0 && accounts.length <= MAX_BATCH_SIZE, "PayoutsContract: invalid batch size");
        
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            require(account != address(0), "PayoutsContract: invalid account");
            if (!whitelist[account]) {
                whitelist[account] = true;
                emit WhitelistAdded(account);
            }
        }
    }

    /**
     * @dev Batch remove addresses from whitelist
     * @param accounts Array of addresses to remove
     */
    function batchRemoveFromWhitelist(address[] calldata accounts) external onlyRole(WHITELIST_ROLE) {
        require(accounts.length > 0 && accounts.length <= MAX_BATCH_SIZE, "PayoutsContract: invalid batch size");
        
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (whitelist[account]) {
                whitelist[account] = false;
                emit WhitelistRemoved(account);
            }
        }
    }

    // ============ View Functions ============

    /**
     * @dev Get distribution information
     * @param distributionId The distribution ID
     * @return dist Distribution struct
     */
    function getDistribution(uint256 distributionId) 
        external 
        view 
        returns (Distribution memory dist) 
    {
        return distributions[distributionId];
    }

    /**
     * @dev Get total number of investors for a distribution
     * @param distributionId The distribution ID
     * @return count Number of investors
     */
    function getInvestorCount(uint256 distributionId) external view returns (uint256 count) {
        return distributions[distributionId].investorCount;
    }

    /**
     * @dev Check if investor can claim payout
     * @param distributionId The distribution ID
     * @param investor Investor address
     * @return canClaim Whether investor can claim
     * @return payoutAmount Amount available to claim
     */
    function canClaimPayout(uint256 distributionId, address investor) 
        external 
        view 
        returns (bool canClaim, uint256 payoutAmount) 
    {
        Distribution storage dist = distributions[distributionId];
        if (!dist.initialized) {
            return (false, 0);
        }

        if (
            snapshotBalances[distributionId][investor] == 0 ||
            payoutPreferences[distributionId][investor] != PayoutMethod.Claim ||
            paidOut[distributionId][investor]
        ) {
            return (false, 0);
        }

        payoutAmount = (snapshotBalances[distributionId][investor] * dist.payoutTokenAmount) / dist.totalSnapshotBalance;
        canClaim = payoutAmount > 0 && dist.payoutTokenAmount >= payoutAmount;
    }

    // ============ Receive Function ============

    /**
     * @dev Receive ETH
     */
    receive() external payable {
        // ETH can be sent directly but should use fundPayoutToken for proper accounting
    }
}