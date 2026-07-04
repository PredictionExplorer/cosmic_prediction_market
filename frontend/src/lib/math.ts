/**
 * Pure bigint math mirroring `GestureSeriesMarket.sol` exactly (floor
 * division, `ceilDiv` rounding in the pool's favor). Keeping this in sync
 * with the contract lets the UI quote bets, route across fee tiers, preview
 * liquidity operations and replay history instantly without extra RPC calls —
 * and lets us property-test the lot (including bit-for-bit differential tests
 * against vectors produced by the real contract).
 */

export const ONE = 10n ** 18n;
export const BPS = 10_000n;
export const MAX_FEE_BPS = 1_000n;
export const MIN_INITIAL_LIQUIDITY = 10n ** 15n;
export const DEAD_SHARES = 1_000n;
export const MIN_PROB_BPS = 100n;
export const MAX_PROB_BPS = 9_900n;

/** One (round, feeTier) pool, exactly as the contract stores it. */
export interface PoolState {
  readonly reserveYes: bigint;
  readonly reserveNo: bigint;
  readonly totalShares: bigint;
  /** Cumulative CST fees per share, 1e18-scaled (MasterChef pattern). */
  readonly accFeePerShare: bigint;
  /** CST escrowed for the pool's LPs' unclaimed fees. */
  readonly feeReserve: bigint;
}

export const EMPTY_POOL: PoolState = {
  reserveYes: 0n,
  reserveNo: 0n,
  totalShares: 0n,
  accFeePerShare: 0n,
  feeReserve: 0n,
};

export type BetSide = "yes" | "no";

/** A pool tagged with its fee tier, the unit the router works over. */
export interface TierPool {
  readonly feeBps: number;
  readonly pool: PoolState;
}

// ---------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------

/** Solidity-style ceiling division for non-negative operands. */
export function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error("ceilDiv: divisor must be positive");
  if (a < 0n) throw new Error("ceilDiv: negative dividend");
  return (a + b - 1n) / b;
}

/** Mirrors the bet fee split: fee rounds down, `net` keeps the remainder. */
export function takeFee(cstIn: bigint, feeBps: bigint): { fee: bigint; net: bigint } {
  const fee = (cstIn * feeBps) / BPS;
  return { fee, net: cstIn - fee };
}

/**
 * Mirrors `_buyAmount`: tokens received when `net` CST mints sets and the
 * unwanted side is swapped into the pool (x*y=k, rounded in the pool's favor).
 */
export function buyAmount(reserveOut: bigint, reserveIn: bigint, net: bigint): bigint {
  return net + reserveOut - ceilDiv(reserveOut * reserveIn, reserveIn + net);
}

/** Whether a pool can currently take a bet at all. */
export function poolIsTradable(pool: PoolState): boolean {
  return pool.totalShares > 0n && pool.reserveYes > 0n && pool.reserveNo > 0n;
}

// ---------------------------------------------------------------------
// Probability
// ---------------------------------------------------------------------

/** P(YES) implied by one pool: reserveNo / (reserveYes + reserveNo), in [0,1]. */
export function probabilityFloat(pool: Pick<PoolState, "reserveYes" | "reserveNo">): number | null {
  const total = pool.reserveYes + pool.reserveNo;
  if (total === 0n) return null;
  const SCALE = 1_000_000n;
  return Number((pool.reserveNo * SCALE) / total) / Number(SCALE);
}

/**
 * The market-wide P(YES): liquidity-weighted across all tier pools, which is
 * simply sum(reserveNo) / sum(reserveYes + reserveNo).
 */
export function aggregateProbabilityFloat(pools: readonly TierPool[]): number | null {
  let yes = 0n;
  let no = 0n;
  for (const { pool } of pools) {
    yes += pool.reserveYes;
    no += pool.reserveNo;
  }
  return probabilityFloat({ reserveYes: yes, reserveNo: no });
}

// ---------------------------------------------------------------------
// Betting
// ---------------------------------------------------------------------

export interface BetResult {
  /** Outcome tokens received. */
  readonly tokensOut: bigint;
  /** Fee taken off the top, escrowed for the pool's LPs. */
  readonly fee: bigint;
  /** CST that actually entered the pool (`cstIn - fee`). */
  readonly net: bigint;
  /** Pool state after the bet (reserves, fee accumulator, escrow). */
  readonly pool: PoolState;
}

/** Mirrors `quoteBetYes` / `quoteBetNo`: 0 when the pool can't take the trade. */
export function quoteBet(side: BetSide, pool: PoolState, cstIn: bigint, feeBps: bigint): bigint {
  if (cstIn === 0n || !poolIsTradable(pool)) return 0n;
  const { net } = takeFee(cstIn, feeBps);
  return side === "yes"
    ? buyAmount(pool.reserveYes, pool.reserveNo, net)
    : buyAmount(pool.reserveNo, pool.reserveYes, net);
}

/** Mirrors `_bet`: quote plus the exact post-trade pool state. */
export function applyBet(side: BetSide, pool: PoolState, cstIn: bigint, feeBps: bigint): BetResult {
  if (!poolIsTradable(pool)) throw new Error("applyBet: pool has no liquidity");
  const { fee, net } = takeFee(cstIn, feeBps);
  const accFeePerShare = pool.accFeePerShare + (fee * ONE) / pool.totalShares;
  const feeReserve = pool.feeReserve + fee;
  if (side === "yes") {
    const tokensOut = buyAmount(pool.reserveYes, pool.reserveNo, net);
    return {
      tokensOut,
      fee,
      net,
      pool: {
        ...pool,
        reserveYes: pool.reserveYes + net - tokensOut,
        reserveNo: pool.reserveNo + net,
        accFeePerShare,
        feeReserve,
      },
    };
  }
  const tokensOut = buyAmount(pool.reserveNo, pool.reserveYes, net);
  return {
    tokensOut,
    fee,
    net,
    pool: {
      ...pool,
      reserveYes: pool.reserveYes + net,
      reserveNo: pool.reserveNo + net - tokensOut,
      accFeePerShare,
      feeReserve,
    },
  };
}

/**
 * Mirrors `_bestTier` / `quoteBet...Best`: the tier with the highest all-in
 * output; ties go to the lowest fee (pools are checked in ascending-fee
 * order, strictly-greater wins). Null when no pool can take the trade.
 */
export function bestTier(
  side: BetSide,
  pools: readonly TierPool[],
  cstIn: bigint,
): { feeBps: number; tokensOut: bigint } | null {
  const sorted = [...pools].sort((a, b) => a.feeBps - b.feeBps);
  let best: { feeBps: number; tokensOut: bigint } | null = null;
  for (const { feeBps, pool } of sorted) {
    const out = quoteBet(side, pool, cstIn, BigInt(feeBps));
    if (out > (best?.tokensOut ?? 0n)) best = { feeBps, tokensOut: out };
  }
  return best;
}

/** Applies a slippage tolerance (in bps) to a quoted amount, rounding down. */
export function minTokensOutForSlippage(quoted: bigint, slippageBps: number): bigint {
  const bps = BigInt(Math.round(slippageBps));
  if (bps < 0n || bps > BPS) throw new Error("slippage out of range");
  return (quoted * (BPS - bps)) / BPS;
}

// ---------------------------------------------------------------------
// Liquidity
// ---------------------------------------------------------------------

export interface OpenPoolResult {
  readonly sharesOut: bigint;
  /** Outcome tokens returned to the LP (the side the seeding didn't need in full). */
  readonly excessYes: bigint;
  readonly excessNo: bigint;
  readonly pool: PoolState;
}

/**
 * Mirrors `_openPool`: the first deposit seeds the reserves at the chosen
 * YES probability; the surplus side stays with the LP; `DEAD_SHARES` are
 * locked forever.
 */
export function openPool(cstIn: bigint, initialYesProbBps: bigint): OpenPoolResult {
  if (cstIn < MIN_INITIAL_LIQUIDITY) throw new Error("openPool: below minimum initial liquidity");
  if (initialYesProbBps < MIN_PROB_BPS || initialYesProbBps > MAX_PROB_BPS) {
    throw new Error("openPool: probability out of range");
  }
  let reserveYes: bigint;
  let reserveNo: bigint;
  if (initialYesProbBps <= BPS / 2n) {
    reserveYes = cstIn;
    reserveNo = (cstIn * initialYesProbBps) / (BPS - initialYesProbBps);
  } else {
    reserveNo = cstIn;
    reserveYes = (cstIn * (BPS - initialYesProbBps)) / initialYesProbBps;
  }
  return {
    sharesOut: cstIn - DEAD_SHARES,
    excessYes: cstIn - reserveYes,
    excessNo: cstIn - reserveNo,
    pool: {
      reserveYes,
      reserveNo,
      totalShares: cstIn,
      accFeePerShare: 0n,
      feeReserve: 0n,
    },
  };
}

export interface JoinPoolResult {
  readonly sharesOut: bigint;
  /** Deposited into the pool (rounds UP, against the joiner). */
  readonly depositYes: bigint;
  readonly depositNo: bigint;
  /** Returned to the LP's outcome balances. */
  readonly excessYes: bigint;
  readonly excessNo: bigint;
  readonly pool: PoolState;
}

/**
 * Mirrors `_joinPool`: joins at the current reserve ratio; deposits round up,
 * shares round down; excess outcome tokens are credited back. Returns null
 * when the pool cannot accept the join (drained reserves or a deposit too
 * small to mint one share) — the contract reverts in those cases.
 */
export function joinPool(pool: PoolState, cstIn: bigint): JoinPoolResult | null {
  const { reserveYes, reserveNo, totalShares } = pool;
  if (totalShares === 0n) throw new Error("joinPool: pool not opened yet");
  if (reserveYes === 0n || reserveNo === 0n) return null;
  const m = reserveYes > reserveNo ? reserveYes : reserveNo;
  const sharesOut = (totalShares * cstIn) / m;
  if (sharesOut === 0n) return null;
  const depositYes = ceilDiv(cstIn * reserveYes, m);
  const depositNo = ceilDiv(cstIn * reserveNo, m);
  return {
    sharesOut,
    depositYes,
    depositNo,
    excessYes: cstIn - depositYes,
    excessNo: cstIn - depositNo,
    pool: {
      ...pool,
      reserveYes: reserveYes + depositYes,
      reserveNo: reserveNo + depositNo,
      totalShares: totalShares + sharesOut,
    },
  };
}

export interface RemoveLiquidityResult {
  /** Outcome tokens credited to the LP (pro-rata, rounds down). */
  readonly yesOut: bigint;
  readonly noOut: bigint;
  readonly pool: PoolState;
}

/** Mirrors `removeLiquidity` (fees are settled separately via `pendingFees`). */
export function removeLiquidity(pool: PoolState, shares: bigint): RemoveLiquidityResult {
  if (shares === 0n || shares > pool.totalShares) throw new Error("removeLiquidity: bad share amount");
  const yesOut = (pool.reserveYes * shares) / pool.totalShares;
  const noOut = (pool.reserveNo * shares) / pool.totalShares;
  return {
    yesOut,
    noOut,
    pool: {
      ...pool,
      reserveYes: pool.reserveYes - yesOut,
      reserveNo: pool.reserveNo - noOut,
      totalShares: pool.totalShares - shares,
    },
  };
}

/** Mirrors `_pendingFees`. */
export function pendingFees(shares: bigint, accFeePerShare: bigint, feeDebt: bigint): bigint {
  return (shares * accFeePerShare) / ONE - feeDebt;
}

/**
 * The CST value of an LP position if it were withdrawn right now, marking
 * outcome tokens at the pool's own implied probability (YES worth p, NO worth
 * 1-p). An honest mark, not a guaranteed exit price.
 */
export function lpPositionValueFloat(pool: PoolState, shares: bigint, pending: bigint): number {
  if (pool.totalShares === 0n || shares === 0n) return Number(pending) / 1e18;
  const { yesOut, noOut } = removeLiquidity(pool, shares);
  const p = probabilityFloat(pool) ?? 0.5;
  return (Number(yesOut) * p + Number(noOut) * (1 - p) + Number(pending)) / 1e18;
}

// ---------------------------------------------------------------------
// Resolution & positions
// ---------------------------------------------------------------------

/** Mirrors `claim`: winning tokens pay 1 CST each, losing tokens nothing. */
export function claimValue(yesBalance: bigint, noBalance: bigint, yesWon: boolean): bigint {
  return yesWon ? yesBalance : noBalance;
}

/**
 * Mark-to-market value of an outcome position at probability `p` (a float in
 * [0,1]): YES tokens worth p CST, NO tokens worth 1-p.
 */
export function positionValueAtProbability(yesBalance: bigint, noBalance: bigint, p: number): number {
  return (Number(yesBalance) * p + Number(noBalance) * (1 - p)) / 1e18;
}

/**
 * The average YES-probability a position was effectively bought at: cost per
 * token. For a YES position, you profit if the true probability exceeds this.
 */
export function entryProbability(cstIn: bigint, tokensOut: bigint): number | null {
  if (tokensOut === 0n) return null;
  const SCALE = 1_000_000n;
  return Number((cstIn * SCALE) / tokensOut) / Number(SCALE);
}
