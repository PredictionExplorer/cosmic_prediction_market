// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICosmicSignatureGame} from "./ICosmicSignatureGame.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title GestureMarket
/// @notice A scalar prediction market, denominated in CST, on how many gestures
/// (bids) one Cosmic Signature round will end with.
///
/// Mechanism, in short:
///
/// - There are two outcome tokens, HIGHER and LOWER, tracked as internal balances.
///   1 CST always mints a complete set of 1 HIGHER + 1 LOWER, and a complete set
///   is always redeemable for 1 CST, so the contract is solvent by construction.
///
/// - A Uniswap-style constant-product pool (x * y = k) between HIGHER and LOWER
///   prices the outcome. The marginal price of HIGHER, mapped over the range
///   [minCount, maxCount], is the market's live prediction of the final gesture
///   count; see `predictedCount()`.
///
/// - `betHigher(cstIn)` mints sets with your CST and swaps the LOWER half into
///   the pool, leaving you holding only HIGHER (and vice versa for `betLower`).
///   To exit a bet early, buy the opposite side and call `redeemSets`.
///
/// - When the round ends (the game's round counter advances), anyone can call
///   `resolve()`. It reads the final gesture count N from the game and clamps it
///   into [minCount, maxCount]. Each HIGHER token then pays
///   (N - minCount) / (maxCount - minCount) CST and each LOWER token pays the
///   complement, so every HIGHER+LOWER pair pays exactly 1 CST in total. The
///   closer the count lands to your side of the range, the more you win.
///
/// - The deployer is the sole liquidity provider. The pool opens at the midpoint
///   of the range; at resolution the pool's remaining tokens plus all trading
///   fees are credited back to the deployer.
///
/// All trading stops automatically the moment the round ends, because every
/// trading function requires the game to still be on this market's round.
contract GestureMarket {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant MAX_FEE_BPS = 1_000; // 10%
    uint256 internal constant BPS = 10_000;
    /// @dev Upper bound on `maxCount`. A trillion gestures is far beyond anything
    /// possible, and the bound keeps every product in this contract comfortably
    /// below 2^256 (an unbounded range could make `resolve()` overflow-revert and
    /// permanently lock funds).
    uint256 internal constant COUNT_LIMIT = 1e12;

    ICosmicSignatureGame public immutable game;
    IERC20 public immutable cst;
    address public immutable creator;
    /// @notice The Cosmic Signature round this market is about (the round that
    /// was current when the market was deployed).
    uint256 public immutable round;
    /// @notice Payout range. Final counts at or below `minCount` make LOWER pay
    /// the full 1 CST per token; counts at or above `maxCount` do the same for HIGHER.
    uint256 public immutable minCount;
    uint256 public immutable maxCount;
    /// @notice Fee in basis points charged on every bet, paid to the creator at resolution.
    uint256 public immutable feeBps;

    uint256 public reserveHigher;
    uint256 public reserveLower;
    mapping(address => uint256) public higherBalance;
    mapping(address => uint256) public lowerBalance;
    uint256 public feesAccrued;

    bool public resolved;
    /// @notice The round's final gesture count as reported by the game (unclamped).
    uint256 public finalGestureCount;
    /// @notice CST paid per 1e18 HIGHER tokens; LOWER pays `1e18 - payoutPerHigher`.
    uint256 public payoutPerHigher;

    event SetsMinted(address indexed user, uint256 amount);
    event SetsRedeemed(address indexed user, uint256 amount);
    event Bet(address indexed user, bool indexed higher, uint256 cstIn, uint256 tokensOut);
    event Resolved(uint256 finalGestureCount, uint256 payoutPerHigher);
    event Claimed(address indexed user, uint256 cstOut);

    error InvalidParams();
    error TradingClosed();
    error NotResolvable();
    error AlreadyResolved();
    error NotResolved();
    error Slippage();
    error TransferFailed();

    modifier whileRoundActive() {
        if (game.roundNum() != round) revert TradingClosed();
        _;
    }

    /// @param game_ The CosmicSignatureGame; the market is for its current round.
    /// @param minCount_ Lower bound of the payout range.
    /// @param maxCount_ Upper bound of the payout range.
    /// @param feeBps_ Bet fee in basis points (max 1000 = 10%).
    /// @param initialLiquidity_ CST pulled from the deployer to seed the pool with
    /// equal reserves, so the market opens predicting the midpoint of the range.
    /// The deployer must approve this contract's (predictable) address beforehand.
    constructor(
        ICosmicSignatureGame game_,
        uint256 minCount_,
        uint256 maxCount_,
        uint256 feeBps_,
        uint256 initialLiquidity_
    ) {
        if (maxCount_ <= minCount_ || maxCount_ > COUNT_LIMIT || feeBps_ > MAX_FEE_BPS || initialLiquidity_ == 0) {
            revert InvalidParams();
        }
        game = game_;
        cst = IERC20(game_.token());
        creator = msg.sender;
        round = game_.roundNum();
        minCount = minCount_;
        maxCount = maxCount_;
        feeBps = feeBps_;
        reserveHigher = initialLiquidity_;
        reserveLower = initialLiquidity_;
        _pullCst(msg.sender, initialLiquidity_);
    }

    // ---------------------------------------------------------------------
    // Trading (only while the round is live)
    // ---------------------------------------------------------------------

    /// @notice Deposit CST and receive HIGHER and LOWER in equal amounts (1 CST = 1 + 1).
    function mintSets(uint256 cstAmount) external whileRoundActive {
        _pullCst(msg.sender, cstAmount);
        higherBalance[msg.sender] += cstAmount;
        lowerBalance[msg.sender] += cstAmount;
        emit SetsMinted(msg.sender, cstAmount);
    }

    /// @notice Burn equal amounts of HIGHER and LOWER and get the CST back.
    /// Buying the opposite side of your bet and redeeming the pairs is how you
    /// exit a position before resolution.
    function redeemSets(uint256 amount) external whileRoundActive {
        higherBalance[msg.sender] -= amount;
        lowerBalance[msg.sender] -= amount;
        _pushCst(msg.sender, amount);
        emit SetsRedeemed(msg.sender, amount);
    }

    /// @notice Bet `cstIn` CST that the final gesture count ends up higher than
    /// the current `predictedCount()`. You receive HIGHER tokens.
    /// @param minTokensOut Slippage guard; reverts if the bet would yield fewer tokens.
    function betHigher(uint256 cstIn, uint256 minTokensOut) external whileRoundActive returns (uint256 tokensOut) {
        _pullCst(msg.sender, cstIn);
        uint256 net = _takeFee(cstIn);
        tokensOut = _buyAmount(reserveHigher, reserveLower, net);
        if (tokensOut < minTokensOut) revert Slippage();
        reserveHigher = reserveHigher + net - tokensOut;
        reserveLower += net;
        higherBalance[msg.sender] += tokensOut;
        emit Bet(msg.sender, true, cstIn, tokensOut);
    }

    /// @notice Bet `cstIn` CST that the final gesture count ends up lower than
    /// the current `predictedCount()`. You receive LOWER tokens.
    /// @param minTokensOut Slippage guard; reverts if the bet would yield fewer tokens.
    function betLower(uint256 cstIn, uint256 minTokensOut) external whileRoundActive returns (uint256 tokensOut) {
        _pullCst(msg.sender, cstIn);
        uint256 net = _takeFee(cstIn);
        tokensOut = _buyAmount(reserveLower, reserveHigher, net);
        if (tokensOut < minTokensOut) revert Slippage();
        reserveLower = reserveLower + net - tokensOut;
        reserveHigher += net;
        lowerBalance[msg.sender] += tokensOut;
        emit Bet(msg.sender, false, cstIn, tokensOut);
    }

    // ---------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------

    /// @notice Callable by anyone once the round is over (the game's round
    /// counter has advanced past this market's round).
    function resolve() external {
        if (resolved) revert AlreadyResolved();
        if (game.roundNum() <= round) revert NotResolvable();
        resolved = true;

        uint256 count = game.bidderAddresses(round);
        finalGestureCount = count;
        uint256 clamped = count < minCount ? minCount : (count > maxCount ? maxCount : count);
        payoutPerHigher = (clamped - minCount) * ONE / (maxCount - minCount);

        // The pool's remaining tokens and all fees belong to the creator, the sole LP.
        higherBalance[creator] += reserveHigher;
        lowerBalance[creator] += reserveLower;
        reserveHigher = 0;
        reserveLower = 0;
        uint256 fees = feesAccrued;
        feesAccrued = 0;
        if (fees > 0) _pushCst(creator, fees);

        emit Resolved(count, payoutPerHigher);
    }

    /// @notice Redeem all your HIGHER and LOWER tokens for CST at the resolved rates.
    function claim() external returns (uint256 cstOut) {
        if (!resolved) revert NotResolved();
        uint256 h = higherBalance[msg.sender];
        uint256 l = lowerBalance[msg.sender];
        higherBalance[msg.sender] = 0;
        lowerBalance[msg.sender] = 0;
        cstOut = (h * payoutPerHigher + l * (ONE - payoutPerHigher)) / ONE;
        if (cstOut > 0) _pushCst(msg.sender, cstOut);
        emit Claimed(msg.sender, cstOut);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice The market's current prediction of the round's final gesture count
    /// (after resolution: the clamped final count).
    function predictedCount() public view returns (uint256) {
        uint256 total = reserveHigher + reserveLower;
        if (total == 0) return minCount + (maxCount - minCount) * payoutPerHigher / ONE;
        // Marginal price of HIGHER is reserveLower / (reserveHigher + reserveLower).
        return minCount + (maxCount - minCount) * reserveLower / total;
    }

    /// @notice HIGHER tokens a `betHigher(cstIn, ...)` would return right now.
    function quoteBetHigher(uint256 cstIn) external view returns (uint256) {
        return _buyAmount(reserveHigher, reserveLower, cstIn - cstIn * feeBps / BPS);
    }

    /// @notice LOWER tokens a `betLower(cstIn, ...)` would return right now.
    function quoteBetLower(uint256 cstIn) external view returns (uint256) {
        return _buyAmount(reserveLower, reserveHigher, cstIn - cstIn * feeBps / BPS);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Outcome tokens received when `net` CST is used to mint sets and the
    /// unwanted side is swapped into the pool: the user gets their `net` freshly
    /// minted tokens plus whatever the pool releases to keep x * y = k.
    /// Rounds in the pool's favor.
    function _buyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) internal pure returns (uint256) {
        return net + reserveOut - _ceilDiv(reserveOut * reserveIn, reserveIn + net);
    }

    function _takeFee(uint256 cstIn) internal returns (uint256 net) {
        uint256 fee = cstIn * feeBps / BPS;
        feesAccrued += fee;
        net = cstIn - fee;
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
