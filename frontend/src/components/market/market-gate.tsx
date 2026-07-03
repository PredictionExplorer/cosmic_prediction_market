"use client";

import { useSearchParams } from "next/navigation";
import { appConfig, resolveMarketAddress } from "@/lib/config";
import { Footer } from "@/components/layout/footer";
import { NoMarketConfigured } from "./empty-states";
import { MarketApp } from "./market-app";

/**
 * Decides which market to show: `?market=0x…` overrides the configured
 * default, so one deployment can serve every round's market.
 */
export function MarketGate() {
  const searchParams = useSearchParams();
  const marketAddress = resolveMarketAddress(appConfig.marketAddress, searchParams.get("market"));

  if (marketAddress === null) {
    return (
      <>
        <div className="py-16">
          <NoMarketConfigured />
        </div>
        <Footer marketAddress={null} cstAddress={null} />
      </>
    );
  }
  return <MarketApp marketAddress={marketAddress} />;
}
