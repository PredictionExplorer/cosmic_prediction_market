import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { formatCst } from "@/lib/format";
import { bestTier, minTokensOutForSlippage, ONE, quoteBet, type TierPool } from "@/lib/math";
import { BetPanel, type BetPanelProps } from "./bet-panel";

const LIQ = 10_000n * ONE;

function tierPool(feeBps: number, reserveYes: bigint, reserveNo: bigint, totalShares = LIQ): TierPool {
  return { feeBps, pool: { reserveYes, reserveNo, totalShares, accFeePerShare: 0n, feeReserve: 0n } };
}

/** Three funded tiers with identical reserves — the 1% tier quotes best. */
const POOLS: TierPool[] = [tierPool(100, LIQ, LIQ), tierPool(200, LIQ, LIQ), tierPool(500, LIQ, LIQ)];

function renderPanel(overrides: Partial<BetPanelProps> = {}) {
  const props: BetPanelProps = {
    pools: POOLS,
    balance: 1_000n * ONE,
    allowance: 10_000_000n * ONE,
    pendingAction: null,
    onConnect: vi.fn(),
    onApprove: vi.fn().mockResolvedValue(true),
    onBet: vi.fn().mockResolvedValue(true),
    ...overrides,
  };
  const utils = render(<BetPanel {...props} />);
  return { props, ...utils };
}

describe("BetPanel", () => {
  it("quotes with the shared math library and routes to the best tier", async () => {
    const user = userEvent.setup();
    renderPanel();

    await user.type(screen.getByTestId("amount-input"), "100");

    // Identical pools: routing must pick the cheapest fee (1%).
    const routed = bestTier("yes", POOLS, 100n * ONE);
    expect(routed?.feeBps).toBe(100);
    expect(screen.getByTestId("tier-auto-label")).toBeInTheDocument();
    const tokens = screen.getByTestId("quote-tokens");
    expect(tokens.textContent).toContain(formatCst(routed!.tokensOut));
    expect(tokens.textContent).toContain("YES");
    const minOut = minTokensOutForSlippage(routed!.tokensOut, 50);
    expect(screen.getByTestId("quote-min-out").textContent).toContain(formatCst(minOut));
  });

  it("re-routes to another tier when the cheap pool is skewed", async () => {
    const user = userEvent.setup();
    // The 1% pool has terrible YES pricing (tiny YES reserve).
    const pools = [tierPool(100, ONE, LIQ * 2n), tierPool(200, LIQ, LIQ), tierPool(500, LIQ, LIQ)];
    renderPanel({ pools });

    await user.type(screen.getByTestId("amount-input"), "100");

    const routed = bestTier("yes", pools, 100n * ONE);
    expect(routed?.feeBps).toBe(200);
    // The routed tier is marked "best" in the tier selector.
    expect(screen.getByTestId("tier-200").textContent).toMatch(/best/i);
  });

  it("lets the user override the routed tier and submits with it", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.type(screen.getByTestId("amount-input"), "50");
    await user.click(screen.getByTestId("tier-500"));
    await user.click(screen.getByTestId("bet-submit"));

    const expected = quoteBet("yes", POOLS[2].pool, 50n * ONE, 500n);
    expect(props.onBet).toHaveBeenCalledWith("yes", 500, 50n * ONE, minTokensOutForSlippage(expected, 50));
  });

  it("switches sides and submits NO bets", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.click(screen.getByTestId("tab-no"));
    await user.type(screen.getByTestId("amount-input"), "50");
    await user.click(screen.getByTestId("bet-submit"));

    expect(screen.getByTestId("tab-no")).toHaveAttribute("aria-selected", "true");
    const routed = bestTier("no", POOLS, 50n * ONE);
    expect(props.onBet).toHaveBeenCalledWith(
      "no",
      routed!.feeBps,
      50n * ONE,
      minTokensOutForSlippage(routed!.tokensOut, 50),
    );
  });

  it("disables unfunded tiers", async () => {
    const user = userEvent.setup();
    renderPanel({ pools: [tierPool(100, LIQ, LIQ), tierPool(200, 0n, 0n, 0n), tierPool(500, LIQ, LIQ)] });
    await user.type(screen.getByTestId("amount-input"), "10");
    expect(screen.getByTestId("tier-200")).toBeDisabled();
  });

  it("routes through approval when allowance is too low", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ allowance: 0n });

    await user.type(screen.getByTestId("amount-input"), "10");
    expect(screen.getByTestId("bet-submit")).toHaveTextContent(/approve/i);
    await user.click(screen.getByTestId("bet-submit"));

    expect(props.onApprove).toHaveBeenCalledWith(10n * ONE);
    expect(props.onBet).not.toHaveBeenCalled();
  });

  it("blocks oversized bets and flags bad input", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ balance: 5n * ONE });

    await user.type(screen.getByTestId("amount-input"), "10");
    expect(screen.getByTestId("bet-submit")).toHaveTextContent(/insufficient/i);
    await user.click(screen.getByTestId("bet-submit"));
    expect(props.onBet).not.toHaveBeenCalled();

    await user.clear(screen.getByTestId("amount-input"));
    await user.type(screen.getByTestId("amount-input"), "1.2.3");
    expect(screen.getByTestId("input-error")).toBeInTheDocument();
  });

  it("prompts to connect when no wallet is present", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ balance: null, allowance: null });

    expect(screen.getByTestId("bet-submit")).toHaveTextContent(/connect wallet/i);
    await user.click(screen.getByTestId("bet-submit"));
    expect(props.onConnect).toHaveBeenCalled();
  });

  it("clears the input only after a successful bet", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ onBet: vi.fn().mockResolvedValue(false) });

    const input = screen.getByTestId<HTMLInputElement>("amount-input");
    await user.type(input, "50");
    await user.click(screen.getByTestId("bet-submit"));
    expect(props.onBet).toHaveBeenCalled();
    expect(input.value).toBe("50");
  });
});
