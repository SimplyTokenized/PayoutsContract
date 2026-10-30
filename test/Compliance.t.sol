// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {WhitelistRegistry} from "../src/compliance/WhitelistRegistry.sol";
import {ERC3643EligibilityAdapter} from "../src/compliance/ERC3643EligibilityAdapter.sol";

/// @dev A registry that always reverts — the "compliance service is down" case.
contract BrokenRegistry {
    function isEligible(address) external pure returns (bool) {
        revert("down");
    }
}

/// @dev Minimal ERC-3643 shape: a token pointing at an identity registry.
contract MockIdentityRegistry {
    mapping(address => bool) public verified;

    function setVerified(address account, bool ok) external {
        verified[account] = ok;
    }

    function isVerified(address account) external view returns (bool) {
        return verified[account];
    }
}

contract MockERC3643Token {
    address public identityRegistry;

    constructor(address registry) {
        identityRegistry = registry;
    }

    function setIdentityRegistry(address registry) external {
        identityRegistry = registry;
    }
}

/**
 * @dev C8 — the pluggable compliance gate: one mechanism, three postures.
 * None (address(0)), an operator-kept WhitelistRegistry, or the security token's own
 * identity registry via the ERC-3643 adapter. Checked at payment time, failing closed.
 */
contract ComplianceTest is PayoutsTestBase {
    WhitelistRegistry internal whitelist;

    function setUp() public override {
        super.setUp();
        whitelist = new WhitelistRegistry(admin);
    }

    function _gatedLive(address registry) internal returns (uint256 id) {
        id = _createGatedDistribution(PayoutsContract.PayoutMode.Claim, 0, registry);
        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));
        _fund(id, 150 ether);
        _finalize(id);
    }

    // ---- posture 1: no gate --------------------------------------------------

    function test_ungatedDistributionPaysAnyoneOnTheList() public {
        uint256 id = _gatedLive(address(0));
        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    // ---- posture 2: operator-kept whitelist ----------------------------------

    function test_whitelistedRecipientClaims() public {
        vm.prank(admin);
        whitelist.add(alice);

        uint256 id = _gatedLive(address(whitelist));

        (bool canClaim, uint256 amount) = payouts.canClaimPayout(id, alice);
        assertTrue(canClaim);
        assertEq(amount, 100 ether);

        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_unlistedRecipientIsRefused() public {
        vm.prank(admin);
        whitelist.add(alice); // bob is not added

        uint256 id = _gatedLive(address(whitelist));

        (bool canClaim,) = payouts.canClaimPayout(id, bob);
        assertFalse(canClaim);

        vm.prank(bob);
        vm.expectRevert(PayoutsContract.RecipientNotEligible.selector);
        payouts.claimPayout(id);
    }

    /// @dev Eligibility is checked when money MOVES: someone whose status is revoked
    /// between entry and claim is refused, and refused only for as long as it stays revoked.
    function test_revocationBetweenEntryAndClaimBlocksPayment() public {
        vm.startPrank(admin);
        whitelist.addBatch(_addrs(alice, bob));
        vm.stopPrank();

        uint256 id = _gatedLive(address(whitelist));

        vm.prank(admin);
        whitelist.remove(alice);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.RecipientNotEligible.selector);
        payouts.claimPayout(id);

        vm.prank(admin);
        whitelist.add(alice);
        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    /// @dev A push batch containing an ineligible recipient reverts — excluding the row
    /// is the operator's decision to make, not the contract's to skip silently.
    function test_pushRevertsForIneligibleRecipient() public {
        vm.prank(admin);
        whitelist.add(alice); // bob is not

        uint256 id = _createGatedDistribution(PayoutsContract.PayoutMode.Auto, 0, address(whitelist));
        _setAmounts(id, _addrs(alice, bob), _amounts(100 ether, 50 ether));
        _fund(id, 150 ether);
        _finalize(id);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RecipientNotEligible.selector);
        payouts.batchDistributeAutomatic(id, _addrs(alice, bob));

        vm.prank(admin);
        payouts.batchDistributeAutomatic(id, _addrs(alice));
        assertEq(token.balanceOf(alice), 100 ether);
    }

    /// @dev The off-chain receipt is ungated: it moves no funds here, and the
    /// settlement it records carries its own compliance.
    function test_markPaidIsUngated() public {
        uint256 id = _gatedLive(address(whitelist)); // nobody whitelisted at all

        vm.prank(admin);
        payouts.markPayoutAsPaid(id, bob);
        assertTrue(payouts.paidOut(id, bob));
    }

    function test_onlyRegistryOwnerEditsTheWhitelist() public {
        vm.prank(outsider);
        vm.expectRevert();
        whitelist.add(outsider);
    }

    // ---- posture 3: ERC-3643 ------------------------------------------------

    function test_erc3643AdapterDefersToTheTokensIdentityRegistry() public {
        MockIdentityRegistry identity = new MockIdentityRegistry();
        MockERC3643Token securityToken = new MockERC3643Token(address(identity));
        ERC3643EligibilityAdapter adapter = new ERC3643EligibilityAdapter(address(securityToken));

        identity.setVerified(alice, true); // bob stays unverified

        uint256 id = _gatedLive(address(adapter));

        vm.prank(alice);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(alice), 100 ether);

        vm.prank(bob);
        vm.expectRevert(PayoutsContract.RecipientNotEligible.selector);
        payouts.claimPayout(id);
    }

    /// @dev The adapter follows the token: a swapped identity registry takes effect
    /// immediately, with no change to the payout contract or the distribution.
    function test_adapterFollowsARegistrySwap() public {
        MockIdentityRegistry oldIdentity = new MockIdentityRegistry();
        MockERC3643Token securityToken = new MockERC3643Token(address(oldIdentity));
        ERC3643EligibilityAdapter adapter = new ERC3643EligibilityAdapter(address(securityToken));

        uint256 id = _gatedLive(address(adapter));

        vm.prank(bob);
        vm.expectRevert(PayoutsContract.RecipientNotEligible.selector);
        payouts.claimPayout(id);

        MockIdentityRegistry newIdentity = new MockIdentityRegistry();
        newIdentity.setVerified(bob, true);
        securityToken.setIdentityRegistry(address(newIdentity));

        vm.prank(bob);
        payouts.claimPayout(id);
        assertEq(token.balanceOf(bob), 50 ether);
    }

    function test_adapterRefusesANonErc3643Token() public {
        MockERC3643Token bare = new MockERC3643Token(address(0));
        vm.expectRevert("ERC3643EligibilityAdapter: no identity registry");
        new ERC3643EligibilityAdapter(address(bare));
    }

    // ---- failing closed ------------------------------------------------------

    /// @dev For a gated distribution, "unknown" must never mean "paid".
    function test_brokenRegistryBlocksPaymentInsteadOfWavingItThrough() public {
        // Registry works at creation, breaks afterwards: simulate by pointing the
        // adapter's token at a registry that reverts.
        MockIdentityRegistry identity = new MockIdentityRegistry();
        MockERC3643Token securityToken = new MockERC3643Token(address(identity));
        ERC3643EligibilityAdapter adapter = new ERC3643EligibilityAdapter(address(securityToken));
        identity.setVerified(alice, true);

        uint256 id = _gatedLive(address(adapter));
        securityToken.setIdentityRegistry(address(new BrokenRegistry()));

        (bool canClaim,) = payouts.canClaimPayout(id, alice);
        assertFalse(canClaim);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.EligibilityCheckUnavailable.selector);
        payouts.claimPayout(id);
    }

    /// @dev A registry that cannot answer is caught when the distribution is opened.
    function test_deadRegistryIsRefusedAtCreation() public {
        // Deployed first: a `new` inside the call's arguments would itself be the
        // "next call" and swallow both the prank and the revert expectation.
        address broken = address(new BrokenRegistry());

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RegistryNotAnswering.selector);
        payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Direct, 0, RUN_REF, broken
        );
    }

    /// @dev The gate is immutable per distribution — stored at creation, no setter.
    function test_registryIsFixedAtCreation() public {
        uint256 id = _gatedLive(address(whitelist));
        assertEq(_dist(id).eligibilityRegistry, address(whitelist));
        // No setter exists; the ABI-absence check lives in Lifecycle's surface test.
    }
}
