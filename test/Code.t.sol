// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {MerkleTreeLib} from "./utils/MerkleTreeLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @dev C10 — giveaways: a prefunded run whose recipients are unknown when it is funded.
 *
 * The leaves commit to CODES, not to people. A code is a private key; redeeming it means
 * signing the address that should be paid. These tests care most about the attack that
 * shape exists to prevent — a bot lifting a redemption out of the mempool and paying
 * itself instead.
 */
contract CodeTest is PayoutsTestBase {
    /// @dev Code keys. In production these are generated per code and handed out as links.
    uint256 internal constant CODE_1_KEY = 0xC0DE01;
    uint256 internal constant CODE_2_KEY = 0xC0DE02;
    uint256 internal constant CODE_3_KEY = 0xC0DE03;

    address internal code1;
    address internal code2;
    address internal code3;

    address internal winner = address(0x111);
    address internal otherWinner = address(0x222);
    address internal thief = address(0x666);
    address internal relayer = address(0x777);

    address[] internal codes;
    uint256[] internal values;
    bytes32[] internal treeLeaves;
    bytes32 internal treeRoot;
    uint256 internal budget;

    event CodeRedeemed(uint256 indexed distributionId, address indexed code, address indexed receiver, uint256 amount);
    event PayoutClaimed(uint256 indexed distributionId, address indexed recipient, uint256 amount);

    function setUp() public override {
        super.setUp();

        code1 = vm.addr(CODE_1_KEY);
        code2 = vm.addr(CODE_2_KEY);
        code3 = vm.addr(CODE_3_KEY);

        codes = [code1, code2, code3];
        values = [uint256(10 ether), 10 ether, 25 ether];
        for (uint256 i = 0; i < values.length; i++) {
            budget += values[i];
        }

        treeLeaves = MerkleTreeLib.leaves(codes, values);
        treeRoot = MerkleTreeLib.root(treeLeaves);
    }

    function _liveCampaign(uint64 expiry) internal returns (uint256 id) {
        vm.prank(admin);
        id = payouts.createDistribution(
            address(token),
            PayoutsContract.PayoutMode.Claim,
            PayoutsContract.EntryMode.Code,
            expiry,
            RUN_REF,
            address(0)
        );
        _setMerkleRoot(id, treeRoot, budget, codes.length);
        _fund(id, budget);
        _finalize(id);
    }

    /**
     * @dev What a code holder signs: the address they want paid.
     * @notice The digest is rebuilt here rather than read from the contract. That checks
     * the construction independently — and, just as importantly, keeps this helper free
     * of external calls, which inside a `vm.expectRevert` argument list would consume
     * the expectation and quietly assert nothing.
     */
    function _sign(uint256 codeKey, uint256 id, address receiver) internal view returns (bytes memory) {
        bytes32 payload = keccak256(abi.encode(block.chainid, address(payouts), id, receiver));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(payload);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(codeKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev ...and the contract agrees with that reconstruction.
    function test_digestMatchesTheContract() public view {
        bytes32 payload = keccak256(abi.encode(block.chainid, address(payouts), uint256(1), winner));
        assertEq(payouts.codeRedemptionDigest(1, winner), MessageHashUtils.toEthSignedMessageHash(payload));
    }

    // ---- the happy path ------------------------------------------------------

    /// @dev The campaign is funded once, before anyone is known.
    function test_campaignIsPrefundedWithNobodyOnIt() public {
        uint256 id = _liveCampaign(0);

        PayoutsContract.Distribution memory dist = _dist(id);
        assertEq(uint8(dist.entryMode), uint8(PayoutsContract.EntryMode.Code));
        assertEq(dist.totalOwed, budget);
        assertEq(dist.funded, budget);
        assertEq(dist.reserved, budget);
        assertEq(dist.recipientCount, codes.length);
        // Nobody is owed anything yet — there are no recipients, only codes.
        assertEq(payouts.getPayoutAmount(id, winner), 0);
    }

    function test_codeHolderNamesTheAddressThatGetsPaid() public {
        uint256 id = _liveCampaign(0);

        vm.expectEmit(true, true, true, true);
        emit CodeRedeemed(id, code1, winner, 10 ether);
        vm.prank(winner);
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, winner));

        assertEq(token.balanceOf(winner), 10 ether);
        assertTrue(payouts.paidOut(id, code1)); // the CODE is spent...
        assertFalse(payouts.paidOut(id, winner)); // ...not the person
        assertEq(_dist(id).reserved, budget - 10 ether);
    }

    /// @dev One person may hold several codes; each pays out on its own.
    function test_onePersonCanRedeemSeveralCodes() public {
        uint256 id = _liveCampaign(0);

        vm.startPrank(winner);
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, winner));
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 1), _sign(CODE_2_KEY, id, winner));
        vm.stopPrank();

        assertEq(token.balanceOf(winner), 20 ether);
    }

    /// @dev Anyone may submit the transaction, so the platform can pay the gas for
    /// someone whose wallet is empty. The signature still decides who is paid.
    function test_anyoneCanSubmitButOnlyTheNamedAddressIsPaid() public {
        uint256 id = _liveCampaign(0);

        vm.prank(relayer);
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, winner));

        assertEq(token.balanceOf(winner), 10 ether);
        assertEq(token.balanceOf(relayer), 0);
    }

    // ---- the attack this design exists to stop -------------------------------

    /**
     * @dev Front-running, the reason a code is a key and not a password.
     *
     * The thief sees the victim's pending redemption in the mempool and re-submits it
     * with more gas. Because the signature names the victim, the thief's copy pays the
     * victim — and then their own attempt fails, the code being spent. There is no
     * ordering of these transactions in which the thief is paid.
     */
    function test_frontRunnerCannotStealARedemption() public {
        uint256 id = _liveCampaign(0);

        bytes memory victimSignature = _sign(CODE_1_KEY, id, winner);
        bytes32[] memory codeProof = MerkleTreeLib.proof(treeLeaves, 0);

        // The thief replays the signature it saw, hoping to be paid instead.
        vm.prank(thief);
        vm.expectRevert(PayoutsContract.InvalidCode.selector);
        payouts.claimWithCode(id, 10 ether, thief, codeProof, victimSignature);

        // Copying it verbatim just pays the victim early, at the thief's expense.
        vm.prank(thief);
        payouts.claimWithCode(id, 10 ether, winner, codeProof, victimSignature);

        assertEq(token.balanceOf(winner), 10 ether);
        assertEq(token.balanceOf(thief), 0);
    }

    /// @dev And knowing a code's ADDRESS — which is public, it is in the tree — is
    /// worthless without the key behind it.
    function test_knowingTheCodeAddressIsNotEnough() public {
        uint256 id = _liveCampaign(0);

        // The thief signs with their own key and points the leaf at code1's value.
        uint256 thiefKey = 0xBAD666;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(thiefKey, payouts.codeRedemptionDigest(id, thief));

        vm.prank(thief);
        vm.expectRevert(PayoutsContract.InvalidCode.selector);
        payouts.claimWithCode(id, 10 ether, thief, MerkleTreeLib.proof(treeLeaves, 0), abi.encodePacked(r, s, v));
    }

    function test_aCodeIsSpentOnce() public {
        uint256 id = _liveCampaign(0);
        bytes32[] memory codeProof = MerkleTreeLib.proof(treeLeaves, 0);

        vm.prank(winner);
        payouts.claimWithCode(id, 10 ether, winner, codeProof, _sign(CODE_1_KEY, id, winner));

        // Not even to a different address.
        vm.prank(otherWinner);
        vm.expectRevert(PayoutsContract.AlreadyPaidOut.selector);
        payouts.claimWithCode(id, 10 ether, otherWinner, codeProof, _sign(CODE_1_KEY, id, otherWinner));
    }

    function test_inflatedValueFailsVerification() public {
        uint256 id = _liveCampaign(0);

        vm.prank(winner);
        vm.expectRevert(PayoutsContract.InvalidCode.selector);
        payouts.claimWithCode(id, 25 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, winner));
    }

    /// @dev A signature is bound to one distribution, so a code from a cheap campaign
    /// cannot be spent against an expensive one.
    function test_signatureIsBoundToItsDistribution() public {
        uint256 first = _liveCampaign(0);
        uint256 second = _liveCampaign(0);

        vm.prank(winner);
        vm.expectRevert(PayoutsContract.InvalidCode.selector);
        payouts.claimWithCode(
            second, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, first, winner)
        );
    }

    function test_zeroReceiverIsRejected() public {
        uint256 id = _liveCampaign(0);

        vm.prank(winner);
        vm.expectRevert(PayoutsContract.InvalidReceiver.selector);
        payouts.claimWithCode(
            id, 10 ether, address(0), MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, address(0))
        );
    }

    function test_garbageSignatureIsRejected() public {
        uint256 id = _liveCampaign(0);

        vm.prank(winner);
        vm.expectRevert();
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), hex"deadbeef");
    }

    // ---- the modes do not mix ------------------------------------------------

    function test_codeDistributionRefusesTheOtherClaimPaths() public {
        uint256 id = _liveCampaign(0);

        vm.prank(winner);
        vm.expectRevert(PayoutsContract.ProofRequired.selector);
        payouts.claimPayout(id);

        vm.prank(winner);
        vm.expectRevert(PayoutsContract.NoProofExpected.selector);
        payouts.claimPayout(id, 10 ether, MerkleTreeLib.proof(treeLeaves, 0));
    }

    function test_claimWithCodeRefusedOnOtherModes() public {
        uint256 direct = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(winner);
        vm.expectRevert(PayoutsContract.NotACodeDistribution.selector);
        payouts.claimWithCode(direct, 10 ether, winner, new bytes32[](0), _sign(CODE_1_KEY, direct, winner));
    }

    function test_codeDistributionCannotBePushed() public {
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RootCommittedDistributionsAreClaimOnly.selector);
        payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Auto, PayoutsContract.EntryMode.Code, 0, RUN_REF, address(0)
        );
    }

    function test_codeDistributionRefusesDirectEntries() public {
        uint256 id = _liveCampaign(0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotInSetup.selector);
        payouts.setPayoutAmounts(id, _addrs(winner), _amounts(1 ether));
    }

    // ---- the campaign's end --------------------------------------------------

    /// @dev Most giveaway codes are never redeemed; the budget comes back.
    function test_unredeemedBudgetIsSweptAfterExpiry() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 id = _liveCampaign(expiry);

        vm.prank(winner);
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, winner));

        vm.warp(expiry);

        // A late code is worthless.
        vm.prank(otherWinner);
        vm.expectRevert(PayoutsContract.DistributionExpired.selector);
        payouts.claimWithCode(
            id, 10 ether, otherWinner, MerkleTreeLib.proof(treeLeaves, 1), _sign(CODE_2_KEY, id, otherWinner)
        );

        uint256 before = token.balanceOf(admin);
        _sweep(id, admin);

        assertEq(token.balanceOf(admin) - before, budget - 10 ether);
        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Done));
        assertEq(payouts.reservedByToken(address(token)), 0);
    }

    /// @dev A giveaway can still be gated: the code proves entitlement, the registry
    /// proves the person may be paid at all.
    function test_campaignCanBeComplianceGated() public {
        // Deployed first: a `new` inside the call would consume the prank.
        address registry = address(new AllowOnly(winner));

        vm.prank(admin);
        uint256 id = payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Code, 0, RUN_REF, registry
        );
        _setMerkleRoot(id, treeRoot, budget, codes.length);
        _fund(id, budget);
        _finalize(id);

        vm.prank(otherWinner);
        vm.expectRevert(PayoutsContract.RecipientNotEligible.selector);
        payouts.claimWithCode(
            id, 10 ether, otherWinner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, otherWinner)
        );

        vm.prank(winner);
        payouts.claimWithCode(id, 10 ether, winner, MerkleTreeLib.proof(treeLeaves, 0), _sign(CODE_1_KEY, id, winner));
        assertEq(token.balanceOf(winner), 10 ether);
    }

    /// @dev The reserve holds however the codes fall: a campaign can never pay out more
    /// than it was funded, whoever redeems and in whatever order.
    function testFuzz_campaignNeverOverspends(uint8 redeemMask, address receiver) public {
        vm.assume(receiver != address(0) && receiver != address(payouts) && receiver.code.length == 0);

        uint256 id = _liveCampaign(0);
        uint256[3] memory keys = [CODE_1_KEY, CODE_2_KEY, CODE_3_KEY];
        uint256 expected;

        for (uint256 i = 0; i < 3; i++) {
            if (redeemMask & (1 << i) == 0) continue;

            vm.prank(receiver);
            payouts.claimWithCode(
                id, values[i], receiver, MerkleTreeLib.proof(treeLeaves, i), _sign(keys[i], id, receiver)
            );
            expected += values[i];
        }

        assertEq(token.balanceOf(receiver), expected);
        assertEq(_dist(id).paidTotal, expected);
        assertEq(_dist(id).reserved, budget - expected);
        assertGe(token.balanceOf(address(payouts)), payouts.reservedByToken(address(token)));
    }
}

/// @dev A one-address eligibility registry, for the gated-giveaway test.
contract AllowOnly {
    address private immutable ALLOWED;

    constructor(address allowed) {
        ALLOWED = allowed;
    }

    function isEligible(address account) external view returns (bool) {
        return account == ALLOWED;
    }
}
