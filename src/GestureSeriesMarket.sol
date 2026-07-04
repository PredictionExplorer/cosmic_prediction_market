// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICosmicSignatureGame} from "./ICosmicSignatureGame.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title GestureSeriesMarket
/// @notice A perpetual series of binary prediction markets, denominated in CST,
/// on the question: "will this Cosmic Signature round end with more gestures
/// (bids) than the previous round?" — one market per round, forever, in a
/// single contract with no owner, no admin keys and no upgradability.
///
/// Mechanism, in short:
///
/// - Markets launch themselves: the first `addLiquidity` for the current
///   round — or ANY future round — initializes that round's market. Nothing
///   needs to be deployed or configured per round.
///
/// - The threshold (the previous round's final gesture count) is locked
///   lazily: it does not exist yet while a round is still in the future, and
///   is snapshotted from the game by the first `addLiquidity`, bet or
///   `resolve` that touches the round once the game has reached it. The value
///   is already public and final before any lock can happen, so lock timing
///   is not a degree of freedom anyone can exploit. Rounds strictly in the
///   past can never be initialized or traded — only exited.
///
/// - Each round has two outcome tokens, YES and NO, tracked as internal
///   balances. 1 CST mints a complete set of 1 YES + 1 NO, and a complete set
///   is always redeemable for 1 CST, so the contract is solvent by
///   construction. YES pays 1 CST iff the round's final count is STRICTLY
///   greater than the threshold (a tie means NO wins); NO pays 1 CST otherwise.
///
/// - Each round has ONE Uniswap-style constant-product pool (x * y = k)
///   between YES and NO. The marginal price of YES,
///   reserveNo / (reserveYes + reserveNo), is the market's implied probability.
///
/// - The trading fee is a LIQUIDITY-WEIGHTED VOTE. Every LP declares the fee
///   they want when depositing (and can re-declare anytime); the pool charges
///   the share-weighted average of all declarations:
///
///       currentFeeBps = sum(shares_i * declaredFee_i) / totalShares
///
///   Declarations set what bettors pay; fee EARNINGS are split pro rata by
///   shares regardless of what each LP declared. Your declaration is a vote,
///   not a private price — LPs who dislike the average can re-vote or leave
///   at any moment.
///
/// - `betYes(...)` mints sets with your CST and swaps the NO half into the
///   pool, leaving you holding only YES (mirror image for `betNo`). To exit
///   early, buy the opposite side and `redeemSets`.
///
/// - The gesture count is public and only ever increases, so the instant it
///   exceeds the threshold the outcome is decided: betting and adding
///   liquidity halt atomically and anyone may `resolve` the round early for
///   YES. Otherwise the round resolves when the game's round counter advances.
///   While a round is still in the future nothing is ever provably certain
///   (its own count is zero and the threshold is unknown), so future-round
///   trading never halts and future rounds are never resolvable.
///
/// - When the game's round counter passes a round, that round's market
///   freezes: betting, adding liquidity and minting sets all revert, while
///   every exit — `removeLiquidity`, `claimFees`, `redeemSets` (until
///   resolution) and `claim` (after it) — keeps working forever.
///
/// - After resolution, `claim` pays winning tokens 1:1. LP positions are never
///   confiscated or swept: `removeLiquidity` and `claimFees` work at any time,
///   before or after resolution.
///
/// Hardening notes (see the test suite for the attacks these defeat):
///
/// - Every trade and liquidity change takes explicit slippage bounds and a
///   deadline. Liquidity pulls, sandwiches, stale transactions AND sudden
///   fee-vote jumps all fail the same way: execution below your signed floor
///   reverts.
/// - First-deposit share inflation is blocked by a minimum initial deposit,
///   permanently locked dead shares, and rounding that always favors the pool.
/// - Reserves and balances are internal accounting: direct CST donations to
///   the contract change nothing.
/// - All state-mutating functions are non-reentrant and follow
///   checks-effects-interactions; rounding always favors the contract, so it
///   can never owe more CST than it holds.
/// - An LP pulling the pool right after your bet fills cannot touch you:
///   your fill already beat your `minTokensOut` floor, every outstanding set
///   stays backed 1:1 by CST held here, and your exits (hold to resolution,
///   or buy the opposite side — bets always return at least their net input
///   in tokens — and `redeemSets`) never close. Liquidity DEPTH, however, is
///   never guaranteed; size positions accordingly, especially in far-future
///   rounds where resolution may be a long way off.
contract GestureSeriesMarket {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Hard cap on any fee declaration (and thus on the average): 10%.
    uint256 internal constant MAX_FEE_BPS = 1_000;
    /// @dev A pool's first deposit must be at least this much CST. Together
    /// with `DEAD_SHARES` this makes classic share-inflation attacks
    /// unprofitable by many orders of magnitude.
    uint256 internal constant MIN_INITIAL_LIQUIDITY = 1e15;
    /// @dev Shares permanently locked (credited to address(0)) on a pool's
    /// first deposit, Uniswap v2 style. They carry the opener's fee
    /// declaration forever (wei-scale weight, economically inert).
    uint256 internal constant DEAD_SHARES = 1e3;
    /// @dev The first LP seeds the pool at their chosen YES probability,
    /// clamped to [1%, 99%] so both reserves are meaningfully nonzero.
    uint256 internal constant MIN_PROB_BPS = 100;
    uint256 internal constant MAX_PROB_BPS = 9_900;

    ICosmicSignatureGame public immutable game;
    IERC20 public immutable cst;

    struct Pool {
        uint256 reserveYes;
        uint256 reserveNo;
        uint256 totalShares;
        /// @dev Cumulative CST fees per share, 1e18-scaled (MasterChef pattern).
        uint256 accFeePerShare;
        /// @dev CST held for this pool's LPs' unclaimed fees. Kept explicit so
        /// solvency is provable: contract balance >= sets outstanding + fee reserves.
        uint256 feeReserve;
        /// @dev The fee-vote ledger: sum over all holders of
        /// `shares * declaredFeeBps`. The pool's fee is `feeWeight / totalShares`.
        uint256 feeWeight;
        mapping(address => uint256) sharesOf;
        mapping(address => uint256) feeDebtOf;
        /// @dev Each LP's current fee declaration (uniform across their shares).
        mapping(address => uint16) feeDeclarationOf;
    }

    struct RoundMarket {
        bool initialized;
        /// @dev True once `threshold` has been snapshotted from the game.
        /// False while the round is still in the future (the previous round
        /// hasn't finished, so its final count doesn't exist yet).
        bool thresholdSet;
        bool resolved;
        bool yesWon;
        /// @dev Final gesture count of the previous round; YES wins iff this
        /// round's final count is strictly greater. Meaningless until
        /// `thresholdSet`.
        uint256 threshold;
        Pool pool;
        mapping(address => uint256) yesBalance;
        mapping(address => uint256) noBalance;
    }

    mapping(uint256 => RoundMarket) internal _rounds;

    uint256 private _lock = 1;

    event RoundInitialized(uint256 indexed roundId);
    event ThresholdLocked(uint256 indexed roundId, uint256 threshold);
    event SetsMinted(uint256 indexed roundId, address indexed user, uint256 amount);
    event SetsRedeemed(uint256 indexed roundId, address indexed user, uint256 amount);
    event Bet(uint256 indexed roundId, address indexed user, bool yes, uint256 cstIn, uint256 netIn, uint256 tokensOut);
    event LiquidityAdded(
        uint256 indexed roundId,
        address indexed provider,
        uint256 cstIn,
        uint16 declaredFeeBps,
        uint256 sharesOut,
        uint256 yesToPool,
        uint256 noToPool
    );
    event LiquidityRemoved(
        uint256 indexed roundId,
        address indexed provider,
        uint256 sharesIn,
        uint256 yesOut,
        uint256 noOut,
        uint256 feesOut
    );
    event FeeDeclarationUpdated(uint256 indexed roundId, address indexed provider, uint16 oldFeeBps, uint16 newFeeBps);
    event FeesClaimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event Resolved(uint256 indexed roundId, uint256 finalCount, bool yesWon);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 cstOut);

    error InvalidParams();
    error RoundNotInitialized();
    error RoundNotActive();
    error OutcomeDecided();
    error AlreadyResolved();
    error NotResolved();
    error NotResolvable();
    error InsufficientLiquidity();
    error InsufficientShares();
    error Slippage();
    error DeadlineExpired();
    error TransferFailed();
    error ReentrantCall();

    modifier nonReentrant() {
        if (_lock != 1) revert ReentrantCall();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param game_ The CosmicSignatureGame proxy; CST is read from it.
    constructor(ICosmicSignatureGame game_) {
        if (address(game_) == address(0)) revert InvalidParams();
        game = game_;
        address token = game_.token();
        if (token == address(0)) revert InvalidParams();
        cst = IERC20(token);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Provide `cstIn` CST of liquidity to round `roundId`'s pool and
    /// receive LP shares. `declaredFeeBps` is your fee vote (0–1000 bps): the
    /// pool charges the share-weighted average of all LPs' declarations, and
    /// this call re-declares YOUR ENTIRE position at `declaredFeeBps`.
    ///
    /// Works for the current round and ANY future round (never past rounds):
    /// the first deposit for a round initializes its market, and the first
    /// deposit into the pool opens it at `initialYesProbBps` (ignored
    /// afterwards; later deposits join at the pool's current ratio, with any
    /// excess outcome tokens credited back to your balances). Providing
    /// across the threshold reveal (the moment the previous round ends) is an
    /// informed-flow risk LPs opt into, priced via their fee vote.
    /// @param minSharesOut Slippage guard on the LP shares received.
    /// @param deadline Unix timestamp after which the transaction reverts.
    function addLiquidity(
        uint256 roundId,
        uint256 cstIn,
        uint16 declaredFeeBps,
        uint256 initialYesProbBps,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 sharesOut) {
        _checkDeadline(deadline);
        if (cstIn == 0 || declaredFeeBps > MAX_FEE_BPS) revert InvalidParams();

        RoundMarket storage rm = _rounds[roundId];
        uint256 currentRound = game.roundNum();
        if (!rm.initialized) {
            _initRound(rm, roundId, currentRound);
        } else if (roundId < currentRound) {
            revert RoundNotActive();
        }
        _syncThreshold(rm, roundId, currentRound);
        if (rm.resolved) revert AlreadyResolved();
        // Once the outcome is certain, adding liquidity would only donate to
        // arbitrageurs; block it in the same breath as betting.
        if (_outcomeDecided(rm, roundId)) revert OutcomeDecided();

        _pullCst(msg.sender, cstIn);
        Pool storage p = rm.pool;

        if (p.totalShares == 0) {
            sharesOut = _openPool(rm, p, roundId, cstIn, declaredFeeBps, initialYesProbBps);
        } else {
            sharesOut = _joinPool(rm, p, roundId, cstIn, declaredFeeBps);
        }
        if (sharesOut < minSharesOut) revert Slippage();
    }

    /// @notice Burn `shares` LP shares of round `roundId`'s pool for a
    /// pro-rata cut of its reserves (credited to your YES/NO balances) plus
    /// all your accrued fees (paid in CST). Works at ANY time — while the
    /// round is live, once the outcome is decided, and after resolution — so
    /// liquidity can never be trapped. Removed shares stop voting on the fee.
    function removeLiquidity(uint256 roundId, uint256 shares, uint256 minYesOut, uint256 minNoOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 yesOut, uint256 noOut, uint256 feesOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _rounds[roundId];
        Pool storage p = rm.pool;
        uint256 userShares = p.sharesOf[msg.sender];
        if (shares == 0 || shares > userShares) revert InsufficientShares();

        feesOut = _pendingFees(p, msg.sender);
        yesOut = p.reserveYes * shares / p.totalShares;
        noOut = p.reserveNo * shares / p.totalShares;
        if (yesOut < minYesOut || noOut < minNoOut) revert Slippage();

        p.reserveYes -= yesOut;
        p.reserveNo -= noOut;
        p.sharesOf[msg.sender] = userShares - shares;
        p.totalShares -= shares;
        p.feeWeight -= shares * uint256(p.feeDeclarationOf[msg.sender]);
        p.feeDebtOf[msg.sender] = (userShares - shares) * p.accFeePerShare / ONE;
        rm.yesBalance[msg.sender] += yesOut;
        rm.noBalance[msg.sender] += noOut;
        if (feesOut > 0) {
            p.feeReserve -= feesOut;
            _pushCst(msg.sender, feesOut);
        }
        emit LiquidityRemoved(roundId, msg.sender, shares, yesOut, noOut, feesOut);
    }

    /// @notice Re-cast your fee vote for round `roundId` without moving funds:
    /// your entire share position switches to `newFeeBps`. Works anytime.
    function updateFeeDeclaration(uint256 roundId, uint16 newFeeBps) external nonReentrant {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidParams();
        Pool storage p = _rounds[roundId].pool;
        uint256 shares = p.sharesOf[msg.sender];
        if (shares == 0) revert InsufficientShares();
        uint16 oldFeeBps = p.feeDeclarationOf[msg.sender];
        p.feeWeight = p.feeWeight - shares * uint256(oldFeeBps) + shares * uint256(newFeeBps);
        p.feeDeclarationOf[msg.sender] = newFeeBps;
        emit FeeDeclarationUpdated(roundId, msg.sender, oldFeeBps, newFeeBps);
    }

    /// @notice Pay out your accrued (so far unclaimed) fees from round
    /// `roundId`'s pool without touching your shares. Works anytime.
    function claimFees(uint256 roundId) external nonReentrant returns (uint256 feesOut) {
        Pool storage p = _rounds[roundId].pool;
        feesOut = _pendingFees(p, msg.sender);
        p.feeDebtOf[msg.sender] = p.sharesOf[msg.sender] * p.accFeePerShare / ONE;
        if (feesOut > 0) {
            p.feeReserve -= feesOut;
            _pushCst(msg.sender, feesOut);
        }
        emit FeesClaimed(roundId, msg.sender, feesOut);
    }

    // ---------------------------------------------------------------------
    // Sets
    // ---------------------------------------------------------------------

    /// @notice Deposit CST and receive YES and NO in equal amounts
    /// (1 CST = 1 YES + 1 NO). Requires the round's market to exist and the
    /// round to be current or future — a set is value-neutral (it always
    /// redeems or claims for exactly 1 CST), so minting stays open even once
    /// the outcome is decided, and only closes when the round is over.
    function mintSets(uint256 roundId, uint256 amount) external nonReentrant {
        RoundMarket storage rm = _rounds[roundId];
        if (!rm.initialized) revert RoundNotInitialized();
        if (rm.resolved) revert AlreadyResolved();
        if (roundId < game.roundNum()) revert RoundNotActive();
        if (amount == 0) revert InvalidParams();
        _pullCst(msg.sender, amount);
        rm.yesBalance[msg.sender] += amount;
        rm.noBalance[msg.sender] += amount;
        emit SetsMinted(roundId, msg.sender, amount);
    }

    /// @notice Burn equal amounts of YES and NO and get the CST back. Allowed
    /// any time before resolution (even after the round ends), so paired
    /// tokens are always an exit.
    function redeemSets(uint256 roundId, uint256 amount) external nonReentrant {
        RoundMarket storage rm = _rounds[roundId];
        if (rm.resolved) revert AlreadyResolved();
        if (amount == 0) revert InvalidParams();
        uint256 yes = rm.yesBalance[msg.sender];
        uint256 no = rm.noBalance[msg.sender];
        if (amount > yes || amount > no) revert InsufficientShares();
        rm.yesBalance[msg.sender] = yes - amount;
        rm.noBalance[msg.sender] = no - amount;
        _pushCst(msg.sender, amount);
        emit SetsRedeemed(roundId, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Betting
    // ---------------------------------------------------------------------

    /// @notice Bet `cstIn` CST on YES ("this round beats the last one"). You
    /// receive YES tokens. Works for the current round and any future round.
    /// The fee charged is the pool's current share-weighted average
    /// (`currentFeeBps`).
    /// @param minTokensOut Slippage guard; reverts if the bet would yield
    /// fewer tokens (your protection against liquidity pulls, sandwiches AND
    /// fee-vote jumps alike).
    function betYes(uint256 roundId, uint256 cstIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _prepareTradableRound(roundId);
        tokensOut = _bet(rm, roundId, true, cstIn, minTokensOut);
    }

    /// @notice Bet `cstIn` CST on NO ("it won't beat the last round"). You
    /// receive NO tokens.
    function betNo(uint256 roundId, uint256 cstIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _prepareTradableRound(roundId);
        tokensOut = _bet(rm, roundId, false, cstIn, minTokensOut);
    }

    // ---------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------

    /// @notice Resolve round `roundId`. Callable by anyone once the round is
    /// over (the game's round counter advanced), or EARLY the moment the live
    /// count exceeds the threshold — the count only ever increases, so YES is
    /// already certain then. Future rounds are never resolvable: nothing
    /// about them is certain before they start. Works no matter how long ago
    /// the round ended (the threshold is locked here if nobody ever touched
    /// the round while it was current — the game value is final either way).
    function resolve(uint256 roundId) external nonReentrant {
        RoundMarket storage rm = _rounds[roundId];
        if (!rm.initialized) revert RoundNotInitialized();
        if (rm.resolved) revert AlreadyResolved();

        uint256 currentRound = game.roundNum();
        if (currentRound < roundId) revert NotResolvable();
        _syncThreshold(rm, roundId, currentRound);

        uint256 count = game.bidderAddresses(roundId);
        bool yesWon_;
        if (currentRound > roundId) {
            yesWon_ = count > rm.threshold; // strict: a tie means NO wins
        } else if (count > rm.threshold) {
            yesWon_ = true; // early resolution: outcome already certain
        } else {
            revert NotResolvable();
        }
        rm.resolved = true;
        rm.yesWon = yesWon_;
        emit Resolved(roundId, count, yesWon_);
    }

    /// @notice Redeem all your outcome tokens of a resolved round: winning
    /// tokens pay 1 CST each, losing tokens pay nothing.
    function claim(uint256 roundId) external nonReentrant returns (uint256 cstOut) {
        RoundMarket storage rm = _rounds[roundId];
        if (!rm.resolved) revert NotResolved();
        cstOut = rm.yesWon ? rm.yesBalance[msg.sender] : rm.noBalance[msg.sender];
        rm.yesBalance[msg.sender] = 0;
        rm.noBalance[msg.sender] = 0;
        if (cstOut > 0) _pushCst(msg.sender, cstOut);
        emit Claimed(roundId, msg.sender, cstOut);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Full lifecycle state of a round's market in one call.
    /// @return initialized Whether the round's market exists.
    /// @return thresholdKnown Whether the threshold is knowable: either
    /// already locked in storage, or final in the game and about to be locked
    /// by the next touch (in which case `threshold` reports that live value).
    /// False while the round is still in the future.
    /// @return resolved Whether the round has been resolved.
    /// @return yesWon The resolved outcome (meaningless until `resolved`).
    /// @return threshold The effective threshold (0 while unknowable).
    /// @return currentCount The round's live gesture count.
    /// @return roundActive Whether this is the game's current round.
    /// @return outcomeDecided Whether YES is already provably certain.
    function roundState(uint256 roundId)
        external
        view
        returns (
            bool initialized,
            bool thresholdKnown,
            bool resolved,
            bool yesWon,
            uint256 threshold,
            uint256 currentCount,
            bool roundActive,
            bool outcomeDecided
        )
    {
        RoundMarket storage rm = _rounds[roundId];
        initialized = rm.initialized;
        resolved = rm.resolved;
        yesWon = rm.yesWon;
        uint256 currentRound = game.roundNum();
        thresholdKnown = rm.thresholdSet || (roundId != 0 && currentRound >= roundId);
        threshold = rm.thresholdSet ? rm.threshold : (thresholdKnown ? game.bidderAddresses(roundId - 1) : 0);
        currentCount = game.bidderAddresses(roundId);
        roundActive = currentRound == roundId;
        outcomeDecided = thresholdKnown && currentCount > threshold;
    }

    /// @notice Reserves, share/fee accounting, and the live fee of a round's pool.
    function pool(uint256 roundId)
        external
        view
        returns (
            uint256 reserveYes,
            uint256 reserveNo,
            uint256 totalShares,
            uint256 accFeePerShare,
            uint256 feeReserve,
            uint256 feeWeight,
            uint256 feeBps
        )
    {
        Pool storage p = _rounds[roundId].pool;
        return (p.reserveYes, p.reserveNo, p.totalShares, p.accFeePerShare, p.feeReserve, p.feeWeight, _poolFeeBps(p));
    }

    /// @notice The fee a bet pays right now: the share-weighted average of
    /// all LP declarations (0 while the pool is unopened).
    function currentFeeBps(uint256 roundId) external view returns (uint256) {
        return _poolFeeBps(_rounds[roundId].pool);
    }

    /// @notice A user's outcome-token balances for a round.
    function balancesOf(uint256 roundId, address user) external view returns (uint256 yes, uint256 no) {
        RoundMarket storage rm = _rounds[roundId];
        return (rm.yesBalance[user], rm.noBalance[user]);
    }

    /// @notice A user's LP position: shares, fees claimable now, and their
    /// current fee declaration (vote).
    function lpPositionOf(uint256 roundId, address user)
        external
        view
        returns (uint256 shares, uint256 pendingFees, uint16 declaredFeeBps)
    {
        Pool storage p = _rounds[roundId].pool;
        return (p.sharesOf[user], _pendingFees(p, user), p.feeDeclarationOf[user]);
    }

    /// @notice YES tokens a `betYes(roundId, cstIn, ...)` would return right
    /// now at the current weighted fee (0 if the pool has no liquidity).
    function quoteBetYes(uint256 roundId, uint256 cstIn) external view returns (uint256) {
        return _quote(_rounds[roundId].pool, true, cstIn);
    }

    /// @notice NO tokens a `betNo(roundId, cstIn, ...)` would return right now.
    function quoteBetNo(uint256 roundId, uint256 cstIn) external view returns (uint256) {
        return _quote(_rounds[roundId].pool, false, cstIn);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Initializes the market for `roundId`: the current round or any
    /// future round. Past rounds can never be initialized (their outcome is
    /// public), and round 0 has no previous round to compare against. The
    /// threshold is NOT read here — it may not exist yet; `_syncThreshold`
    /// locks it as soon as it is final.
    function _initRound(RoundMarket storage rm, uint256 roundId, uint256 currentRound) internal {
        if (roundId == 0 || roundId < currentRound) revert RoundNotActive();
        rm.initialized = true;
        emit RoundInitialized(roundId);
    }

    /// @dev Locks the threshold — the previous round's final gesture count —
    /// the first time the round is touched once the game has reached it.
    /// `bidderAddresses(roundId - 1)` is immutable from that moment on, so
    /// the locked value is identical no matter when the lock happens; the
    /// snapshot exists so decided-checks and resolution stay internally
    /// consistent forever after. Ran (idempotently) by every threshold-
    /// dependent entry point: `addLiquidity`, both bets, and `resolve`.
    function _syncThreshold(RoundMarket storage rm, uint256 roundId, uint256 currentRound) internal {
        if (!rm.thresholdSet && currentRound >= roundId) {
            uint256 t = game.bidderAddresses(roundId - 1);
            rm.threshold = t;
            rm.thresholdSet = true;
            emit ThresholdLocked(roundId, t);
        }
    }

    /// @dev YES is provably certain: the live count exceeds the locked
    /// threshold. Never true while the round is still in the future — its
    /// count is zero and the threshold doesn't exist yet, so nothing can be
    /// certain and future-round trading never halts.
    function _outcomeDecided(RoundMarket storage rm, uint256 roundId) internal view returns (bool) {
        return rm.thresholdSet && game.bidderAddresses(roundId) > rm.threshold;
    }

    /// @dev First deposit into the pool: seeds reserves at the LP's chosen YES
    /// probability using all `cstIn` minted sets — the surplus side stays with
    /// the LP as outcome tokens. Locks `DEAD_SHARES` forever (inflation
    /// guard); the dead shares carry the opener's fee declaration.
    function _openPool(
        RoundMarket storage rm,
        Pool storage p,
        uint256 roundId,
        uint256 cstIn,
        uint16 declaredFeeBps,
        uint256 initialYesProbBps
    ) internal returns (uint256 sharesOut) {
        if (cstIn < MIN_INITIAL_LIQUIDITY) revert InsufficientLiquidity();
        if (initialYesProbBps < MIN_PROB_BPS || initialYesProbBps > MAX_PROB_BPS) revert InvalidParams();

        // Price of YES = reserveNo / (reserveYes + reserveNo) = prob. The
        // larger reserve takes the full deposit, the smaller one is scaled.
        uint256 rY;
        uint256 rN;
        if (initialYesProbBps <= BPS / 2) {
            rY = cstIn;
            rN = cstIn * initialYesProbBps / (BPS - initialYesProbBps);
        } else {
            rN = cstIn;
            rY = cstIn * (BPS - initialYesProbBps) / initialYesProbBps;
        }
        p.reserveYes = rY;
        p.reserveNo = rN;
        rm.yesBalance[msg.sender] += cstIn - rY;
        rm.noBalance[msg.sender] += cstIn - rN;

        p.sharesOf[address(0)] = DEAD_SHARES;
        sharesOut = cstIn - DEAD_SHARES;
        p.sharesOf[msg.sender] = sharesOut;
        p.totalShares = cstIn;
        p.feeWeight = cstIn * uint256(declaredFeeBps);
        p.feeDeclarationOf[msg.sender] = declaredFeeBps;
        p.feeDeclarationOf[address(0)] = declaredFeeBps;
        emit LiquidityAdded(roundId, msg.sender, cstIn, declaredFeeBps, sharesOut, rY, rN);
    }

    /// @dev Subsequent deposit: joins at the pool's current ratio. Deposits
    /// round UP (against the joiner) and shares round DOWN, so joining can
    /// never extract value from existing LPs. Excess outcome tokens are
    /// credited back, accrued fees are settled, and the joiner's ENTIRE
    /// position is re-declared at `declaredFeeBps`.
    function _joinPool(RoundMarket storage rm, Pool storage p, uint256 roundId, uint256 cstIn, uint16 declaredFeeBps)
        internal
        returns (uint256 sharesOut)
    {
        uint256 rY = p.reserveYes;
        uint256 rN = p.reserveNo;
        // A pool whose reserves were fully drained (possible only as dust
        // after every LP exits) cannot define a join ratio; it is dead.
        if (rY == 0 || rN == 0) revert InsufficientLiquidity();
        uint256 m = rY > rN ? rY : rN;
        sharesOut = p.totalShares * cstIn / m;
        if (sharesOut == 0) revert InsufficientLiquidity();
        uint256 dY = _ceilDiv(cstIn * rY, m);
        uint256 dN = _ceilDiv(cstIn * rN, m);

        uint256 pending = _pendingFees(p, msg.sender);
        uint256 oldShares = p.sharesOf[msg.sender];
        uint256 newShares = oldShares + sharesOut;

        p.reserveYes = rY + dY;
        p.reserveNo = rN + dN;
        rm.yesBalance[msg.sender] += cstIn - dY;
        rm.noBalance[msg.sender] += cstIn - dN;
        p.totalShares += sharesOut;
        p.sharesOf[msg.sender] = newShares;
        // Re-cast the fee vote for the whole position at the new declaration.
        p.feeWeight =
            p.feeWeight - oldShares * uint256(p.feeDeclarationOf[msg.sender]) + newShares * uint256(declaredFeeBps);
        p.feeDeclarationOf[msg.sender] = declaredFeeBps;
        p.feeDebtOf[msg.sender] = newShares * p.accFeePerShare / ONE;
        if (pending > 0) {
            p.feeReserve -= pending;
            _pushCst(msg.sender, pending);
        }
        emit LiquidityAdded(roundId, msg.sender, cstIn, declaredFeeBps, sharesOut, dY, dN);
    }

    /// @dev Common bet body: pull CST, credit the pool's LPs the weighted-
    /// average fee, mint sets with the rest and swap the unwanted side in.
    function _bet(RoundMarket storage rm, uint256 roundId, bool yes, uint256 cstIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        if (cstIn == 0) revert InvalidParams();
        Pool storage p = rm.pool;
        if (p.totalShares == 0 || p.reserveYes == 0 || p.reserveNo == 0) revert InsufficientLiquidity();

        _pullCst(msg.sender, cstIn);
        uint256 fee = cstIn * _poolFeeBps(p) / BPS;
        uint256 net = cstIn - fee;
        p.feeReserve += fee;
        p.accFeePerShare += fee * ONE / p.totalShares;

        if (yes) {
            tokensOut = _buyAmount(p.reserveYes, p.reserveNo, net);
            if (tokensOut < minTokensOut) revert Slippage();
            p.reserveYes = p.reserveYes + net - tokensOut;
            p.reserveNo += net;
            rm.yesBalance[msg.sender] += tokensOut;
        } else {
            tokensOut = _buyAmount(p.reserveNo, p.reserveYes, net);
            if (tokensOut < minTokensOut) revert Slippage();
            p.reserveNo = p.reserveNo + net - tokensOut;
            p.reserveYes += net;
            rm.noBalance[msg.sender] += tokensOut;
        }
        emit Bet(roundId, msg.sender, yes, cstIn, net, tokensOut);
    }

    /// @dev The round must be initialized, unresolved, current or future,
    /// AND the outcome must still be genuinely uncertain. The threshold is
    /// synced in the same call, so at the exact block the game reaches the
    /// round the just-locked value is already enforced; together with the
    /// decided-check this means there is never a block in which a decided
    /// outcome (or a stale/unset threshold) can be traded.
    function _prepareTradableRound(uint256 roundId) internal returns (RoundMarket storage rm) {
        rm = _rounds[roundId];
        if (!rm.initialized) revert RoundNotInitialized();
        if (rm.resolved) revert AlreadyResolved();
        uint256 currentRound = game.roundNum();
        if (roundId < currentRound) revert RoundNotActive();
        _syncThreshold(rm, roundId, currentRound);
        if (_outcomeDecided(rm, roundId)) revert OutcomeDecided();
    }

    /// @dev The share-weighted average fee; 0 for an unopened pool. Bounded
    /// by MAX_FEE_BPS since every declaration is.
    function _poolFeeBps(Pool storage p) internal view returns (uint256) {
        uint256 total = p.totalShares;
        if (total == 0) return 0;
        return p.feeWeight / total;
    }

    /// @dev Quote at the current weighted fee; 0 when the pool can't trade.
    function _quote(Pool storage p, bool yes, uint256 cstIn) internal view returns (uint256) {
        if (cstIn == 0 || p.totalShares == 0 || p.reserveYes == 0 || p.reserveNo == 0) return 0;
        uint256 net = cstIn - cstIn * _poolFeeBps(p) / BPS;
        return yes ? _buyAmount(p.reserveYes, p.reserveNo, net) : _buyAmount(p.reserveNo, p.reserveYes, net);
    }

    /// @dev Outcome tokens received when `net` CST is used to mint sets and the
    /// unwanted side is swapped into the pool: the buyer gets their `net`
    /// freshly minted tokens plus whatever the pool releases to keep
    /// x * y = k. Rounds in the pool's favor.
    function _buyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) internal pure returns (uint256) {
        return net + reserveOut - _ceilDiv(reserveOut * reserveIn, reserveIn + net);
    }

    function _pendingFees(Pool storage p, address user) internal view returns (uint256) {
        return p.sharesOf[user] * p.accFeePerShare / ONE - p.feeDebtOf[user];
    }

    function _checkDeadline(uint256 deadline) internal view {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _pullCst(address from, uint256 amount) internal {
        if (!cst.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _pushCst(address to, uint256 amount) internal {
        if (!cst.transfer(to, amount)) revert TransferFailed();
    }
}
