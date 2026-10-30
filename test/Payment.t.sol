// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";

/// @dev C4 — the three ways an entry is settled, and the one flag that stops it twice.
contract PaymentTest is PayoutsTestBase {
    event PayoutClaimed(uint256 indexed distributionId, address indexed recipient, uint256 amount);
    event PayoutSent(uint256 indexed distributionId, address indexed recipient, uint256 amount);
    event PayoutMarkedAsPaid(uint256 indexed distributionId, address indexed recipient, uint256 amount);

    // ---- claim ---------------------------------------------------------------

    function test_recipientClaimsExactlyWhatTheStatementSaid() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        (bool canClaim, uint256 amount) = payouts.canClaimPayout(id, alice);
        assertTrue(canClaim);
        assertEq(amount, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit PayoutClaimed(id, alice, 100 ether);
        vm.prank(alice);
        payouts.claimPayout(id);

        assertEq(token.balanceOf(alice), 100 ether);
        assertTrue(payouts.paidOut(id, alice));
        assertEq(_dist(id).paidTotal, 100 ether);
        assertEq(_dist(id).reserved, 50 ether);
        assertEq(payouts.reservedByToken(address(token)), 50 ether);
    }

    function test_claimingTwiceReverts() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(alice);
        payouts.claimPayout(id);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.AlreadyPaidOut.selector);
        payouts.claimPayout(id);
    }

    function test_someoneNotOnTheListCannotClaim() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(outsider);
        vm.expectRevert(PayoutsContract.NothingOwed.selector);
        payouts.claimPayout(id);

        (bool canClaim,) = payouts.canClaimPayout(id, outsider);
        assertFalse(canClaim);
    }

    function test_claimRefusedOnAnAutoDistribution() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.NotAClaimDistribution.selector);
        payouts.claimPayout(id);

        (bool canClaim,) = payouts.canClaimPayout(id, alice);
        assertFalse(canClaim);
    }

    function test_claimRefusedAfterExpiry() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, expiry);

        vm.warp(expiry - 1);
        (bool canClaim,) = payouts.canClaimPayout(id, alice);
        assertTrue(canClaim);

        vm.warp(expiry);
        (canClaim,) = payouts.canClaimPayout(id, alice);
        assertFalse(canClaim);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.DistributionExpired.selector);
        payouts.claimPayout(id);
    }

    function test_claimRefusedBeforeTheDistributionIsLive() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.NotInPayout.selector);
        payouts.claimPayout(id);
    }

    // ---- push ----------------------------------------------------------------

    /// @dev The screen pays one row at a time, so an arbitrary subset must work.
    function test_operatorPushesASingleRow() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        vm.expectEmit(true, true, true, true);
        emit PayoutSent(id, bob, 50 ether);
        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(bob));

        assertEq(token.balanceOf(bob), 50 ether);
        assertFalse(payouts.paidOut(id, alice));
        assertEq(_dist(id).reserved, 100 ether);
    }

    function test_operatorPushesTheWholeList() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(alice, bob));

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(_dist(id).reserved, 0);
        assertEq(payouts.reservedByToken(address(token)), 0);
    }

    /// @dev A batch retried after a partial failure must finish, not refuse.
    function test_pushSkipsAlreadySettledRecipients() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(alice));

        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(alice, bob));

        assertEq(token.balanceOf(alice), 100 ether); // paid once, not twice
        assertEq(token.balanceOf(bob), 50 ether);
    }

    /// @dev An address that is not on the list is an operator mistake, not a retry.
    function test_pushRevertsForSomeoneNotOnTheList() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NothingOwed.selector);
        payouts.batchDistributeAutomatic(id, _addrs(outsider));
    }

    function test_pushRefusedOnAClaimDistribution() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotAnAutomaticDistribution.selector);
        payouts.batchDistributeAutomatic(id, _addrs(alice));
    }

    function test_onlyOperatorPushes() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        _expectMissingRole(outsider, payouts.OPERATOR_ROLE());
        payouts.batchDistributeAutomatic(id, _addrs(alice));
    }

    // ---- settled elsewhere ---------------------------------------------------

    /// @dev No funds move; the share stops being reserved so it is not stranded.
    function test_markPaidRecordsOffChainSettlementAndReleasesTheShare() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.expectEmit(true, true, true, true);
        emit PayoutMarkedAsPaid(id, alice, 100 ether);
        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice);

        assertTrue(payouts.paidOut(id, alice));
        assertEq(token.balanceOf(alice), 0); // paid by bank, not here
        assertEq(token.balanceOf(address(payouts)), 150 ether); // funds stayed
        assertEq(_dist(id).paidTotal, 0);
        assertEq(_dist(id).reserved, 50 ether);
        assertEq(payouts.reservedByToken(address(token)), 50 ether);
    }

    function test_markPaidBlocksALaterClaim() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.AlreadyPaidOut.selector);
        payouts.claimPayout(id);
    }

    function test_batchMarkPaidSkipsSettledAndRevertsForStrangers() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice);

        vm.prank(admin);
        payouts.batchMarkPayoutAsPaid(id, _addrs(alice, bob));
        assertTrue(payouts.paidOut(id, bob));
        assertEq(_dist(id).reserved, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NothingOwed.selector);
        payouts.batchMarkPayoutAsPaid(id, _addrs(outsider));
    }

    // ---- the race ------------------------------------------------------------

    /// @dev Claim, push and off-chain receipt all arbitrate on one flag, so whoever is
    /// first wins and nobody is paid twice by two routes.
    function test_claimAndMarkPaidCannotBothSettleTheSameEntry() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(alice);
        payouts.claimPayout(id);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.AlreadyPaidOut.selector);
        payouts.markPayoutAsPaid(id, alice);

        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_totalPaidNeverExceedsWhatWasFunded() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(alice, bob));
        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(alice, bob));

        assertEq(_dist(id).paidTotal, _dist(id).funded);
        assertEq(token.balanceOf(address(payouts)), 0);
    }
}
