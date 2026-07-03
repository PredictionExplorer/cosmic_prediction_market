"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo } from "react";
import type { Address, Log, PublicClient } from "viem";
import { parseEventLogs } from "viem";
import { usePublicClient, useWatchContractEvent } from "wagmi";
import { gestureMarketAbi } from "@/lib/abi/gesture-market";
import { appConfig } from "@/lib/config";
import type { BetEvent } from "@/lib/history";
import type { BetSide } from "@/lib/math";

/** Any market event, normalized for the activity feed. */
export interface ActivityEvent {
  readonly kind: "bet" | "mint" | "redeem" | "resolved" | "claimed";
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly user: `0x${string}` | null;
  readonly side: BetSide | null;
  /** Primary CST-denominated amount (bet in, set size, or claim out). */
  readonly amount: bigint;
  /** For bets: outcome tokens received. For `resolved`: the final gesture count. */
  readonly secondary: bigint;
  readonly timestamp: number | null;
}

interface EventScan {
  readonly activity: ActivityEvent[];
  readonly bets: BetEvent[];
}

/** How many of the newest events get real block timestamps (1 RPC call per block). */
const TIMESTAMPED_BLOCKS = 30;

function decodeScan(logs: Log[]): Omit<EventScan, "timestamps"> {
  const parsed = parseEventLogs({ abi: gestureMarketAbi, logs });
  const activity: ActivityEvent[] = [];
  const bets: BetEvent[] = [];

  for (const log of parsed) {
    const base = {
      blockNumber: log.blockNumber ?? 0n,
      logIndex: log.logIndex ?? 0,
      transactionHash: (log.transactionHash ?? "0x") as `0x${string}`,
      timestamp: null,
    };
    switch (log.eventName) {
      case "Bet": {
        const side: BetSide = log.args.higher ? "higher" : "lower";
        activity.push({ ...base, kind: "bet", user: log.args.user, side, amount: log.args.cstIn, secondary: log.args.tokensOut });
        bets.push({ ...base, user: log.args.user, side, cstIn: log.args.cstIn, tokensOut: log.args.tokensOut });
        break;
      }
      case "SetsMinted":
        activity.push({ ...base, kind: "mint", user: log.args.user, side: null, amount: log.args.amount, secondary: 0n });
        break;
      case "SetsRedeemed":
        activity.push({ ...base, kind: "redeem", user: log.args.user, side: null, amount: log.args.amount, secondary: 0n });
        break;
      case "Resolved":
        activity.push({
          ...base,
          kind: "resolved",
          user: null,
          side: null,
          amount: log.args.payoutPerHigher,
          secondary: log.args.finalGestureCount,
        });
        break;
      case "Claimed":
        activity.push({ ...base, kind: "claimed", user: log.args.user, side: null, amount: log.args.cstOut, secondary: 0n });
        break;
    }
  }
  return { activity, bets };
}

async function scanEvents(client: PublicClient, market: Address): Promise<EventScan> {
  const fromBlock = appConfig.deployBlock ?? "earliest";
  const logs = await client.getLogs({
    address: market,
    fromBlock,
    toBlock: "latest",
  });
  const { activity, bets } = decodeScan(logs);

  // Timestamp only the newest blocks — enough for a human activity feed,
  // cheap enough for public RPCs.
  const uniqueBlocks = [...new Set(activity.map((e) => e.blockNumber))].sort((a, b) => (a < b ? 1 : -1));
  const stamped = new Map<bigint, number>();
  await Promise.all(
    uniqueBlocks.slice(0, TIMESTAMPED_BLOCKS).map(async (bn) => {
      try {
        const block = await client.getBlock({ blockNumber: bn });
        stamped.set(bn, Number(block.timestamp));
      } catch {
        // Timestamps are cosmetic; ignore failures.
      }
    }),
  );

  const withTs = <T extends { blockNumber: bigint; timestamp: number | null }>(e: T): T => ({
    ...e,
    timestamp: stamped.get(e.blockNumber) ?? null,
  });

  return {
    activity: activity.map(withTs),
    bets: bets.map(withTs),
  };
}

/**
 * Full event history of the market plus live updates.
 *
 * Strategy: one `eth_getLogs` scan (from the configured deploy block) cached in
 * react-query, then `watchContractEvent` invalidates the scan whenever any new
 * market event lands, so all consumers refresh together.
 */
export function useMarketEvents(market: Address | null) {
  const client = usePublicClient();
  const queryClient = useQueryClient();
  const queryKey = useMemo(() => ["market-events", market] as const, [market]);

  const query = useQuery({
    queryKey,
    enabled: market !== null && !!client,
    staleTime: 30_000,
    refetchInterval: 60_000,
    queryFn: () => scanEvents(client as PublicClient, market as Address),
  });

  useWatchContractEvent({
    address: market ?? undefined,
    abi: gestureMarketAbi,
    enabled: market !== null,
    poll: true,
    pollingInterval: 8_000,
    onLogs: () => {
      void queryClient.invalidateQueries({ queryKey });
    },
  });

  // Newest-first for the activity feed.
  const activity = useMemo(() => {
    const list = query.data?.activity ?? [];
    return [...list].sort((a, b) => {
      if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? 1 : -1;
      return b.logIndex - a.logIndex;
    });
  }, [query.data]);

  const bets = query.data?.bets ?? [];

  return { activity, bets, isLoading: query.isLoading, error: query.error as Error | null };
}

/** Sum of CST wagered through bets — the market's traded volume. */
export function totalVolume(bets: readonly BetEvent[]): bigint {
  return bets.reduce((acc, b) => acc + b.cstIn, 0n);
}
