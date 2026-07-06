import { render, screen } from "@testing-library/react";
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
    }
    // Collapsed panels are hidden from assistive tech…
    expect(screen.queryByRole("region")).not.toBeInTheDocument();
  });

  it("keeps every answer in the DOM while collapsed, so crawlers and AI agents can read it", () => {
    render(<FaqAccordion items={ITEMS} />);

    for (const item of ITEMS) {
      const panel = screen.getByTestId(`faq-answer-${item.id}`);
      expect(panel).toHaveAttribute("aria-hidden", "true");
      for (const paragraph of item.answer) {
        expect(panel).toHaveTextContent(paragraph);
      }
    }
  });

  it("expands on click, revealing all answer paragraphs", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    await user.click(screen.getByTestId("faq-question-first"));

    expect(screen.getByTestId("faq-question-first")).toHaveAttribute("aria-expanded", "true");
    const answer = screen.getByTestId("faq-answer-first");
    expect(answer).toHaveAttribute("aria-hidden", "false");
    expect(answer).toHaveTextContent("First answer, paragraph one.");
    expect(answer).toHaveTextContent("First answer, paragraph two.");
  });

  it("collapses again on a second click without removing the content", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    await user.click(screen.getByTestId("faq-question-first"));
    expect(screen.getByTestId("faq-answer-first")).toHaveAttribute("aria-hidden", "false");

    await user.click(screen.getByTestId("faq-question-first"));
    expect(screen.getByTestId("faq-question-first")).toHaveAttribute("aria-expanded", "false");
    const panel = screen.getByTestId("faq-answer-first");
    expect(panel).toHaveAttribute("aria-hidden", "true");
    expect(panel).toHaveTextContent("First answer, paragraph one.");
  });

  it("keeps items independent: opening one never closes another", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    await user.click(screen.getByTestId("faq-question-first"));
    await user.click(screen.getByTestId("faq-question-second"));

    expect(screen.getByTestId("faq-answer-first")).toHaveAttribute("aria-hidden", "false");
    expect(screen.getByTestId("faq-answer-second")).toHaveAttribute("aria-hidden", "false");
  });

  it("links the disclosure button to its panel for assistive tech", async () => {
    const user = userEvent.setup();
    render(<FaqAccordion items={ITEMS} />);

    const button = screen.getByTestId("faq-question-first");
    await user.click(button);
    const panel = screen.getByRole("region");

    expect(button).toHaveAttribute("aria-controls", panel.id);
    expect(panel).toHaveAttribute("aria-labelledby", button.id);
    expect(panel).toBe(screen.getByTestId("faq-answer-first"));
  });
});
