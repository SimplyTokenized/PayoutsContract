// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PayoutsContract} from "../../src/PayoutsContract.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @dev Shared fixture: one proxied PayoutsContract with `admin` operating and funding,
 * `approver` as the structurally separate second pair of eyes, and helpers for the
 * run-shaped flow every suite exercises — open a distribution, write the entries, fund
 * it, take it live (propose + approve).
 */
abstract contract PayoutsTestBase is Test {
    PayoutsContract internal payouts;
    MockERC20 internal token;

    address internal admin = address(0xAD1);
    address internal approver = address(0xA44);
    address internal outsider = address(0xBAD);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0);
    address internal carol = address(0xC0);

    bytes32 internal constant RUN_REF = keccak256("payout_run:demo");

    function setUp() public virtual {
        token = new MockERC20("Payout Token", "PAY");

        address proxy = Upgrades.deployTransparentProxy(
            "PayoutsContract.sol", admin, abi.encodeCall(PayoutsContract.initialize, (admin, approver, address(0)))
        );
        payouts = PayoutsContract(payable(proxy));

        token.mint(admin, 1_000_000 ether);
        vm.prank(admin);
        token.approve(address(payouts), type(uint256).max);
    }

    // ---- helpers -------------------------------------------------------------

    function _createDistribution(PayoutsContract.PayoutMode mode, uint64 expiry) internal returns (uint256 id) {
        return _createGatedDistribution(mode, expiry, address(0));
    }

    function _createGatedDistribution(PayoutsContract.PayoutMode mode, uint64 expiry, address registry)
        internal
        returns (uint256 id)
    {
        vm.prank(admin);
        return
            payouts.createDistribution(
                address(token), mode, PayoutsContract.EntryMode.Direct, expiry, RUN_REF, registry
            );
    }

    /// @dev A Merkle distribution, list committed with four eyes.
    function _createMerkleDistribution(uint64 expiry, bytes32 root, uint256 declaredTotal, uint256 recipientCount)
        internal
        returns (uint256 id)
    {
        vm.prank(admin);
        id = payouts.createDistribution(
            address(token),
            PayoutsContract.PayoutMode.Claim,
            PayoutsContract.EntryMode.Merkle,
            expiry,
            RUN_REF,
            address(0)
        );
        _setMerkleRoot(id, root, declaredTotal, recipientCount);
    }

    function _setMerkleRoot(uint256 id, bytes32 root, uint256 declaredTotal, uint256 recipientCount) internal {
        vm.prank(admin);
        payouts.proposeSetMerkleRoot(id, root, declaredTotal, recipientCount);
        vm.prank(approver);
        payouts.approveSetMerkleRoot(id, root, declaredTotal, recipientCount);
    }

    /**
     * @dev Grant a role the way the contract now requires: announce it, wait out
     * `ROLE_GRANT_DELAY`, then execute. Time moves forward — tests that care about the
     * clock should set it after calling this, not before.
     */
    function _grantRoleAfterDelay(bytes32 role, address account) internal {
        vm.prank(admin);
        payouts.scheduleRoleGrant(role, account);

        vm.warp(block.timestamp + payouts.ROLE_GRANT_DELAY());

        vm.prank(admin);
        payouts.grantRole(role, account);
    }

    function _setAmounts(uint256 id, address[] memory recipients, uint256[] memory amounts) internal {
        vm.prank(admin);
        payouts.setPayoutAmounts(id, recipients, amounts);
    }

    function _fund(uint256 id, uint256 amount) internal {
        vm.prank(admin);
        payouts.fundPayoutToken(id, amount);
    }

    /// @dev The four-eyes path to live: admin proposes, approver approves.
    function _finalize(uint256 id) internal {
        vm.prank(admin);
        payouts.proposeFinalizeDistribution(id);
        vm.prank(approver);
        payouts.approveFinalizeDistribution(id);
    }

    function _sweep(uint256 id, address to) internal {
        vm.prank(admin);
        payouts.proposeSweepUnclaimed(id, to);
        vm.prank(approver);
        payouts.approveSweepUnclaimed(id, to);
    }

    function _withdraw(address token_, address to, uint256 amount) internal {
        vm.prank(admin);
        payouts.proposeEmergencyWithdraw(token_, to, amount);
        vm.prank(approver);
        payouts.approveEmergencyWithdraw(token_, to, amount);
    }

    function _setForwarder(address forwarder_) internal {
        vm.prank(admin);
        payouts.proposeSetTrustedForwarder(forwarder_);
        vm.prank(approver);
        payouts.approveSetTrustedForwarder(forwarder_);
    }

    /// @dev A live distribution paying alice 100 and bob 50, fully funded.
    function _liveDistribution(PayoutsContract.PayoutMode mode, uint64 expiry) internal returns (uint256 id) {
        id = _createDistribution(mode, expiry);
        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));
        _fund(id, 150 ether);
        _finalize(id);
    }

    function _addrs(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _addrs(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _dist(uint256 id) internal view returns (PayoutsContract.Distribution memory) {
        return payouts.getDistribution(id);
    }

    /**
     * @dev Arm "the next call from `caller` is rejected for want of `role`".
     * @notice The role is read *before* the expectation is armed on purpose: reading it
     * is itself a call, and it would otherwise consume the prank meant for the call
     * under test — which silently turns the assertion into one about the test contract.
     */
    function _expectMissingRole(address caller, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
        vm.prank(caller);
    }

    /// @dev Same expectation, without arming a prank — for a call already pranked.
    function _expectMissingRoleFor(address caller, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
    }
}
