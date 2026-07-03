import { ArrowUpDown, Award, Scale, Timer } from "lucide-react";
import { Card } from "@/components/ui/card";

const STEPS = [
  {
    icon: Scale,
    title: "One number, two sides",
    body: "The market prices the round's final gesture (bid) count. HIGHER tokens gain value as the expected count rises, LOWER tokens as it falls — the live prediction is where the two sides balance.",
  },
  {
    icon: ArrowUpDown,
    title: "Bet with CST",
    body: "Betting swaps your CST into one side through an automated pool, so you always trade at the market's current prediction. Your entry is the count you effectively bought at.",
  },
  {
    icon: Timer,
    title: "Trading stops automatically",
    body: "The instant the round's main prize is claimed, the market locks. Nobody can bet on a known outcome — resolution reads the final count straight from the game contract.",
  },
  {
    icon: Award,
    title: "Linear payouts, fully backed",
    body: "At resolution each HIGHER pays proportionally to where the count lands in the range; LOWER pays the complement. Every HIGHER+LOWER pair is always worth exactly 1 CST, so the market can always pay.",
  },
] as const;

/** A plain-language explainer of the market mechanism. */
export function HowItWorks() {
  return (
    <section aria-labelledby="how-it-works-title" data-testid="how-it-works">
      <h2 id="how-it-works-title" className="font-display text-lg font-semibold">
        How it works
      </h2>
      <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {STEPS.map((step, i) => (
          <Card key={step.title} className="p-5">
            <div className="flex items-center gap-2.5">
              <span className="flex size-8 items-center justify-center rounded-lg bg-nova/12 text-nova-bright">
                <step.icon className="size-4" aria-hidden />
              </span>
              <span className="font-mono text-xs text-ink-faint">0{i + 1}</span>
            </div>
            <h3 className="mt-3 font-display text-sm font-semibold text-ink">{step.title}</h3>
            <p className="mt-1.5 text-xs leading-relaxed text-ink-dim">{step.body}</p>
          </Card>
        ))}
      </div>
    </section>
  );
}
