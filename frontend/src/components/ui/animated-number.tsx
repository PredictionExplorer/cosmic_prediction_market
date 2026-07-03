"use client";

import { animate, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

interface AnimatedNumberProps {
  value: number;
  /** Formats the interpolated value for display. */
  format?: (value: number) => string;
  className?: string;
  durationS?: number;
}

/**
 * Smoothly tweens between numeric values (the live prediction, position value…).
 * Falls back to instant updates when the user prefers reduced motion.
 */
export function AnimatedNumber({
  value,
  format = (v) => v.toLocaleString("en-US", { maximumFractionDigits: 1, minimumFractionDigits: 1 }),
  className,
  durationS = 0.7,
}: AnimatedNumberProps) {
  const reduced = useReducedMotion();
  const [display, setDisplay] = useState(value);
  const previous = useRef(value);

  useEffect(() => {
    if (reduced || previous.current === value) {
      previous.current = value;
      setDisplay(value);
      return;
    }
    const controls = animate(previous.current, value, {
      duration: durationS,
      ease: "easeOut",
      onUpdate: setDisplay,
    });
    previous.current = value;
    return () => controls.stop();
  }, [value, reduced, durationS]);

  return (
    <span className={className} data-testid="animated-number">
      {format(display)}
    </span>
  );
}
