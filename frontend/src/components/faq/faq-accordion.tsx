"use client";

import { ChevronDown } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { useState } from "react";
import type { FaqItem } from "./faq-data";
import { Card } from "@/components/ui/card";

/**
 * One expandable Q&A. Items are independent (opening one never closes
 * another) and collapsed by default so the page reads as a scannable index.
 */
function FaqAccordionItem({ item }: { item: FaqItem }) {
  const [open, setOpen] = useState(false);
  const reducedMotion = useReducedMotion();
  const buttonId = `faq-q-${item.id}`;
  const panelId = `faq-a-${item.id}`;

  return (
    <Card className="overflow-hidden" data-testid={`faq-item-${item.id}`}>
      <h3>
        <button
          id={buttonId}
          aria-expanded={open}
          aria-controls={panelId}
          onClick={() => setOpen((v) => !v)}
          data-testid={`faq-question-${item.id}`}
          className="flex w-full items-center justify-between gap-4 p-5 text-left transition-colors hover:bg-surface-2/40"
        >
          <span className="font-display text-sm font-semibold text-ink sm:text-base">{item.question}</span>
          <ChevronDown
            className={[
              "size-4 shrink-0 text-ink-faint transition-transform duration-200",
              open ? "rotate-180 text-nova-bright" : "",
            ].join(" ")}
            aria-hidden
          />
        </button>
      </h3>
      <AnimatePresence initial={false}>
        {open && (
          <motion.div
            id={panelId}
            role="region"
            aria-labelledby={buttonId}
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: reducedMotion ? 0 : 0.22, ease: "easeOut" }}
            className="overflow-hidden"
            data-testid={`faq-answer-${item.id}`}
          >
            <div className="space-y-2.5 border-t border-line px-5 pb-5 pt-4">
              {item.answer.map((paragraph) => (
                <p key={paragraph} className="text-sm leading-relaxed text-ink-dim">
                  {paragraph}
                </p>
              ))}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </Card>
  );
}

/** A stack of accordion items for one FAQ category. */
export function FaqAccordion({ items }: { items: readonly FaqItem[] }) {
  return (
    <div className="space-y-3">
      {items.map((item) => (
        <FaqAccordionItem key={item.id} item={item} />
      ))}
    </div>
  );
}
