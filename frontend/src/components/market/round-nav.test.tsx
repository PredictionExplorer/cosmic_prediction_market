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
    expect(screen.queryByTestId("round-future")).not.toBeInTheDocument();
  });

  it("cannot navigate before round 1; forward navigation is always open", () => {
    render(<RoundNav roundId={1n} currentRound={1n} />);
    expect(screen.getByTestId("round-prev")).toBeDisabled();
    expect(screen.getByTestId("round-next")).toBeEnabled();
  });

  it("navigates into future rounds and marks them", async () => {
    const user = userEvent.setup();
    render(<RoundNav roundId={9n} currentRound={7n} />);

    expect(screen.getByTestId("round-future")).toHaveTextContent(/future/i);
    expect(screen.getByTestId("round-live")).toBeInTheDocument();

    await user.click(screen.getByTestId("round-next"));
    expect(push).toHaveBeenCalledWith("/?round=10");
  });

  it("disables forward navigation only while the live round is unknown", () => {
    render(<RoundNav roundId={5n} currentRound={null} />);
    expect(screen.getByTestId("round-next")).toBeDisabled();
    expect(screen.queryByTestId("round-future")).not.toBeInTheDocument();
  });
});
