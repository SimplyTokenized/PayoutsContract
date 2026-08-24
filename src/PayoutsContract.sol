// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEligibilityRegistry} from "./compliance/IEligibilityRegistry.sol";

/**
 * @title PayoutsContract (v2)
 * @notice One payout contract per tenant, one distribution per payout run.
 *
 * @dev v2 is deliberately SMALLER than v1. The platform computes what each recipient is
 * owed off-chain — a payout run produces one statement per recipient, with its own
 * arithmetic — so the contract never needs a snapshot, a proportional formula, or a
 * compute phase. It holds a list of `(recipient, amount)` entries, the money to cover
 * them, and the record of who has been paid.
 *
 * What v1 had and v2 does not:
 * - `baseToken` — was write-only metadata, and the only reason a contract had to be
 *   deployed per offering. Gone, so one contract serves a whole tenant. The asset is a
 *   property of each distribution (`payoutToken`), which it already was.
 * - Proportional mode, snapshots, and the Compute state — the amount is now always
 *   supplied by the caller. A per-recipient tax deduction cannot be expressed as
 *   `balance x total / totalBalance` anyway, so the on-chain formula could never be the
 *   authority once withholding existed.
 * - The built-in whitelist — an entry with an amount *is* the entitlement, and the
 *   operator curates the recipient list off-chain, where the KYC facts live. Tenants
 *   who need an on-chain gate get a stronger one instead: see COMPLIANCE below.
 *
 * COMPLIANCE — one pluggable gate, three postures:
 *
 * Each distribution may name an eligibility registry at creation (immutable for its
 * life). When set, `claimPayout` and `batchDistributeAutomatic` refuse recipients the
 * registry does not vouch for — checked at PAYMENT time, so someone whose verification
 * lapses between entry and claim is refused. The check fails CLOSED: an unreachable
 * registry blocks payment rather than waving it through.
 *   1. address(0)                — no gate; the curated entry list is the entitlement.
 *   2. WhitelistRegistry         — an operator-kept on-chain list (companion contract).
 *   3. ERC3643EligibilityAdapter — the security token's own identity registry decides,
 *      an INDEPENDENT compliance layer, which is what a regulated fund's counsel
 *      actually requires. `markPayoutAsPaid` is ungated on purpose: it moves no funds
 *      here, and the off-chain settlement it records carries its own compliance.
 *
 * Lifecycle: `Setup -> Payout -> Done`.
 *   Setup   — entries are written and the money is put in. Nothing can be paid yet.
 *   Payout  — fully funded and immutable. Recipients claim, or the operator pushes.
 *   Done    — closed, either because everything was settled or because what was left
 *             was swept back after expiry.
 *
 * HOW THE LIST GETS ON-CHAIN — `EntryMode`, chosen per distribution:
 *
 * - `Direct` writes one storage entry per recipient, in batches. Every amount is
 *   on-chain and self-sufficient, `totalOwed` is *computed* by the contract, and the
 *   operator can push as well as let people claim. Right up to a few thousand people.
 * - `Merkle` commits the whole list as one 32-byte root and takes the total as a
 *   *declared* figure. One transaction regardless of list size — the only thing that
 *   works at tens of thousands of recipients — at the cost of two things worth stating
 *   plainly. First, the amounts live off-chain: the list must stay published for
 *   recipients to build proofs, or nobody can collect. Second, `totalOwed` is an
 *   assertion rather than a sum, so under-declaring it would leave the last claimants
 *   with an empty reserve. The approver's job in Merkle mode is therefore to recompute
 *   BOTH the root and the total from the published list before approving — which is
 *   what `MerkleRootSet` publishes, so the check is reproducible by anyone afterwards.
 *   Merkle is claim-only: a push needs an on-chain list to read amounts from.
 * - `Code` is Merkle for a run whose recipients are *not known when it is funded* — a
 *   giveaway. The leaves commit to redeemable CODES rather than to people, the campaign
 *   budget is prefunded once, and whoever presents a code names the address it pays.
 *   Unredeemed value comes back on the sweep after expiry.
 *
 *   A code is not a password — it is a **private key**. That is what makes redeeming it
 *   safe in public: the holder signs the address they want paid, and the contract checks
 *   the signature came from a key the tree commits to. Watching the mempool gains an
 *   attacker nothing, because every signature it sees is already bound to somebody
 *   else's address. A code that were merely a secret string in calldata would be stolen
 *   by the first bot to copy it into a higher-gas transaction — which is the reason this
 *   mode is built the way it is, and the reason it cannot be simplified into one.
 *
 * Two safety properties are enforced on-chain rather than trusted to the caller:
 *
 * 1. A distribution cannot go live under-funded. Finalizing requires
 *    `funded == totalOwed`, so once recipients can claim, the money for every one of
 *    them is already here. v1 could not check this — its funding maths lived off-chain.
 *
 * 2. One run can never spend another run's money. Every distribution's unspent balance
 *    is reserved (`Distribution.reserved`, summed per asset in `reservedByToken`), and
 *    both emergency withdrawal and any transfer out respect it. A tenant contract holds
 *    many runs at once, which makes this the difference between a shared pot and a
 *    shared accident.
 *
 * GOVERNANCE — enforced in code, not left to key policy:
 *
 * - Duties are split by role. OPERATOR runs the day-to-day (open runs, write entries,
 *   push payments, record receipts). FUNDER is the only role that moves money in.
 *   ADMIN guards the contract (pause, and proposing its riskiest changes). APPROVER is
 *   the second pair of eyes. One address may hold several roles, but each function
 *   demands exactly the role whose job it is.
 * - The irreversible actions take FOUR EYES: taking a run live, sweeping unclaimed
 *   money back, withdrawing surplus, and changing the trusted forwarder each require a
 *   proposal by the owning role and an approval by an APPROVER **who is not the
 *   proposer**. A proposal binds to the exact parameters — and, for finalizing, to the
 *   run's exact content — so what was approved is what executes, and it lapses if not
 *   approved within `PROPOSAL_TTL`.
 * - **Role grants are delayed; revocations are not.** Handing someone a role must be
 *   announced (`scheduleRoleGrant`) and takes effect only after `ROLE_GRANT_DELAY` —
 *   which is what stops the root key defeating four eyes in a single transaction by
 *   granting `APPROVER_ROLE` to a second address it controls and approving its own
 *   proposal in the next call. Taking a role away stays immediate, because a
 *   compromised key must be removable now. Either the role's admin or the guardian may
 *   cancel a pending grant, so the veto does not require the key that scheduled it.
 * - The role-admin root (`DEFAULT_ADMIN_ROLE`) still ultimately controls the role graph,
 *   so it belongs on a multisig behind a timelock; the delay above buys the time to
 *   notice and react. Upgrades are governed outside this contract by the ProxyAdmin
 *   owner, which the deploy script can place behind a TimelockController so every
 *   upgrade is publicly visible before it executes — the backstop if the root itself is
 *   the problem.
 *
 * Gas for claiming is selectable by the tenant: with no trusted forwarder set the
 * recipient signs and pays, which is the default; setting one lets a relayer pay on
 * their behalf (ERC-2771). Both paths credit the real recipient.
 *
 * @notice Fee-on-transfer tokens are NOT supported as payout tokens — funding one would
 * credit more than actually arrived and break the funded/owed equality above.
 */
contract PayoutsContract is Initializable, AccessControlUpgradeable, ReentrancyGuardTransient, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    //
    // Custom errors rather than revert strings: four bytes at the revert site instead
    // of a stored literal, which is what keeps this contract inside the 24KB limit with
    // room for an audit to add to it. The names carry the meaning the strings did.

    /// @dev invalid admin
    error InvalidAdmin();
    /// @dev invalid approver
    error InvalidApprover();
    /// @dev approver must not be admin
    error ApproverMustNotBeAdmin();
    /// @dev expiry in the past
    error ExpiryInThePast();
    /// @dev root-committed distributions are claim-only
    error RootCommittedDistributionsAreClaimOnly();
    /// @dev distribution not found
    error DistributionNotFound();
    /// @dev not in setup
    error NotInSetup();
    /// @dev not a direct distribution
    error NotADirectDistribution();
    /// @dev recipients and amounts length mismatch
    error RecipientsAndAmountsLengthMismatch();
    /// @dev invalid batch size
    error InvalidBatchSize();
    /// @dev invalid recipient address
    error InvalidRecipientAddress();
    /// @dev invalid amount
    error InvalidAmount();
    /// @dev recipient already set
    error RecipientAlreadySet();
    /// @dev not a root-committed distribution
    error NotARootCommittedDistribution();
    /// @dev invalid root
    error InvalidRoot();
    /// @dev invalid total
    error InvalidTotal();
    /// @dev invalid recipient count
    error InvalidRecipientCount();
    /// @dev already funded
    error AlreadyFunded();
    /// @dev exceeds amount owed
    error ExceedsAmountOwed();
    /// @dev native amount mismatch
    error NativeAmountMismatch();
    /// @dev native value not accepted
    error NativeValueNotAccepted();
    /// @dev not in payout
    error NotInPayout();
    /// @dev funds still reserved
    error FundsStillReserved();
    /// @dev nothing to pay
    error NothingToPay();
    /// @dev not fully funded
    error NotFullyFunded();
    /// @dev proof required
    error ProofRequired();
    /// @dev no proof expected
    error NoProofExpected();
    /// @dev invalid proof
    error InvalidProof();
    /// @dev not a code distribution
    error NotACodeDistribution();
    /// @dev invalid receiver
    error InvalidReceiver();
    /// @dev invalid code
    error InvalidCode();
    /// @dev not a claim distribution
    error NotAClaimDistribution();
    /// @dev distribution expired
    error DistributionExpired();
    /// @dev already paid out
    error AlreadyPaidOut();
    /// @dev nothing owed
    error NothingOwed();
    /// @dev insufficient funds
    error InsufficientFunds();
    /// @dev not an automatic distribution
    error NotAnAutomaticDistribution();
    /// @dev distribution never expires
    error DistributionNeverExpires();
    /// @dev not expired
    error NotExpired();
    /// @dev invalid recipient
    error InvalidRecipient();
    /// @dev reserve accounting broken
    error ReserveAccountingBroken();
    /// @dev amount is reserved
    error AmountIsReserved();
    /// @dev no such proposal
    error NoSuchProposal();
    /// @dev proposal expired
    error ProposalExpired();
    /// @dev approver must not be proposer
    error ApproverMustNotBeProposer();
    /// @dev invalid account
    error InvalidAccount();
    /// @dev already has role
    error AlreadyHasRole();
    /// @dev not allowed to cancel
    error NotAllowedToCancel();
    /// @dev no pending grant
    error NoPendingGrant();
    /// @dev grant not scheduled
    error GrantNotScheduled();
    /// @dev grant still waiting
    error GrantStillWaiting();
    /// @dev grant expired
    error GrantExpired();
    /// @dev recipient not eligible
    error RecipientNotEligible();
    /// @dev the distribution named an eligibility registry that cannot answer
    error RegistryNotAnswering();
    /// @dev the gate reverted, so eligibility is unknown — which is never "paid"
    error EligibilityCheckUnavailable();
    /// @dev native transfer failed
    error NativeTransferFailed();

    /// @notice Guards the contract: pause, and proposes withdrawals and forwarder changes.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Runs payouts day-to-day: distributions, entries, pushes, receipts.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice The only role that can move money into the contract.
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    /// @notice The second pair of eyes: approves what someone else proposed.
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");

    /// @dev Batch ceiling for every array-taking function, to stay inside a block's gas.
    uint256 public constant MAX_BATCH_SIZE = 200;

    /// @notice How long a proposal stays approvable before it lapses.
    uint256 public constant PROPOSAL_TTL = 7 days;

    /**
     * @notice How long a role grant must wait between being scheduled and taking effect.
     *
     * @dev This is what stops four-eyes being defeated in a single transaction. Without
     * it, whoever holds a role's admin could grant `APPROVER_ROLE` to a second address
     * they control and then approve their own proposal in the very next call — two
     * signatures, one person, four eyes in name only.
     *
     * The delay is deliberately one-directional: **granting waits, revoking does not.**
     * A compromised key must be removable this second, while an added one is the thing
     * that needs daylight. Two days is enough for the guardian to cancel it, or — if the
     * root key itself is the problem — for the timelocked upgrade path to be used.
     */
    uint256 public constant ROLE_GRANT_DELAY = 2 days;

    /// @dev Length of the ERC-2771 calldata suffix carrying the original sender.
    uint256 private constant _CONTEXT_SUFFIX_LENGTH = 20;

    /// @notice How a distribution's money reaches the people on it.
    enum PayoutMode {
        Claim, // 0 - recipients collect it themselves
        Auto // 1 - the operator pushes it to them
    }

    /// @notice Where a distribution is in its life.
    enum DistributionState {
        Setup, // 0 - entries and funding
        Payout, // 1 - live, fully funded
        Done // 2 - closed
    }

    /// @notice How the recipient list reaches the chain.
    enum EntryMode {
        Direct, // 0 - one storage entry per recipient; amounts on-chain, total computed
        Merkle, // 1 - one root for the whole list; amounts off-chain, total declared
        Code // 2 - one root over redeemable CODES; who receives is decided at claim
    }

    /// @notice The five actions that require four eyes.
    enum ActionKind {
        FinalizeDistribution, // take a run live
        SweepUnclaimed, // return uncollected money after expiry
        EmergencyWithdraw, // withdraw surplus
        SetTrustedForwarder, // change who may relay claims
        SetMerkleRoot // commit a whole recipient list at once
    }

    struct Distribution {
        uint256 distributionId;
        address payoutToken; // address(0) means the chain's native asset
        PayoutMode mode;
        EntryMode entryMode;
        DistributionState state;
        uint64 expiry; // 0 means it never expires and can never be swept
        bytes32 runRef; // the payout run this distribution pays; the join key for evidence
        bytes32 merkleRoot; // Merkle mode only; 0 until the list is committed
        address eligibilityRegistry; // compliance gate; address(0) means ungated
        uint256 totalOwed; // Direct: the sum of every entry. Merkle: the declared total
        uint256 funded; // what has actually been paid in
        uint256 paidTotal; // what has actually left the contract to recipients
        uint256 reserved; // what is still held for unpaid entries
        uint256 recipientCount; // Direct: entries written. Merkle: declared leaf count
        bool initialized;
    }

    /// @notice A pending four-eyes action, waiting for an approver who is not its proposer.
    struct Proposal {
        address proposer;
        uint64 proposedAt;
    }

    /// @dev Counter for distribution ids; starts at 1 so 0 always means "none".
    uint256 public nextDistributionId;

    /// @dev ERC-2771 forwarder, in storage rather than immutable so each tenant's proxy
    /// can turn gasless claiming on or off without a new implementation.
    address private _trustedForwarder;

    mapping(uint256 => Distribution) public distributions;

    /// @notice distributionId => recipient => amount owed. Written once, in Setup.
    mapping(uint256 => mapping(address => uint256)) public payoutAmounts;

    /// @notice distributionId => recipient => settled. The single arbiter of double
    /// payment, whoever acts first: the recipient claiming, the operator pushing, or
    /// the operator recording an off-chain settlement.
    mapping(uint256 => mapping(address => bool)) public paidOut;

    /// @notice payout asset => amount held for unpaid entries across all distributions.
    /// Anything above this is surplus the tenant may withdraw.
    mapping(address => uint256) public reservedByToken;

    /// @notice proposal id => the pending proposal. Ids bind kind and parameters, so an
    /// approval can only ever execute exactly what was proposed.
    mapping(bytes32 => Proposal) public proposals;

    /// @notice keccak256(role, account) => when the grant was scheduled. 0 means no
    /// pending grant, which is also what a grant becomes once it is used or cancelled.
    mapping(bytes32 => uint64) public roleGrantScheduledAt;

    event DistributionCreated(
        uint256 indexed distributionId,
        address indexed payoutToken,
        PayoutMode mode,
        EntryMode entryMode,
        uint64 expiry,
        bytes32 indexed runRef,
        address eligibilityRegistry
    );
    event PayoutAmountsSet(uint256 indexed distributionId, uint256 count, uint256 totalOwed);
    /// @dev Everything an outsider needs to re-derive the tree and check the total.
    event MerkleRootSet(
        uint256 indexed distributionId, bytes32 indexed merkleRoot, uint256 declaredTotal, uint256 recipientCount
    );
    event PayoutTokenFunded(uint256 indexed distributionId, uint256 amount);
    event DistributionStateAdvanced(uint256 indexed distributionId, DistributionState state);
    /// @dev The recipient collected it themselves.
    event PayoutClaimed(uint256 indexed distributionId, address indexed recipient, uint256 amount);
    /// @dev The operator pushed it to them.
    event PayoutSent(uint256 indexed distributionId, address indexed recipient, uint256 amount);
    /// @dev A giveaway code was spent, and by whom it was directed. Emitted alongside
    /// `PayoutClaimed`, which records the payment itself.
    event CodeRedeemed(uint256 indexed distributionId, address indexed code, address indexed receiver, uint256 amount);
    /// @dev Settled off-chain (a bank transfer); no funds moved here.
    event PayoutMarkedAsPaid(uint256 indexed distributionId, address indexed recipient, uint256 amount);
    event UnclaimedSwept(uint256 indexed distributionId, address indexed to, uint256 amount);
    event TrustedForwarderUpdated(address indexed forwarder);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event ActionProposed(bytes32 indexed proposalId, ActionKind indexed kind, address indexed proposer);
    event ActionApproved(bytes32 indexed proposalId, ActionKind indexed kind, address indexed approver);
    event ActionCancelled(bytes32 indexed proposalId, address indexed by);
    event RoleGrantScheduled(bytes32 indexed role, address indexed account, uint256 effectiveFrom, address indexed by);
    event RoleGrantCancelled(bytes32 indexed role, address indexed account, address indexed by);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract for one tenant.
     * @param _admin Guards the contract, runs and funds payouts, administers roles.
     * @param _approver The second pair of eyes. MUST be a different address from
     *        `_admin` — four-eyes is structural here, not a policy hope, so the split
     *        exists from the first block.
     * @param forwarder_ ERC-2771 forwarder, or address(0) for recipient-pays-gas only.
     */
    function initialize(address _admin, address _approver, address forwarder_) public initializer {
        __AccessControl_init();
        __Pausable_init();

        if (!(_admin != address(0))) revert InvalidAdmin();
        if (!(_approver != address(0))) revert InvalidApprover();
        if (!(_approver != _admin)) revert ApproverMustNotBeAdmin();

        nextDistributionId = 1;
        _trustedForwarder = forwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(FUNDER_ROLE, _admin);
        _grantRole(APPROVER_ROLE, _approver);

        if (forwarder_ != address(0)) {
            emit TrustedForwarderUpdated(forwarder_);
        }
    }

    // ============ Distribution setup ============

    /**
     * @dev Open a new distribution for one payout run.
     * @param _payoutToken The asset it pays in; address(0) for the native asset.
     * @param _mode Whether recipients claim or the operator pushes.
     * @param _expiry Unix time after which unclaimed money may be swept; 0 to never expire.
     * @param _runRef The payout run this pays, carried on-chain so a payment can be tied
     *        back to the statements it came from without trusting an off-chain index.
     * @param _entryMode How the list reaches the chain — see the contract notes.
     * @param _eligibilityRegistry Compliance gate for this distribution, immutable for
     *        its life; address(0) for none. See COMPLIANCE in the contract notes.
     */
    function createDistribution(
        address _payoutToken,
        PayoutMode _mode,
        EntryMode _entryMode,
        uint64 _expiry,
        bytes32 _runRef,
        address _eligibilityRegistry
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (uint256 distributionId) {
        if (!(_expiry == 0 || _expiry > block.timestamp)) revert ExpiryInThePast();
        // A push needs an on-chain list to read amounts from, so the combination is
        // refused here rather than half-supported and discovered at hand-over.
        if (_entryMode != EntryMode.Direct && _mode == PayoutMode.Auto) {
            revert RootCommittedDistributionsAreClaimOnly();
        }
        if (_eligibilityRegistry != address(0)) {
            // Fail at creation, not at the first claim, if the gate cannot answer.
            try IEligibilityRegistry(_eligibilityRegistry).isEligible(address(this)) returns (bool) {}
            catch {
                revert RegistryNotAnswering();
            }
        }

        distributionId = nextDistributionId;
        nextDistributionId++;

        Distribution storage dist = distributions[distributionId];
        dist.distributionId = distributionId;
        dist.payoutToken = _payoutToken;
        dist.mode = _mode;
        dist.entryMode = _entryMode;
        dist.state = DistributionState.Setup;
        dist.expiry = _expiry;
        dist.runRef = _runRef;
        dist.eligibilityRegistry = _eligibilityRegistry;
        dist.initialized = true;

        emit DistributionCreated(
            distributionId, _payoutToken, _mode, _entryMode, _expiry, _runRef, _eligibilityRegistry
        );
        return distributionId;
    }

    /**
     * @dev Write what each recipient is owed. Call repeatedly to add the whole list.
     * @notice An entry is written once. Setting the same recipient twice reverts rather
     * than overwriting, because a distribution's entries are the on-chain copy of a set
     * of statements and a silent second write would make the two disagree. Nothing is
     * funded during Setup, so correcting a mistake means opening a new distribution.
     */
    function setPayoutAmounts(uint256 distributionId, address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Setup)) revert NotInSetup();
        if (!(dist.entryMode == EntryMode.Direct)) revert NotADirectDistribution();
        if (!(recipients.length == amounts.length)) revert RecipientsAndAmountsLengthMismatch();
        if (!(recipients.length > 0 && recipients.length <= MAX_BATCH_SIZE)) revert InvalidBatchSize();

        uint256 added;
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];

            if (!(recipient != address(0))) revert InvalidRecipientAddress();
            if (!(amount > 0)) revert InvalidAmount();
            if (!(payoutAmounts[distributionId][recipient] == 0)) revert RecipientAlreadySet();

            payoutAmounts[distributionId][recipient] = amount;
            added += amount;
        }

        dist.totalOwed += added;
        dist.recipientCount += recipients.length;

        emit PayoutAmountsSet(distributionId, recipients.length, dist.totalOwed);
    }

    // ============ Four-eyes: the merkle list ============

    /**
     * @notice The id an approval must match to commit this exact list.
     * @dev Binds the root, the total AND the leaf count, so an approver cannot be shown
     * one list and asked to approve another.
     */
    function merkleRootProposalId(uint256 distributionId, bytes32 root, uint256 declaredTotal, uint256 recipientCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(ActionKind.SetMerkleRoot, distributionId, root, declaredTotal, recipientCount));
    }

    /**
     * @dev Propose committing the whole recipient list as one root.
     * @param root Merkle root over leaves of
     *        `keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))))` — the
     *        double-hashed leaf OpenZeppelin's `merkle-tree` library produces, which is
     *        what stops an internal node being replayed as a forged leaf.
     * @param declaredTotal The sum of every leaf. Unlike Direct mode the contract cannot
     *        verify this, which is exactly why committing it takes four eyes.
     * @param recipientCount How many leaves the tree has. Recorded so the published list
     *        can be checked for completeness, not only for its sum.
     */
    function proposeSetMerkleRoot(uint256 distributionId, bytes32 root, uint256 declaredTotal, uint256 recipientCount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Setup)) revert NotInSetup();
        if (!(dist.entryMode != EntryMode.Direct)) revert NotARootCommittedDistribution();
        if (!(root != bytes32(0))) revert InvalidRoot();
        if (!(declaredTotal > 0)) revert InvalidTotal();
        if (!(recipientCount > 0)) revert InvalidRecipientCount();
        // Re-committing after money is in would move the goalposts under the funding.
        if (!(dist.funded == 0)) revert AlreadyFunded();

        _propose(merkleRootProposalId(distributionId, root, declaredTotal, recipientCount), ActionKind.SetMerkleRoot);
    }

    /**
     * @dev Approve and execute: the list is committed and the distribution owes
     * `declaredTotal`.
     * @notice Before approving, recompute the root AND the sum from the published list.
     * The contract cannot do it for you — that is the trade for a list of any size — and
     * `MerkleRootSet` records all three figures so the check stays reproducible later.
     */
    function approveSetMerkleRoot(uint256 distributionId, bytes32 root, uint256 declaredTotal, uint256 recipientCount)
        external
        onlyRole(APPROVER_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Setup)) revert NotInSetup();
        if (!(dist.entryMode != EntryMode.Direct)) revert NotARootCommittedDistribution();
        if (!(dist.funded == 0)) revert AlreadyFunded();

        _approve(merkleRootProposalId(distributionId, root, declaredTotal, recipientCount), ActionKind.SetMerkleRoot);

        dist.merkleRoot = root;
        dist.totalOwed = declaredTotal;
        dist.recipientCount = recipientCount;

        emit MerkleRootSet(distributionId, root, declaredTotal, recipientCount);
    }

    /**
     * @dev Put money in, up to what the distribution owes. FUNDER only — the role that
     * moves money in is deliberately not the role that decides who gets it.
     * @notice Funding happens during Setup and may be split over several transactions;
     * over-funding is refused rather than left as a surplus nobody accounted for.
     */
    function fundPayoutToken(uint256 distributionId, uint256 amount)
        external
        payable
        onlyRole(FUNDER_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Setup)) revert NotInSetup();
        if (!(amount > 0)) revert InvalidAmount();
        if (!(dist.funded + amount <= dist.totalOwed)) revert ExceedsAmountOwed();

        address payoutToken = dist.payoutToken;
        if (payoutToken == address(0)) {
            if (!(msg.value == amount)) revert NativeAmountMismatch();
        } else {
            if (!(msg.value == 0)) revert NativeValueNotAccepted();
            IERC20(payoutToken).safeTransferFrom(_msgSender(), address(this), amount);
        }

        dist.funded += amount;
        dist.reserved += amount;
        reservedByToken[payoutToken] += amount;

        emit PayoutTokenFunded(distributionId, amount);
    }

    /**
     * @dev Close a distribution once nothing is left owed on it.
     * @notice For a distribution that still holds money, the way out is the sweep
     * after its expiry — so money can never be closed away from the people owed it.
     */
    function closeDistribution(uint256 distributionId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (!(dist.reserved == 0)) revert FundsStillReserved();

        dist.state = DistributionState.Done;
        emit DistributionStateAdvanced(distributionId, DistributionState.Done);
    }

    // ============ Four-eyes: finalize ============

    /**
     * @notice The id an approval must match to take this run live, bound to the run's
     * exact content (`totalOwed`, `recipientCount`) — if entries change after proposing,
     * the pending approval can no longer execute.
     */
    function finalizeProposalId(uint256 distributionId) public view returns (bytes32) {
        Distribution storage dist = distributions[distributionId];
        return
            keccak256(abi.encode(ActionKind.FinalizeDistribution, distributionId, dist.totalOwed, dist.recipientCount));
    }

    /**
     * @dev Propose taking a distribution live. Validates now what must also hold at
     * approval, so a doomed proposal fails at the first pair of eyes, not the second.
     */
    function proposeFinalizeDistribution(uint256 distributionId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Setup)) revert NotInSetup();
        if (!(dist.totalOwed > 0)) revert NothingToPay();
        if (!(dist.funded == dist.totalOwed)) revert NotFullyFunded();

        _propose(finalizeProposalId(distributionId), ActionKind.FinalizeDistribution);
    }

    /**
     * @dev Approve and execute: the distribution goes live. Refuses unless every entry
     * is covered, whoever approves.
     */
    function approveFinalizeDistribution(uint256 distributionId) external onlyRole(APPROVER_ROLE) whenNotPaused {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Setup)) revert NotInSetup();
        if (!(dist.totalOwed > 0)) revert NothingToPay();
        if (!(dist.funded == dist.totalOwed)) revert NotFullyFunded();

        _approve(finalizeProposalId(distributionId), ActionKind.FinalizeDistribution);

        dist.state = DistributionState.Payout;
        emit DistributionStateAdvanced(distributionId, DistributionState.Payout);
    }

    // ============ Paying ============

    /**
     * @dev Collect your own payout. The recipient pays the gas, unless a trusted
     * forwarder is set, in which case a relayer may pay it on their behalf.
     */
    function claimPayout(uint256 distributionId) external nonReentrant whenNotPaused {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.entryMode == EntryMode.Direct)) revert ProofRequired();

        address recipient = _msgSender();
        uint256 amount = payoutAmounts[distributionId][recipient];

        _settleClaim(dist, distributionId, recipient, recipient, amount);
    }

    /**
     * @dev Collect your own payout from a Merkle distribution, proving your entry.
     * @param amount The amount your leaf carries — from the published list.
     * @param proof The sibling hashes from your leaf to the committed root.
     * @notice The proof is what the entry is: nothing is stored per recipient until it
     * is paid, so a wrong amount simply hashes to a leaf the root does not contain.
     */
    function claimPayout(uint256 distributionId, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.entryMode == EntryMode.Merkle)) revert NoProofExpected();

        address recipient = _msgSender();

        // Double-hashed leaf: hashing once would let an internal node — which an
        // attacker can read straight off the published tree — be replayed as a leaf.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))));
        if (!(MerkleProof.verify(proof, dist.merkleRoot, leaf))) revert InvalidProof();

        _settleClaim(dist, distributionId, recipient, recipient, amount);
    }

    /**
     * @notice What a code's holder signs to redeem it — binding the code to the address
     * it should pay, to this contract and to this chain.
     * @dev Binding the receiver is the whole defence against front-running: a signature
     * lifted from the mempool names somebody else and pays them, not the thief. The chain
     * id and contract address stop it being replayed against a twin deployment.
     */
    function codeRedemptionDigest(uint256 distributionId, address receiver) public view returns (bytes32) {
        bytes32 payload = keccak256(abi.encode(block.chainid, address(this), distributionId, receiver));
        return MessageHashUtils.toEthSignedMessageHash(payload);
    }

    /**
     * @dev Redeem a giveaway code, naming the address it should pay.
     * @param amount The value this code carries, from the published code list.
     * @param receiver Who gets paid — chosen by whoever holds the code.
     * @param proof The code's inclusion proof against the committed root.
     * @param signature `codeRedemptionDigest(distributionId, receiver)` signed by the
     *        code's own key.
     * @notice The caller need not be the receiver: anyone may submit a redemption, which
     * is what lets the platform pay the gas for someone who has none. They still cannot
     * redirect it — the signature, not the sender, decides who is paid.
     */
    function claimWithCode(
        uint256 distributionId,
        uint256 amount,
        address receiver,
        bytes32[] calldata proof,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.entryMode == EntryMode.Code)) revert NotACodeDistribution();
        if (!(receiver != address(0))) revert InvalidReceiver();

        // Recover which code signed this, then ask the tree whether that code exists.
        address code = ECDSA.recover(codeRedemptionDigest(distributionId, receiver), signature);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(code, amount))));
        if (!(MerkleProof.verify(proof, dist.merkleRoot, leaf))) revert InvalidCode();

        // The ledger key is the CODE, not the receiver: a code is spent once, while one
        // person may hold several codes and one wallet may receive from all of them.
        _settleClaim(dist, distributionId, receiver, code, amount);

        emit CodeRedeemed(distributionId, code, receiver, amount);
    }

    /**
     * @dev Everything a claim does once the entitlement is established, however it was.
     * @param payee who receives the money.
     * @param ledgerKey what is spent — the payee, or the code that paid them.
     */
    function _settleClaim(
        Distribution storage dist,
        uint256 distributionId,
        address payee,
        address ledgerKey,
        uint256 amount
    ) private {
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (!(dist.mode == PayoutMode.Claim)) revert NotAClaimDistribution();
        if (!(dist.expiry == 0 || block.timestamp < dist.expiry)) revert DistributionExpired();
        if (paidOut[distributionId][ledgerKey]) revert AlreadyPaidOut();
        if (!(amount > 0)) revert NothingOwed();
        if (!(dist.reserved >= amount)) revert InsufficientFunds();
        _requireEligible(dist, payee);

        paidOut[distributionId][ledgerKey] = true;
        dist.paidTotal += amount;
        _release(dist, amount);

        _transferOut(dist.payoutToken, payee, amount);

        emit PayoutClaimed(distributionId, payee, amount);
    }

    /**
     * @dev Send payouts to recipients on an Auto distribution.
     * @notice Takes any subset of the list, so one row or a whole page can be sent from
     * the same call. Recipients already settled are skipped rather than reverted, so a
     * batch retried after a failure finishes the job instead of refusing it; an address
     * that is not on the list reverts, because that is an operator mistake, not a retry.
     */
    function batchDistributeAutomatic(uint256 distributionId, address[] calldata recipients)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (!(dist.mode == PayoutMode.Auto)) revert NotAnAutomaticDistribution();
        if (!(recipients.length > 0 && recipients.length <= MAX_BATCH_SIZE)) revert InvalidBatchSize();

        address payoutToken = dist.payoutToken;

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = payoutAmounts[distributionId][recipient];
            if (!(amount > 0)) revert NothingOwed();

            if (paidOut[distributionId][recipient]) continue;

            if (!(dist.reserved >= amount)) revert InsufficientFunds();
            // An ineligible recipient reverts the batch rather than being skipped:
            // pushing to them was an operator decision, and the honest answer is
            // "exclude that row", not a payment that silently did not happen.
            _requireEligible(dist, recipient);

            paidOut[distributionId][recipient] = true;
            dist.paidTotal += amount;
            _release(dist, amount);

            _transferOut(payoutToken, recipient, amount);

            emit PayoutSent(distributionId, recipient, amount);
        }
    }

    /**
     * @dev Record that a recipient was settled off-chain, without moving funds here.
     * @notice This is the on-chain receipt for a payment made another way — a bank
     * transfer, say, for someone on the list with no usable wallet. Their share stops
     * being reserved, so it returns to the tenant's withdrawable balance rather than
     * sitting here forever waiting for a claim that will never come.
     */
    function markPayoutAsPaid(uint256 distributionId, address recipient)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.entryMode == EntryMode.Direct)) revert ProofRequired();

        _settleOffChain(dist, distributionId, recipient, payoutAmounts[distributionId][recipient]);
    }

    /**
     * @dev Record off-chain settlement on a Merkle distribution, proving the entry.
     * @notice Single-recipient only: at merkle scale an off-chain settlement is the
     * exception (someone with no usable wallet), and a batch of proofs is a lot of
     * calldata to spend on an exception.
     */
    function markPayoutAsPaid(uint256 distributionId, address recipient, uint256 amount, bytes32[] calldata proof)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.entryMode == EntryMode.Merkle)) revert NoProofExpected();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))));
        if (!(MerkleProof.verify(proof, dist.merkleRoot, leaf))) revert InvalidProof();

        _settleOffChain(dist, distributionId, recipient, amount);
    }

    /// @dev Everything an off-chain receipt does once the entry is established.
    function _settleOffChain(Distribution storage dist, uint256 distributionId, address recipient, uint256 amount)
        private
    {
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (paidOut[distributionId][recipient]) revert AlreadyPaidOut();
        if (!(amount > 0)) revert NothingOwed();
        if (!(dist.reserved >= amount)) revert InsufficientFunds();

        paidOut[distributionId][recipient] = true;
        _release(dist, amount);

        emit PayoutMarkedAsPaid(distributionId, recipient, amount);
    }

    /**
     * @dev Record off-chain settlement for several recipients at once.
     * @notice Same skip-if-already-settled rule as `batchDistributeAutomatic`.
     */
    function batchMarkPayoutAsPaid(uint256 distributionId, address[] calldata recipients)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (!(dist.entryMode == EntryMode.Direct)) revert ProofRequired();
        if (!(recipients.length > 0 && recipients.length <= MAX_BATCH_SIZE)) revert InvalidBatchSize();

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = payoutAmounts[distributionId][recipient];
            if (!(amount > 0)) revert NothingOwed();

            if (paidOut[distributionId][recipient]) continue;

            if (!(dist.reserved >= amount)) revert InsufficientFunds();

            paidOut[distributionId][recipient] = true;
            _release(dist, amount);

            emit PayoutMarkedAsPaid(distributionId, recipient, amount);
        }
    }

    // ============ Four-eyes: sweep ============

    /// @notice The id an approval must match to sweep this run's remainder to `to`.
    function sweepProposalId(uint256 distributionId, address to) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.SweepUnclaimed, distributionId, to));
    }

    /**
     * @dev Propose returning what nobody collected. The amount is whatever is still
     * reserved at execution — claims arriving between proposal and approval keep
     * working, and simply shrink what comes back.
     */
    function proposeSweepUnclaimed(uint256 distributionId, address to) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (!(dist.expiry != 0)) revert DistributionNeverExpires();
        if (!(block.timestamp >= dist.expiry)) revert NotExpired();
        if (!(to != address(0))) revert InvalidRecipient();

        _propose(sweepProposalId(distributionId, to), ActionKind.SweepUnclaimed);
    }

    /// @dev Approve and execute: the remainder returns to the tenant and the run closes.
    function approveSweepUnclaimed(uint256 distributionId, address to)
        external
        onlyRole(APPROVER_ROLE)
        nonReentrant
        whenNotPaused
    {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        if (!(dist.state == DistributionState.Payout)) revert NotInPayout();
        if (!(dist.expiry != 0)) revert DistributionNeverExpires();
        if (!(block.timestamp >= dist.expiry)) revert NotExpired();
        if (!(to != address(0))) revert InvalidRecipient();

        _approve(sweepProposalId(distributionId, to), ActionKind.SweepUnclaimed);

        uint256 amount = dist.reserved;
        _release(dist, amount);
        dist.state = DistributionState.Done;

        if (amount > 0) {
            _transferOut(dist.payoutToken, to, amount);
        }

        emit UnclaimedSwept(distributionId, to, amount);
        emit DistributionStateAdvanced(distributionId, DistributionState.Done);
    }

    // ============ Four-eyes: withdraw surplus ============

    /// @notice The id an approval must match to withdraw exactly this surplus.
    function withdrawProposalId(address token, address to, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.EmergencyWithdraw, token, to, amount));
    }

    /**
     * @dev Propose withdrawing surplus — anything held here that is not reserved for an
     * unpaid entry. Deliberately unpausable: the emergency path must work in an emergency.
     */
    function proposeEmergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (!(to != address(0))) revert InvalidRecipient();

        _propose(withdrawProposalId(token, to, amount), ActionKind.EmergencyWithdraw);
    }

    /**
     * @dev Approve and execute the withdrawal.
     * @notice Cannot touch reserved money, whoever approves: on a contract holding many
     * runs at once, an unbounded withdrawal is one mistake away from spending the money
     * owed to a different run's recipients.
     */
    function approveEmergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyRole(APPROVER_ROLE)
        nonReentrant
    {
        if (!(to != address(0))) revert InvalidRecipient();

        _approve(withdrawProposalId(token, to, amount), ActionKind.EmergencyWithdraw);

        uint256 held = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 reserved = reservedByToken[token];
        if (!(held >= reserved)) revert ReserveAccountingBroken();
        if (!(amount <= held - reserved)) revert AmountIsReserved();

        _transferOut(token, to, amount);

        emit EmergencyWithdrawal(token, to, amount);
    }

    // ============ Four-eyes: trusted forwarder ============

    /// @notice The id an approval must match to point relaying at `forwarder_`.
    function forwarderProposalId(address forwarder_) public pure returns (bytes32) {
        return keccak256(abi.encode(ActionKind.SetTrustedForwarder, forwarder_));
    }

    /**
     * @dev Propose turning gasless claiming on (a forwarder address) or off (address(0)).
     * Four-eyes because a trusted forwarder can act as ANY recipient — pointing it at
     * the wrong contract is equivalent to handing over every unclaimed payout.
     */
    function proposeSetTrustedForwarder(address forwarder_) external onlyRole(ADMIN_ROLE) {
        _propose(forwarderProposalId(forwarder_), ActionKind.SetTrustedForwarder);
    }

    /// @dev Approve and execute the forwarder change.
    function approveSetTrustedForwarder(address forwarder_) external onlyRole(APPROVER_ROLE) {
        _approve(forwarderProposalId(forwarder_), ActionKind.SetTrustedForwarder);

        _trustedForwarder = forwarder_;
        emit TrustedForwarderUpdated(forwarder_);
    }

    // ============ Proposals ============

    /// @dev Record a proposal under `proposalId`. Re-proposing overwrites, restarting the clock.
    function _propose(bytes32 proposalId, ActionKind kind) private {
        proposals[proposalId] = Proposal({proposer: _msgSender(), proposedAt: uint64(block.timestamp)});
        emit ActionProposed(proposalId, kind, _msgSender());
    }

    /**
     * @dev Consume the proposal under `proposalId`, enforcing the two rules that make
     * this four eyes rather than two: the approver is not the proposer, and the
     * proposal has not lapsed.
     */
    function _approve(bytes32 proposalId, ActionKind kind) private {
        Proposal memory proposal = proposals[proposalId];
        if (!(proposal.proposer != address(0))) revert NoSuchProposal();
        if (!(block.timestamp <= uint256(proposal.proposedAt) + PROPOSAL_TTL)) revert ProposalExpired();
        if (!(proposal.proposer != _msgSender())) revert ApproverMustNotBeProposer();

        delete proposals[proposalId];
        emit ActionApproved(proposalId, kind, _msgSender());
    }

    // ============ Delayed role grants ============

    /// @notice The key a pending grant is filed under.
    function roleGrantId(bytes32 role, address account) public pure returns (bytes32) {
        return keccak256(abi.encode(role, account));
    }

    /**
     * @notice When a scheduled grant may be executed, and until when. Zero means there
     * is no pending grant for this pair.
     */
    function roleGrantWindow(bytes32 role, address account)
        public
        view
        returns (uint256 effectiveFrom, uint256 expiresAt)
    {
        uint64 scheduledAt = roleGrantScheduledAt[roleGrantId(role, account)];
        if (scheduledAt == 0) return (0, 0);

        effectiveFrom = uint256(scheduledAt) + ROLE_GRANT_DELAY;
        expiresAt = effectiveFrom + PROPOSAL_TTL;
    }

    /**
     * @dev Announce a role grant. It becomes executable after `ROLE_GRANT_DELAY`, and
     * lapses `PROPOSAL_TTL` after that so an old announcement cannot be dusted off
     * months later.
     */
    function scheduleRoleGrant(bytes32 role, address account) external onlyRole(getRoleAdmin(role)) {
        if (!(account != address(0))) revert InvalidAccount();
        if (hasRole(role, account)) revert AlreadyHasRole();

        roleGrantScheduledAt[roleGrantId(role, account)] = uint64(block.timestamp);

        emit RoleGrantScheduled(role, account, block.timestamp + ROLE_GRANT_DELAY, _msgSender());
    }

    /**
     * @dev Cancel an announced grant, before it takes effect.
     * @notice The guardian may cancel as well as the role's own admin — a veto that does
     * not require holding the key that scheduled it.
     */
    function cancelRoleGrant(bytes32 role, address account) external {
        if (!(hasRole(getRoleAdmin(role), _msgSender()) || hasRole(ADMIN_ROLE, _msgSender()))) {
            revert NotAllowedToCancel();
        }

        bytes32 id = roleGrantId(role, account);
        if (!(roleGrantScheduledAt[id] != 0)) revert NoPendingGrant();

        delete roleGrantScheduledAt[id];
        emit RoleGrantCancelled(role, account, _msgSender());
    }

    /**
     * @dev Grant a role that was announced at least `ROLE_GRANT_DELAY` ago.
     * @notice Overrides AccessControl's immediate grant. The initial roles set in
     * `initialize` bypass this — they are established before the contract can do
     * anything, and there is nobody yet for the delay to protect against.
     */
    function grantRole(bytes32 role, address account)
        public
        override(AccessControlUpgradeable)
        onlyRole(getRoleAdmin(role))
    {
        (uint256 effectiveFrom, uint256 expiresAt) = roleGrantWindow(role, account);
        if (!(effectiveFrom != 0)) revert GrantNotScheduled();
        if (!(block.timestamp >= effectiveFrom)) revert GrantStillWaiting();
        if (!(block.timestamp <= expiresAt)) revert GrantExpired();

        delete roleGrantScheduledAt[roleGrantId(role, account)];
        _grantRole(role, account);
    }

    /// @dev Withdraw a pending proposal — its proposer changing their mind, or an admin.
    function cancelProposal(bytes32 proposalId) external {
        Proposal memory proposal = proposals[proposalId];
        if (!(proposal.proposer != address(0))) revert NoSuchProposal();
        if (!(proposal.proposer == _msgSender() || hasRole(ADMIN_ROLE, _msgSender()))) revert NotAllowedToCancel();

        delete proposals[proposalId];
        emit ActionCancelled(proposalId, _msgSender());
    }

    // ============ Admin ============

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ Views ============

    function getDistribution(uint256 distributionId) external view returns (Distribution memory dist) {
        return distributions[distributionId];
    }

    /// @notice What a recipient is owed. Always 0 on a Merkle distribution — nothing is
    /// stored per recipient there; the published list plus a proof is the entry.
    function getPayoutAmount(uint256 distributionId, address recipient) external view returns (uint256 amount) {
        return payoutAmounts[distributionId][recipient];
    }

    /// @notice Whether `proof` really places `(recipient, amount)` in this distribution's
    /// committed list. Lets a recipient check a proof before spending gas on it.
    function verifyEntry(uint256 distributionId, address recipient, uint256 amount, bytes32[] calldata proof)
        public
        view
        returns (bool)
    {
        Distribution storage dist = distributions[distributionId];
        if (!dist.initialized || dist.entryMode == EntryMode.Direct) return false;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))));
        return MerkleProof.verify(proof, dist.merkleRoot, leaf);
    }

    /// @notice What still has to be paid in before this distribution can go live.
    function remainingFunding(uint256 distributionId) external view returns (uint256) {
        Distribution storage dist = distributions[distributionId];
        if (!(dist.initialized)) revert DistributionNotFound();
        return dist.totalOwed - dist.funded;
    }

    function getRecipientCount(uint256 distributionId) external view returns (uint256 count) {
        return distributions[distributionId].recipientCount;
    }

    /// @notice Whether this recipient could claim right now, and for how much.
    /// @dev Direct distributions only — a Merkle entry needs its proof, below.
    function canClaimPayout(uint256 distributionId, address recipient)
        external
        view
        returns (bool canClaim, uint256 amount)
    {
        Distribution storage dist = distributions[distributionId];
        if (dist.entryMode != EntryMode.Direct) return (false, 0);

        amount = payoutAmounts[distributionId][recipient];
        canClaim = _claimable(dist, distributionId, recipient, amount);
        if (!canClaim) amount = 0;
    }

    /// @notice The same question for a Merkle distribution, answered against a proof.
    function canClaimPayout(uint256 distributionId, address recipient, uint256 amount, bytes32[] calldata proof)
        external
        view
        returns (bool canClaim)
    {
        Distribution storage dist = distributions[distributionId];
        if (dist.entryMode != EntryMode.Merkle) return false;
        if (!verifyEntry(distributionId, recipient, amount, proof)) return false;

        return _claimable(dist, distributionId, recipient, amount);
    }

    /// @dev Every condition a claim must meet, once the amount is known.
    function _claimable(Distribution storage dist, uint256 distributionId, address recipient, uint256 amount)
        private
        view
        returns (bool)
    {
        if (!dist.initialized || dist.state != DistributionState.Payout || dist.mode != PayoutMode.Claim) {
            return false;
        }
        if (dist.expiry != 0 && block.timestamp >= dist.expiry) return false;
        if (paidOut[distributionId][recipient]) return false;
        if (!_isEligible(dist, recipient)) return false;

        return amount > 0 && dist.reserved >= amount;
    }

    function trustedForwarder() public view virtual returns (address) {
        return _trustedForwarder;
    }

    function isTrustedForwarder(address forwarder) public view virtual returns (bool) {
        return forwarder != address(0) && forwarder == _trustedForwarder;
    }

    // ============ Internals ============

    /**
     * @dev Enforce the distribution's compliance gate, if it has one. Fails CLOSED: a
     * registry that reverts or cannot be reached blocks the payment — for a gated
     * distribution, "unknown" must never mean "paid".
     */
    function _requireEligible(Distribution storage dist, address recipient) private view {
        address registry = dist.eligibilityRegistry;
        if (registry == address(0)) return;

        try IEligibilityRegistry(registry).isEligible(recipient) returns (bool eligible) {
            if (!(eligible)) revert RecipientNotEligible();
        } catch {
            revert EligibilityCheckUnavailable();
        }
    }

    /// @dev Non-reverting twin of {_requireEligible}, for views.
    function _isEligible(Distribution storage dist, address recipient) private view returns (bool) {
        address registry = dist.eligibilityRegistry;
        if (registry == address(0)) return true;

        try IEligibilityRegistry(registry).isEligible(recipient) returns (bool eligible) {
            return eligible;
        } catch {
            return false;
        }
    }

    /// @dev Stop reserving `amount` on this distribution, and for its asset overall.
    function _release(Distribution storage dist, uint256 amount) private {
        dist.reserved -= amount;
        reservedByToken[dist.payoutToken] -= amount;
    }

    function _transferOut(address token, address to, uint256 amount) private {
        if (amount == 0) return;

        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            if (!(success)) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ============ ERC-2771 context ============
    //
    // The forwarder lives in storage, not in an immutable, so one implementation can
    // serve tenants who pay their recipients' gas and tenants who do not.

    function _msgSender() internal view virtual override(ContextUpgradeable) returns (address) {
        uint256 calldataLength = msg.data.length;
        if (calldataLength >= _CONTEXT_SUFFIX_LENGTH && isTrustedForwarder(msg.sender)) {
            unchecked {
                return address(bytes20(msg.data[calldataLength - _CONTEXT_SUFFIX_LENGTH:]));
            }
        }
        return super._msgSender();
    }

    function _msgData() internal view virtual override(ContextUpgradeable) returns (bytes calldata) {
        uint256 calldataLength = msg.data.length;
        if (calldataLength >= _CONTEXT_SUFFIX_LENGTH && isTrustedForwarder(msg.sender)) {
            unchecked {
                return msg.data[:calldataLength - _CONTEXT_SUFFIX_LENGTH];
            }
        }
        return super._msgData();
    }

    function _contextSuffixLength() internal view virtual override(ContextUpgradeable) returns (uint256) {
        return _CONTEXT_SUFFIX_LENGTH;
    }

    /// @dev Native asset arrives through `fundPayoutToken`, which accounts for it. A bare
    /// transfer is accepted but reserved for nothing, so it is surplus until withdrawn.
    receive() external payable {}
}
