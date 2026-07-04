import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { HowItWorks } from "./how-it-works";

describe("HowItWorks", () => {
  it("explains the mechanism in five steps", () => {
    render(<HowItWorks />);
    const section = screen.getByTestId("how-it-works");
    expect(section).toHaveTextContent(/one question, every round/i);
    expect(section).toHaveTextContent(/fully backed, no keys/i);
  });

  it("links to the full FAQ", () => {
    render(<HowItWorks />);
    expect(screen.getByTestId("how-it-works-faq-link")).toHaveAttribute("href", "/faq");
  });
});
