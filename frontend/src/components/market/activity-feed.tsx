"use client";

import { ArrowDown, ArrowUp, CheckCheck, Flag, Layers, Undo2 } from "lucide-react";
import type { ReactNode } from "react";
import type { ActivityEvent } from "@/hooks/use-market-events";
import { formatCount, formatCst, timeAgo } from "@/lib/format";
import { AddressLink } from "@/components/ui/address-link";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

interface ActivityFeedProps {
  events: readonly ActivityEvent[];
  isLoading: boolean;
  maxItems?: number;
}

function describe(event: ActivityEvent): { icon: ReactNode; text: ReactNode } {
  switch (event.kind) {
    case "bet": {
      const higher = event.side === "higher";
      return {
        icon: higher ? (
          <span className="flex size-7 items-center justify-center rounded-full bg-higher/12 text-higher">
            <ArrowUp className="size-3.5" aria-hidden />
          </span>
        ) : (
          <span className="flex size-7 items-center justify-center rounded-full bg-lower/12 text-lower">
            <ArrowDown className="size-3.5" aria-hidden />
          </span>
        ),
        text: (
          <>
            bet <span className="font-mono font-semibold text-ink">{formatCst(event.amount)} CST</span> on{" "}
            <span className={higher ? "font-semibold text-higher" : "font-semibold text-lower"}>
              {higher ? "HIGHER" : "LOWER"}
            </span>
          </>
        ),
      };
    }
    case "mint":
      return {
        icon: (
          <span className="flex size-7 items-center justify-center rounded-full bg-nova/12 text-nova-bright">
            <Layers className="size-3.5" aria-hidden />
          </span>
        ),
        text: (
          <>
            minted <span className="font-mono font-semibold text-ink">{formatCst(event.amount)}</span> sets
          </>
        ),
      };
    case "redeem":
      return {
        icon: (
          <span className="flex size-7 items-center justify-center rounded-full bg-nova/12 text-nova-bright">
            <Undo2 className="size-3.5" aria-hidden />
          </span>
        ),
        text: (
          <>
            redeemed <span className="font-mono font-semibold text-ink">{formatCst(event.amount)}</span> sets for CST
          </>
        ),
      };
    case "resolved":
      return {
        icon: (
          <span className="flex size-7 items-center justify-center rounded-full bg-ended/12 text-ended">
            <Flag className="size-3.5" aria-hidden />
          </span>
        ),
        text: (
          <>
            market resolved at{" "}
            <span className="font-mono font-semibold text-ended">{formatCount(event.secondary)} gestures</span>
          </>
        ),
      };
    case "claimed":
      return {
        icon: (
          <span className="flex size-7 items-center justify-center rounded-full bg-higher/12 text-higher">
            <CheckCheck className="size-3.5" aria-hidden />
          </span>
        ),
        text: (
          <>
            claimed <span className="font-mono font-semibold text-ink">{formatCst(event.amount)} CST</span>
          </>
        ),
      };
  }
}

/** Reverse-chronological feed of everything happening in the market. */
export function ActivityFeed({ events, isLoading, maxItems = 40 }: ActivityFeedProps) {
  return (
    <Card className="p-5" data-testid="activity-feed">
      <h2 className="font-display text-lg font-semibold">Activity</h2>
      {isLoading ? (
        <div className="mt-4 space-y-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-9 w-full" />
          ))}
        </div>
      ) : events.length === 0 ? (
        <p className="mt-4 rounded-xl border border-dashed border-line p-6 text-center text-sm text-ink-faint" data-testid="activity-empty">
          No activity yet — be the first to place a bet.
        </p>
      ) : (
        <ul className="scroll-thin mt-4 max-h-105 space-y-1 overflow-y-auto pr-1">
          {events.slice(0, maxItems).map((event) => {
            const { icon, text } = describe(event);
            return (
              <li
                key={`${event.transactionHash}-${event.logIndex}`}
                className="flex items-center gap-3 rounded-xl px-2 py-2 transition-colors hover:bg-surface-2/60"
              >
                {icon}
                <div className="min-w-0 flex-1 text-sm text-ink-dim">
                  {event.user ? (
                    <AddressLink address={event.user} className="mr-1.5 align-baseline" />
                  ) : null}
                  {text}
                </div>
                <div className="shrink-0 text-right">
                  <AddressLink
                    address={event.transactionHash}
                    kind="tx"
                    label={event.timestamp ? timeAgo(event.timestamp) : "view tx"}
                    className="text-[11px]"
                  />
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}
