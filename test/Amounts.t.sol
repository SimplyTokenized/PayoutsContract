// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";

/// @dev C2 — writing the statements onto the contract: one entry per recipient, summed.
contract AmountsTest is PayoutsTestBase {
    event PayoutAmountsSet(uint256 indexed distributionId, uint256 count, uint256 totalOwed);

    function test_setPayoutAmountsRecordsEntriesAndAccumulatesTotalOwed() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.expectEmit(true, true, true, true);
        emit PayoutAmountsSet(id, 2, 150 ether);
        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));

        assertEq(payouts.getPayoutAmount(id, alice), 100 ether);
        assertEq(payouts.getPayoutAmount(id, bob), 50 ether);
        assertEq(_dist(id).totalOwed, 150 ether);
        assertEq(_dist(id).recipientCount, 2);
    }

    /// @dev A run's list arrives in pages; the total is the sum of every page.
    function test_totalOwedAccumulatesAcrossBatches() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));
        _setAmounts(id, _addrs(carol), _amounts(25 ether));

        assertEq(_dist(id).totalOwed, 175 ether);
        assertEq(_dist(id).recipientCount, 3);
        assertEq(payouts.remainingFunding(id), 175 ether);
    }

    /// @dev v1 required a non-zero snapshot balance before an exact amount could be set,
    /// so paying someone a flat sum meant inventing a fake token balance for them.
    function test_recipientNeedsNoTokenBalanceToBeOwedMoney() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(7 ether));

        assertEq(payouts.getPayoutAmount(id, alice), 7 ether);
        assertEq(_dist(id).totalOwed, 7 ether);
    }

    function test_duplicateRecipientReverts() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RecipientAlreadySet.selector);
        payouts.setPayoutAmounts(id, _addrs(alice), _amounts(1 ether));

        assertEq(_dist(id).totalOwed, 100 ether);
    }

    function test_duplicateWithinOneBatchReverts() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RecipientAlreadySet.selector);
        payouts.setPayoutAmounts(id, _addrs(alice, alice), _amounts(1 ether, 2 ether));
    }

    function test_zeroAmountAndZeroAddressAreRejected() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidAmount.selector);
        payouts.setPayoutAmounts(id, _addrs(alice), _amounts(0));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidRecipientAddress.selector);
        payouts.setPayoutAmounts(id, _addrs(address(0)), _amounts(1 ether));
    }

    function test_lengthMismatchReverts() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RecipientsAndAmountsLengthMismatch.selector);
        payouts.setPayoutAmounts(id, _addrs(alice, bob), _amounts(1 ether));
    }

    function test_batchSizeBoundaries() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        uint256 max = payouts.MAX_BATCH_SIZE();

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidBatchSize.selector);
        payouts.setPayoutAmounts(id, new address[](0), new uint256[](0));

        (address[] memory tooMany, uint256[] memory tooManyAmounts) = _list(max + 1, 1);
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidBatchSize.selector);
        payouts.setPayoutAmounts(id, tooMany, tooManyAmounts);

        (address[] memory atLimit, uint256[] memory atLimitAmounts) = _list(max, 1_000_000);
        _setAmounts(id, atLimit, atLimitAmounts);
        assertEq(_dist(id).recipientCount, max);
    }

    function test_entriesAreSetupOnly() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotInSetup.selector);
        payouts.setPayoutAmounts(id, _addrs(carol), _amounts(1 ether));
    }

    function test_onlyOperatorSetsAmounts() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        _expectMissingRole(outsider, payouts.OPERATOR_ROLE());
        payouts.setPayoutAmounts(id, _addrs(alice), _amounts(1 ether));
    }

    /// @dev Whatever the list, the contract's total is exactly the sum of its entries.
    function testFuzz_totalOwedEqualsSumOfEntries(uint96[10] memory raw) public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        address[] memory recipients = new address[](raw.length);
        uint256[] memory amounts = new uint256[](raw.length);
        uint256 expected;

        for (uint256 i = 0; i < raw.length; i++) {
            recipients[i] = address(uint160(i + 1000));
            amounts[i] = uint256(raw[i]) + 1; // entries are always positive
            expected += amounts[i];
        }

        _setAmounts(id, recipients, amounts);
        assertEq(_dist(id).totalOwed, expected);
    }

    function _list(uint256 count, uint256 amount)
        private
        pure
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            recipients[i] = address(uint160(i + 1));
            amounts[i] = amount;
        }
    }
}
