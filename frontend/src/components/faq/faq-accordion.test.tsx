import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { FaqAccordion } from "./faq-accordion";
import type { FaqItem } from "./faq-data";

const ITEMS: readonly FaqItem[] = [
  {
    id: "first",
    question: "What is the first question?",
    answer: ["First answer, paragraph one.", "First answer, paragraph two."],
  },
  { id: "second", question: "What is the second question?", answer: ["Second answer."] },
];

describe("FaqAccordion", () => {
  it("renders every question collapsed", () => {
    render(<FaqAccordion items={ITEMS} />);

    for (const item of ITEMS) {
      const button = screen.getByTestId(`faq-question-${item.id}`);
      expect(button).toHaveTextContent(item.question);
      expect(button).toHaveAttribute("aria-expanded", "false");
      expect(screen.queryByTestId(`faq-answer-${item.id}`)).not.toBeInTheDocument();
    }
  });

  it("expands on click, showing all answer paragraphs", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    await user.click(screen.getByTestId("faq-question-first"));

    expect(screen.getByTestId("faq-question-first")).toHaveAttribute("aria-expanded", "true");
    const answer = screen.getByTestId("faq-answer-first");
    expect(answer).toHaveTextContent("First answer, paragraph one.");
    expect(answer).toHaveTextContent("First answer, paragraph two.");
  });

  it("collapses again on a second click", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    await user.click(screen.getByTestId("faq-question-first"));
    expect(screen.getByTestId("faq-answer-first")).toBeInTheDocument();

    await user.click(screen.getByTestId("faq-question-first"));
    expect(screen.getByTestId("faq-question-first")).toHaveAttribute("aria-expanded", "false");
    // The exit animation removes the panel asynchronously.
    await waitFor(() => expect(screen.queryByTestId("faq-answer-first")).not.toBeInTheDocument());
  });

  it("keeps items independent: opening one never closes another", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    await user.click(screen.getByTestId("faq-question-first"));
    await user.click(screen.getByTestId("faq-question-second"));

    expect(screen.getByTestId("faq-answer-first")).toBeInTheDocument();
    expect(screen.getByTestId("faq-answer-second")).toBeInTheDocument();
  });

  it("links the disclosure button to its panel for assistive tech", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    const button = screen.getByTestId("faq-question-first");
    await user.click(button);
    const panel = screen.getByTestId("faq-answer-first");

    expect(button).toHaveAttribute("aria-controls", panel.id);
    expect(panel).toHaveAttribute("role", "region");
    expect(panel).toHaveAttribute("aria-labelledby", button.id);
  });
});
