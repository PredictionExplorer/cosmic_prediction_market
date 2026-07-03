"use client";

import { useMemo, useState } from "react";
import { useChainId, useConnection } from "wagmi";
import { useMarket } from "@/hooks/use-market";
import { useMarketActions } from "@/hooks/use-market-actions";
import { totalVolume, useMarketEvents } from "@/hooks/use-market-events";
import { appConfig } from "@/lib/config";
import { deriveOpeningLiquidity, replayHistory } from "@/lib/history";
import { hasPosition, marketPhase, marketRange, poolState, userEntries } from "@/lib/market";
import { breakEvenCount } from "@/lib/math";
import type { Address } from "viem";
import { Footer } from "@/components/layout/footer";
import { WalletModal } from "@/components/wallet/wallet-modal";
import { ActivityFeed } from "./activity-feed";
import { BetPanel } from "./bet-panel";
import { MarketError, MarketSkeleton } from "./empty-states";
import { HowItWorks } from "./how-it-works";
import { MarketHero } from "./market-hero";
import { PositionPanel } from "./position-panel";
import { ResolveBanner } from "./resolve-banner";
import { StatsGrid } from "./stats-grid";

interface MarketAppProps {
  marketAddress: Address;
}

/** Wires all hooks together and lays out the trading screen. */
export function MarketApp({ marketAddress }: MarketAppProps) {
  const { snapshot, user, isLoading, error, refetchAll } = useMarket(marketAddress);
  const events = useMarketEvents(marketAddress);
  const actions = useMarketActions(marketAddress);
  const connection = useConnection();
  const chainId = useChainId();
  const [walletModalOpen, setWalletModalOpen] = useState(false);

  const history = useMemo(() => {
    if (!snapshot) return [];
    // Recover the opening pool from current reserves + recorded bets (exact,
    // no archive node needed), then replay forward for the chart.
    const opening = deriveOpeningLiquidity(poolState(snapshot), snapshot.feeBps, events.bets);
    if (opening === null || opening <= 0n) return [];
    return replayHistory(marketRange(snapshot), opening, snapshot.feeBps, events.bets).points;
  }, [snapshot, events.bets]);

  const breakEven = useMemo(() => {
    if (!snapshot || !user || !hasPosition(user) || user.higherBalance === user.lowerBalance) return null;
    const entries = userEntries(marketRange(snapshot), events.bets, user.address);
    // Prefer the wagered-cost break-even when we have the user's bet history.
    if (entries.totalWagered > 0n) {
      return breakEvenCount(marketRange(snapshot), user.higherBalance, user.lowerBalance, entries.totalWagered);
    }
    return null;
  }, [snapshot, user, events.bets]);

  if (error && !snapshot) {
    return (
      <>
        <MarketError message={error.message} onRetry={refetchAll} />
        <Footer marketAddress={marketAddress} cstAddress={null} />
      </>
    );
  }
  if (isLoading || !snapshot) {
    return <MarketSkeleton />;
  }

  const phase = marketPhase(snapshot);
  const wrongChain = connection.status === "connected" && chainId !== appConfig.chain.id;
  const connected = connection.status === "connected" && !wrongChain;

  return (
    <div className="space-y-6">
      {phase === "ended" && (
        <ResolveBanner
          snapshot={snapshot}
          pending={actions.pending === "resolve"}
          connected={connected}
          onResolve={actions.resolve}
          onConnect={() => setWalletModalOpen(true)}
        />
      )}

      <div className="grid items-start gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <MarketHero snapshot={snapshot} history={history} breakEven={breakEven} />
          <StatsGrid snapshot={snapshot} volume={totalVolume(events.bets)} />
        </div>

        <div className="space-y-6">
          {phase === "live" && (
            <BetPanel
              range={marketRange(snapshot)}
              pool={poolState(snapshot)}
              feeBps={snapshot.feeBps}
              balance={connected && user ? user.cstBalance : null}
              allowance={connected && user ? user.cstAllowance : null}
              pendingAction={actions.pending === "approve" || actions.pending === "bet" ? actions.pending : null}
              onConnect={() => setWalletModalOpen(true)}
              onApprove={(amount) => actions.approve(snapshot.cstAddress, amount)}
              onBet={actions.bet}
            />
          )}
          {user && connected && (
            <PositionPanel
              snapshot={snapshot}
              user={user}
              breakEven={breakEven}
              pendingAction={actions.pending === "redeem" || actions.pending === "claim" ? actions.pending : null}
              onRedeemSets={actions.redeemSets}
              onClaim={actions.claim}
            />
          )}
          <ActivityFeed events={events.activity} isLoading={events.isLoading} />
        </div>
      </div>

      <HowItWorks />

      <Footer marketAddress={snapshot.address} cstAddress={snapshot.cstAddress} />

      <WalletModal open={walletModalOpen} onClose={() => setWalletModalOpen(false)} />
    </div>
  );
}
