"use client";

import { Sparkles } from "lucide-react";
import { formatCount } from "@/lib/format";
import type { MarketSnapshot } from "@/lib/market";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

interface ResolveBannerProps {
  snapshot: MarketSnapshot;
  pending: boolean;
  connected: boolean;
  onResolve: () => Promise<boolean>;
  onConnect: () => void;
}

/** Shown when the round has ended but `resolve()` hasn't been called yet. */
export function ResolveBanner({ snapshot, pending, connected, onResolve, onConnect }: ResolveBannerProps) {
  return (
    <Card accent="ended" className="p-5" data-testid="resolve-banner">
      <div className="flex flex-col items-start justify-between gap-4 sm:flex-row sm:items-center">
        <div>
          <h2 className="flex items-center gap-2 font-display text-lg font-semibold text-ended">
            <Sparkles className="size-5" aria-hidden />
            The round has ended
          </h2>
          <p className="mt-1 text-sm text-ink-dim">
            Final count: <span className="font-mono font-semibold text-ink">{formatCount(snapshot.liveGestureCount)}</span>{" "}
            gestures. Anyone can now resolve the market to fix payouts and unlock claims — one
            transaction, no special permissions.
          </p>
        </div>
        <Button
          variant="ended"
          size="lg"
          loading={pending}
          onClick={() => (connected ? void onResolve() : onConnect())}
          data-testid="resolve-button"
        >
          {connected ? "Resolve market" : "Connect to resolve"}
        </Button>
      </div>
    </Card>
  );
}
