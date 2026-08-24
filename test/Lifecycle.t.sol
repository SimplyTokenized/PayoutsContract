// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev C1 — the distribution's life: Setup -> Payout -> Done, and who may move it.
contract LifecycleTest is PayoutsTestBase {
    event DistributionCreated(
        uint256 indexed distributionId,
        address indexed payoutToken,
        PayoutsContract.PayoutMode mode,
        PayoutsContract.EntryMode entryMode,
        uint64 expiry,
        bytes32 indexed runRef,
        address eligibilityRegistry
    );
    event DistributionStateAdvanced(uint256 indexed distributionId, PayoutsContract.DistributionState state);

    function test_initializeSplitsTheRolesFromTheFirstBlock() public view {
        assertTrue(payouts.hasRole(payouts.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(payouts.hasRole(payouts.ADMIN_ROLE(), admin));
        assertTrue(payouts.hasRole(payouts.OPERATOR_ROLE(), admin));
        assertTrue(payouts.hasRole(payouts.FUNDER_ROLE(), admin));
        assertTrue(payouts.hasRole(payouts.APPROVER_ROLE(), approver));
        // The second pair of eyes holds nothing else.
        assertFalse(payouts.hasRole(payouts.ADMIN_ROLE(), approver));
        assertFalse(payouts.hasRole(payouts.OPERATOR_ROLE(), approver));
        assertFalse(payouts.hasRole(payouts.APPROVER_ROLE(), admin));
        assertEq(payouts.nextDistributionId(), 1);
        assertEq(payouts.trustedForwarder(), address(0));
    }

    /// @dev Deployed without the Upgrades helper so the contract's own revert reason
    /// reaches the assertion instead of the helper's wrapper error.
    function test_initializeRejectsZeroAdmin() public {
        PayoutsContract implementation = new PayoutsContract();
        bytes memory initData = abi.encodeCall(PayoutsContract.initialize, (address(0), approver, address(0)));

        vm.expectRevert(PayoutsContract.InvalidAdmin.selector);
        new TransparentUpgradeableProxy(address(implementation), admin, initData);
    }

    function test_initializeRejectsZeroApprover() public {
        PayoutsContract implementation = new PayoutsContract();
        bytes memory initData = abi.encodeCall(PayoutsContract.initialize, (admin, address(0), address(0)));

        vm.expectRevert(PayoutsContract.InvalidApprover.selector);
        new TransparentUpgradeableProxy(address(implementation), admin, initData);
    }

    /// @dev Four-eyes is structural: the contract refuses to be born with one pair.
    function test_initializeRejectsApproverEqualToAdmin() public {
        PayoutsContract implementation = new PayoutsContract();
        bytes memory initData = abi.encodeCall(PayoutsContract.initialize, (admin, admin, address(0)));

        vm.expectRevert(PayoutsContract.ApproverMustNotBeAdmin.selector);
        new TransparentUpgradeableProxy(address(implementation), admin, initData);
    }

    /// @dev The implementation itself must never be initializable behind the proxy's back.
    function test_implementationCannotBeInitialized() public {
        PayoutsContract implementation = new PayoutsContract();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin, approver, address(0));
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        payouts.initialize(admin, approver, address(0));
    }

    function test_createDistributionEmitsRunRefAndAssignsSequentialIds() public {
        vm.expectEmit(true, true, true, true);
        emit DistributionCreated(
            1,
            address(token),
            PayoutsContract.PayoutMode.Claim,
            PayoutsContract.EntryMode.Direct,
            0,
            RUN_REF,
            address(0)
        );

        uint256 first = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        uint256 second = _createDistribution(PayoutsContract.PayoutMode.Auto, 0);

        assertEq(first, 1);
        assertEq(second, 2);

        PayoutsContract.Distribution memory dist = _dist(first);
        assertEq(dist.runRef, RUN_REF);
        assertEq(dist.payoutToken, address(token));
        assertEq(dist.eligibilityRegistry, address(0));
        assertEq(uint8(dist.state), uint8(PayoutsContract.DistributionState.Setup));
        assertEq(uint8(dist.mode), uint8(PayoutsContract.PayoutMode.Claim));
        assertTrue(dist.initialized);
    }

    /// @dev One tenant contract, many assets: the asset is per distribution, not per contract.
    function test_oneContractHoldsDistributionsInDifferentAssets() public {
        uint256 erc20Run = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        uint256 nativeRun = payouts.createDistribution(
            address(0), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );

        assertEq(_dist(erc20Run).payoutToken, address(token));
        assertEq(_dist(nativeRun).payoutToken, address(0));
    }

    function test_createDistributionRejectsExpiryInThePast() public {
        vm.warp(1_000_000);
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ExpiryInThePast.selector);
        payouts.createDistribution(
            address(token),
            PayoutsContract.PayoutMode.Claim,
            PayoutsContract.EntryMode.Direct,
            uint64(block.timestamp),
            RUN_REF,
            address(0)
        );
    }

    function test_onlyOperatorCreatesDistributions() public {
        _expectMissingRole(outsider, payouts.OPERATOR_ROLE());
        payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );
    }

    function test_finalizeMovesSetupToPayout() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        vm.expectEmit(true, true, true, true);
        emit DistributionStateAdvanced(id, PayoutsContract.DistributionState.Payout);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);

        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Payout));
    }

    /// @dev A doomed proposal fails at the first pair of eyes, not the second.
    function test_proposeFinalizeRejectsEmptyDistribution() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NothingToPay.selector);
        payouts.proposeFinalizeDistribution(id);
    }

    function test_cannotFinalizeTwice() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotInSetup.selector);
        payouts.proposeFinalizeDistribution(id);
    }

    function test_closeRequiresNothingLeftReserved() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.FundsStillReserved.selector);
        payouts.closeDistribution(id);

        vm.prank(alice);
        payouts.claimPayout(id);
        vm.prank(bob);
        payouts.claimPayout(id);

        vm.expectEmit(true, true, true, true);
        emit DistributionStateAdvanced(id, PayoutsContract.DistributionState.Done);
        vm.prank(admin);
        payouts.closeDistribution(id);

        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Done));
    }

    function test_doneDistributionAcceptsNoFurtherPayouts() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);
        _finalize(id);

        vm.prank(alice);
        payouts.claimPayout(id);
        vm.prank(admin);
        payouts.closeDistribution(id);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.NotInPayout.selector);
        payouts.claimPayout(id);
    }

    function test_unknownDistributionIsRejectedEverywhere() public {
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.DistributionNotFound.selector);
        payouts.setPayoutAmounts(99, _addrs(alice), _amounts(1 ether));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.DistributionNotFound.selector);
        payouts.fundPayoutToken(99, 1 ether);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.DistributionNotFound.selector);
        payouts.proposeFinalizeDistribution(99);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.DistributionNotFound.selector);
        payouts.claimPayout(99);
    }

    function test_pauseStopsOperatorAndRecipientActions() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        payouts.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        payouts.claimPayout(id);

        vm.prank(admin);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );

        vm.prank(admin);
        payouts.unpause();

        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    /// @dev v1's snapshot/proportional/whitelist surface is gone, not merely unused —
    /// and v2's irreversible actions have no single-signer entry points at all.
    function test_removedAndSingleSignerSurfaceIsAbsentFromTheAbi() public view {
        string[12] memory absent = [
            // v1, removed outright
            "setInvestorBalances(uint256,address[],uint256[],uint8[])",
            "setDistributionTotalAmount(uint256,uint256)",
            "computePayoutAmounts(uint256,address[])",
            "startCompute(uint256)",
            "finalizeCompute(uint256)",
            "getRequiredFundingAmount(uint256)",
            "addToWhitelist(address)",
            "baseToken()",
            // v2: these exist only as propose/approve pairs
            "finalizeDistribution(uint256)",
            "sweepUnclaimed(uint256,address)",
            "emergencyWithdraw(address,address,uint256)",
            "setTrustedForwarder(address)"
        ];

        for (uint256 i = 0; i < absent.length; i++) {
            bytes4 selector = bytes4(keccak256(bytes(absent[i])));
            (bool success,) = address(payouts).staticcall(abi.encodePacked(selector));
            assertFalse(success, absent[i]);
        }
    }
}
