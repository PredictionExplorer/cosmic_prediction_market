import type { BetSide, PoolState, TierPool } from "./math";
import { aggregateProbabilityFloat, applyBet, DEAD_SHARES, EMPTY_POOL } from "./math";

/**
 * Event-sourced replay of one round's pools. The contract's events carry the
 * exact reserve deltas (deposits, net swap amounts, withdrawals), so the full
 * pool state at any point in history is reconstructible from logs alone — no
 * archive node, no backward unwinding.
 */

/** A Bet event, decoded. Ordering fields sort exactly as the chain did. */
export interface BetEvent {
  readonly kind: "bet";
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly user: `0x${string}`;
  readonly feeBps: number;
  readonly side: BetSide;
  readonly cstIn: bigint;
  readonly netIn: bigint;
  readonly tokensOut: bigint;
  readonly timestamp: number | null;
}

/** A LiquidityAdded event: `yesToPool`/`noToPool` are the exact deposits. */
export interface LiquidityAddedEvent {
  readonly kind: "add";
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly provider: `0x${string}`;
  readonly feeBps: number;
  readonly cstIn: bigint;
  readonly sharesOut: bigint;
  readonly yesToPool: bigint;
  readonly noToPool: bigint;
  readonly timestamp: number | null;
}

/** A LiquidityRemoved event: exact withdrawals. */
export interface LiquidityRemovedEvent {
  readonly kind: "remove";
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly provider: `0x${string}`;
  readonly feeBps: number;
  readonly sharesIn: bigint;
  readonly yesOut: bigint;
  readonly noOut: bigint;
  readonly feesOut: bigint;
  readonly timestamp: number | null;
}

export type PoolEvent = BetEvent | LiquidityAddedEvent | LiquidityRemovedEvent;

export interface ProbabilityPoint {
  /** Market-wide P(YES) after this event, in [0,1]. */
  readonly probability: number;
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly timestamp: number | null;
}

/** Chain order: by block, then by log index within the block. */
export function sortEvents<T extends { blockNumber: bigint; logIndex: number }>(events: readonly T[]): T[] {
  return [...events].sort((a, b) => {
    if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
    return a.logIndex - b.logIndex;
  });
}

/** Applies one event to its tier's pool, mirroring the contract exactly. */
export function applyPoolEvent(pool: PoolState, event: PoolEvent): PoolState {
  switch (event.kind) {
    case "add": {
      const opening = pool.totalShares === 0n;
      return {
        ...pool,
        reserveYes: pool.reserveYes + event.yesToPool,
        reserveNo: pool.reserveNo + event.noToPool,
        // The contract locks DEAD_SHARES on top of the first LP's shares.
        totalShares: pool.totalShares + event.sharesOut + (opening ? DEAD_SHARES : 0n),
      };
    }
    case "remove":
      return {
        ...pool,
        reserveYes: pool.reserveYes - event.yesOut,
        reserveNo: pool.reserveNo - event.noOut,
        totalShares: pool.totalShares - event.sharesIn,
        feeReserve: pool.feeReserve - event.feesOut,
      };
    case "bet":
      return applyBet(event.side, pool, event.cstIn, BigInt(event.feeBps)).pool;
  }
}

export interface ReplayResult {
  /** Market-wide probability after every event (skipping events that don't move it). */
  readonly points: ProbabilityPoint[];
  /** Final state of every tier pool touched by the events. */
  readonly pools: TierPool[];
}

/**
 * Replays all of one round's pool events forward, producing the probability
 * chart and the final per-tier pool states. The reconstruction is exact: the
 * end state must equal the current on-chain reserves (asserted in tests).
 */
export function replayRound(events: readonly PoolEvent[]): ReplayResult {
  const pools = new Map<number, PoolState>();
  const points: ProbabilityPoint[] = [];

  for (const event of sortEvents(events)) {
    const current = pools.get(event.feeBps) ?? EMPTY_POOL;
    pools.set(event.feeBps, applyPoolEvent(current, event));

    const tierPools: TierPool[] = [...pools.entries()].map(([feeBps, pool]) => ({ feeBps, pool }));
    const probability = aggregateProbabilityFloat(tierPools);
    if (probability !== null) {
      points.push({
        probability,
        blockNumber: event.blockNumber,
        logIndex: event.logIndex,
        timestamp: event.timestamp,
      });
    }
  }

  return {
    points,
    pools: [...pools.entries()]
      .map(([feeBps, pool]) => ({ feeBps, pool }))
      .sort((a, b) => a.feeBps - b.feeBps),
  };
}
