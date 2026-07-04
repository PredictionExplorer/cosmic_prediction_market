import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { RoundNav } from "./round-nav";

const push = vi.fn();
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
  usePathname: () => "/",
  useSearchParams: () => new URLSearchParams("round=5"),
}));

describe("RoundNav", () => {
  beforeEach(() => {
    push.mockClear();
  });

  it("navigates between adjacent rounds via the ?round= param", async () => {
    const user = userEvent.setup();
    render(<RoundNav roundId={5n} currentRound={7n} />);

    await user.click(screen.getByTestId("round-prev"));
    expect(push).toHaveBeenCalledWith("/?round=4");

    await user.click(screen.getByTestId("round-next"));
    expect(push).toHaveBeenCalledWith("/?round=6");
  });

  it("jumps back to live by clearing the override", async () => {
    const user = userEvent.setup();
    render(<RoundNav roundId={5n} currentRound={7n} />);

    await user.click(screen.getByTestId("round-live"));
    expect(push).toHaveBeenCalledWith("/");
  });

  it("hides the live button when already following the live round", () => {
    render(<RoundNav roundId={7n} currentRound={7n} />);
    expect(screen.queryByTestId("round-live")).not.toBeInTheDocument();
  });

  it("cannot navigate before round 1 or past the live round", () => {
    render(<RoundNav roundId={1n} currentRound={1n} />);
    expect(screen.getByTestId("round-prev")).toBeDisabled();
    expect(screen.getByTestId("round-next")).toBeDisabled();
  });
});
