// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {CommonBase} from "forge-std/Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev C5 — expiry, sweeping, and the reserve that keeps one run out of another's money.
contract ReserveTest is PayoutsTestBase {
    event UnclaimedSwept(uint256 indexed distributionId, address indexed to, uint256 amount);

    // ---- sweep ---------------------------------------------------------------

    function test_sweepReturnsWhatNobodyCollectedAndClosesTheRun() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, expiry);

        vm.prank(alice);
        payouts.claimPayout(id);

        vm.warp(expiry);
        vm.prank(admin);
        payouts.proposeSweepUnclaimed(id, admin);

        vm.expectEmit(true, true, true, true);
        emit UnclaimedSwept(id, admin, 50 ether);
        vm.prank(approver);
        payouts.approveSweepUnclaimed(id, admin);

        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Done));
        assertEq(_dist(id).reserved, 0);
        assertEq(payouts.reservedByToken(address(token)), 0);
        assertEq(token.balanceOf(address(payouts)), 0);
    }

    function test_sweepRefusedBeforeExpiry() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, expiry);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotExpired.selector);
        payouts.proposeSweepUnclaimed(id, admin);
    }

    /// @dev Without an expiry the money stays claimable forever — it cannot be taken back.
    function test_sweepRefusedWhenTheDistributionNeverExpires() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.DistributionNeverExpires.selector);
        payouts.proposeSweepUnclaimed(id, admin);
    }

    function test_sweepRejectsZeroRecipientAndCannotRunTwice() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, expiry);
        vm.warp(expiry);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidRecipient.selector);
        payouts.proposeSweepUnclaimed(id, address(0));

        _sweep(id, admin);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotInPayout.selector);
        payouts.proposeSweepUnclaimed(id, admin);
    }

    /// @dev Claims arriving between proposal and approval keep working; the sweep
    /// takes only whatever is still unclaimed at execution.
    function test_claimBetweenProposeAndApproveShrinksTheSweep() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, expiry);

        vm.warp(expiry - 1);
        vm.prank(alice);
        payouts.claimPayout(id);

        vm.warp(expiry);
        vm.prank(admin);
        payouts.proposeSweepUnclaimed(id, admin);

        uint256 before = token.balanceOf(admin);
        vm.prank(approver);
        payouts.approveSweepUnclaimed(id, admin);

        assertEq(token.balanceOf(admin) - before, 50 ether); // bob's unclaimed share only
        assertEq(token.balanceOf(alice), 100 ether);
    }

    // ---- the cross-run property ---------------------------------------------

    /// @dev The reason a tenant-wide contract is safe: run B's money is not withdrawable
    /// while run B still owes it, no matter what run A does.
    function test_emergencyWithdrawCannotTouchAnotherRunsMoney() public {
        uint256 runA = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        uint256 runB = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(runB, _addrs(carol), _amounts(400 ether));
        _fund(runB, 400 ether);
        _finalize(runB);

        assertEq(payouts.reservedByToken(address(token)), 550 ether);
        assertEq(token.balanceOf(address(payouts)), 550 ether);

        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(address(token), admin, 1);
        vm.prank(approver);
        vm.expectRevert(PayoutsContract.AmountIsReserved.selector);
        payouts.approveEmergencyWithdraw(address(token), admin, 1);

        // Run A settles; only run A's money becomes free, and run B is untouched.
        vm.prank(alice);
        payouts.claimPayout(runA);
        vm.prank(admin);
        payouts.markPayoutAsPaid(runA, bob);

        assertEq(payouts.reservedByToken(address(token)), 400 ether);

        _withdraw(address(token), admin, 50 ether); // bob's released share

        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(address(token), admin, 1);
        vm.prank(approver);
        vm.expectRevert(PayoutsContract.AmountIsReserved.selector);
        payouts.approveEmergencyWithdraw(address(token), admin, 1);

        // Carol is still able to collect in full.
        vm.prank(carol);
        payouts.claimPayout(runB);
        assertEq(token.balanceOf(carol), 400 ether);
    }

    /// @dev Money delivered by bank is no longer owed here, so it returns to the tenant.
    function test_markPaidReleasesShareToSurplus() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice);

        uint256 before = token.balanceOf(admin);
        _withdraw(address(token), admin, 100 ether);

        assertEq(token.balanceOf(admin) - before, 100 ether);
        assertEq(payouts.reservedByToken(address(token)), 50 ether);
    }

    function test_unaccountedTokensAreWithdrawableSurplus() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        // Someone transfers straight to the contract, bypassing fundPayoutToken.
        token.mint(address(payouts), 7 ether);

        _withdraw(address(token), admin, 7 ether);

        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(address(token), admin, 1);
        vm.prank(approver);
        vm.expectRevert(PayoutsContract.AmountIsReserved.selector);
        payouts.approveEmergencyWithdraw(address(token), admin, 1);

        // The distribution is unaffected.
        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_withdrawProposalRejectsZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidRecipient.selector);
        payouts.proposeEmergencyWithdraw(address(token), address(0), 0);
    }

    function test_nativeReserveIsTrackedSeparatelyFromTokenReserve() public {
        vm.prank(admin);
        uint256 nativeRun = payouts.createDistribution(
            address(0), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );
        _setAmounts(nativeRun, _addrs(alice), _amounts(3 ether));
        vm.deal(admin, 3 ether);
        vm.prank(admin);
        payouts.fundPayoutToken{value: 3 ether}(nativeRun, 3 ether);
        _finalize(nativeRun);

        uint256 tokenRun = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        assertEq(payouts.reservedByToken(address(0)), 3 ether);
        assertEq(payouts.reservedByToken(address(token)), 150 ether);

        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(address(0), admin, 1);
        vm.prank(approver);
        vm.expectRevert(PayoutsContract.AmountIsReserved.selector);
        payouts.approveEmergencyWithdraw(address(0), admin, 1);

        vm.prank(alice);
        payouts.claimPayout(tokenRun);
        assertEq(payouts.reservedByToken(address(0)), 3 ether); // untouched by the token run
    }
}

/**
 * @dev Stateful invariant: whatever sequence of operator, approver and recipient
 * actions runs, the contract never holds less of an asset than it has promised to the
 * people still owed it. This is the property that makes one contract per tenant —
 * rather than one per offering — safe to operate.
 */
contract ReserveInvariantTest is PayoutsTestBase {
    ReserveHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ReserveHandler(payouts, address(token), admin, approver);
        token.mint(address(handler), 10_000_000 ether);

        // The handler plays operator, funder and guardian; each grant waits out the
        // delay, scheduled together so the fixture costs one wait rather than three.
        bytes32 operatorRole = payouts.OPERATOR_ROLE();
        bytes32 funderRole = payouts.FUNDER_ROLE();
        bytes32 adminRole = payouts.ADMIN_ROLE();

        vm.startPrank(admin);
        payouts.scheduleRoleGrant(operatorRole, address(handler));
        payouts.scheduleRoleGrant(funderRole, address(handler));
        payouts.scheduleRoleGrant(adminRole, address(handler));
        vm.stopPrank();

        vm.warp(block.timestamp + payouts.ROLE_GRANT_DELAY());

        vm.startPrank(admin);
        payouts.grantRole(operatorRole, address(handler));
        payouts.grantRole(funderRole, address(handler));
        payouts.grantRole(adminRole, address(handler));
        vm.stopPrank();

        targetContract(address(handler));
    }

    function invariant_contractHoldsAtLeastWhatItReserves() public view {
        assertGe(token.balanceOf(address(payouts)), payouts.reservedByToken(address(token)));
    }

    function invariant_reserveEqualsSumOfLiveDistributionReserves() public view {
        uint256 summed;
        uint256 count = payouts.nextDistributionId();
        for (uint256 id = 1; id < count; id++) {
            summed += payouts.getDistribution(id).reserved;
        }
        assertEq(summed, payouts.reservedByToken(address(token)));
    }

    function invariant_nobodyIsPaidMoreThanTheirEntry() public view {
        uint256 count = payouts.nextDistributionId();
        for (uint256 id = 1; id < count; id++) {
            PayoutsContract.Distribution memory dist = payouts.getDistribution(id);
            assertLe(dist.paidTotal, dist.funded);
        }
    }
}

/// @dev Drives the contract through arbitrary but legal sequences, playing operator,
/// funder and admin itself and borrowing the approver for every four-eyes step.
contract ReserveHandler is CommonBase {
    PayoutsContract private immutable payouts;
    address private immutable token;
    address private immutable admin;
    address private immutable approver;

    uint256[] private liveIds;
    mapping(uint256 => address[]) private recipientsOf;

    constructor(PayoutsContract payouts_, address token_, address admin_, address approver_) {
        payouts = payouts_;
        token = token_;
        admin = admin_;
        approver = approver_;
        IERC20(token_).approve(address(payouts_), type(uint256).max);
    }

    function openRun(uint8 recipientCount, uint96 unitAmount, bool auto_, bool withExpiry) external {
        uint256 count = uint256(recipientCount) % 5 + 1;
        uint256 amount = uint256(unitAmount) % 1_000 ether + 1;

        uint256 id = payouts.createDistribution(
            token,
            auto_ ? PayoutsContract.PayoutMode.Auto : PayoutsContract.PayoutMode.Claim,
            PayoutsContract.EntryMode.Direct,
            withExpiry ? uint64(block.timestamp + 7 days) : 0,
            keccak256(abi.encode("run", liveIds.length)),
            address(0)
        );

        address[] memory recipients = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode(id, i)))));
            if (recipients[i] == address(0)) recipients[i] = address(uint160(i + 1));
            amounts[i] = amount;
            recipientsOf[id].push(recipients[i]);
        }

        payouts.setPayoutAmounts(id, recipients, amounts);
        payouts.fundPayoutToken(id, amount * count);
        payouts.proposeFinalizeDistribution(id);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);
        liveIds.push(id);
    }

    function pushSome(uint256 seed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[seed % liveIds.length];
        PayoutsContract.Distribution memory dist = payouts.getDistribution(id);
        if (dist.state != PayoutsContract.DistributionState.Payout) return;
        if (dist.mode != PayoutsContract.PayoutMode.Auto) return;

        payouts.batchDistributeAutomatic(id, recipientsOf[id]);
    }

    function claimOne(uint256 seed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[seed % liveIds.length];
        PayoutsContract.Distribution memory dist = payouts.getDistribution(id);
        if (dist.state != PayoutsContract.DistributionState.Payout) return;
        if (dist.mode != PayoutsContract.PayoutMode.Claim) return;
        if (dist.expiry != 0 && block.timestamp >= dist.expiry) return;

        address[] storage recipients = recipientsOf[id];
        if (recipients.length == 0) return;
        address recipient = recipients[seed % recipients.length];
        if (payouts.paidOut(id, recipient)) return;

        vm.prank(recipient);
        payouts.claimPayout(id);
    }

    function markOne(uint256 seed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[seed % liveIds.length];
        PayoutsContract.Distribution memory dist = payouts.getDistribution(id);
        if (dist.state != PayoutsContract.DistributionState.Payout) return;

        address[] storage recipients = recipientsOf[id];
        if (recipients.length == 0) return;
        address recipient = recipients[seed % recipients.length];
        if (payouts.paidOut(id, recipient)) return;

        payouts.markPayoutAsPaid(id, recipient);
    }

    function sweep(uint256 seed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[seed % liveIds.length];
        PayoutsContract.Distribution memory dist = payouts.getDistribution(id);
        if (dist.state != PayoutsContract.DistributionState.Payout) return;
        if (dist.expiry == 0 || block.timestamp < dist.expiry) return;

        payouts.proposeSweepUnclaimed(id, admin);
        vm.prank(approver);
        payouts.approveSweepUnclaimed(id, admin);
    }

    function skipAhead(uint32 secondsAhead) external {
        vm.warp(block.timestamp + (uint256(secondsAhead) % 30 days));
    }

    function withdrawSurplus(uint256 amount) external {
        uint256 held = IERC20(token).balanceOf(address(payouts));
        uint256 reserved = payouts.reservedByToken(token);
        if (held <= reserved) return;
        uint256 surplus = held - reserved;
        uint256 take = amount % (surplus + 1);

        payouts.proposeEmergencyWithdraw(token, admin, take);
        vm.prank(approver);
        payouts.approveEmergencyWithdraw(token, admin, take);
    }
}
