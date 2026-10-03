"use client";

import { useState } from "react";

/* ─────────────────────────────────────────────────────────
 * INSIGHT CARDS
 * A pager ("Insights N ‹ ›") over cards the page supplies:
 * each page is a line of prose, a card and a button under it.
 * It ships no sample content of its own, so the pages and the
 * heading are required.
 * ───────────────────────────────────────────────────────── */

/* content shape for one insight page in the carousel */
export type InsightPage = {
  key: string;
  prose: React.ReactNode;
  Card: React.ComponentType;
  pill: string;
};

export type InsightCardsLabels = {
  /** carousel heading shown before the page count */
  title: string;
};

export type InsightCardsProps = {
  variant?: string;
  pages: InsightPage[];
  labels: InsightCardsLabels;
  onAction?: (page: InsightPage) => void;
  actionDisabled?: boolean;
};

export default function InsightCards({
  pages,
  labels,
  onAction,
  actionDisabled,
}: InsightCardsProps) {
  const [page, setPage] = useState(0);
  if (pages.length === 0) return null;

  const move = (direction: -1 | 1) => {
    setPage((current) => (current + direction + pages.length) % pages.length);
  };

  /* a list that got shorter while a later page was showing falls back to its last page */
  const index = Math.min(page, pages.length - 1);
  const { prose, Card, pill } = pages[index];

  return (
    <div className="min-h-[408px] w-full max-w-86">
      {/* pager header */}
      <div className="flex items-center justify-between">
        <span className="flex items-baseline gap-1.5">
          <span className="text-[13px] font-semibold text-ink">{labels.title}</span>
          <span className="text-[13px] text-ink-3 tabular-nums">{pages.length}</span>
        </span>
        <span className="flex items-center gap-0.5">
          {(["M15 18l-6-6 6-6", "M9 6l6 6-6 6"] as const).map((d, i) => (
            <button
              key={i}
              aria-label={i === 0 ? "Previous insight" : "Next insight"}
              onClick={() => move(i === 0 ? -1 : 1)}
              className="flex size-6 items-center justify-center rounded-[6px] text-ink-3
                transition-[background-color,color,transform] duration-100 hover:bg-hover
                hover:text-ink active:scale-[0.96]"
            >
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                <path d={d} />
              </svg>
            </button>
          ))}
        </span>
      </div>

      {/* page content — blurred crossfade */}
      <div
        key={pages[index].key}
        className="transition-[opacity,filter] duration-250"
        style={{ opacity: 1, filter: "blur(0)", animation: "fade-up 250ms cubic-bezier(0.23,1,0.32,1) both" }}
      >
        <p className="mt-1.5 text-[13px] leading-relaxed text-ink-2">{prose}</p>
        <div className="mt-2">
          <Card />
        </div>
        <button
          type="button"
          disabled={actionDisabled}
          onClick={() => onAction?.(pages[index])}
          className="mt-2 rounded-full bg-surface px-3 py-1.5 text-left text-[12px] text-ink
            shadow-btn transition-colors duration-100 hover:bg-hover disabled:opacity-50 disabled:pointer-events-none"
        >
          {pill}
        </button>
      </div>
    </div>
  );
}
