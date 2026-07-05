"use client";

import { CircleQuestionMark } from "lucide-react";
import {
  cloneElement,
  isValidElement,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type ReactElement,
  type ReactNode,
} from "react";

type Side = "top" | "bottom";
type Align = "center" | "start" | "end";

const SIDE_CLASSES: Record<Side, string> = {
  top: "bottom-full mb-1.5",
  bottom: "top-full mt-1.5",
};

const ALIGN_CLASSES: Record<Align, string> = {
  center: "left-1/2 -translate-x-1/2",
  start: "left-0",
  end: "right-0",
};

/** `useLayoutEffect` warns during SSR; the measurement only matters on the client. */
const useIsomorphicLayoutEffect = typeof window === "undefined" ? useEffect : useLayoutEffect;

export type TooltipProps = Omit<HTMLAttributes<HTMLSpanElement>, "content"> & {
  /** The explanation shown in the bubble. */
  content: ReactNode;
  /** Which side of the trigger the bubble opens on. */
  side?: Side;
  /** How the bubble aligns to the trigger along the horizontal axis. */
  align?: Align;
  /**
   * Keep the default (0) when wrapping plain text or icons so keyboard users
   * can reach the tooltip. Pass -1 when the child is already focusable
   * (button, link): its focus bubbles up and still opens the tooltip, and the
   * `aria-describedby` moves onto the child instead of the wrapper.
   */
  tabIndex?: number;
};

/**
 * A dependency-free tooltip in the app's cosmic style. Opens on hover and
 * keyboard focus, on tap on touch devices; closes on Escape, blur, unhover,
 * or an outside tap. The bubble is positioned absolutely inside the trigger
 * wrapper — NOT `position: fixed`, which breaks inside the app's
 * backdrop-blurred cards (they become containing blocks).
 */
export function Tooltip({
  content,
  side = "top",
  align = "center",
  tabIndex = 0,
  className = "",
  children,
  ...rest
}: TooltipProps) {
  const id = useId();
  const [open, setOpen] = useState(false);
  /** Horizontal nudge (px) applied after measuring, so the bubble never bleeds off-screen. */
  const [shift, setShift] = useState(0);
  const rootRef = useRef<HTMLSpanElement>(null);
  const bubbleRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: PointerEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  useIsomorphicLayoutEffect(() => {
    if (!open) {
      setShift(0);
      return;
    }
    const rect = bubbleRef.current?.getBoundingClientRect();
    if (!rect || rect.width === 0) return; // jsdom and pre-paint renders
    const pad = 8;
    if (rect.left < pad) setShift(pad - rect.left);
    else if (rect.right > window.innerWidth - pad) setShift(window.innerWidth - pad - rect.right);
  }, [open]);

  const describedBy = open ? id : undefined;
  // When the child is the focusable trigger, the description belongs on it.
  const child =
    tabIndex < 0 && isValidElement(children)
      ? cloneElement(children as ReactElement<HTMLAttributes<HTMLElement>>, { "aria-describedby": describedBy })
      : children;

  return (
    <span
      ref={rootRef}
      {...rest}
      tabIndex={tabIndex < 0 ? undefined : tabIndex}
      aria-describedby={tabIndex < 0 ? undefined : describedBy}
      className={`relative inline-flex ${className}`}
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
      onFocus={() => setOpen(true)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setOpen(false);
      }}
      onClick={() => setOpen(true)}
    >
      {child}
      {open && (
        <span
          ref={bubbleRef}
          role="tooltip"
          id={id}
          style={shift !== 0 ? { marginLeft: shift } : undefined}
          className={[
            "pointer-events-none absolute z-40 w-max max-w-64",
            "rounded-xl border border-line-strong bg-surface-2 px-3 py-2",
            "text-left font-sans text-[11px] font-normal normal-case leading-relaxed tracking-normal whitespace-normal text-ink-dim",
            "shadow-[0_12px_32px_rgba(2,0,16,0.7)]",
            SIDE_CLASSES[side],
            ALIGN_CLASSES[align],
          ].join(" ")}
        >
          {content}
        </span>
      )}
    </span>
  );
}

export interface InfoTipProps {
  /** Accessible name for the trigger, e.g. `About "Returned to you"`. */
  label: string;
  content: ReactNode;
  side?: Side;
  align?: Align;
  className?: string;
  iconClassName?: string;
}

/**
 * A small "?" button that reveals an explanation — the standard way to
 * annotate a label. Renders a real button so it is tabbable, tappable, and
 * announced with `label`.
 */
export function InfoTip({ label, content, side, align, className = "", iconClassName = "size-3.5" }: InfoTipProps) {
  return (
    <Tooltip content={content} side={side} align={align} tabIndex={-1} className={className}>
      <button
        type="button"
        aria-label={label}
        className="inline-flex cursor-help items-center justify-center rounded-full text-ink-faint transition-colors hover:text-nova-bright focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-nova"
      >
        <CircleQuestionMark className={iconClassName} aria-hidden />
      </button>
    </Tooltip>
  );
}
