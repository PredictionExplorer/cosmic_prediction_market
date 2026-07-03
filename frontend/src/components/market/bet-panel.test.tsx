import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { formatCst } from "@/lib/format";
import { minTokensOutForSlippage, ONE, quoteBet } from "@/lib/math";
import { BetPanel, type BetPanelProps } from "./bet-panel";

const RANGE = { minCount: 200n, maxCount: 1_200n };
const POOL = { reserveHigher: 10_000n * ONE, reserveLower: 10_000n * ONE };

function renderPanel(overrides: Partial<BetPanelProps> = {}) {
  const props: BetPanelProps = {
    range: RANGE,
    pool: POOL,
    feeBps: 100n,
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
  it("shows a live quote matching the contract math as the user types", async () => {
    const user = userEvent.setup();
    renderPanel();

    await user.type(screen.getByTestId("amount-input"), "100");

    // 100 CST into a balanced 10k/10k pool with 1% fee mints ~99 sets and
    // swaps the LOWER half, for ~197 HIGHER total. Assert against the shared
    // math library (itself validated against the Solidity suite).
    const expected = quoteBet("higher", POOL, 100n * ONE, 100n);
    expect(expected / ONE).toBe(197n);
    const tokens = screen.getByTestId("quote-tokens");
    expect(tokens.textContent).toContain(formatCst(expected));
    expect(tokens.textContent).toContain("HIGHER");
    // And the min-received respects the default 0.5% slippage setting.
    const minOut = minTokensOutForSlippage(expected, 50);
    expect(screen.getByText(/Min received/i).parentElement?.textContent).toContain(formatCst(minOut));
  });

  it("switches sides and re-quotes", async () => {
    const user = userEvent.setup();
    renderPanel();

    await user.type(screen.getByTestId("amount-input"), "100");
    await user.click(screen.getByTestId("tab-lower"));

    expect(screen.getByTestId("tab-lower")).toHaveAttribute("aria-selected", "true");
    expect(screen.getByTestId("quote-tokens").textContent).toContain("LOWER");
  });

  it("submits a bet with the slippage-guarded minimum", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.type(screen.getByTestId("amount-input"), "50");
    await user.click(screen.getByTestId("bet-submit"));

    const expectedQuote = quoteBet("higher", POOL, 50n * ONE, 100n);
    expect(props.onBet).toHaveBeenCalledWith(
      "higher",
      50n * ONE,
      minTokensOutForSlippage(expectedQuote, 50),
    );
  });

  it("clears the input after a successful bet", async () => {
    const user = userEvent.setup();
    renderPanel();

    const input = screen.getByTestId<HTMLInputElement>("amount-input");
    await user.type(input, "50");
    await user.click(screen.getByTestId("bet-submit"));

    expect(input.value).toBe("");
  });

  it("keeps the input after a failed bet", async () => {
    const user = userEvent.setup();
    renderPanel({ onBet: vi.fn().mockResolvedValue(false) });

    const input = screen.getByTestId<HTMLInputElement>("amount-input");
    await user.type(input, "50");
    await user.click(screen.getByTestId("bet-submit"));

    expect(input.value).toBe("50");
  });

  it("routes through approval when allowance is too low", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ allowance: 0n });

    await user.type(screen.getByTestId("amount-input"), "10");
    const button = screen.getByTestId("bet-submit");
    expect(button).toHaveTextContent(/approve cst/i);

    await user.click(button);
    expect(props.onApprove).toHaveBeenCalledWith(10n * ONE);
    expect(props.onBet).not.toHaveBeenCalled();
  });

  it("blocks amounts above the balance", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ balance: 5n * ONE });

    await user.type(screen.getByTestId("amount-input"), "10");
    const button = screen.getByTestId("bet-submit");
    expect(button).toBeDisabled();
    expect(button).toHaveTextContent(/insufficient/i);

    await user.click(button);
    expect(props.onBet).not.toHaveBeenCalled();
  });

  it("offers connect when no wallet is present", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ balance: null, allowance: null });

    const button = screen.getByTestId("bet-submit");
    expect(button).toHaveTextContent(/connect wallet/i);
    await user.click(button);
    expect(props.onConnect).toHaveBeenCalled();
  });

  it("surfaces input validation errors and disables submission", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.type(screen.getByTestId("amount-input"), "0");
    expect(screen.getByTestId("input-error")).toHaveTextContent(/more than 0/i);
    expect(screen.getByTestId("bet-submit")).toBeDisabled();

    await user.click(screen.getByTestId("bet-submit"));
    expect(props.onBet).not.toHaveBeenCalled();
  });

  it("fills the exact full balance via MAX", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ balance: 1_234n * ONE + 567n });

    await user.click(screen.getByTestId("max-button"));
    await user.click(screen.getByTestId("bet-submit"));

    expect(props.onBet).toHaveBeenCalledWith("higher", 1_234n * ONE + 567n, expect.any(BigInt));
  });

  it("changes slippage via presets", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.click(screen.getByLabelText(/slippage settings/i));
    await user.click(screen.getByRole("button", { name: "1%" }));
    await user.type(screen.getByTestId("amount-input"), "100");
    await user.click(screen.getByTestId("bet-submit"));

    const expectedQuote = quoteBet("higher", POOL, 100n * ONE, 100n);
    expect(props.onBet).toHaveBeenCalledWith("higher", 100n * ONE, minTokensOutForSlippage(expectedQuote, 100));
  });

  it("shows a spinner state while an action is pending", () => {
    renderPanel({ pendingAction: "bet" });
    expect(screen.getByTestId("bet-submit")).toBeDisabled();
    expect(screen.getByTestId("bet-submit")).toHaveTextContent(/confirming/i);
  });
});
