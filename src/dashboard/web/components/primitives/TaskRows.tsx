"use client";

import { useEffect, useState } from "react";

/* ─────────────────────────────────────────────────────────
 * TASK ROWS
 *
 *     0ms   rows enter staggered (80ms apart)
 *   600ms   row 1 ring sweeps 0 → 66%
 *  1500ms   row 1 expands — detail steps drop down
 *  3900ms   row 1 collapses; row 2 flips to Failed + retry
 *  5300ms   row 2 resolves to Completed
 * The status run completes once; task details stay clickable.
 * ───────────────────────────────────────────────────────── */

const TICKS = [600, 900, 2400, 1400, 2400, 600];

function useTick(intervals: number[], enabled: boolean) {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!enabled || tick >= intervals.length - 1) return;
    const t = setTimeout(() => setTick((x) => x + 1), intervals[tick]);
    return () => clearTimeout(t);
  }, [enabled, tick, intervals]);
  return tick;
}

function SpinnerRing({ active, children }: { active?: boolean; children?: React.ReactNode }) {
  const size = 24, stroke = 2;
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return (
    <span className="relative inline-flex shrink-0 items-center justify-center" style={{ width: size, height: size }}>
      <svg
        width={size} height={size} className="absolute inset-0"
        style={active ? { animation: "spin 1.1s linear infinite" } : undefined}
      >
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--line)" strokeWidth={stroke} />
        {active && (
          <circle
            cx={size / 2} cy={size / 2} r={r} fill="none"
            stroke="var(--ink-3)" strokeWidth={stroke} strokeLinecap="round"
            strokeDasharray={`${c * 0.28} ${c * 0.72}`}
          />
        )}
      </svg>
      <span className="relative text-[11px] font-semibold tabular-nums text-ink">{children}</span>
    </span>
  );
}

function Badge({ tone, children }: { tone: "red" | "green" | "neutral"; children: React.ReactNode }) {
  return (
    <span
      className={`flex size-5.5 shrink-0 items-center justify-center rounded-full
        ${tone === "red" ? "bg-red text-white" : tone === "green" ? "bg-green text-white" : "bg-field text-ink-2 shadow-hairline"}`}
      style={{ animation: "pop-in 300ms cubic-bezier(0.23,1,0.32,1) both" }}
    >
      {children}
    </span>
  );
}

const XIcon = (
  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3.5" strokeLinecap="round"><path d="M18 6L6 18M6 6l12 12" /></svg>
);
const CheckIcon = (
  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6L9 17l-5-5" /></svg>
);
const RetryIcon = (
  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36M21 3v6h-6" /></svg>
);

/* One detail line shown when a task row is expanded. */
export type TaskDetail = { label: string; meta: string };

/* A single task row.
 *  - "done"     → green check badge + completed pill (static)
 *  - "lastRun"  → neutral check badge + "Last run" pill: the latest run finished this step, but
 *                 the overall status (overdue, paused, review pending) no longer vouches for it
 *  - "cancelled" → neutral X badge + "Cancelled" pill: a stop the user asked for is not a failure
 *  - "running"  → active spinner showing `step`, no pill (static)
 *  - "sequence" → animation-driven: pending spinner → failed → completed
 */
export type TaskRow = {
  key: string;
  label: string;
  amount: string;
  status: "guide" | "pending" | "running" | "done" | "lastRun" | "failed" | "cancelled" | "sequence";
  step?: number;
  details: TaskDetail[];
};

export type TaskRowsLabels = {
  pending: string;
  completed: string;
  lastRun: string;
  failed: string;
  cancelled: string;
};

const DEFAULT_LABELS: TaskRowsLabels = {
  pending: "Pending",
  completed: "Completed",
  lastRun: "Last run",
  failed: "Failed",
  cancelled: "Cancelled",
};

/* The rows are the caller's: there are no sample rows to fall back on. */
export type TaskRowsProps = {
  variant?: string;
  rows: TaskRow[];
  labels?: Partial<TaskRowsLabels>;
  className?: string;
  onToggleRow?: (key: string, open: boolean) => void;
};

export default function TaskRows({
  variant = "Capsules",
  rows,
  labels,
  className,
  onToggleRow,
}: TaskRowsProps) {
  const tick = useTick(TICKS, rows.some((row) => row.status === "sequence"));
  const [manualOpen, setManualOpen] = useState<Record<string, boolean>>({});
  const row2: "pending" | "failed" | "done" = tick < 3 ? "pending" : tick === 3 ? "failed" : "done";
  const copy = { ...DEFAULT_LABELS, ...labels };

  const badgeFor = (row: TaskRow) => {
    if (row.status === "pending" || row.status === "guide") return <SpinnerRing>{row.step}</SpinnerRing>;
    if (row.status === "failed") return <Badge tone="red">{XIcon}</Badge>;
    // A stop the user asked for is not a failure: it keeps the neutral tone of its "Cancelled" pill.
    if (row.status === "cancelled") return <Badge tone="neutral">{XIcon}</Badge>;
    if (row.status === "done") return <Badge tone="green">{CheckIcon}</Badge>;
    if (row.status === "lastRun") return <Badge tone="neutral">{CheckIcon}</Badge>;
    if (row.status === "running") return <SpinnerRing active>{row.step}</SpinnerRing>;
    return row2 === "pending" ? (
      <SpinnerRing>{row.step}</SpinnerRing>
    ) : row2 === "failed" ? (
      <Badge tone="red">{XIcon}</Badge>
    ) : (
      <Badge tone="green">{CheckIcon}</Badge>
    );
  };

  const pillFor = (row: TaskRow) => {
    if (row.status === "guide") return null;
    if (row.status === "pending")
      return (
        <span className="inline-flex h-5.5 items-center rounded-full bg-field px-2 text-[12px] font-medium text-ink-2">
          {copy.pending}
        </span>
      );
    if (row.status === "failed")
      return (
        <span className="inline-flex h-5.5 items-center rounded-full bg-red-tint px-2 text-[12px] font-medium text-red-ink">
          {copy.failed}
        </span>
      );
    if (row.status === "cancelled")
      return (
        <span className="inline-flex h-5.5 items-center rounded-full bg-field px-2 text-[12px] font-medium text-ink-2">
          {copy.cancelled}
        </span>
      );
    if (row.status === "done")
      return (
        <span className="inline-flex h-5.5 items-center rounded-full bg-green-tint px-2 text-[12px] font-medium text-green-ink">
          {copy.completed}
        </span>
      );
    if (row.status === "lastRun")
      return (
        <span className="inline-flex h-5.5 items-center rounded-full bg-field px-2 text-[12px] font-medium text-ink-2">
          {copy.lastRun}
        </span>
      );
    if (row.status === "running") return null;
    return row2 === "failed" ? (
      <span className="inline-flex h-5.5 items-center gap-1.5 rounded-full bg-red-tint px-2 text-[12px] font-medium text-red-ink" style={{ animation: "fade-in 200ms ease-out both" }}>
        {copy.failed} <span style={{ animation: "spin 1.2s linear infinite" }} className="flex">{RetryIcon}</span>
      </span>
    ) : row2 === "done" ? (
      <span className="inline-flex h-5.5 items-center gap-1.5 rounded-full bg-green-tint px-2 text-[12px] font-medium text-green-ink" style={{ animation: "fade-in 200ms ease-out both" }}>
        {copy.completed}
      </span>
    ) : null;
  };

  const list = variant === "List";
  return (
    <div
      className={`flex w-full max-w-110 flex-col ${
        list ? "gap-0 self-start overflow-hidden rounded-card bg-surface shadow-card" : "min-h-[196px] gap-2"
      }${className ? ` ${className}` : ""}`}
    >
      {rows.map((row, i) => {
        const open = manualOpen[row.key] ?? (row.key === "index" && tick === 2);
        return (
          <div
            key={row.key}
            className={`self-stretch overflow-hidden transition-[border-radius,background-color] duration-300 hover:bg-inset ${
              list ? "border-b border-line last:border-0" : "bg-surface shadow-card"
            }`}
            style={{
              borderRadius: list ? 0 : open ? 14 : 22,
              animation: `fade-up 450ms cubic-bezier(0.23,1,0.32,1) ${i * 80}ms both`,
            }}
          >
            <button
              type="button"
              aria-expanded={open}
              onClick={() => {
                setManualOpen((current) => ({ ...current, [row.key]: !open }));
                onToggleRow?.(row.key, !open);
              }}
              className="flex h-11 w-full items-center gap-2.5 px-2.5 text-left"
            >
              <span className="flex size-6 shrink-0 items-center justify-center">
                {badgeFor(row)}
              </span>
              <span className="min-w-0 flex-1 truncate text-[13px] font-medium text-ink">
                {row.label}
              </span>
              <span className="text-[13px] text-ink-2 tabular-nums">{row.amount}</span>
              {pillFor(row)}
              <span
                aria-hidden="true"
                className="-ml-2 flex size-7 shrink-0 items-center justify-center rounded-full text-ink-3"
              >
                <svg
                  width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
                  className="transition-transform duration-300"
                  style={{ transform: open ? "rotate(180deg)" : "rotate(0)" }}
                >
                  <path d="M6 9l6 6 6-6" />
                </svg>
              </span>
            </button>

            {/* dropdown detail — same expandable grammar as Chain of Thought */}
            <div
              className="grid transition-[grid-template-rows,opacity] duration-300"
              aria-hidden={!open}
              inert={!open}
                style={{
                  gridTemplateRows: open ? "1fr" : "0fr",
                  opacity: open ? 1 : 0,
                  transitionTimingFunction: "cubic-bezier(0.23, 1, 0.32, 1)",
                }}
              >
                <div className="overflow-hidden">
                  <div className="mb-2.5 grid grid-cols-[24px_1fr] gap-2.5 px-2.5">
                    <span aria-hidden className="mx-auto h-full w-px bg-line" />
                    <div className="flex flex-col gap-1.5">
                      {row.details.map((d, j) => (
                        <div
                          key={d.label}
                          className="flex items-center justify-between"
                          style={
                            open
                              ? { animation: `fade-up 300ms cubic-bezier(0.23,1,0.32,1) ${120 + j * 100}ms both` }
                              : undefined
                          }
                        >
                          <span className="text-[12px] text-ink-2">{d.label}</span>
                          <span className="font-mono text-[12px] text-ink-3 tabular-nums">
                            {d.meta}
                          </span>
                        </div>
                      ))}
                    </div>
                  </div>
                </div>
              </div>
          </div>
        );
      })}
    </div>
  );
}
