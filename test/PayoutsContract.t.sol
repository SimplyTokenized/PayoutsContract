// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 tokens for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PayoutsContractTest is Test {
    PayoutsContract public payouts;
    MockERC20 public baseToken;
    MockERC20 public payoutToken;
    
    address public admin;
    address public snapshotRole;
    address public whitelistRole;
    address public investor1;
    address public investor2;
    address public investor3;
    address public nonInvestor;
    
    uint256 public distributionId1;
    uint256 public distributionId2;
    
    uint256 public constant INITIAL_BALANCE = 10000 * 10 ** 18;

    event DistributionCreated(uint256 indexed distributionId, uint256 blockNumber, address indexed payoutToken);
    event InvestorBalancesSet(uint256 indexed distributionId, address[] investors, uint256[] balances, uint256 totalBalance);
    event PayoutTokenFunded(uint256 indexed distributionId, uint256 amount);
    event DistributionTotalAmountSet(uint256 indexed distributionId, uint256 amount);
    event PayoutClaimed(uint256 indexed distributionId, address indexed investor, uint256 amount);
    event PayoutMarkedAsPaid(uint256 indexed distributionId, address indexed investor, uint256 amount);
    event WhitelistRequirementUpdated(bool requireWhitelist);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);

    function setUp() public {
        admin = address(this);
        snapshotRole = address(0x100);
        whitelistRole = address(0x200);
        investor1 = address(0x1);
        investor2 = address(0x2);
        investor3 = address(0x3);
        nonInvestor = address(0x999);

        // Set block number to ensure valid block numbers for tests
        vm.roll(100);

        // Deploy mock tokens
        baseToken = new MockERC20("Base Token", "BASE");
        payoutToken = new MockERC20("Payout Token", "PAYOUT");

        // Deploy PayoutsContract with proxy
        address payable proxyAddress = payable(Upgrades.deployTransparentProxy(
            "PayoutsContract.sol",
            admin,
            abi.encodeCall(
                PayoutsContract.initialize,
                (address(baseToken), admin)
            )
        ));

        payouts = PayoutsContract(proxyAddress);

        // Grant roles
        vm.prank(admin);
        payouts.grantRole(payouts.SNAPSHOT_ROLE(), snapshotRole);
        vm.prank(admin);
        payouts.grantRole(payouts.WHITELIST_ROLE(), whitelistRole);
    }

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(address(payouts.baseToken()), address(baseToken));
        assertEq(payouts.nextDistributionId(), 1);
        assertFalse(payouts.requireWhitelist());
        assertTrue(payouts.hasRole(payouts.ADMIN_ROLE(), admin));
        assertTrue(payouts.hasRole(payouts.SNAPSHOT_ROLE(), admin));
        assertTrue(payouts.hasRole(payouts.WHITELIST_ROLE(), admin));
    }

    // Note: test_Initialization_InvalidBaseToken removed - can't test invalid initialization through proxy
    // The proxy deployment would fail during initialization, making this test impractical

    // ============ Distribution Creation Tests ============

    function test_CreateDistribution() public {
        vm.prank(snapshotRole);
        vm.expectEmit(true, false, false, true);
        emit DistributionCreated(1, block.number, address(payoutToken));
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        assertEq(distributionId1, 1);
        assertEq(payouts.nextDistributionId(), 2);
        
        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.distributionId, 1);
        assertEq(dist.snapshotBlockNumber, block.number);
        assertEq(dist.payoutToken, address(payoutToken));
        assertEq(dist.totalSnapshotBalance, 0);
        assertEq(dist.payoutTokenAmount, 0);
        assertTrue(dist.initialized);
    }

    function test_CreateDistribution_ETH() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(0));

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.payoutToken, address(0));
    }

    function test_CreateDistribution_InvalidBlockNumber() public {
        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: invalid block number");
        payouts.createDistribution(0, address(payoutToken));

        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: invalid block number");
        payouts.createDistribution(block.number + 1, address(payoutToken));
    }

    function test_CreateDistribution_Unauthorized() public {
        vm.prank(investor1);
        vm.expectRevert();
        payouts.createDistribution(block.number, address(payoutToken));
    }

    function test_CreateDistribution_WhenPaused() public {
        vm.prank(admin);
        payouts.pause();

        vm.prank(snapshotRole);
        vm.expectRevert();
        payouts.createDistribution(block.number, address(payoutToken));
    }

    function test_CreateMultipleDistributions() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.roll(block.number + 1);
        vm.prank(snapshotRole);
        distributionId2 = payouts.createDistribution(block.number - 1, address(0));

        assertEq(distributionId1, 1);
        assertEq(distributionId2, 2);
        assertEq(payouts.nextDistributionId(), 3);
    }

    // ============ Setting Investor Balances Tests ============

    function test_SetInvestorBalances_Batch() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](3);
        investors[0] = investor1;
        investors[1] = investor2;
        investors[2] = investor3;

        uint256[] memory balances = new uint256[](3);
        balances[0] = 1000 * 10 ** 18;
        balances[1] = 2000 * 10 ** 18;
        balances[2] = 3000 * 10 ** 18;

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](3);
        methods[0] = PayoutsContract.PayoutMethod.Claim;
        methods[1] = PayoutsContract.PayoutMethod.Automatic;
        methods[2] = PayoutsContract.PayoutMethod.Bank;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.totalSnapshotBalance, 6000 * 10 ** 18);
        assertEq(dist.claimBalance, 1000 * 10 ** 18);
        assertEq(dist.automaticBalance, 2000 * 10 ** 18);
        assertEq(dist.bankBalance, 3000 * 10 ** 18);
        assertEq(dist.investorCount, 3);

        assertEq(payouts.snapshotBalances(distributionId1, investor1), 1000 * 10 ** 18);
        assertEq(payouts.snapshotBalances(distributionId1, investor2), 2000 * 10 ** 18);
        assertEq(payouts.snapshotBalances(distributionId1, investor3), 3000 * 10 ** 18);
        assertEq(uint256(payouts.payoutPreferences(distributionId1, investor1)), uint256(PayoutsContract.PayoutMethod.Claim));
        assertEq(uint256(payouts.payoutPreferences(distributionId1, investor2)), uint256(PayoutsContract.PayoutMethod.Automatic));
        assertEq(uint256(payouts.payoutPreferences(distributionId1, investor3)), uint256(PayoutsContract.PayoutMethod.Bank));
    }

    function test_SetInvestorBalance_Single() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        assertEq(payouts.snapshotBalances(distributionId1, investor1), 1000 * 10 ** 18);
        assertEq(payouts.getInvestorCount(distributionId1), 1);
    }

    function test_SetInvestorBalances_UpdateExisting() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](1);
        investors[0] = investor1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 1000 * 10 ** 18;
        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](1);
        methods[0] = PayoutsContract.PayoutMethod.Claim;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // Update balance and method
        balances[0] = 2000 * 10 ** 18;
        methods[0] = PayoutsContract.PayoutMethod.Automatic;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.totalSnapshotBalance, 2000 * 10 ** 18);
        assertEq(dist.claimBalance, 0);
        assertEq(dist.automaticBalance, 2000 * 10 ** 18);
        assertEq(dist.investorCount, 1);
    }

    function test_SetInvestorBalances_InvalidInputs() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](1);
        investors[0] = investor1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 1000 * 10 ** 18;
        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](1);
        methods[0] = PayoutsContract.PayoutMethod.Claim;

        // Invalid distribution ID
        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: distribution not found");
        payouts.setInvestorBalances(999, investors, balances, methods);

        // Length mismatch
        uint256[] memory wrongBalances = new uint256[](2);
        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: investors and balances length mismatch");
        payouts.setInvestorBalances(distributionId1, investors, wrongBalances, methods);

        // Zero address
        investors[0] = address(0);
        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: invalid investor address");
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // None method
        investors[0] = investor1;
        methods[0] = PayoutsContract.PayoutMethod.None;
        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: payout method must be set");
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // Batch size too large
        investors = new address[](201);
        balances = new uint256[](201);
        methods = new PayoutsContract.PayoutMethod[](201);
        for (uint i = 0; i < 201; i++) {
            investors[i] = address(uint160(i + 100));
            balances[i] = 100 * 10 ** 18;
            methods[i] = PayoutsContract.PayoutMethod.Claim;
        }
        vm.prank(snapshotRole);
        vm.expectRevert("PayoutsContract: invalid batch size");
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);
    }

    // ============ Funding Tests ============

    function test_FundPayoutToken_ERC20() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        uint256 fundingAmount = 10000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit PayoutTokenFunded(distributionId1, fundingAmount);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.payoutTokenAmount, fundingAmount);
        assertEq(payoutToken.balanceOf(address(payouts)), fundingAmount);
    }

    function test_FundPayoutToken_ETH() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(0));

        uint256 fundingAmount = 10 ether;
        
        vm.deal(admin, fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken{value: fundingAmount}(distributionId1, fundingAmount);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.payoutTokenAmount, fundingAmount);
        assertEq(address(payouts).balance, fundingAmount);
    }

    function test_FundPayoutToken_ETHAmountMismatch() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(0));

        vm.deal(admin, 10 ether);
        vm.prank(admin);
        vm.expectRevert("PayoutsContract: ETH amount mismatch");
        payouts.fundPayoutToken{value: 5 ether}(distributionId1, 10 ether);
    }

    function test_FundPayoutToken_MultipleFundings() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        uint256 amount1 = 5000 * 10 ** 18;
        uint256 amount2 = 3000 * 10 ** 18;
        
        payoutToken.mint(admin, amount1 + amount2);
        payoutToken.approve(address(payouts), amount1 + amount2);

        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, amount1);
        
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, amount2);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.payoutTokenAmount, amount1 + amount2);
    }

    function test_GetRequiredFundingAmount() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](3);
        investors[0] = investor1;
        investors[1] = investor2;
        investors[2] = investor3;

        uint256[] memory balances = new uint256[](3);
        balances[0] = 1000 * 10 ** 18; // Claim
        balances[1] = 2000 * 10 ** 18; // Automatic
        balances[2] = 3000 * 10 ** 18; // Bank

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](3);
        methods[0] = PayoutsContract.PayoutMethod.Claim;
        methods[1] = PayoutsContract.PayoutMethod.Automatic;
        methods[2] = PayoutsContract.PayoutMethod.Bank;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        uint256 totalPayoutAmount = 6000 * 10 ** 18;
        vm.prank(admin);
        payouts.setDistributionTotalAmount(distributionId1, totalPayoutAmount);
        uint256 requiredAmount = payouts.getRequiredFundingAmount(distributionId1);
        
        // Should be (1000 + 2000) / 6000 * 6000 = 3000 (excludes bank)
        assertEq(requiredAmount, 3000 * 10 ** 18);
    }

    function test_GetRequiredFundingAmount_WithoutTotalDistributionAmount() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](2);
        investors[0] = investor1;
        investors[1] = investor2;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000 * 10 ** 18;
        balances[1] = 1000 * 10 ** 18;

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](2);
        methods[0] = PayoutsContract.PayoutMethod.Claim;
        methods[1] = PayoutsContract.PayoutMethod.Bank;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // totalDistributionAmount is not set yet, so required funding should be 0.
        uint256 requiredAmount = payouts.getRequiredFundingAmount(distributionId1);
        assertEq(requiredAmount, 0);
    }

    function test_SetDistributionTotalAmount() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit DistributionTotalAmountSet(distributionId1, 6000 * 10 ** 18);
        payouts.setDistributionTotalAmount(distributionId1, 6000 * 10 ** 18);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.totalDistributionAmount, 6000 * 10 ** 18);
    }

    function test_SetDistributionTotalAmount_InvalidDistribution() public {
        vm.prank(admin);
        vm.expectRevert("PayoutsContract: distribution not found");
        payouts.setDistributionTotalAmount(999, 1000 * 10 ** 18);
    }

    function test_SetDistributionTotalAmount_InvalidAmount() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: invalid total amount");
        payouts.setDistributionTotalAmount(distributionId1, 0);
    }

    function test_SetDistributionTotalAmount_AlreadySet() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(admin);
        payouts.setDistributionTotalAmount(distributionId1, 1000 * 10 ** 18);

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: total amount already set");
        payouts.setDistributionTotalAmount(distributionId1, 2000 * 10 ** 18);
    }

    function test_SetDistributionTotalAmount_AfterPayoutStarted() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        uint256 fundingAmount = 1000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        vm.prank(investor1);
        payouts.claimPayout(distributionId1);

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: payout already started");
        payouts.setDistributionTotalAmount(distributionId1, 1000 * 10 ** 18);
    }

    function test_SetDistributionTotalAmount_Unauthorized() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(investor1);
        vm.expectRevert();
        payouts.setDistributionTotalAmount(distributionId1, 1000 * 10 ** 18);
    }

    // ============ Claim Payout Tests ============

    function test_ClaimPayout_ERC20() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        uint256 fundingAmount = 1000 * 10 ** 18; // Match snapshot balance for 1:1 payout
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);

        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        uint256 expectedPayout = 1000 * 10 ** 18;
        uint256 balanceBefore = payoutToken.balanceOf(investor1);

        vm.prank(investor1);
        vm.expectEmit(true, true, false, true);
        emit PayoutClaimed(distributionId1, investor1, expectedPayout);
        payouts.claimPayout(distributionId1);

        assertEq(payoutToken.balanceOf(investor1), balanceBefore + expectedPayout);
        assertTrue(payouts.paidOut(distributionId1, investor1));
    }

    function test_ClaimPayout_ETH() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(0));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        uint256 fundingAmount = 1000 ether; // Match snapshot balance for 1:1 payout
        vm.deal(admin, fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken{value: fundingAmount}(distributionId1, fundingAmount);

        uint256 expectedPayout = 1000 ether;
        uint256 balanceBefore = investor1.balance;

        vm.prank(investor1);
        payouts.claimPayout(distributionId1);

        assertEq(investor1.balance, balanceBefore + expectedPayout);
        assertTrue(payouts.paidOut(distributionId1, investor1));
    }

    function test_ClaimPayout_Proportional() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](2);
        investors[0] = investor1;
        investors[1] = investor2;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000 * 10 ** 18; // 33.33%
        balances[1] = 2000 * 10 ** 18; // 66.67%

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](2);
        methods[0] = PayoutsContract.PayoutMethod.Claim;
        methods[1] = PayoutsContract.PayoutMethod.Claim;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        uint256 fundingAmount = 3000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        uint256 balance1Before = payoutToken.balanceOf(investor1);
        uint256 balance2Before = payoutToken.balanceOf(investor2);

        vm.prank(investor1);
        payouts.claimPayout(distributionId1);
        // Investor1: (1000 / 3000) * 3000 = 1000
        assertEq(payoutToken.balanceOf(investor1), balance1Before + 1000 * 10 ** 18);

        vm.prank(investor2);
        payouts.claimPayout(distributionId1);
        // Investor2: (2000 / 3000) * 3000 = 2000 (fixed: proportional regardless of claim order)
        assertEq(payoutToken.balanceOf(investor2), balance2Before + 2000 * 10 ** 18);
    }

    /**
     * @notice Regression test for shrinking-pool bug: payouts must use fixed total allocation,
     *         not decreasing pool. With the bug, later claimants would be underpaid.
     *         Example: 50/50 split, 1000 total -> both must get 500 regardless of claim order.
     */
    function test_Regression_ProportionalPayout_OrderIndependent() public {
        uint256 totalPayout = 1000 * 10 ** 18;   // 1000 USDC allocated
        uint256 balanceA = 50 * 10 ** 18;        // 50%
        uint256 balanceB = 50 * 10 ** 18;        // 50%
        uint256 expectedEach = 500 * 10 ** 18;   // (50/100) * 1000 = 500

        // Setup distribution 1: A claims first, B claims second
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));
        vm.prank(snapshotRole);
        payouts.setInvestorBalances(
            distributionId1,
            _arr(investor1, investor2),
            _arr(balanceA, balanceB),
            _arr(PayoutsContract.PayoutMethod.Claim, PayoutsContract.PayoutMethod.Claim)
        );
        payoutToken.mint(admin, totalPayout);
        payoutToken.approve(address(payouts), totalPayout);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, totalPayout);

        vm.prank(investor1);
        payouts.claimPayout(distributionId1);
        vm.prank(investor2);
        payouts.claimPayout(distributionId1);

        assertEq(payoutToken.balanceOf(investor1), expectedEach, "A must get 500");
        assertEq(payoutToken.balanceOf(investor2), expectedEach, "B must get 500 when claiming second (bug would give 250)");

        // Setup distribution 2: B claims first, A claims second (reverse order)
        vm.roll(block.number + 1);
        vm.prank(snapshotRole);
        distributionId2 = payouts.createDistribution(block.number, address(payoutToken));
        vm.prank(snapshotRole);
        payouts.setInvestorBalances(
            distributionId2,
            _arr(investor1, investor2),
            _arr(balanceA, balanceB),
            _arr(PayoutsContract.PayoutMethod.Claim, PayoutsContract.PayoutMethod.Claim)
        );
        payoutToken.mint(admin, totalPayout);
        payoutToken.approve(address(payouts), totalPayout);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId2, totalPayout);

        vm.prank(investor2);
        payouts.claimPayout(distributionId2);
        vm.prank(investor1);
        payouts.claimPayout(distributionId2);

        assertEq(payoutToken.balanceOf(investor1), expectedEach * 2, "A must get 500 when claiming second");
        assertEq(payoutToken.balanceOf(investor2), expectedEach * 2, "B must get 500 when claiming first");
    }

    function _arr(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _arr(uint256 a, uint256 b) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _arr(PayoutsContract.PayoutMethod a, PayoutsContract.PayoutMethod b) internal pure returns (PayoutsContract.PayoutMethod[] memory) {
        PayoutsContract.PayoutMethod[] memory arr = new PayoutsContract.PayoutMethod[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function test_ClaimPayout_InvalidConditions() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        // Not funded
        vm.prank(investor1);
        vm.expectRevert("PayoutsContract: no payout available");
        payouts.claimPayout(distributionId1);

        // Wrong payout method
        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor2, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Automatic);
        
        uint256 fundingAmount = 1000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        vm.prank(investor2);
        vm.expectRevert("PayoutsContract: not set for claim");
        payouts.claimPayout(distributionId1);

        // Already paid out
        vm.prank(investor1);
        payouts.claimPayout(distributionId1);
        
        vm.prank(investor1);
        vm.expectRevert("PayoutsContract: already paid out");
        payouts.claimPayout(distributionId1);
    }

    function test_ClaimPayout_WithWhitelist() public {
        vm.prank(admin);
        payouts.updateWhitelistRequirement(true);

        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(whitelistRole);
        payouts.addToWhitelist(investor1);

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        uint256 fundingAmount = 1000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        vm.prank(investor1);
        payouts.claimPayout(distributionId1); // Should succeed

        // Non-whitelisted
        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor2, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);
        
        uint256 fundingAmount2 = 1000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount2);
        payoutToken.approve(address(payouts), fundingAmount2);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount2);

        vm.prank(investor2);
        vm.expectRevert("PayoutsContract: not whitelisted");
        payouts.claimPayout(distributionId1);
    }

    // ============ Automatic Distribution Tests ============

    function test_BatchDistributeAutomatic() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](2);
        investors[0] = investor1;
        investors[1] = investor2;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000 * 10 ** 18;
        balances[1] = 2000 * 10 ** 18;

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](2);
        methods[0] = PayoutsContract.PayoutMethod.Automatic;
        methods[1] = PayoutsContract.PayoutMethod.Automatic;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        uint256 fundingAmount = 3000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        uint256 balance1Before = payoutToken.balanceOf(investor1);
        uint256 balance2Before = payoutToken.balanceOf(investor2);

        vm.prank(admin);
        payouts.batchDistributeAutomatic(distributionId1, investors);

        // Investor1: (1000 / 3000) * 3000 = 1000
        assertEq(payoutToken.balanceOf(investor1), balance1Before + 1000 * 10 ** 18);
        // Investor2: (2000 / 3000) * 3000 = 2000 (fixed: proportional regardless of order)
        assertEq(payoutToken.balanceOf(investor2), balance2Before + 2000 * 10 ** 18);
        assertTrue(payouts.paidOut(distributionId1, investor1));
        assertTrue(payouts.paidOut(distributionId1, investor2));
    }

    function test_BatchDistributeAutomatic_ETH() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(0));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Automatic);

        uint256 fundingAmount = 1000 ether; // Match snapshot balance for 1:1 payout
        vm.deal(admin, fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken{value: fundingAmount}(distributionId1, fundingAmount);

        address[] memory investors = new address[](1);
        investors[0] = investor1;

        uint256 balanceBefore = investor1.balance;
        vm.prank(admin);
        payouts.batchDistributeAutomatic(distributionId1, investors);

        assertEq(investor1.balance, balanceBefore + 1000 ether);
    }

    // ============ Bank Transfer Tests ============

    function test_MarkPayoutAsPaid() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Bank);

        // Fund with matching amount for calculation (bank transfers are off-chain, but calculation needs funding)
        uint256 fundingAmount = 1000 * 10 ** 18; // Match snapshot balance for calculation
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        uint256 contractBalanceBefore = payoutToken.balanceOf(address(payouts));

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit PayoutMarkedAsPaid(distributionId1, investor1, 1000 * 10 ** 18);
        payouts.markPayoutAsPaid(distributionId1, investor1);

        assertTrue(payouts.paidOut(distributionId1, investor1));
        // Contract balance should not change (bank transfer is off-chain)
        assertEq(payoutToken.balanceOf(address(payouts)), contractBalanceBefore);
    }

    function test_BatchMarkPayoutAsPaid() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](2);
        investors[0] = investor1;
        investors[1] = investor2;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000 * 10 ** 18;
        balances[1] = 2000 * 10 ** 18;

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](2);
        methods[0] = PayoutsContract.PayoutMethod.Bank;
        methods[1] = PayoutsContract.PayoutMethod.Bank;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // Fund with matching amount for calculation (bank transfers are off-chain, but calculation needs funding)
        uint256 fundingAmount = 3000 * 10 ** 18; // Match total snapshot balance
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        vm.prank(admin);
        payouts.batchMarkPayoutAsPaid(distributionId1, investors);

        assertTrue(payouts.paidOut(distributionId1, investor1));
        assertTrue(payouts.paidOut(distributionId1, investor2));
    }

    function test_BatchDistributeAutomatic_InvalidDistributionId() public {
        address[] memory investors = new address[](1);
        investors[0] = investor1;

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: distribution not found");
        payouts.batchDistributeAutomatic(999, investors);
    }

    function test_BatchDistributeAutomatic_ExceedsMaxBatchSize() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](201);
        for (uint i = 0; i < 201; i++) {
            investors[i] = address(uint160(i + 100));
        }

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: invalid batch size");
        payouts.batchDistributeAutomatic(distributionId1, investors);
    }

    function test_BatchMarkPayoutAsPaid_InvalidDistributionId() public {
        address[] memory investors = new address[](1);
        investors[0] = investor1;

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: distribution not found");
        payouts.batchMarkPayoutAsPaid(999, investors);
    }

    function test_BatchMarkPayoutAsPaid_ExceedsMaxBatchSize() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](201);
        for (uint i = 0; i < 201; i++) {
            investors[i] = address(uint160(i + 100));
        }

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: invalid batch size");
        payouts.batchMarkPayoutAsPaid(distributionId1, investors);
    }

    function test_MarkPayoutAsPaid_InvalidConditions() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: not set for bank transfer");
        payouts.markPayoutAsPaid(distributionId1, investor1);
    }

    // ============ Whitelist Tests ============

    function test_UpdateWhitelistRequirement() public {
        assertFalse(payouts.requireWhitelist());

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit WhitelistRequirementUpdated(true);
        payouts.updateWhitelistRequirement(true);

        assertTrue(payouts.requireWhitelist());
    }

    function test_AddToWhitelist() public {
        vm.prank(whitelistRole);
        vm.expectEmit(true, false, false, true);
        emit WhitelistAdded(investor1);
        payouts.addToWhitelist(investor1);

        assertTrue(payouts.whitelist(investor1));
    }

    function test_RemoveFromWhitelist() public {
        vm.prank(whitelistRole);
        payouts.addToWhitelist(investor1);

        vm.prank(whitelistRole);
        vm.expectEmit(true, false, false, true);
        emit WhitelistRemoved(investor1);
        payouts.removeFromWhitelist(investor1);

        assertFalse(payouts.whitelist(investor1));
    }

    function test_BatchAddToWhitelist() public {
        address[] memory accounts = new address[](3);
        accounts[0] = investor1;
        accounts[1] = investor2;
        accounts[2] = investor3;

        vm.prank(whitelistRole);
        payouts.batchAddToWhitelist(accounts);

        assertTrue(payouts.whitelist(investor1));
        assertTrue(payouts.whitelist(investor2));
        assertTrue(payouts.whitelist(investor3));
    }

    function test_BatchRemoveFromWhitelist() public {
        address[] memory accounts = new address[](2);
        accounts[0] = investor1;
        accounts[1] = investor2;

        vm.prank(whitelistRole);
        payouts.batchAddToWhitelist(accounts);

        vm.prank(whitelistRole);
        payouts.batchRemoveFromWhitelist(accounts);

        assertFalse(payouts.whitelist(investor1));
        assertFalse(payouts.whitelist(investor2));
    }

    function test_AddToWhitelist_InvalidAddress() public {
        vm.prank(whitelistRole);
        vm.expectRevert("PayoutsContract: invalid account");
        payouts.addToWhitelist(address(0));
    }

    function test_AddToWhitelist_AlreadyWhitelisted() public {
        vm.prank(whitelistRole);
        payouts.addToWhitelist(investor1);

        vm.prank(whitelistRole);
        vm.expectRevert("PayoutsContract: already whitelisted");
        payouts.addToWhitelist(investor1);
    }

    function test_RemoveFromWhitelist_NotWhitelisted() public {
        vm.prank(whitelistRole);
        vm.expectRevert("PayoutsContract: not whitelisted");
        payouts.removeFromWhitelist(investor1);
    }

    function test_BatchAddToWhitelist_InvalidAddress() public {
        address[] memory accounts = new address[](2);
        accounts[0] = investor1;
        accounts[1] = address(0);

        vm.prank(whitelistRole);
        vm.expectRevert("PayoutsContract: invalid account");
        payouts.batchAddToWhitelist(accounts);
    }

    function test_BatchAddToWhitelist_ExceedsMaxBatchSize() public {
        address[] memory accounts = new address[](201);
        for (uint i = 0; i < 201; i++) {
            accounts[i] = address(uint160(i + 100));
        }

        vm.prank(whitelistRole);
        vm.expectRevert("PayoutsContract: invalid batch size");
        payouts.batchAddToWhitelist(accounts);
    }

    function test_BatchRemoveFromWhitelist_ExceedsMaxBatchSize() public {
        address[] memory accounts = new address[](201);
        for (uint i = 0; i < 201; i++) {
            accounts[i] = address(uint160(i + 100));
        }

        vm.prank(whitelistRole);
        vm.expectRevert("PayoutsContract: invalid batch size");
        payouts.batchRemoveFromWhitelist(accounts);
    }

    // ============ View Function Tests ============

    function test_GetPayoutAmount() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        uint256 fundingAmount = 1000 * 10 ** 18; // Match snapshot balance for 1:1 payout
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        uint256 payoutAmount = payouts.getPayoutAmount(distributionId1, investor1);
        assertEq(payoutAmount, 1000 * 10 ** 18);
    }

    function test_GetPayoutAmount_FallbackWhenTotalDistributionAmountUnset() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        // totalDistributionAmount intentionally not set - should use backward-compatible fallback.
        uint256 fundingAmount = 1000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        uint256 payoutAmount = payouts.getPayoutAmount(distributionId1, investor1);
        assertEq(payoutAmount, 1000 * 10 ** 18);
    }

    function test_CanClaimPayout_UsesTotalDistributionAmountInMixedMethods() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](2);
        investors[0] = investor1; // Claim
        investors[1] = investor2; // Bank

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1000 * 10 ** 18;
        balances[1] = 1000 * 10 ** 18;

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](2);
        methods[0] = PayoutsContract.PayoutMethod.Claim;
        methods[1] = PayoutsContract.PayoutMethod.Bank;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // Total intended distribution is 2000. Claim investor should get 1000.
        vm.prank(admin);
        payouts.setDistributionTotalAmount(distributionId1, 2000 * 10 ** 18);

        // Fund only on-chain portion (claim side).
        uint256 fundingAmount = 1000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        (bool canClaim, uint256 payoutAmount) = payouts.canClaimPayout(distributionId1, investor1);
        assertTrue(canClaim);
        assertEq(payoutAmount, 1000 * 10 ** 18);
    }

    function test_CanClaimPayout() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        uint256 fundingAmount = 1000 * 10 ** 18; // Match snapshot balance for 1:1 payout
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        (bool canClaim, uint256 payoutAmount) = payouts.canClaimPayout(distributionId1, investor1);
        assertTrue(canClaim);
        assertEq(payoutAmount, 1000 * 10 ** 18);
    }

    function test_CanClaimPayout_False() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Automatic);

        (bool canClaim, uint256 payoutAmount) = payouts.canClaimPayout(distributionId1, investor1);
        assertFalse(canClaim);
        assertEq(payoutAmount, 0);
    }

    function test_GetDistribution() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.distributionId, distributionId1);
        assertEq(dist.snapshotBlockNumber, block.number);
        assertEq(dist.payoutToken, address(payoutToken));
        assertEq(dist.totalSnapshotBalance, 1000 * 10 ** 18);
        assertEq(dist.claimBalance, 1000 * 10 ** 18);
        assertEq(dist.automaticBalance, 0);
        assertEq(dist.bankBalance, 0);
        assertEq(dist.investorCount, 1);
        assertTrue(dist.initialized);
    }

    function test_GetInvestorCount() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        assertEq(payouts.getInvestorCount(distributionId1), 0);

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        assertEq(payouts.getInvestorCount(distributionId1), 1);

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor2, 2000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        assertEq(payouts.getInvestorCount(distributionId1), 2);
    }

    // ============ Pausability Tests ============

    function test_Pause() public {
        vm.prank(admin);
        payouts.pause();

        assertTrue(payouts.paused());
    }

    function test_Unpause() public {
        vm.prank(admin);
        payouts.pause();
        
        vm.prank(admin);
        payouts.unpause();

        assertFalse(payouts.paused());
    }

    function test_Pause_PreventsOperations() public {
        vm.prank(admin);
        payouts.pause();

        vm.prank(snapshotRole);
        vm.expectRevert();
        payouts.createDistribution(block.number, address(payoutToken));
    }

    // ============ Emergency Withdraw Tests ============

    function test_EmergencyWithdraw_ERC20() public {
        payoutToken.mint(address(payouts), 1000 * 10 ** 18);
        uint256 balanceBefore = payoutToken.balanceOf(admin);

        vm.prank(admin);
        payouts.emergencyWithdraw(address(payoutToken), admin, 1000 * 10 ** 18);

        assertEq(payoutToken.balanceOf(admin), balanceBefore + 1000 * 10 ** 18);
    }

    function test_EmergencyWithdraw_ETH() public {
        // Send ETH to contract using vm.deal directly on the contract
        vm.deal(address(payouts), 10 ether);
        
        address recipient = address(0x999);
        vm.deal(recipient, 0); // Ensure recipient starts with 0 balance
        uint256 balanceBefore = recipient.balance;

        vm.prank(admin);
        payouts.emergencyWithdraw(address(0), recipient, 10 ether);

        assertEq(recipient.balance, balanceBefore + 10 ether);
    }

    function test_EmergencyWithdraw_Unauthorized() public {
        vm.prank(investor1);
        vm.expectRevert();
        payouts.emergencyWithdraw(address(payoutToken), admin, 1000 * 10 ** 18);
    }

    function test_EmergencyWithdraw_InsufficientBalance_ETH() public {
        vm.deal(address(payouts), 500 ether);

        vm.prank(admin);
        vm.expectRevert("PayoutsContract: insufficient ETH");
        payouts.emergencyWithdraw(address(0), admin, 1000 ether);
    }

    function test_EmergencyWithdraw_InsufficientBalance_ERC20() public {
        payoutToken.mint(address(payouts), 500 * 10 ** 18);

        vm.prank(admin);
        // SafeERC20 will revert with its own error message
        vm.expectRevert();
        payouts.emergencyWithdraw(address(payoutToken), admin, 1000 * 10 ** 18);
    }

    // ============ Edge Cases and Integration Tests ============

    function test_MultipleDistributions_Independent() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        vm.roll(block.number + 1);
        vm.prank(snapshotRole);
        distributionId2 = payouts.createDistribution(block.number - 1, address(0));

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId2, investor1, 2000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        assertEq(payouts.snapshotBalances(distributionId1, investor1), 1000 * 10 ** 18);
        assertEq(payouts.snapshotBalances(distributionId2, investor1), 2000 * 10 ** 18);
    }

    function test_FullFlow_Claim() public {
        // Create distribution
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        // Set investor balance
        vm.prank(snapshotRole);
        payouts.setInvestorBalance(distributionId1, investor1, 1000 * 10 ** 18, PayoutsContract.PayoutMethod.Claim);

        // Fund
        uint256 fundingAmount = 1000 * 10 ** 18; // Match snapshot balance for 1:1 payout
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        // Claim
        uint256 balanceBefore = payoutToken.balanceOf(investor1);
        vm.prank(investor1);
        payouts.claimPayout(distributionId1);

        assertEq(payoutToken.balanceOf(investor1), balanceBefore + 1000 * 10 ** 18);
        assertTrue(payouts.paidOut(distributionId1, investor1));
        
        PayoutsContract.Distribution memory dist = payouts.getDistribution(distributionId1);
        assertEq(dist.payoutTokenAmount, fundingAmount); // Total allocated (fixed)
        assertEq(dist.payoutTokenClaimed, fundingAmount); // All claimed
    }

    function test_FullFlow_AllMethods() public {
        vm.prank(snapshotRole);
        distributionId1 = payouts.createDistribution(block.number, address(payoutToken));

        address[] memory investors = new address[](3);
        investors[0] = investor1;
        investors[1] = investor2;
        investors[2] = investor3;

        uint256[] memory balances = new uint256[](3);
        balances[0] = 1000 * 10 ** 18;
        balances[1] = 2000 * 10 ** 18;
        balances[2] = 3000 * 10 ** 18;

        PayoutsContract.PayoutMethod[] memory methods = new PayoutsContract.PayoutMethod[](3);
        methods[0] = PayoutsContract.PayoutMethod.Claim;
        methods[1] = PayoutsContract.PayoutMethod.Automatic;
        methods[2] = PayoutsContract.PayoutMethod.Bank;

        vm.prank(snapshotRole);
        payouts.setInvestorBalances(distributionId1, investors, balances, methods);

        // Total intended distribution across all methods.
        vm.prank(admin);
        payouts.setDistributionTotalAmount(distributionId1, 6000 * 10 ** 18);

        // Fund only for Claim and Automatic (3000)
        uint256 fundingAmount = 3000 * 10 ** 18;
        payoutToken.mint(admin, fundingAmount);
        payoutToken.approve(address(payouts), fundingAmount);
        vm.prank(admin);
        payouts.fundPayoutToken(distributionId1, fundingAmount);

        // Claim
        uint256 balance1Before = payoutToken.balanceOf(investor1);
        uint256 balance2Before = payoutToken.balanceOf(investor2);
        
        vm.prank(investor1);
        payouts.claimPayout(distributionId1);
        // Investor1: (1000 / 6000) * 6000 = 1000
        assertEq(payoutToken.balanceOf(investor1), balance1Before + 1000 * 10 ** 18);

        // Automatic
        address[] memory autoInvestors = new address[](1);
        autoInvestors[0] = investor2;
        vm.prank(admin);
        payouts.batchDistributeAutomatic(distributionId1, autoInvestors);
        // Investor2: (2000 / 6000) * 6000 = 2000
        assertEq(payoutToken.balanceOf(investor2), balance2Before + 2000 * 10 ** 18);

        // Bank (off-chain, just mark as paid)
        vm.prank(admin);
        payouts.markPayoutAsPaid(distributionId1, investor3);
        assertTrue(payouts.paidOut(distributionId1, investor3));
        
        // Investor1 got 1000, Investor2 got 2000. Total on-chain distributed: 3000
        // Remaining in contract: 3000 - 3000 = 0 (Bank investor paid off-chain)
        assertEq(payoutToken.balanceOf(address(payouts)), 0);
    }
}