// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";

/// @dev C3 — a distribution cannot go live owing more than it holds.
contract FundingTest is PayoutsTestBase {
    event PayoutTokenFunded(uint256 indexed distributionId, uint256 amount);

    function test_fundingAccumulatesAndReserves() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));

        vm.expectEmit(true, true, true, true);
        emit PayoutTokenFunded(id, 60 ether);
        _fund(id, 60 ether);

        assertEq(_dist(id).funded, 60 ether);
        assertEq(_dist(id).reserved, 60 ether);
        assertEq(payouts.reservedByToken(address(token)), 60 ether);
        assertEq(payouts.remainingFunding(id), 90 ether);
        assertEq(token.balanceOf(address(payouts)), 60 ether);

        _fund(id, 90 ether);
        assertEq(payouts.remainingFunding(id), 0);
    }

    function test_overfundingIsRefused() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ExceedsAmountOwed.selector);
        payouts.fundPayoutToken(id, 100 ether + 1);

        _fund(id, 100 ether);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ExceedsAmountOwed.selector);
        payouts.fundPayoutToken(id, 1);
    }

    /// @dev The property v1 could not enforce: money for every entry is present before
    /// anyone is told they can collect. An under-funded run cannot even be proposed.
    function test_finalizeRefusesAnUnderfundedDistribution() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));
        _fund(id, 149 ether);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotFullyFunded.selector);
        payouts.proposeFinalizeDistribution(id);

        _fund(id, 1 ether);
        _finalize(id);
        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Payout));
    }

    /// @dev Adding an entry after funding puts the distribution back out of balance.
    function test_addingAnEntryAfterFundingBlocksFinalizeUntilTopUp() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        _setAmounts(id, _addrs(bob), _amounts(50 ether));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotFullyFunded.selector);
        payouts.proposeFinalizeDistribution(id);

        _fund(id, 50 ether);
        _finalize(id);
    }

    /// @dev The role that moves money in is not the role that decides who gets it.
    function test_onlyFunderFunds() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));

        _expectMissingRole(outsider, payouts.FUNDER_ROLE());
        payouts.fundPayoutToken(id, 1 ether);
    }

    function test_fundingIsSetupOnly() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotInSetup.selector);
        payouts.fundPayoutToken(id, 1 ether);
    }

    function test_zeroFundingIsRejected() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidAmount.selector);
        payouts.fundPayoutToken(id, 0);
    }

    function test_erc20DistributionRejectsNativeValue() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));

        vm.deal(admin, 1 ether);
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NativeValueNotAccepted.selector);
        payouts.fundPayoutToken{value: 1 ether}(id, 100 ether);
    }

    function test_nativeDistributionRequiresMatchingValue() public {
        vm.prank(admin);
        uint256 id = payouts.createDistribution(
            address(0), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );
        _setAmounts(id, _addrs(alice), _amounts(5 ether));

        vm.deal(admin, 10 ether);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NativeAmountMismatch.selector);
        payouts.fundPayoutToken{value: 4 ether}(id, 5 ether);

        vm.prank(admin);
        payouts.fundPayoutToken{value: 5 ether}(id, 5 ether);

        assertEq(payouts.reservedByToken(address(0)), 5 ether);
        assertEq(address(payouts).balance, 5 ether);

        _finalize(id);
        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(alice.balance, 5 ether);
    }

    function test_remainingFundingRejectsUnknownDistribution() public {
        vm.expectRevert(PayoutsContract.DistributionNotFound.selector);
        payouts.remainingFunding(42);
    }

    /// @dev However the funding is split up, live means fully covered.
    function testFuzz_finalizeIffFundedEqualsOwed(uint96 owed, uint96 funded) public {
        vm.assume(owed > 0);
        uint256 owedAmount = uint256(owed);
        uint256 fundedAmount = uint256(funded);
        vm.assume(fundedAmount <= owedAmount);

        token.mint(admin, owedAmount);

        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(owedAmount));
        if (fundedAmount > 0) _fund(id, fundedAmount);

        if (fundedAmount == owedAmount) {
            _finalize(id);
            assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Payout));
        } else {
            vm.prank(admin);
            vm.expectRevert(PayoutsContract.NotFullyFunded.selector);
            payouts.proposeFinalizeDistribution(id);
        }
    }
}
