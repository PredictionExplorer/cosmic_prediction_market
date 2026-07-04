// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
/// - Markets launch themselves: the first `addLiquidity` for the current round
///   initializes that round's market, reading the threshold (the previous
///   round's final gesture count, frozen the moment this round started) from
///   the game. Nothing needs to be deployed or configured per round.
///
/// - Each round has two outcome tokens, YES and NO, tracked as internal
///   balances. 1 CST mints a complete set of 1 YES + 1 NO, and a complete set
///   is always redeemable for 1 CST, so the contract is solvent by
///   construction. YES pays 1 CST iff the round's final count is STRICTLY
///   greater than the threshold (a tie means NO wins); NO pays 1 CST otherwise.
///
/// - Liquidity lives in Uniswap-style constant-product pools (x * y = k)
///   between YES and NO — one pool per fee tier, so LPs choose the fee they
///   are willing to accept (like Uniswap v3 fee tiers). Anyone can provide
///   liquidity and earns that tier's fee on every bet, pro rata by LP shares.
///   The marginal price of YES in a pool, reserveNo / (reserveYes + reserveNo),
///   is that pool's implied probability.
///
/// - `betYes(...)` mints sets with your CST and swaps the NO half into the
///   pool, leaving you holding only YES (mirror image for `betNo`). The
///   `bet...Best` variants route to whichever tier gives the best execution.
///   To exit early, buy the opposite side and `redeemSets`.
///
/// - The gesture count is public and only ever increases, so the instant it
///   exceeds the threshold the outcome is decided: betting and adding
///   liquidity halt atomically and anyone may `resolve` the round early for
///   YES. Otherwise the round resolves when the game's round counter advances.
///
/// - After resolution, `claim` pays winning tokens 1:1. LP positions are never
///   confiscated or swept: `removeLiquidity` and `claimFees` work at any time,
///   before or after resolution.
///
/// Hardening notes (see the test suite for the attacks these defeat):
///
/// - Every trade and liquidity change takes explicit slippage bounds and a
///   deadline, so liquidity pulls, sandwiches and stale transactions cannot
///   worsen your execution beyond what you signed.
/// - First-deposit share inflation is blocked by a minimum initial deposit,
///   permanently locked dead shares, and rounding that always favors the pool.
/// - Reserves and balances are internal accounting: direct CST donations to
///   the contract change nothing.
/// - All state-mutating functions are non-reentrant and follow
///   checks-effects-interactions; rounding always favors the contract, so it
///   can never owe more CST than it holds.
contract GestureSeriesMarket {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Hard cap on any fee tier: 10%.
    uint256 internal constant MAX_FEE_BPS = 1_000;
    /// @dev At most this many fee tiers (bounds all tier loops).
    uint256 internal constant MAX_TIERS = 5;
    /// @dev A pool's first deposit must be at least this much CST. Together
    /// with `DEAD_SHARES` this makes classic share-inflation attacks
    /// unprofitable by many orders of magnitude.
    uint256 internal constant MIN_INITIAL_LIQUIDITY = 1e15;
    /// @dev Shares permanently locked (credited to address(0)) on a pool's
    /// first deposit, Uniswap v2 style.
    uint256 internal constant DEAD_SHARES = 1e3;
    /// @dev The first LP seeds the pool at their chosen YES probability,
    /// clamped to [1%, 99%] so both reserves are meaningfully nonzero.
    uint256 internal constant MIN_PROB_BPS = 100;
    uint256 internal constant MAX_PROB_BPS = 9_900;

    ICosmicSignatureGame public immutable game;
    IERC20 public immutable cst;

    /// @dev Allowed fee tiers in strictly ascending order, fixed at deployment.
    uint16[] internal _feeTiers;

    struct Pool {
        uint256 reserveYes;
        uint256 reserveNo;
        uint256 totalShares;
        /// @dev Cumulative CST fees per share, 1e18-scaled (MasterChef pattern).
        uint256 accFeePerShare;
        /// @dev CST held for this pool's LPs' unclaimed fees. Kept explicit so
        /// solvency is provable: contract balance >= sets outstanding + fee reserves.
        uint256 feeReserve;
        mapping(address => uint256) sharesOf;
        mapping(address => uint256) feeDebtOf;
    }

    struct RoundMarket {
        bool initialized;
        bool resolved;
        bool yesWon;
        /// @dev Final gesture count of the previous round; YES wins iff this
        /// round's final count is strictly greater.
        uint256 threshold;
        mapping(uint16 => Pool) pools;
        mapping(address => uint256) yesBalance;
        mapping(address => uint256) noBalance;
    }

    mapping(uint256 => RoundMarket) internal _rounds;

    uint256 private _lock = 1;

    event RoundInitialized(uint256 indexed roundId, uint256 threshold);
    event SetsMinted(uint256 indexed roundId, address indexed user, uint256 amount);
    event SetsRedeemed(uint256 indexed roundId, address indexed user, uint256 amount);
    event Bet(
        uint256 indexed roundId,
        address indexed user,
        uint16 feeBps,
        bool yes,
        uint256 cstIn,
        uint256 netIn,
        uint256 tokensOut
    );
    event LiquidityAdded(
        uint256 indexed roundId,
        address indexed provider,
        uint16 feeBps,
        uint256 cstIn,
        uint256 sharesOut,
        uint256 yesToPool,
        uint256 noToPool
    );
    event LiquidityRemoved(
        uint256 indexed roundId,
        address indexed provider,
        uint16 feeBps,
        uint256 sharesIn,
        uint256 yesOut,
        uint256 noOut,
        uint256 feesOut
    );
    event FeesClaimed(uint256 indexed roundId, address indexed user, uint16 feeBps, uint256 amount);
    event Resolved(uint256 indexed roundId, uint256 finalCount, bool yesWon);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 cstOut);

    error InvalidParams();
    error InvalidFeeTier();
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
    /// @param feeTiers_ Allowed fee tiers in basis points, strictly ascending,
    /// each in (0, 1000]. E.g. [100, 200, 500] for 1% / 2% / 5%.
    constructor(ICosmicSignatureGame game_, uint16[] memory feeTiers_) {
        if (address(game_) == address(0)) revert InvalidParams();
        uint256 n = feeTiers_.length;
        if (n == 0 || n > MAX_TIERS) revert InvalidParams();
        for (uint256 i = 0; i < n; i++) {
            uint16 tier = feeTiers_[i];
            if (tier == 0 || tier > MAX_FEE_BPS) revert InvalidParams();
            if (i > 0 && tier <= feeTiers_[i - 1]) revert InvalidParams();
            _feeTiers.push(tier);
        }
        game = game_;
        address token = game_.token();
        if (token == address(0)) revert InvalidParams();
        cst = IERC20(token);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Provide `cstIn` CST of liquidity to the (`roundId`, `feeBps`)
    /// pool and receive LP shares. The first deposit for the current round
    /// initializes the round's market (reading the threshold from the game),
    /// and the first deposit into a pool opens it at `initialYesProbBps`
    /// (ignored afterwards; later deposits join at the pool's current ratio,
    /// with any excess outcome tokens credited back to your balances).
    /// @param minSharesOut Slippage guard on the LP shares received.
    /// @param deadline Unix timestamp after which the transaction reverts.
    function addLiquidity(
        uint256 roundId,
        uint16 feeBps,
        uint256 cstIn,
        uint256 initialYesProbBps,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 sharesOut) {
        _checkDeadline(deadline);
        _checkTier(feeBps);
        if (cstIn == 0) revert InvalidParams();

        RoundMarket storage rm = _rounds[roundId];
        if (!rm.initialized) {
            _initRound(rm, roundId);
        } else if (game.roundNum() != roundId) {
            revert RoundNotActive();
        }
        if (rm.resolved) revert AlreadyResolved();
        // Once the outcome is certain, adding liquidity would only donate to
        // arbitrageurs; block it in the same breath as betting.
        if (game.bidderAddresses(roundId) > rm.threshold) revert OutcomeDecided();

        _pullCst(msg.sender, cstIn);
        Pool storage p = rm.pools[feeBps];

        if (p.totalShares == 0) {
            sharesOut = _openPool(rm, p, roundId, feeBps, cstIn, initialYesProbBps);
        } else {
            sharesOut = _joinPool(rm, p, roundId, feeBps, cstIn);
        }
        if (sharesOut < minSharesOut) revert Slippage();
    }

    /// @notice Burn `shares` LP shares of the (`roundId`, `feeBps`) pool for a
    /// pro-rata cut of its reserves (credited to your YES/NO balances) plus
    /// all your accrued fees (paid in CST). Works at ANY time — while the
    /// round is live, once the outcome is decided, and after resolution — so
    /// liquidity can never be trapped.
    function removeLiquidity(
        uint256 roundId,
        uint16 feeBps,
        uint256 shares,
        uint256 minYesOut,
        uint256 minNoOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 yesOut, uint256 noOut, uint256 feesOut) {
        _checkDeadline(deadline);
        RoundMarket storage rm = _rounds[roundId];
        Pool storage p = rm.pools[feeBps];
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
        p.feeDebtOf[msg.sender] = (userShares - shares) * p.accFeePerShare / ONE;
        rm.yesBalance[msg.sender] += yesOut;
        rm.noBalance[msg.sender] += noOut;
        if (feesOut > 0) {
            p.feeReserve -= feesOut;
            _pushCst(msg.sender, feesOut);
        }
        emit LiquidityRemoved(roundId, msg.sender, feeBps, shares, yesOut, noOut, feesOut);
    }

    /// @notice Pay out your accrued (so far unclaimed) fees from the
    /// (`roundId`, `feeBps`) pool without touching your shares. Works anytime.
    function claimFees(uint256 roundId, uint16 feeBps) external nonReentrant returns (uint256 feesOut) {
        Pool storage p = _rounds[roundId].pools[feeBps];
        feesOut = _pendingFees(p, msg.sender);
        p.feeDebtOf[msg.sender] = p.sharesOf[msg.sender] * p.accFeePerShare / ONE;
        if (feesOut > 0) {
            p.feeReserve -= feesOut;
            _pushCst(msg.sender, feesOut);
        }
        emit FeesClaimed(roundId, msg.sender, feeBps, feesOut);
    }

    // ---------------------------------------------------------------------
    // Sets
    // ---------------------------------------------------------------------

    /// @notice Deposit CST and receive YES and NO in equal amounts
    /// (1 CST = 1 YES + 1 NO). Requires the round's market to exist and the
    /// round to still be live.
    function mintSets(uint256 roundId, uint256 amount) external nonReentrant {
        RoundMarket storage rm = _rounds[roundId];
        if (!rm.initialized) revert RoundNotInitialized();
        if (rm.resolved) revert AlreadyResolved();
        if (game.roundNum() != roundId) revert RoundNotActive();
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

    /// @notice Bet `cstIn` CST on YES ("this round beats the last one") in the
    /// (`roundId`, `feeBps`) pool. You receive YES tokens.
    /// @param minTokensOut Slippage guard; reverts if the bet would yield fewer
    /// tokens (also your protection against liquidity being pulled first).
    function betYes(uint256 roundId, uint16 feeBps, uint256 cstIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _tradableRound(roundId);
        tokensOut = _bet(rm, roundId, feeBps, true, cstIn, minTokensOut);
    }

    /// @notice Bet `cstIn` CST on NO ("it won't beat the last round") in the
    /// (`roundId`, `feeBps`) pool. You receive NO tokens.
    function betNo(uint256 roundId, uint16 feeBps, uint256 cstIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _tradableRound(roundId);
        tokensOut = _bet(rm, roundId, feeBps, false, cstIn, minTokensOut);
    }

    /// @notice Bet on YES via whichever fee tier currently gives the most
    /// tokens for `cstIn` (all-in, i.e. net of each tier's fee).
    function betYesBest(uint256 roundId, uint256 cstIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint16 feeBps, uint256 tokensOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _tradableRound(roundId);
        feeBps = _bestTier(rm, true, cstIn);
        tokensOut = _bet(rm, roundId, feeBps, true, cstIn, minTokensOut);
    }

    /// @notice Bet on NO via whichever fee tier currently gives the most
    /// tokens for `cstIn`.
    function betNoBest(uint256 roundId, uint256 cstIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        returns (uint16 feeBps, uint256 tokensOut)
    {
        _checkDeadline(deadline);
        RoundMarket storage rm = _tradableRound(roundId);
        feeBps = _bestTier(rm, false, cstIn);
        tokensOut = _bet(rm, roundId, feeBps, false, cstIn, minTokensOut);
    }

    // ---------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------

    /// @notice Resolve round `roundId`. Callable by anyone once the round is
    /// over (the game's round counter advanced), or EARLY the moment the live
    /// count exceeds the threshold — the count only ever increases, so YES is
    /// already certain then.
    function resolve(uint256 roundId) external nonReentrant {
        RoundMarket storage rm = _rounds[roundId];
        if (!rm.initialized) revert RoundNotInitialized();
        if (rm.resolved) revert AlreadyResolved();

        uint256 count = game.bidderAddresses(roundId);
        bool yesWon_;
        if (game.roundNum() > roundId) {
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

    /// @notice The fixed, contract-wide fee tiers in basis points (ascending).
    function feeTiers() external view returns (uint16[] memory) {
        return _feeTiers;
    }

    /// @notice Full lifecycle state of a round's market in one call.
    function roundState(uint256 roundId)
        external
        view
        returns (
            bool initialized,
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
        threshold = rm.threshold;
        currentCount = game.bidderAddresses(roundId);
        roundActive = game.roundNum() == roundId;
        outcomeDecided = initialized && currentCount > threshold;
    }

    /// @notice Reserves and share/fee accounting of one pool.
    function pool(uint256 roundId, uint16 feeBps)
        external
        view
        returns (uint256 reserveYes, uint256 reserveNo, uint256 totalShares, uint256 accFeePerShare, uint256 feeReserve)
    {
        Pool storage p = _rounds[roundId].pools[feeBps];
        return (p.reserveYes, p.reserveNo, p.totalShares, p.accFeePerShare, p.feeReserve);
    }

    /// @notice A user's outcome-token balances for a round.
    function balancesOf(uint256 roundId, address user) external view returns (uint256 yes, uint256 no) {
        RoundMarket storage rm = _rounds[roundId];
        return (rm.yesBalance[user], rm.noBalance[user]);
    }

    /// @notice A user's LP position in one pool: shares plus fees claimable now.
    function lpPositionOf(uint256 roundId, uint16 feeBps, address user)
        external
        view
        returns (uint256 shares, uint256 pendingFees)
    {
        Pool storage p = _rounds[roundId].pools[feeBps];
        return (p.sharesOf[user], _pendingFees(p, user));
    }

    /// @notice YES tokens a `betYes(roundId, feeBps, cstIn, ...)` would return
    /// right now (0 if the pool has no liquidity).
    function quoteBetYes(uint256 roundId, uint16 feeBps, uint256 cstIn) external view returns (uint256) {
        return _quote(_rounds[roundId].pools[feeBps], true, feeBps, cstIn);
    }

    /// @notice NO tokens a `betNo(roundId, feeBps, cstIn, ...)` would return right now.
    function quoteBetNo(uint256 roundId, uint16 feeBps, uint256 cstIn) external view returns (uint256) {
        return _quote(_rounds[roundId].pools[feeBps], false, feeBps, cstIn);
    }

    /// @notice The tier `betYesBest` would route to and its quote
    /// (0, 0 when no pool has liquidity).
    function quoteBetYesBest(uint256 roundId, uint256 cstIn) external view returns (uint16 feeBps, uint256 tokensOut) {
        return _bestQuote(_rounds[roundId], true, cstIn);
    }

    /// @notice The tier `betNoBest` would route to and its quote.
    function quoteBetNoBest(uint256 roundId, uint256 cstIn) external view returns (uint16 feeBps, uint256 tokensOut) {
        return _bestQuote(_rounds[roundId], false, cstIn);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Initializes the market for `roundId`. Only the CURRENT round can be
    /// initialized (so the threshold — the previous round's count — is final),
    /// and round 0 has no previous round to compare against.
    function _initRound(RoundMarket storage rm, uint256 roundId) internal {
        if (roundId == 0 || game.roundNum() != roundId) revert RoundNotActive();
        rm.initialized = true;
        rm.threshold = game.bidderAddresses(roundId - 1);
        emit RoundInitialized(roundId, rm.threshold);
    }

    /// @dev First deposit into a pool: seeds reserves at the LP's chosen YES
    /// probability using all `cstIn` minted sets — the surplus side stays with
    /// the LP as outcome tokens. Locks `DEAD_SHARES` forever (inflation guard).
    function _openPool(
        RoundMarket storage rm,
        Pool storage p,
        uint256 roundId,
        uint16 feeBps,
        uint256 cstIn,
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
        emit LiquidityAdded(roundId, msg.sender, feeBps, cstIn, sharesOut, rY, rN);
    }

    /// @dev Subsequent deposit: joins at the pool's current ratio. Deposits
    /// round UP (against the joiner) and shares round DOWN, so joining can
    /// never extract value from existing LPs. Excess outcome tokens are
    /// credited back. Also settles the joiner's accrued fees.
    function _joinPool(RoundMarket storage rm, Pool storage p, uint256 roundId, uint16 feeBps, uint256 cstIn)
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
        p.reserveYes = rY + dY;
        p.reserveNo = rN + dN;
        rm.yesBalance[msg.sender] += cstIn - dY;
        rm.noBalance[msg.sender] += cstIn - dN;
        p.totalShares += sharesOut;
        p.sharesOf[msg.sender] += sharesOut;
        p.feeDebtOf[msg.sender] = p.sharesOf[msg.sender] * p.accFeePerShare / ONE;
        if (pending > 0) {
            p.feeReserve -= pending;
            _pushCst(msg.sender, pending);
        }
        emit LiquidityAdded(roundId, msg.sender, feeBps, cstIn, sharesOut, dY, dN);
    }

    /// @dev Common bet body: pull CST, credit the pool's LPs their fee, mint
    /// sets with the rest and swap the unwanted side into the pool.
    function _bet(RoundMarket storage rm, uint256 roundId, uint16 feeBps, bool yes, uint256 cstIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        if (cstIn == 0) revert InvalidParams();
        Pool storage p = rm.pools[feeBps];
        if (p.totalShares == 0 || p.reserveYes == 0 || p.reserveNo == 0) revert InsufficientLiquidity();

        _pullCst(msg.sender, cstIn);
        uint256 fee = cstIn * uint256(feeBps) / BPS;
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
        emit Bet(roundId, msg.sender, feeBps, yes, cstIn, net, tokensOut);
    }

    /// @dev The round must be initialized, unresolved, still the game's
    /// current round, AND the outcome must still be genuinely uncertain.
    /// The last check closes the window between the count crossing the
    /// threshold and someone calling `resolve`: there is never a block in
    /// which a decided outcome can be traded.
    function _tradableRound(uint256 roundId) internal view returns (RoundMarket storage rm) {
        rm = _rounds[roundId];
        if (!rm.initialized) revert RoundNotInitialized();
        if (rm.resolved) revert AlreadyResolved();
        if (game.roundNum() != roundId) revert RoundNotActive();
        if (game.bidderAddresses(roundId) > rm.threshold) revert OutcomeDecided();
    }

    /// @dev Tier with the highest all-in output for this bet; ties go to the
    /// lowest fee. Reverts if no pool can take the trade.
    function _bestTier(RoundMarket storage rm, bool yes, uint256 cstIn) internal view returns (uint16 best) {
        uint256 bestOut = 0;
        uint256 n = _feeTiers.length;
        for (uint256 i = 0; i < n; i++) {
            uint16 tier = _feeTiers[i];
            uint256 out = _quote(rm.pools[tier], yes, tier, cstIn);
            if (out > bestOut) {
                bestOut = out;
                best = tier;
            }
        }
        if (bestOut == 0) revert InsufficientLiquidity();
    }

    function _bestQuote(RoundMarket storage rm, bool yes, uint256 cstIn)
        internal
        view
        returns (uint16 feeBps, uint256 tokensOut)
    {
        uint256 n = _feeTiers.length;
        for (uint256 i = 0; i < n; i++) {
            uint16 tier = _feeTiers[i];
            uint256 out = _quote(rm.pools[tier], yes, tier, cstIn);
            if (out > tokensOut) {
                tokensOut = out;
                feeBps = tier;
            }
        }
    }

    /// @dev Quote for one pool; 0 when the pool can't take the trade.
    function _quote(Pool storage p, bool yes, uint16 feeBps, uint256 cstIn) internal view returns (uint256) {
        if (cstIn == 0 || p.totalShares == 0 || p.reserveYes == 0 || p.reserveNo == 0) return 0;
        uint256 net = cstIn - cstIn * uint256(feeBps) / BPS;
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

    function _checkTier(uint16 feeBps) internal view {
        uint256 n = _feeTiers.length;
        for (uint256 i = 0; i < n; i++) {
            if (_feeTiers[i] == feeBps) return;
        }
        revert InvalidFeeTier();
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
