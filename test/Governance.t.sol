// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";

/**
 * @dev C7 — governance is code, not key policy: duties split by role, and the
 * irreversible actions demanding a second, different pair of eyes.
 */
contract GovernanceTest is PayoutsTestBase {
    address internal funderOnly = address(0xF0D);
    address internal operatorOnly = address(0x0FE);

    event ActionProposed(bytes32 indexed proposalId, PayoutsContract.ActionKind indexed kind, address indexed proposer);
    event ActionApproved(bytes32 indexed proposalId, PayoutsContract.ActionKind indexed kind, address indexed approver);
    event ActionCancelled(bytes32 indexed proposalId, address indexed by);

    function setUp() public override {
        super.setUp();

        _grantRoleAfterDelay(payouts.FUNDER_ROLE(), funderOnly);
        _grantRoleAfterDelay(payouts.OPERATOR_ROLE(), operatorOnly);

        vm.prank(admin);
        token.transfer(funderOnly, 1_000 ether);

        vm.prank(funderOnly);
        token.approve(address(payouts), type(uint256).max);
    }

    // ---- role granularity ----------------------------------------------------

    /// @dev The funder moves money in; it decides nothing about who gets it.
    function test_funderCannotOperate() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        bytes32 operatorRole = payouts.OPERATOR_ROLE();

        _expectMissingRole(funderOnly, operatorRole);
        payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );

        _expectMissingRole(funderOnly, operatorRole);
        payouts.setPayoutAmounts(id, _addrs(alice), _amounts(1 ether));

        _expectMissingRole(funderOnly, operatorRole);
        payouts.markPayoutAsPaid(id, alice);
    }

    /// @dev The operator decides who gets what; it cannot move money in.
    function test_operatorCannotFund() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));

        _expectMissingRole(operatorOnly, payouts.FUNDER_ROLE());
        payouts.fundPayoutToken(id, 100 ether);
    }

    /// @dev Neither the day-to-day roles nor the funder can pause; guarding is ADMIN's job.
    function test_operatorAndFunderCannotPause() public {
        bytes32 adminRole = payouts.ADMIN_ROLE();

        _expectMissingRole(operatorOnly, adminRole);
        payouts.pause();

        _expectMissingRole(funderOnly, adminRole);
        payouts.pause();
    }

    /// @dev A funder-only signer can fund a run someone else operates — the exact split.
    function test_splitDutiesRunEndToEnd() public {
        vm.prank(operatorOnly);
        uint256 id = payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, address(0)
        );

        vm.prank(operatorOnly);
        payouts.setPayoutAmounts(id, _addrs(alice), _amounts(100 ether));

        vm.prank(funderOnly);
        payouts.fundPayoutToken(id, 100 ether);

        vm.prank(operatorOnly);
        payouts.proposeFinalizeDistribution(id);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);

        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    // ---- four eyes -----------------------------------------------------------

    function test_finalizeNeedsAProposalFirst() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveFinalizeDistribution(id);
    }

    /// @dev The same person wearing both hats is still one person.
    function test_proposerCannotApproveTheirOwnProposal() public {
        _grantRoleAfterDelay(payouts.APPROVER_ROLE(), admin);

        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ApproverMustNotBeProposer.selector);
        payouts.approveFinalizeDistribution(id);

        // A different approver still can.
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);
        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Payout));
    }

    function test_onlyApproverApproves() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        _expectMissingRole(outsider, payouts.APPROVER_ROLE());
        payouts.approveFinalizeDistribution(id);
    }

    function test_proposalLapsesAfterTtl() public {
        vm.warp(1_000_000);
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        vm.warp(block.timestamp + payouts.PROPOSAL_TTL() + 1);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.ProposalExpired.selector);
        payouts.approveFinalizeDistribution(id);

        // Re-proposing restarts the clock.
        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);
    }

    /// @dev What was approved is what executes: changing the run after proposing
    /// invalidates the pending approval, because the proposal binds to the content.
    function test_finalizeApprovalBindsToTheRunsContent() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        // The operator slips in another entry (and funds it) after the proposal.
        _setAmounts(id, _addrs(bob), _amounts(50 ether));
        _fund(id, 50 ether);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveFinalizeDistribution(id);

        // The changed run must be proposed — and seen — again.
        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);
        assertEq(_dist(id).totalOwed, 150 ether);
    }

    /// @dev One proposal buys one execution — proven on withdraw, the only four-eyes
    /// action whose re-execution the state machine would not block anyway.
    function test_approvalIsConsumedOnce() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);
        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice); // frees 100 ether of surplus

        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(address(token), admin, 50 ether);
        vm.prank(approver);
        payouts.approveEmergencyWithdraw(address(token), admin, 50 ether);

        // Surplus would still cover it; only the consumed proposal stands in the way.
        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveEmergencyWithdraw(address(token), admin, 50 ether);
    }

    /// @dev An approval binds the exact parameters — approving a different amount
    /// than was proposed matches no proposal.
    function test_withdrawApprovalBindsExactParameters() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);
        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice); // frees 100 ether of surplus

        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(address(token), admin, 100 ether);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveEmergencyWithdraw(address(token), admin, 99 ether);

        vm.prank(approver);
        payouts.approveEmergencyWithdraw(address(token), admin, 100 ether);
    }

    // ---- delayed role grants -------------------------------------------------

    /**
     * @dev The escape hatch this delay exists to close.
     *
     * Without it, whoever holds the role admin defeats four eyes in one transaction:
     * grant `APPROVER_ROLE` to a second address they control, then approve their own
     * proposal in the very next call. With it, the second address cannot be armed today,
     * so the proposal stands in the open — cancellable, and visible to anyone watching —
     * for two days before it could be self-approved.
     */
    function test_rootCannotArmASecondApproverAndSelfApproveInOneGo() public {
        address puppet = address(0x9999);
        bytes32 approverRole = payouts.APPROVER_ROLE();

        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        // The grant cannot be executed on the spot...
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.GrantNotScheduled.selector);
        payouts.grantRole(approverRole, puppet);

        // ...only announced, and then only used after the delay.
        vm.prank(admin);
        payouts.scheduleRoleGrant(approverRole, puppet);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.GrantStillWaiting.selector);
        payouts.grantRole(approverRole, puppet);

        vm.prank(puppet);
        _expectMissingRoleFor(puppet, approverRole);
        payouts.approveFinalizeDistribution(id);
    }

    function test_grantTakesEffectAfterTheDelay() public {
        address newOperator = address(0x8888);
        bytes32 operatorRole = payouts.OPERATOR_ROLE();

        vm.warp(1_000_000);
        vm.prank(admin);
        payouts.scheduleRoleGrant(operatorRole, newOperator);

        (uint256 effectiveFrom, uint256 expiresAt) = payouts.roleGrantWindow(operatorRole, newOperator);
        assertEq(effectiveFrom, block.timestamp + payouts.ROLE_GRANT_DELAY());
        assertEq(expiresAt, effectiveFrom + payouts.PROPOSAL_TTL());

        vm.warp(effectiveFrom);
        vm.prank(admin);
        payouts.grantRole(operatorRole, newOperator);

        assertTrue(payouts.hasRole(operatorRole, newOperator));
        // The announcement is spent, not reusable after a later revocation.
        (uint256 clearedFrom,) = payouts.roleGrantWindow(operatorRole, newOperator);
        assertEq(clearedFrom, 0);
    }

    /// @dev A compromised key must be removable this second — revoking is not delayed.
    function test_revokingIsImmediate() public {
        bytes32 operatorRole = payouts.OPERATOR_ROLE();
        assertTrue(payouts.hasRole(operatorRole, operatorOnly));

        vm.prank(admin);
        payouts.revokeRole(operatorRole, operatorOnly);

        assertFalse(payouts.hasRole(operatorRole, operatorOnly));

        _expectMissingRole(operatorOnly, operatorRole);
        payouts.setPayoutAmounts(1, _addrs(alice), _amounts(1 ether));
    }

    /// @dev The guardian can veto an announced grant without holding the key that made it.
    function test_guardianCanCancelAPendingGrant() public {
        address puppet = address(0x9999);
        bytes32 approverRole = payouts.APPROVER_ROLE();

        vm.prank(admin);
        payouts.scheduleRoleGrant(approverRole, puppet);

        vm.prank(outsider);
        vm.expectRevert(PayoutsContract.NotAllowedToCancel.selector);
        payouts.cancelRoleGrant(approverRole, puppet);

        vm.prank(admin); // holds ADMIN_ROLE, the guardian
        payouts.cancelRoleGrant(approverRole, puppet);

        vm.warp(block.timestamp + payouts.ROLE_GRANT_DELAY());
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.GrantNotScheduled.selector);
        payouts.grantRole(approverRole, puppet);
    }

    function test_announcementLapsesIfUnused() public {
        address puppet = address(0x9999);
        bytes32 approverRole = payouts.APPROVER_ROLE();

        vm.warp(1_000_000);
        vm.prank(admin);
        payouts.scheduleRoleGrant(approverRole, puppet);

        (, uint256 expiresAt) = payouts.roleGrantWindow(approverRole, puppet);
        vm.warp(expiresAt + 1);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.GrantExpired.selector);
        payouts.grantRole(approverRole, puppet);
    }

    function test_schedulingRejectsNonsense() public {
        bytes32 operatorRole = payouts.OPERATOR_ROLE();

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidAccount.selector);
        payouts.scheduleRoleGrant(operatorRole, address(0));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.AlreadyHasRole.selector);
        payouts.scheduleRoleGrant(operatorRole, operatorOnly);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NoPendingGrant.selector);
        payouts.cancelRoleGrant(operatorRole, address(0x1234));
    }

    function test_onlyRoleAdminSchedules() public {
        bytes32 operatorRole = payouts.OPERATOR_ROLE();
        bytes32 rootRole = payouts.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), outsider, rootRole
            )
        );
        vm.prank(outsider);
        payouts.scheduleRoleGrant(operatorRole, outsider);
    }

    // ---- cancelling ----------------------------------------------------------

    function test_proposerCanCancel() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        bytes32 proposalId = payouts.finalizeProposalId(id);
        vm.expectEmit(true, true, true, true);
        emit ActionCancelled(proposalId, admin);
        vm.prank(admin);
        payouts.cancelProposal(proposalId);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveFinalizeDistribution(id);
    }

    function test_strangerCannotCancel() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        bytes32 proposalId = payouts.finalizeProposalId(id);
        vm.prank(outsider);
        vm.expectRevert(PayoutsContract.NotAllowedToCancel.selector);
        payouts.cancelProposal(proposalId);
    }

    function test_cancellingNothingReverts() public {
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.cancelProposal(bytes32(uint256(1)));
    }

    // ---- events --------------------------------------------------------------

    function test_proposalLifecycleIsFullyEvented() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);
        _setAmounts(id, _addrs(alice), _amounts(100 ether));
        _fund(id, 100 ether);

        bytes32 proposalId = payouts.finalizeProposalId(id);

        vm.expectEmit(true, true, true, true);
        emit ActionProposed(proposalId, PayoutsContract.ActionKind.FinalizeDistribution, admin);
        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);

        vm.expectEmit(true, true, true, true);
        emit ActionApproved(proposalId, PayoutsContract.ActionKind.FinalizeDistribution, approver);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);
    }
}
