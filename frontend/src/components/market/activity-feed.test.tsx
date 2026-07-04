import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { ActivityEvent } from "@/hooks/use-market-events";
import { ONE } from "@/lib/math";
import { ActivityFeed } from "./activity-feed";

let logIndex = 0;
function event(overrides: Partial<ActivityEvent>): ActivityEvent {
  return {
    kind: "bet",
    blockNumber: 100n,
    logIndex: logIndex++,
    transactionHash: "0xabc",
    user: "0x1234567890123456789012345678901234567890",
    side: null,
    feeBps: null,
    amount: 0n,
    secondary: 0n,
    yesWon: null,
    timestamp: null,
    ...overrides,
  };
}

describe("ActivityFeed", () => {
  it("shows an empty state without events", () => {
    render(<ActivityFeed events={[]} isLoading={false} />);
    expect(screen.getByTestId("activity-empty")).toBeInTheDocument();
  });

  it("describes every event kind in plain language", () => {
    const events: ActivityEvent[] = [
      event({ kind: "bet", side: "yes", amount: 50n * ONE, secondary: 98n * ONE }),
      event({ kind: "bet", side: "no", amount: 10n * ONE }),
      event({ kind: "add", feeBps: 200, amount: 1_000n * ONE }),
      event({ kind: "remove", amount: 400n * ONE }),
      event({ kind: "feeVote", feeBps: 500, secondary: 200n }),
      event({ kind: "feesClaimed", amount: 3n * ONE }),
      event({ kind: "mint", amount: 25n * ONE }),
      event({ kind: "redeem", amount: 5n * ONE }),
      event({ kind: "resolved", user: null, secondary: 950n, yesWon: true }),
      event({ kind: "claimed", amount: 75n * ONE }),
    ];
    render(<ActivityFeed events={events} isLoading={false} />);

    const feed = screen.getByTestId("activity-feed");
    expect(feed).toHaveTextContent(/bet 50 CST on YES/);
    expect(feed).toHaveTextContent(/bet 10 CST on NO/);
    expect(feed).toHaveTextContent(/added 1,000 CST of liquidity · voting 2%/);
    expect(feed).toHaveTextContent(/removed liquidity from the pool/);
    expect(feed).toHaveTextContent(/re-voted the fee to 5%/);
    expect(feed).toHaveTextContent(/claimed 3 CST in LP fees/);
    expect(feed).toHaveTextContent(/minted 25 sets/);
    expect(feed).toHaveTextContent(/redeemed 5 sets for CST/);
    expect(feed).toHaveTextContent(/round resolved YES at 950 gestures/);
    expect(feed).toHaveTextContent(/claimed 75 CST/);
  });

  it("respects maxItems", () => {
    const events = Array.from({ length: 10 }, (_, i) =>
      event({ kind: "mint", amount: BigInt(i + 1) * ONE, logIndex: i }),
    );
    render(<ActivityFeed events={events} isLoading={false} maxItems={3} />);
    expect(screen.getByTestId("activity-feed").querySelectorAll("li")).toHaveLength(3);
  });
});
