"use client";

import { useMemo } from "react";
import type { Address } from "viem";
import { useConnection, useReadContract, useReadContracts } from "wagmi";
import { cosmicGameAbi } from "@/lib/abi/cosmic-game";
import { erc20Abi } from "@/lib/abi/erc20";
import { gestureSeriesMarketAbi } from "@/lib/abi/gesture-series-market";
import type { LpPosition, RoundSnapshot, UserSnapshot } from "@/lib/market";
import type { TierPool } from "@/lib/math";

const REFRESH_MS = 8_000;

/** The series' immutable configuration — fetched once, cached forever. */
export interface SeriesStatics {
  readonly feeTiers: readonly number[];
  readonly cstAddress: Address;
  readonly gameAddress: Address;
}

export function useSeriesStatics(series: Address | null) {
  const contract = { address: series ?? undefined, abi: gestureSeriesMarketAbi } as const;
  const result = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...contract, functionName: "feeTiers" },
      { ...contract, functionName: "cst" },
      { ...contract, functionName: "game" },
    ],
    query: {
      enabled: series !== null,
      staleTime: Infinity,
      gcTime: Infinity,
      retry: 3,
    },
  });

  const statics: SeriesStatics | null = useMemo(() => {
    if (!result.data) return null;
    const [tiers, cstAddress, gameAddress] = result.data;
    return { feeTiers: tiers.map((t) => Number(t)), cstAddress, gameAddress };
  }, [result.data]);

  return { statics, isLoading: result.isLoading, error: result.error, refetch: result.refetch };
}

/** The game's live round counter — decides which round the app follows. */
export function useCurrentGameRound(statics: SeriesStatics | null) {
  return useReadContract({
    address: statics?.gameAddress,
    abi: cosmicGameAbi,
    functionName: "roundNum",
    query: {
      enabled: statics !== null,
      refetchInterval: REFRESH_MS,
    },
  });
}

/** Full state of one round: lifecycle flags + every tier pool. Polls. */
export function useRoundSnapshot(series: Address | null, statics: SeriesStatics | null, roundId: bigint | null) {
  const contract = { address: series ?? undefined, abi: gestureSeriesMarketAbi } as const;
  const gameContract = { address: statics?.gameAddress, abi: cosmicGameAbi } as const;
  const tiers = statics?.feeTiers ?? [];

  const result = useReadContracts({
    allowFailure: false,
    contracts:
      roundId === null
        ? []
        : [
            { ...contract, functionName: "roundState", args: [roundId] },
            { ...gameContract, functionName: "roundNum" },
            // The would-be threshold, shown before anyone initializes the round.
            { ...gameContract, functionName: "bidderAddresses", args: [roundId === 0n ? 0n : roundId - 1n] },
            ...tiers.map((tier) => ({ ...contract, functionName: "pool", args: [roundId, tier] }) as const),
          ],
    query: {
      enabled: series !== null && statics !== null && roundId !== null,
      refetchInterval: REFRESH_MS,
    },
  });

  const snapshot: RoundSnapshot | null = useMemo(() => {
    if (!series || !statics || roundId === null || !result.data) return null;
    const [state, gameRoundNum, prevRoundCount, ...poolRows] = result.data as [
      readonly [boolean, boolean, boolean, bigint, bigint, boolean, boolean],
      bigint,
      bigint,
      ...(readonly [bigint, bigint, bigint, bigint, bigint])[],
    ];
    const [initialized, resolved, yesWon, storedThreshold, currentCount] = state;
    const threshold = initialized ? storedThreshold : prevRoundCount;
    const pools: TierPool[] = poolRows.map((row, i) => ({
      feeBps: statics.feeTiers[i],
      pool: {
        reserveYes: row[0],
        reserveNo: row[1],
        totalShares: row[2],
        accFeePerShare: row[3],
        feeReserve: row[4],
      },
    }));
    return {
      seriesAddress: series,
      roundId,
      initialized,
      resolved,
      yesWon,
      threshold,
      currentCount,
      gameRoundNum,
      pools,
      cstAddress: statics.cstAddress,
      gameAddress: statics.gameAddress,
    };
  }, [series, statics, roundId, result.data]);

  return { snapshot, isLoading: result.isLoading, error: result.error, refetch: result.refetch };
}

/** The connected user's balances, allowance and LP positions for one round. */
export function useUserSnapshot(series: Address | null, statics: SeriesStatics | null, roundId: bigint | null) {
  const { address } = useConnection();
  const contract = { address: series ?? undefined, abi: gestureSeriesMarketAbi } as const;
  const cstContract = { address: statics?.cstAddress, abi: erc20Abi } as const;
  const tiers = statics?.feeTiers ?? [];

  const result = useReadContracts({
    allowFailure: false,
    contracts:
      !address || roundId === null
        ? []
        : [
            { ...contract, functionName: "balancesOf", args: [roundId, address] },
            { ...cstContract, functionName: "balanceOf", args: [address] },
            { ...cstContract, functionName: "allowance", args: [address, series ?? "0x"] },
            ...tiers.map(
              (tier) => ({ ...contract, functionName: "lpPositionOf", args: [roundId, tier, address] }) as const,
            ),
          ],
    query: {
      enabled: series !== null && statics !== null && roundId !== null && !!address,
      refetchInterval: REFRESH_MS,
    },
  });

  const user: UserSnapshot | null = useMemo(() => {
    if (!result.data || !address || !statics) return null;
    const [balances, cstBalance, cstAllowance, ...lpRows] = result.data as [
      readonly [bigint, bigint],
      bigint,
      bigint,
      ...(readonly [bigint, bigint])[],
    ];
    const lpPositions: LpPosition[] = lpRows.map((row, i) => ({
      feeBps: statics.feeTiers[i],
      shares: row[0],
      pendingFees: row[1],
    }));
    return {
      address,
      yesBalance: balances[0],
      noBalance: balances[1],
      cstBalance,
      cstAllowance,
      lpPositions,
    };
  }, [result.data, address, statics]);

  return { user, isLoading: result.isLoading, refetch: result.refetch };
}

export interface MarketState {
  readonly statics: SeriesStatics | null;
  readonly snapshot: RoundSnapshot | null;
  readonly user: UserSnapshot | null;
  /** The round the app is displaying (override or the game's current round). */
  readonly roundId: bigint | null;
  /** The game's live round (null until loaded). */
  readonly currentRound: bigint | null;
  readonly isLoading: boolean;
  readonly error: Error | null;
  readonly refetchAll: () => void;
}

/**
 * One-stop hook assembling the full view: series statics, the followed round
 * (live round unless `?round=` overrides), that round's snapshot, and the
 * connected user's stake in it.
 */
export function useMarket(series: Address | null, roundOverride: bigint | null): MarketState {
  const { statics, isLoading: staticsLoading, error: staticsError, refetch: refetchStatics } = useSeriesStatics(series);
  const currentRound = useCurrentGameRound(statics);
  const roundId = roundOverride ?? currentRound.data ?? null;
  const { snapshot, isLoading: snapshotLoading, error: snapshotError, refetch: refetchSnapshot } = useRoundSnapshot(
    series,
    statics,
    roundId,
  );
  const { user, refetch: refetchUser } = useUserSnapshot(series, statics, roundId);

  return {
    statics,
    snapshot,
    user,
    roundId,
    currentRound: currentRound.data ?? null,
    isLoading: staticsLoading || currentRound.isLoading || (roundId !== null && snapshotLoading),
    error: (staticsError ?? currentRound.error ?? snapshotError) as Error | null,
    refetchAll: () => {
      void refetchStatics();
      void currentRound.refetch();
      void refetchSnapshot();
      void refetchUser();
    },
  };
}
