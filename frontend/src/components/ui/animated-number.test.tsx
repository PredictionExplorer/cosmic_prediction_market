import { act, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { AnimatedNumber } from "./animated-number";

describe("AnimatedNumber", () => {
  it("renders the initial value immediately", () => {
    render(<AnimatedNumber value={700} />);
    expect(screen.getByTestId("animated-number")).toHaveTextContent("700.0");
  });

  it("applies a custom formatter", () => {
    render(<AnimatedNumber value={1234.5} format={(v) => `#${Math.round(v)}`} />);
    expect(screen.getByTestId("animated-number")).toHaveTextContent("#1235");
  });

  it("settles on the new value after an update", async () => {
    vi.useFakeTimers();
    try {
      const { rerender } = render(<AnimatedNumber value={100} durationS={0.05} />);
      rerender(<AnimatedNumber value={200} durationS={0.05} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(500);
      });
      expect(screen.getByTestId("animated-number")).toHaveTextContent("200.0");
    } finally {
      vi.useRealTimers();
    }
  });
});
