// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {MockForwarder} from "./utils/MockForwarder.sol";

/**
 * @dev C6 — who pays the gas is the tenant's choice.
 *
 * With no forwarder the recipient signs and pays, which is the default and the only
 * behaviour v1 had. Setting a forwarder lets a relayer submit the claim and pay for it,
 * while the money still goes to the person the statement names. Because a trusted
 * forwarder can act as ANY recipient, changing it takes four eyes.
 */
contract ForwarderTest is PayoutsTestBase {
    MockForwarder internal forwarder;

    event TrustedForwarderUpdated(address indexed forwarder);
    event PayoutClaimed(uint256 indexed distributionId, address indexed recipient, uint256 amount);

    function setUp() public override {
        super.setUp();
        forwarder = new MockForwarder();
    }

    function test_noForwarderByDefault() public view {
        assertEq(payouts.trustedForwarder(), address(0));
        assertFalse(payouts.isTrustedForwarder(address(0)));
        assertFalse(payouts.isTrustedForwarder(address(forwarder)));
    }

    function test_gaslessGoesOnAndOffWithFourEyes() public {
        vm.prank(admin);
        payouts.proposeSetTrustedForwarder(address(forwarder));

        vm.expectEmit(true, true, true, true);
        emit TrustedForwarderUpdated(address(forwarder));
        vm.prank(approver);
        payouts.approveSetTrustedForwarder(address(forwarder));

        assertEq(payouts.trustedForwarder(), address(forwarder));
        assertTrue(payouts.isTrustedForwarder(address(forwarder)));

        _setForwarder(address(0));
        assertFalse(payouts.isTrustedForwarder(address(forwarder)));
    }

    function test_onlyAdminProposesTheForwarder() public {
        _expectMissingRole(outsider, payouts.ADMIN_ROLE());
        payouts.proposeSetTrustedForwarder(address(forwarder));
    }

    function test_forwarderChangeCannotBeSelfApproved() public {
        // Give admin the approver role too — the proposer/approver split must still hold.
        _grantRoleAfterDelay(payouts.APPROVER_ROLE(), admin);

        vm.prank(admin);
        payouts.proposeSetTrustedForwarder(address(forwarder));

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ApproverMustNotBeProposer.selector);
        payouts.approveSetTrustedForwarder(address(forwarder));
    }

    /// @dev The relayer submits and pays; alice receives, and never spends a wei.
    function test_relayedClaimPaysTheRecipientNotTheRelayer() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        _setForwarder(address(forwarder));

        vm.expectEmit(true, true, true, true);
        emit PayoutClaimed(id, alice, 100 ether);
        forwarder.forward(address(payouts), abi.encodeWithSignature("claimPayout(uint256)", id), alice);

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(forwarder)), 0);
        assertTrue(payouts.paidOut(id, alice));
        assertFalse(payouts.paidOut(id, bob));
    }

    /// @dev An untrusted relayer is just an ordinary caller — it cannot claim for someone.
    function test_untrustedForwarderCannotClaimOnSomeonesBehalf() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.expectRevert(PayoutsContract.NothingOwed.selector);
        forwarder.forward(address(payouts), abi.encodeWithSignature("claimPayout(uint256)", id), alice);

        assertFalse(payouts.paidOut(id, alice));
    }

    /// @dev Turning gasless off again stops the relayer immediately.
    function test_revokedForwarderStopsRelaying() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        _setForwarder(address(forwarder));
        _setForwarder(address(0));

        vm.expectRevert(PayoutsContract.NothingOwed.selector);
        forwarder.forward(address(payouts), abi.encodeWithSignature("claimPayout(uint256)", id), alice);
    }

    /// @dev Recipient-pays keeps working while a forwarder is configured.
    function test_directClaimStillWorksWithAForwarderSet() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        _setForwarder(address(forwarder));

        vm.prank(bob);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(bob), 50 ether);
    }

    /// @dev A relayed call must not be able to impersonate the operator.
    function test_relayedOperatorCallIsStillRoleChecked() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Auto, 0);

        _setForwarder(address(forwarder));

        bytes32 operatorRole = payouts.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), outsider, operatorRole
            )
        );
        forwarder.forward(
            address(payouts), abi.encodeCall(PayoutsContract.batchDistributeAutomatic, (id, _addrs(alice))), outsider
        );
    }
}
