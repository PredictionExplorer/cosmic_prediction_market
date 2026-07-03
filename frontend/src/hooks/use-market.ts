"use client";

import { useMemo } from "react";
import type { Address } from "viem";
import { useConnection, useReadContracts } from "wagmi";
import { cosmicGameAbi } from "@/lib/abi/cosmic-game";
import { erc20Abi } from "@/lib/abi/erc20";
import { gestureMarketAbi } from "@/lib/abi/gesture-market";
import type { MarketSnapshot, UserSnapshot } from "@/lib/market";

const REFRESH_MS = 8_000;

/** The market's immutable configuration — fetched once, cached forever. */
export interface MarketStatics {
  readonly round: bigint;
  readonly minCount: bigint;
  readonly maxCount: bigint;
  readonly feeBps: bigint;
  readonly creator: Address;
  readonly cstAddress: Address;
  readonly gameAddress: Address;
}

export function useMarketStatics(market: Address | null) {
  const contract = { address: market ?? undefined, abi: gestureMarketAbi } as const;
  const result = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...contract, functionName: "round" },
      { ...contract, functionName: "minCount" },
      { ...contract, functionName: "maxCount" },
      { ...contract, functionName: "feeBps" },
      { ...contract, functionName: "creator" },
      { ...contract, functionName: "cst" },
      { ...contract, functionName: "game" },
    ],
    query: {
      enabled: market !== null,
      staleTime: Infinity,
      gcTime: Infinity,
      retry: 3,
    },
  });

  const statics: MarketStatics | null = useMemo(() => {
    if (!result.data) return null;
    const [round, minCount, maxCount, feeBps, creator, cstAddress, gameAddress] = result.data;
    return { round, minCount, maxCount, feeBps, creator, cstAddress, gameAddress };
  }, [result.data]);

  return { statics, isLoading: result.isLoading, error: result.error, refetch: result.refetch };
}

/** The live, changing part of the market + game state. Polls every few seconds. */
export function useMarketDynamics(market: Address | null, statics: MarketStatics | null) {
  const marketContract = { address: market ?? undefined, abi: gestureMarketAbi } as const;
  const gameContract = { address: statics?.gameAddress, abi: cosmicGameAbi } as const;

  const result = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...marketContract, functionName: "reserveHigher" },
      { ...marketContract, functionName: "reserveLower" },
      { ...marketContract, functionName: "resolved" },
      { ...marketContract, functionName: "finalGestureCount" },
      { ...marketContract, functionName: "payoutPerHigher" },
      { ...marketContract, functionName: "feesAccrued" },
      { ...gameContract, functionName: "roundNum" },
      { ...gameContract, functionName: "bidderAddresses", args: statics ? [statics.round] : undefined },
    ],
    query: {
      enabled: market !== null && statics !== null,
      refetchInterval: REFRESH_MS,
    },
  });

  return result;
}

/** The connected user's balances and allowance. Polls alongside the market. */
export function useUserSnapshot(market: Address | null, statics: MarketStatics | null) {
  const { address } = useConnection();
  const marketContract = { address: market ?? undefined, abi: gestureMarketAbi } as const;
  const cstContract = { address: statics?.cstAddress, abi: erc20Abi } as const;

  const result = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...marketContract, functionName: "higherBalance", args: address ? [address] : undefined },
      { ...marketContract, functionName: "lowerBalance", args: address ? [address] : undefined },
      { ...cstContract, functionName: "balanceOf", args: address ? [address] : undefined },
      {
        ...cstContract,
        functionName: "allowance",
        args: address && market ? [address, market] : undefined,
      },
    ],
    query: {
      enabled: market !== null && statics !== null && !!address,
      refetchInterval: REFRESH_MS,
    },
  });

  const user: UserSnapshot | null = useMemo(() => {
    if (!result.data || !address) return null;
    const [higherBalance, lowerBalance, cstBalance, cstAllowance] = result.data;
    return { address, higherBalance, lowerBalance, cstBalance, cstAllowance };
  }, [result.data, address]);

  return { user, isLoading: result.isLoading, refetch: result.refetch };
}

export interface MarketState {
  readonly snapshot: MarketSnapshot | null;
  readonly user: UserSnapshot | null;
  readonly isLoading: boolean;
  readonly error: Error | null;
  readonly refetchAll: () => void;
}

/** One-stop hook assembling the full market view the UI renders from. */
export function useMarket(market: Address | null): MarketState {
  const { statics, isLoading: staticsLoading, error: staticsError, refetch: refetchStatics } = useMarketStatics(market);
  const dynamics = useMarketDynamics(market, statics);
  const { user, refetch: refetchUser } = useUserSnapshot(market, statics);

  const snapshot: MarketSnapshot | null = useMemo(() => {
    if (!market || !statics || !dynamics.data) return null;
    const [reserveHigher, reserveLower, resolved, finalGestureCount, payoutPerHigher, feesAccrued, gameRoundNum, liveGestureCount] =
      dynamics.data;
    return {
      address: market,
      ...statics,
      reserveHigher,
      reserveLower,
      resolved,
      finalGestureCount,
      payoutPerHigher,
      feesAccrued,
      gameRoundNum,
      liveGestureCount,
    };
  }, [market, statics, dynamics.data]);

  return {
    snapshot,
    user,
    isLoading: staticsLoading || (statics !== null && dynamics.isLoading),
    error: (staticsError ?? dynamics.error) as Error | null,
    refetchAll: () => {
      void refetchStatics();
      void dynamics.refetch();
      void refetchUser();
    },
  };
}
