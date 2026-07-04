import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Header } from "./header";

let pathname = "/";
vi.mock("next/navigation", () => ({
  usePathname: () => pathname,
}));

// The wallet button needs a wagmi provider tree; the header's own concerns don't.
vi.mock("@/components/wallet/connect-button", () => ({
  ConnectButton: () => <button>Connect wallet</button>,
}));

describe("Header", () => {
  beforeEach(() => {
    pathname = "/";
  });

  it("shows a prominent beta badge", () => {
    render(<Header />);
    expect(screen.getByTestId("beta-badge")).toHaveTextContent(/beta/i);
  });

  it("links the brand home and navigates to Market and FAQ", () => {
    render(<Header />);
    expect(screen.getByRole("link", { name: /gesture/i })).toHaveAttribute("href", "/");

    const nav = screen.getByRole("navigation", { name: /primary/i });
    expect(screen.getByRole("link", { name: "Market" })).toHaveAttribute("href", "/");
    expect(screen.getByRole("link", { name: "FAQ" })).toHaveAttribute("href", "/faq");
    expect(nav).toContainElement(screen.getByRole("link", { name: "FAQ" }));
  });

  it("marks Market as current on the home page", () => {
    render(<Header />);
    expect(screen.getByRole("link", { name: "Market" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "FAQ" })).not.toHaveAttribute("aria-current");
  });

  it("marks FAQ as current on the FAQ page", () => {
    pathname = "/faq";
    render(<Header />);
    expect(screen.getByRole("link", { name: "FAQ" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "Market" })).not.toHaveAttribute("aria-current");
  });

  it("keeps the wallet entry point", () => {
    render(<Header />);
    expect(screen.getByRole("button", { name: /connect wallet/i })).toBeInTheDocument();
  });
});
