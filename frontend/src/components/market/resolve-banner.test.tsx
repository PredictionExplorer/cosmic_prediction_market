import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { RoundSnapshot } from "@/lib/market";
import { ONE } from "@/lib/math";
import { ResolveBanner } from "./resolve-banner";

const SERIES = "0x1111111111111111111111111111111111111111" as const;

function snapshot(overrides: Partial<RoundSnapshot> = {}): RoundSnapshot {
  return {
    seriesAddress: SERIES,
    roundId: 5n,
    initialized: true,
    thresholdKnown: true,
    resolved: false,
    yesWon: false,
    threshold: 800n,
    currentCount: 750n,
    gameRoundNum: 6n, // the game moved on: this round has ended
    prevRoundCount: 800n,
    pool: {
      reserveYes: 1_000n * ONE,
      reserveNo: 1_000n * ONE,
      totalShares: 1_000n * ONE,
      accFeePerShare: 0n,
      feeReserve: 0n,
      feeWeight: 1_000n * ONE * 200n,
    },
    cstAddress: "0x2222222222222222222222222222222222222222",
    gameAddress: "0x3333333333333333333333333333333333333333",
    ...overrides,
  };
}

function renderBanner(overrides: Partial<Parameters<typeof ResolveBanner>[0]> = {}) {
  const props = {
    snapshot: snapshot(),
    pending: false,
    connected: true,
    onResolve: vi.fn().mockResolvedValue(true),
    onConnect: vi.fn(),
    ...overrides,
  };
  const utils = render(<ResolveBanner {...props} />);
  return { props, ...utils };
}

describe("ResolveBanner", () => {
  it("shows the ended round with its final count and resolves on click", async () => {
    const user = userEvent.setup();
    const { props } = renderBanner();

    expect(screen.getByText(/the round has ended/i)).toBeInTheDocument();
    expect(screen.getByTestId("banner-count")).toHaveTextContent("750");
    await user.click(screen.getByTestId("resolve-button"));
    expect(props.onResolve).toHaveBeenCalled();
  });

  it("frames an early YES resolution as already decided", () => {
    renderBanner({ snapshot: snapshot({ gameRoundNum: 5n, currentCount: 801n }) });
    expect(screen.getByText(/YES already won/i)).toBeInTheDocument();
    expect(screen.getByText(/trading halted automatically/i)).toBeInTheDocument();
  });

  it("asks to connect first when no wallet is present", async () => {
    const user = userEvent.setup();
    const { props } = renderBanner({ connected: false });

    await user.click(screen.getByTestId("resolve-button"));
    expect(props.onConnect).toHaveBeenCalled();
    expect(props.onResolve).not.toHaveBeenCalled();
  });

  it("explains permissionless resolution in a tooltip", async () => {
    const user = userEvent.setup();
    renderBanner();

    await user.hover(screen.getByRole("button", { name: "About resolving" }));
    const tip = screen.getByRole("tooltip");
    expect(tip).toHaveTextContent(/permissionless by design/i);
    expect(tip).toHaveTextContent(/no admin, no oracle committee/i);
  });
});
