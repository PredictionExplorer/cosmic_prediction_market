"use client";

import { Activity, Coins, Droplets, Percent, Ruler, TrendingUp } from "lucide-react";
import type { ReactNode } from "react";
import { formatBps, formatCount, formatCst } from "@/lib/format";
import type { MarketSnapshot } from "@/lib/market";
import { Card } from "@/components/ui/card";

interface StatsGridProps {
  snapshot: MarketSnapshot;
  volume: bigint;
}

interface Stat {
  readonly icon: ReactNode;
  readonly label: string;
  readonly value: string;
  readonly unit?: string;
  readonly hint?: string;
}

/** The market's vital signs at a glance. */
export function StatsGrid({ snapshot, volume }: StatsGridProps) {
  const liquidity = snapshot.reserveHigher + snapshot.reserveLower;
  const stats: Stat[] = [
    {
      icon: <Activity className="size-4" aria-hidden />,
      label: "Gestures so far",
      value: formatCount(snapshot.liveGestureCount),
      hint: "bids placed in this round to date",
    },
    {
      icon: <Ruler className="size-4" aria-hidden />,
      label: "Range",
      value: `${formatCount(snapshot.minCount)}–${formatCount(snapshot.maxCount)}`,
      hint: "payouts clamp outside this range",
    },
    {
      icon: <TrendingUp className="size-4" aria-hidden />,
      label: "Volume",
      value: formatCst(volume),
      unit: "CST",
      hint: "total CST wagered through bets",
    },
    {
      icon: <Droplets className="size-4" aria-hidden />,
      label: "Liquidity",
      value: formatCst(liquidity),
      unit: "CST",
      hint: "outcome tokens in the trading pool",
    },
    {
      icon: <Percent className="size-4" aria-hidden />,
      label: "Trading fee",
      value: formatBps(snapshot.feeBps),
      hint: "charged per bet, paid to the market creator",
    },
    {
      icon: <Coins className="size-4" aria-hidden />,
      label: "Fees accrued",
      value: formatCst(snapshot.feesAccrued),
      unit: "CST",
      hint: "collected so far this round",
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
