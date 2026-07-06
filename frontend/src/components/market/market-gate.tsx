"use client";

import { useSearchParams } from "next/navigation";
import { appConfig, resolveMarketAddress, resolveRoundOverride } from "@/lib/config";
import { NoMarketConfigured } from "./empty-states";
import { MarketApp } from "./market-app";

/**
 * Decides what to show: the series contract from config (`?market=0x…`
 * overrides it) and the round (`?round=N` shows a past round; default follows
 * the game's current round live).
 */
export function MarketGate() {
  const searchParams = useSearchParams();
  const seriesAddress = resolveMarketAddress(appConfig.marketAddress, searchParams.get("market"));
  const roundOverride = resolveRoundOverride(searchParams.get("round"));

  if (seriesAddress === null) {
    return (
      <div className="py-16">
        <NoMarketConfigured />
      </div>
    );
  }
  return <MarketApp seriesAddress={seriesAddress} roundOverride={roundOverride} />;
}
