export type ValuePillTone = "neutral" | "green" | "orange" | "red" | "accent";

const TONES: Record<ValuePillTone, { cls: string; ring: string }> = {
  neutral: { cls: "bg-field text-ink-2", ring: "var(--shadow-hairline)" },
  green: { cls: "bg-green-tint text-green-ink", ring: "0 0 0 1px color-mix(in oklch, var(--green) 28%, transparent)" },
  orange: { cls: "bg-orange-tint text-orange-ink", ring: "0 0 0 1px color-mix(in oklch, var(--orange) 28%, transparent)" },
  red: { cls: "bg-red-tint text-red-ink", ring: "0 0 0 1px color-mix(in oklch, var(--red) 28%, transparent)" },
  accent: { cls: "bg-accent-tint text-accent-ink", ring: "0 0 0 1px color-mix(in oklch, var(--accent) 28%, transparent)" },
};

/** Inline value badge — a plain value (a date, a name, a count) set off in
 *  prose. Softer than a StatusPill (no dot) and not a mono token (see Chip). */
export type ValuePillProps = {
  children: React.ReactNode;
  tone?: ValuePillTone;
  className?: string;
};

export function ValuePill({
  children,
  tone = "neutral",
  className = "",
}: ValuePillProps) {
  const t = TONES[tone];
  return (
    <span
      className={`mx-0.5 inline-flex items-center rounded-full px-1.5 py-0
        align-middle text-[12px] font-medium ${t.cls} ${className}`}
      style={{ boxShadow: t.ring }}
    >
      {children}
    </span>
  );
}
