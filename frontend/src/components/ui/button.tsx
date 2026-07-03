"use client";

import type { ButtonHTMLAttributes } from "react";
import { Loader2 } from "lucide-react";

export type ButtonVariant = "nova" | "higher" | "lower" | "ghost" | "outline" | "ended";
export type ButtonSize = "sm" | "md" | "lg";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
  loading?: boolean;
};

const VARIANTS: Record<ButtonVariant, string> = {
  nova: "bg-nova text-space font-semibold hover:bg-nova-bright shadow-glow-nova disabled:shadow-none",
  higher:
    "bg-higher text-space font-semibold hover:brightness-110 shadow-glow-higher disabled:shadow-none",
  lower: "bg-lower text-space font-semibold hover:brightness-110 shadow-glow-lower disabled:shadow-none",
  ended: "bg-ended text-space font-semibold hover:brightness-110 disabled:shadow-none",
  ghost: "bg-transparent text-ink-dim hover:text-ink hover:bg-surface-2",
  outline: "border border-line-strong text-ink hover:border-nova/60 hover:text-nova-bright bg-surface/40",
};

const SIZES: Record<ButtonSize, string> = {
  sm: "h-8 px-3 text-xs rounded-lg gap-1.5",
  md: "h-10 px-4 text-sm rounded-xl gap-2",
  lg: "h-13 px-6 text-base rounded-xl gap-2",
};

export function Button({
  variant = "nova",
  size = "md",
  loading = false,
  disabled,
  className = "",
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={[
        "inline-flex items-center justify-center font-medium transition-all duration-150",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-nova",
        "disabled:opacity-45 disabled:cursor-not-allowed active:enabled:scale-[0.98]",
        VARIANTS[variant],
        SIZES[size],
        className,
      ].join(" ")}
    >
      {loading && <Loader2 className="size-4 animate-spin" aria-hidden />}
      {children}
    </button>
  );
}
