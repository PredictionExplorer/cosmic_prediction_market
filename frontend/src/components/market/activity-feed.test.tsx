import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { ActivityEvent } from "@/hooks/use-market-events";
import { ONE } from "@/lib/math";
import { ActivityFeed } from "./activity-feed";

function event(partial: Partial<ActivityEvent>): ActivityEvent {
  return {
    kind: "bet",
    blockNumber: 1n,
    logIndex: 0,
    transactionHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    user: "0x5555555555555555555555555555555555555555",
    side: "higher",
    amount: 100n * ONE,
    secondary: 105n * ONE,
    timestamp: null,
    ...partial,
  };
}

describe("ActivityFeed", () => {
  it("shows skeletons while loading", () => {
    render(<ActivityFeed events={[]} isLoading />);
    expect(screen.getAllByTestId("skeleton").length).toBeGreaterThan(0);
  });

  it("shows an empty state without events", () => {
    render(<ActivityFeed events={[]} isLoading={false} />);
    expect(screen.getByTestId("activity-empty")).toHaveTextContent(/no activity yet/i);
  });

  it("describes each event kind in plain language", () => {
    const events: ActivityEvent[] = [
      event({ kind: "bet", side: "higher", logIndex: 0 }),
      event({ kind: "bet", side: "lower", logIndex: 1, amount: 25n * ONE }),
      event({ kind: "mint", side: null, logIndex: 2, amount: 10n * ONE }),
      event({ kind: "redeem", side: null, logIndex: 3, amount: 4n * ONE }),
      event({ kind: "resolved", side: null, user: null, logIndex: 4, secondary: 987n }),
      event({ kind: "claimed", side: null, logIndex: 5, amount: 55n * ONE }),
    ];
    render(<ActivityFeed events={events} isLoading={false} />);

    expect(screen.getByText("HIGHER")).toBeInTheDocument();
    expect(screen.getByText("LOWER")).toBeInTheDocument();
    expect(screen.getByText(/minted/)).toBeInTheDocument();
    expect(screen.getByText(/redeemed/)).toBeInTheDocument();
    expect(screen.getByText(/market resolved at/)).toBeInTheDocument();
    expect(screen.getByText("987 gestures")).toBeInTheDocument();
    expect(screen.getByText(/claimed/)).toBeInTheDocument();
  });

  it("caps the list at maxItems", () => {
    const events = Array.from({ length: 10 }, (_, i) => event({ logIndex: i }));
    render(<ActivityFeed events={events} isLoading={false} maxItems={3} />);
    expect(screen.getAllByRole("listitem")).toHaveLength(3);
  });
});
