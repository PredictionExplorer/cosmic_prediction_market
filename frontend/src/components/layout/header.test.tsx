import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { Header } from "./header";

describe("Header", () => {
  it("shows a prominent beta badge", () => {
    render(<Header active="market" />);
    expect(screen.getByTestId("beta-badge")).toHaveTextContent(/beta/i);
  });

  it("explains what beta means on hover", async () => {
    const user = userEvent.setup();
    render(<Header active="market" />);

    await user.hover(screen.getByTestId("beta-badge"));
    expect(screen.getByRole("tooltip")).toHaveTextContent(/size your bets accordingly/i);
  });

  it("links the brand home and navigates to Market and FAQ", () => {
    render(<Header active="market" />);
    expect(screen.getByRole("link", { name: /chaos/i })).toHaveAttribute("href", "/");

    const nav = screen.getByRole("navigation", { name: /primary/i });
    expect(screen.getByRole("link", { name: "Market" })).toHaveAttribute("href", "/");
    expect(screen.getByRole("link", { name: "FAQ" })).toHaveAttribute("href", "/faq");
    expect(nav).toContainElement(screen.getByRole("link", { name: "FAQ" }));
  });

  it("marks Market as current on the market page", () => {
    render(<Header active="market" />);
    expect(screen.getByRole("link", { name: "Market" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "FAQ" })).not.toHaveAttribute("aria-current");
  });

  it("marks FAQ as current on the FAQ page", () => {
    render(<Header active="faq" />);
    expect(screen.getByRole("link", { name: "FAQ" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "Market" })).not.toHaveAttribute("aria-current");
  });

  it("renders whatever action the page provides (wallet button, CTA…)", () => {
    render(<Header active="market" actions={<button>Connect wallet</button>} />);
    expect(screen.getByRole("button", { name: /connect wallet/i })).toBeInTheDocument();
  });

  it("keeps the outbound link to the game", () => {
    render(<Header active="market" />);
    const link = screen.getByRole("link", { name: /play cosmic signature/i });
    expect(link).toHaveAttribute("href", "https://cosmicsignature.com");
    expect(link).toHaveAttribute("rel", expect.stringContaining("noopener"));
  });
});
