"use client";

import { Activity, Coins, Droplets, Percent, Target, TrendingUp } from "lucide-react";
import type { ReactNode } from "react";
import { formatBps, formatCount, formatCst } from "@/lib/format";
import type { RoundSnapshot } from "@/lib/market";
import { totalLiquidity } from "@/lib/market";
import { currentFeeBps } from "@/lib/math";
import { Card } from "@/components/ui/card";

interface StatsGridProps {
  snapshot: RoundSnapshot;
  volume: bigint;
}

interface Stat {
  readonly icon: ReactNode;
  readonly label: string;
  readonly value: string;
  readonly unit?: string;
  readonly hint?: string;
}

/** The round's vital signs at a glance. */
export function StatsGrid({ snapshot, volume }: StatsGridProps) {
  const funded = snapshot.pool.totalShares > 0n;
  const stats: Stat[] = [
    {
      icon: <Activity className="size-4" aria-hidden />,
      label: "Gestures so far",
      value: formatCount(snapshot.currentCount),
      hint: "bids placed in this round to date",
    },
    {
      icon: <Target className="size-4" aria-hidden />,
      label: "To beat",
      value: formatCount(snapshot.threshold),
      hint: "the previous round's final count — YES needs strictly more",
    },
    {
      icon: <TrendingUp className="size-4" aria-hidden />,
      label: "Volume",
      value: formatCst(volume),
      unit: "CST",
      hint: "total CST wagered through bets this round",
    },
    {
      icon: <Droplets className="size-4" aria-hidden />,
      label: "Liquidity",
      value: formatCst(totalLiquidity(snapshot.pool)),
      hint: "outcome tokens in the pool",
    },
    {
      icon: <Percent className="size-4" aria-hidden />,
      label: "Pool fee",
      value: funded ? formatBps(currentFeeBps(snapshot.pool)) : "—",
      hint: "the share-weighted average of all LPs' fee votes",
    },
    {
      icon: <Coins className="size-4" aria-hidden />,
      label: "LP fees unclaimed",
      value: formatCst(snapshot.pool.feeReserve),
      unit: "CST",
      hint: "earned by liquidity providers, claimable anytime",
    },
  ];

  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6" data-testid="stats-grid">
      {stats.map((stat) => (
        <Card key={stat.label} className="p-4" title={stat.hint}>
          <div className="flex items-center gap-1.5 text-ink-faint">
            {stat.icon}
            <p className="text-[10px] font-semibold uppercase tracking-wider">{stat.label}</p>
          </div>
          <p className="mt-1.5 font-mono text-sm font-semibold text-ink">
            {stat.value}
            {stat.unit && <span className="ml-1 text-[10px] font-normal text-ink-faint">{stat.unit}</span>}
          </p>
        </Card>
      ))}
    </div>
  );
}
