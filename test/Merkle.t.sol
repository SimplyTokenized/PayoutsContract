// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PayoutsTestBase} from "./utils/PayoutsTestBase.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {MerkleTreeLib} from "./utils/MerkleTreeLib.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/**
 * @dev C9 — committing a whole recipient list as one root.
 *
 * The point of the mode is that one transaction commits any number of people, so these
 * tests care most about what stops a forged entry: the proof itself, the double-hashed
 * leaf, and the four eyes on a total the contract cannot compute for itself.
 */
contract MerkleTest is PayoutsTestBase {
    using MerkleTreeLib for bytes32[];

    address[] internal people;
    uint256[] internal owed;
    bytes32[] internal treeLeaves;
    bytes32 internal treeRoot;
    uint256 internal declaredTotal;

    event MerkleRootSet(
        uint256 indexed distributionId, bytes32 indexed merkleRoot, uint256 declaredTotal, uint256 recipientCount
    );
    event PayoutClaimed(uint256 indexed distributionId, address indexed recipient, uint256 amount);

    function setUp() public override {
        super.setUp();

        // Five recipients, deliberately an odd number so the tree is unbalanced and the
        // promote-the-lone-node path is exercised.
        people = [alice, bob, carol, address(0xD1), address(0xE1)];
        owed = [uint256(100 ether), 50 ether, 25 ether, 10 ether, 5 ether];

        for (uint256 i = 0; i < owed.length; i++) {
            declaredTotal += owed[i];
        }

        treeLeaves = MerkleTreeLib.leaves(people, owed);
        treeRoot = MerkleTreeLib.root(treeLeaves);
    }

    function _liveMerkle(uint64 expiry) internal returns (uint256 id) {
        id = _createMerkleDistribution(expiry, treeRoot, declaredTotal, people.length);
        _fund(id, declaredTotal);
        _finalize(id);
    }

    function _proofFor(uint256 index) internal view returns (bytes32[] memory) {
        return MerkleTreeLib.proof(treeLeaves, index);
    }

    // ---- committing the list -------------------------------------------------

    function test_oneTransactionCommitsTheWholeList() public {
        vm.prank(admin);
        uint256 id = payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Merkle, 0, RUN_REF, address(0)
        );

        vm.prank(admin);
        payouts.proposeSetMerkleRoot(id, treeRoot, declaredTotal, people.length);

        vm.expectEmit(true, true, true, true);
        emit MerkleRootSet(id, treeRoot, declaredTotal, people.length);
        vm.prank(approver);
        payouts.approveSetMerkleRoot(id, treeRoot, declaredTotal, people.length);

        PayoutsContract.Distribution memory dist = _dist(id);
        assertEq(dist.merkleRoot, treeRoot);
        assertEq(dist.totalOwed, declaredTotal);
        assertEq(dist.recipientCount, people.length);
        assertEq(uint8(dist.entryMode), uint8(PayoutsContract.EntryMode.Merkle));
    }

    /// @dev The contract cannot sum the leaves, so a second person must — the approval
    /// binds the root, the total AND the count together.
    function test_approvalBindsRootTotalAndCount() public {
        vm.prank(admin);
        uint256 id = payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Merkle, 0, RUN_REF, address(0)
        );

        vm.prank(admin);
        payouts.proposeSetMerkleRoot(id, treeRoot, declaredTotal, people.length);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveSetMerkleRoot(id, treeRoot, declaredTotal - 1, people.length);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveSetMerkleRoot(id, treeRoot, declaredTotal, people.length - 1);

        vm.prank(approver);
        vm.expectRevert(PayoutsContract.NoSuchProposal.selector);
        payouts.approveSetMerkleRoot(id, keccak256("other list"), declaredTotal, people.length);
    }

    function test_rootCannotBeSelfApproved() public {
        _grantRoleAfterDelay(payouts.APPROVER_ROLE(), admin);

        vm.prank(admin);
        uint256 id = payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Merkle, 0, RUN_REF, address(0)
        );
        vm.prank(admin);
        payouts.proposeSetMerkleRoot(id, treeRoot, declaredTotal, people.length);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ApproverMustNotBeProposer.selector);
        payouts.approveSetMerkleRoot(id, treeRoot, declaredTotal, people.length);
    }

    /// @dev Re-committing after funding would move the goalposts under the money.
    function test_rootCannotChangeOnceFunded() public {
        uint256 id = _createMerkleDistribution(0, treeRoot, declaredTotal, people.length);
        _fund(id, 1 ether);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.AlreadyFunded.selector);
        payouts.proposeSetMerkleRoot(id, keccak256("new list"), declaredTotal, people.length);
    }

    function test_rejectsEmptyRootTotalOrCount() public {
        vm.prank(admin);
        uint256 id = payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Claim, PayoutsContract.EntryMode.Merkle, 0, RUN_REF, address(0)
        );

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidRoot.selector);
        payouts.proposeSetMerkleRoot(id, bytes32(0), declaredTotal, people.length);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidTotal.selector);
        payouts.proposeSetMerkleRoot(id, treeRoot, 0, people.length);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidRecipientCount.selector);
        payouts.proposeSetMerkleRoot(id, treeRoot, declaredTotal, 0);
    }

    // ---- the two modes do not mix -------------------------------------------

    function test_merkleDistributionRefusesDirectEntries() public {
        uint256 id = _createMerkleDistribution(0, treeRoot, declaredTotal, people.length);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotADirectDistribution.selector);
        payouts.setPayoutAmounts(id, _addrs(alice), _amounts(1 ether));
    }

    function test_directDistributionRefusesARoot() public {
        uint256 id = _createDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotARootCommittedDistribution.selector);
        payouts.proposeSetMerkleRoot(id, treeRoot, declaredTotal, people.length);
    }

    /// @dev A push needs an on-chain list, so the combination is refused at creation
    /// rather than discovered at hand-over.
    function test_autoPlusMerkleIsRefusedAtCreation() public {
        vm.prank(admin);
        vm.expectRevert(PayoutsContract.RootCommittedDistributionsAreClaimOnly.selector);
        payouts.createDistribution(
            address(token), PayoutsContract.PayoutMode.Auto, PayoutsContract.EntryMode.Merkle, 0, RUN_REF, address(0)
        );
    }

    function test_claimWithoutProofIsRefusedOnMerkle() public {
        uint256 id = _liveMerkle(0);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.ProofRequired.selector);
        payouts.claimPayout(id);
    }

    function test_claimWithProofIsRefusedOnDirect() public {
        uint256 id = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.NoProofExpected.selector);
        payouts.claimPayout(id, 100 ether, new bytes32[](0));
    }

    // ---- claiming ------------------------------------------------------------

    function test_everyRecipientCanClaimTheirOwnEntry() public {
        uint256 id = _liveMerkle(0);

        for (uint256 i = 0; i < people.length; i++) {
            assertTrue(payouts.canClaimPayout(id, people[i], owed[i], _proofFor(i)));

            vm.prank(people[i]);
            payouts.claimPayout(id, owed[i], _proofFor(i));

            assertEq(token.balanceOf(people[i]), owed[i]);
        }

        assertEq(_dist(id).reserved, 0);
        assertEq(_dist(id).paidTotal, declaredTotal);
        assertEq(token.balanceOf(address(payouts)), 0);
    }

    function test_claimingTwiceReverts() public {
        uint256 id = _liveMerkle(0);

        vm.prank(alice);
        payouts.claimPayout(id, owed[0], _proofFor(0));

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.AlreadyPaidOut.selector);
        payouts.claimPayout(id, owed[0], _proofFor(0));
    }

    // ---- what stops a forgery ------------------------------------------------

    /// @dev The proof is the entry: a bigger number simply is not in the tree.
    function test_inflatedAmountFailsVerification() public {
        uint256 id = _liveMerkle(0);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.InvalidProof.selector);
        payouts.claimPayout(id, owed[0] + 1, _proofFor(0));
    }

    /// @dev Someone else's proof does not make you them — the leaf binds the address.
    function test_someoneElsesProofDoesNotWork() public {
        uint256 id = _liveMerkle(0);

        vm.prank(outsider);
        vm.expectRevert(PayoutsContract.InvalidProof.selector);
        payouts.claimPayout(id, owed[0], _proofFor(0));
    }

    function test_emptyAndGarbageProofsFail() public {
        uint256 id = _liveMerkle(0);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.InvalidProof.selector);
        payouts.claimPayout(id, owed[0], new bytes32[](0));

        bytes32[] memory garbage = new bytes32[](2);
        garbage[0] = keccak256("nonsense");
        garbage[1] = keccak256("more nonsense");

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.InvalidProof.selector);
        payouts.claimPayout(id, owed[0], garbage);
    }

    /**
     * @dev The second-preimage attack, and the reason leaves are hashed twice.
     *
     * An attacker can read the whole published tree, so they know its internal nodes.
     * If leaves and internal nodes were hashed the same way, an internal node could be
     * presented as if it were a leaf — inventing an entry nobody granted. Here the
     * attacker takes a real internal node (the parent of alice's and bob's leaves) and
     * tries to spend it; the double-hashed leaf format means it cannot be one.
     */
    function test_internalNodeCannotBeReplayedAsALeaf() public {
        uint256 id = _liveMerkle(0);

        bytes32 internalNode = Hashes.commutativeKeccak256(treeLeaves[0], treeLeaves[1]);

        // The node is genuinely in the tree...
        bytes32[] memory siblingPath = new bytes32[](2);
        siblingPath[0] = Hashes.commutativeKeccak256(treeLeaves[2], treeLeaves[3]);
        siblingPath[1] = treeLeaves[4];
        assertEq(_foldProof(internalNode, siblingPath), treeRoot, "precondition: node is in the tree");

        // ...but no (recipient, amount) pair hashes to it, so it can never be claimed.
        vm.prank(outsider);
        vm.expectRevert(PayoutsContract.InvalidProof.selector);
        payouts.claimPayout(id, uint256(internalNode), siblingPath);
    }

    // ---- the funding guarantee, and what merkle costs it ---------------------

    function test_stillCannotGoLiveUnderfunded() public {
        uint256 id = _createMerkleDistribution(0, treeRoot, declaredTotal, people.length);
        _fund(id, declaredTotal - 1);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.NotFullyFunded.selector);
        payouts.proposeFinalizeDistribution(id);

        _fund(id, 1);
        _finalize(id);
    }

    function test_overfundingIsStillRefused() public {
        uint256 id = _createMerkleDistribution(0, treeRoot, declaredTotal, people.length);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ExceedsAmountOwed.selector);
        payouts.fundPayoutToken(id, declaredTotal + 1);
    }

    /**
     * @dev The honest cost of Merkle mode, made visible.
     *
     * `totalOwed` is declared rather than computed, so a total understating the tree
     * leaves the last claimants with an empty reserve. Nobody is over-paid and no other
     * run is touched — the reserve holds — but somebody is left unpaid, which is why the
     * approver's job is to recompute the sum from the published list before approving.
     */
    function test_underDeclaredTotalStrandsTheLastClaimants() public {
        uint256 short = declaredTotal - owed[4]; // the last recipient's share is missing
        uint256 id = _createMerkleDistribution(0, treeRoot, short, people.length);
        _fund(id, short);
        _finalize(id);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(people[i]);
            payouts.claimPayout(id, owed[i], _proofFor(i));
        }

        assertEq(_dist(id).reserved, 0);

        vm.prank(people[4]);
        vm.expectRevert(PayoutsContract.InsufficientFunds.selector);
        payouts.claimPayout(id, owed[4], _proofFor(4));

        // The contract never paid out more than it held.
        assertEq(token.balanceOf(address(payouts)), 0);
        assertEq(payouts.reservedByToken(address(token)), 0);
    }

    // ---- everything else still applies --------------------------------------

    function test_expiryAndSweepWorkTheSame() public {
        vm.warp(1_000_000);
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 id = _liveMerkle(expiry);

        vm.prank(alice);
        payouts.claimPayout(id, owed[0], _proofFor(0));

        vm.warp(expiry);
        vm.prank(bob);
        vm.expectRevert(PayoutsContract.DistributionExpired.selector);
        payouts.claimPayout(id, owed[1], _proofFor(1));

        _sweep(id, admin);
        assertEq(uint8(_dist(id).state), uint8(PayoutsContract.DistributionState.Done));
        assertEq(token.balanceOf(address(payouts)), 0);
    }

    function test_offChainReceiptNeedsAProofAndReleasesTheShare() public {
        uint256 id = _liveMerkle(0);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.ProofRequired.selector);
        payouts.markPayoutAsPaid(id, alice);

        vm.prank(admin);
        vm.expectRevert(PayoutsContract.InvalidProof.selector);
        payouts.markPayoutAsPaid(id, alice, owed[0] + 1, _proofFor(0));

        vm.prank(admin);
        payouts.markPayoutAsPaid(id, alice, owed[0], _proofFor(0));

        assertTrue(payouts.paidOut(id, alice));
        assertEq(token.balanceOf(alice), 0);
        assertEq(_dist(id).reserved, declaredTotal - owed[0]);

        vm.prank(alice);
        vm.expectRevert(PayoutsContract.AlreadyPaidOut.selector);
        payouts.claimPayout(id, owed[0], _proofFor(0));
    }

    function test_verifyEntryLetsAWalletCheckBeforeSpendingGas() public {
        uint256 id = _liveMerkle(0);

        assertTrue(payouts.verifyEntry(id, alice, owed[0], _proofFor(0)));
        assertFalse(payouts.verifyEntry(id, alice, owed[0] + 1, _proofFor(0)));
        assertFalse(payouts.verifyEntry(id, outsider, owed[0], _proofFor(0)));
    }

    /// @dev One tenant contract, both entry modes side by side, neither disturbing the other.
    function test_directAndMerkleRunsCoexist() public {
        uint256 direct = _liveDistribution(PayoutsContract.PayoutMode.Claim, 0); // owes 150
        uint256 merkle = _liveMerkle(0);

        assertEq(payouts.reservedByToken(address(token)), 150 ether + declaredTotal);

        vm.prank(alice);
        payouts.claimPayout(direct); // 100 from the direct run
        vm.prank(alice);
        payouts.claimPayout(merkle, owed[0], _proofFor(0)); // 100 from the merkle run

        assertEq(token.balanceOf(alice), 200 ether);
        assertEq(_dist(direct).reserved, 50 ether);
        assertEq(_dist(merkle).reserved, declaredTotal - owed[0]);
    }

    /// @dev Whatever the list, every member of it can collect exactly their entry.
    function testFuzz_anyListPaysEveryoneExactlyOnce(uint96[6] memory raw) public {
        address[] memory recipients = new address[](raw.length);
        uint256[] memory amounts = new uint256[](raw.length);
        uint256 total;

        for (uint256 i = 0; i < raw.length; i++) {
            recipients[i] = address(uint160(i + 5000));
            amounts[i] = uint256(raw[i]) + 1;
            total += amounts[i];
        }

        bytes32[] memory fuzzLeaves = MerkleTreeLib.leaves(recipients, amounts);
        bytes32 fuzzRoot = MerkleTreeLib.root(fuzzLeaves);

        token.mint(admin, total);
        uint256 id = _createMerkleDistribution(0, fuzzRoot, total, recipients.length);
        _fund(id, total);
        _finalize(id);

        for (uint256 i = 0; i < recipients.length; i++) {
            vm.prank(recipients[i]);
            payouts.claimPayout(id, amounts[i], MerkleTreeLib.proof(fuzzLeaves, i));
            assertEq(token.balanceOf(recipients[i]), amounts[i]);
        }

        assertEq(_dist(id).reserved, 0);
    }

    /// @dev Re-fold a proof by hand, to assert a node really is in the tree.
    function _foldProof(bytes32 node, bytes32[] memory path) private pure returns (bytes32 computed) {
        computed = node;
        for (uint256 i = 0; i < path.length; i++) {
            computed = Hashes.commutativeKeccak256(computed, path[i]);
        }
    }
}
