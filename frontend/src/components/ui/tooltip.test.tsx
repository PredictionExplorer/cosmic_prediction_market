import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { InfoTip, Tooltip } from "./tooltip";

describe("Tooltip", () => {
  it("stays hidden until triggered", () => {
    render(<Tooltip content="An explanation">trigger</Tooltip>);
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("opens on hover and closes on unhover", async () => {
    const user = userEvent.setup();
    render(<Tooltip content="An explanation">trigger</Tooltip>);

    await user.hover(screen.getByText("trigger"));
    expect(screen.getByRole("tooltip")).toHaveTextContent("An explanation");

    await user.unhover(screen.getByText("trigger"));
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("opens on keyboard focus and closes on blur", async () => {
    const user = userEvent.setup();
    render(
      <>
        <Tooltip content="An explanation">trigger</Tooltip>
        <button>elsewhere</button>
      </>,
    );

    await user.tab();
    expect(screen.getByRole("tooltip")).toBeInTheDocument();

    await user.tab();
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("closes on Escape", async () => {
    const user = userEvent.setup();
    render(<Tooltip content="An explanation">trigger</Tooltip>);

    await user.hover(screen.getByText("trigger"));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("opens on tap and closes on an outside tap", async () => {
    const user = userEvent.setup();
    render(
      <>
        <Tooltip content="An explanation">trigger</Tooltip>
        <p>outside</p>
      </>,
    );

    await user.click(screen.getByText("trigger"));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();

    await user.click(screen.getByText("outside"));
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("wires aria-describedby from the focusable wrapper to the bubble", async () => {
    const user = userEvent.setup();
    render(<Tooltip content="An explanation">trigger</Tooltip>);

    const wrapper = screen.getByText("trigger");
    expect(wrapper).toHaveAttribute("tabindex", "0");
    expect(wrapper).not.toHaveAttribute("aria-describedby");

    await user.hover(wrapper);
    expect(wrapper).toHaveAttribute("aria-describedby", screen.getByRole("tooltip").id);
  });

  it("moves aria-describedby onto an already-focusable child when tabIndex is -1", async () => {
    const user = userEvent.setup();
    render(
      <Tooltip content="An explanation" tabIndex={-1}>
        <button>action</button>
      </Tooltip>,
    );

    const button = screen.getByRole("button", { name: "action" });
    // No duplicate tab stop around the button.
    expect(button.parentElement).not.toHaveAttribute("tabindex");

    await user.hover(button);
    expect(button).toHaveAttribute("aria-describedby", screen.getByRole("tooltip").id);

    await user.unhover(button);
    expect(button).not.toHaveAttribute("aria-describedby");
  });

  it("opens when a wrapped focusable child receives focus", async () => {
    const user = userEvent.setup();
    render(
      <Tooltip content="An explanation" tabIndex={-1}>
        <button>action</button>
      </Tooltip>,
    );

    await user.tab();
    expect(screen.getByRole("button", { name: "action" })).toHaveFocus();
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
  });
});

describe("InfoTip", () => {
  it("renders a help button with an accessible name", () => {
    render(<InfoTip label='About "Returned to you"' content="Excess tokens come back to you." />);
    expect(screen.getByRole("button", { name: 'About "Returned to you"' })).toBeInTheDocument();
  });

  it("reveals its content on hover", async () => {
    const user = userEvent.setup();
    render(<InfoTip label="About fees" content="Fees go to LPs." />);

    await user.hover(screen.getByRole("button", { name: "About fees" }));
    expect(screen.getByRole("tooltip")).toHaveTextContent("Fees go to LPs.");
  });

  it("is reachable and readable by keyboard alone", async () => {
    const user = userEvent.setup();
    render(<InfoTip label="About fees" content="Fees go to LPs." />);

    await user.tab();
    const button = screen.getByRole("button", { name: "About fees" });
    expect(button).toHaveFocus();
    expect(screen.getByRole("tooltip")).toHaveTextContent("Fees go to LPs.");
    expect(button).toHaveAttribute("aria-describedby", screen.getByRole("tooltip").id);

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("does not submit surrounding forms when tapped", async () => {
    const user = userEvent.setup();
    let submitted = false;
    render(
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submitted = true;
        }}
      >
        <InfoTip label="About fees" content="Fees go to LPs." />
      </form>,
    );

    await user.click(screen.getByRole("button", { name: "About fees" }));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    expect(submitted).toBe(false);
  });
});
