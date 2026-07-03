import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { MarketError, MarketSkeleton, NoMarketConfigured } from "./empty-states";

describe("empty states", () => {
  it("NoMarketConfigured explains both configuration paths", () => {
    render(<NoMarketConfigured />);
    expect(screen.getByTestId("no-market")).toHaveTextContent("NEXT_PUBLIC_MARKET_ADDRESS");
    expect(screen.getByTestId("no-market")).toHaveTextContent("?market=0x…");
  });

  it("MarketSkeleton renders placeholder blocks", () => {
    render(<MarketSkeleton />);
    expect(screen.getByTestId("market-skeleton")).toBeInTheDocument();
  });

  it("MarketError surfaces the message and retries", async () => {
    const user = userEvent.setup();
    const onRetry = vi.fn();
    render(<MarketError message="RPC unreachable" onRetry={onRetry} />);

    expect(screen.getByTestId("market-error")).toHaveTextContent("RPC unreachable");
    await user.click(screen.getByRole("button", { name: /try again/i }));
    expect(onRetry).toHaveBeenCalled();
  });
});
