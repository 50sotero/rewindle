"use client";

import { memo, useId, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Check, ChevronRight, Minus, OctagonAlert, type LucideIcon } from "lucide-react";

/* ─────────────────────────────────────────────────────────
 * FILTER TABLE
 * Status chips directly filter the task table.
 *
 * With `onRowClick` the table is an ARIA grid with row focus: one row is the Tab stop and the
 * arrow keys, Home/End and PageUp/PageDown move between the visible rows. Enter opens a row
 * (`onRowOpen`) and Space selects it. A double-click opens a row too, and a trailing button
 * opens it for pointer users (it is not a Tab stop of its own: the row is). Without
 * `onRowClick` the table is plain, non-interactive content.
 * ───────────────────────────────────────────────────────── */

export type FilterTableStatus = "todo" | "progress" | "done";
export type FilterTableSelection = "all" | FilterTableStatus;

export type TableRow = { id?: string; task: string; date: string; status: FilterTableStatus; statusLabel?: string; owner: string };

export type FilterTableLabels = {
  columns: { task: string; date: string; status: string; owner: string };
  filters?: Partial<Record<"all" | FilterTableStatus, string>>;
  statuses?: Partial<Record<FilterTableStatus, string>>;
  /** Names the trailing per-row button, which is drawn only when the table has `onRowOpen`. */
  openRow?: string;
};

/* The chip dots use the same tokens as the pills below, so a chip and its rows read as one status. */
const FILTERS: { key: "all" | FilterTableStatus; label: string; dot?: string }[] = [
  { key: "all", label: "All" },
  { key: "todo", label: "To do", dot: "var(--red)" },
  { key: "progress", label: "In Progress", dot: "var(--ink-3)" },
  { key: "done", label: "Completed", dot: "var(--green)" },
];

/* Each status has its own shape as well as its own color, so a pill never relies on color alone. */
const PILLS: Record<FilterTableStatus, { label: string; cls: string; Icon: LucideIcon }> = {
  todo: { label: "To do", cls: "filter-status-todo", Icon: OctagonAlert },
  progress: { label: "In Progress", cls: "filter-status-progress", Icon: Minus },
  done: { label: "Completed", cls: "filter-status-done", Icon: Check },
};

/* PageUp / PageDown move this many visible rows. */
const PAGE_STEP = 8;

/* One literal per layout so Tailwind sees the whole class. The last track holds the open button. */
const GRID = "grid-cols-[minmax(0,1.3fr)_minmax(0,0.6fr)_minmax(0,0.95fr)_minmax(10rem,0.9fr)]";
const GRID_OPEN = "grid-cols-[minmax(0,1.3fr)_minmax(0,0.6fr)_minmax(0,0.95fr)_minmax(10rem,0.9fr)_2.75rem]";

/* The rows and the column names are the caller's: there are no sample ones to fall back on. */
export type FilterTableProps = {
  rows: TableRow[];
  labels: FilterTableLabels;
  selectedRowId?: string | null;
  onRowClick?: (row: TableRow) => void;
  onRowOpen?: (row: TableRow) => void;
  filter?: FilterTableSelection;
  onFilterChange?: (filter: FilterTableSelection) => void;
  emptyContent?: ReactNode;
  tableLabel?: string;
  sortControl?: ReactNode;
  className?: string;
  variant?: string;
};

function FilterTable({
  rows,
  labels,
  selectedRowId,
  onRowClick,
  onRowOpen,
  filter: controlledFilter,
  onFilterChange,
  emptyContent,
  tableLabel = "Scrollable task table",
  sortControl,
  className = "",
}: FilterTableProps) {
  const [internalFilter, setFilter] = useState<FilterTableSelection>("all");
  const filter = controlledFilter ?? internalFilter;
  const [internalSelectedRowId, setInternalSelectedRowId] = useState<string | null>(null);
  const [focusedRowId, setFocusedRowId] = useState<string | null>(null);
  const rowRefs = useRef(new Map<string, HTMLDivElement>());
  const keysHintId = useId();
  const resolvedSelectedRowId = selectedRowId === undefined ? internalSelectedRowId : selectedRowId;
  const filterLabels = labels.filters ?? {};
  const statusLabels = labels.statuses ?? {};
  const countFor = (key: "all" | FilterTableStatus) =>
    key === "all" ? rows.length : rows.filter((row) => row.status === key).length;

  const interactive = !!onRowClick;
  const openable = interactive && !!onRowOpen;
  const openLabel = labels.openRow ?? "Open details";
  const grid = openable ? GRID_OPEN : GRID;
  const cellRole = interactive ? "gridcell" : "cell";
  const rowIdFor = (row: TableRow, index: number) => row.id ?? `${row.task}-${index}`;
  /* Rows hidden by the filter are inert, so keyboard movement and the Tab stop skip them. */
  const visibleIds = rows
    .map((row, index) => ({ row, id: rowIdFor(row, index) }))
    .filter(({ row }) => filter === "all" || row.status === filter)
    .map(({ id }) => id);
  /* Roving tabindex: the row last focused, else the selected row, else the first visible row. */
  const tabStopId =
    focusedRowId !== null && visibleIds.includes(focusedRowId)
      ? focusedRowId
      : resolvedSelectedRowId != null && visibleIds.includes(resolvedSelectedRowId)
        ? resolvedSelectedRowId
        : visibleIds[0];

  const focusRow = (id: string | undefined) => {
    const element = id === undefined ? undefined : rowRefs.current.get(id);
    if (!element) return;
    element.focus();
    element.scrollIntoView({ block: "nearest" });
  };

  const onRowKeyDown = (event: KeyboardEvent<HTMLDivElement>, row: TableRow, rowId: string) => {
    /* Only the row itself handles keys: the open button inside it keeps its own Enter and Space. */
    if (!onRowClick || event.altKey || event.metaKey || event.target !== event.currentTarget) return;
    const position = visibleIds.indexOf(rowId);
    const last = visibleIds.length - 1;
    switch (event.key) {
      case "ArrowDown": event.preventDefault(); focusRow(visibleIds[Math.min(last, position + 1)]); return;
      case "ArrowUp": event.preventDefault(); focusRow(visibleIds[Math.max(0, position - 1)]); return;
      case "PageDown": event.preventDefault(); focusRow(visibleIds[Math.min(last, position + PAGE_STEP)]); return;
      case "PageUp": event.preventDefault(); focusRow(visibleIds[Math.max(0, position - PAGE_STEP)]); return;
      case "Home": event.preventDefault(); focusRow(visibleIds[0]); return;
      case "End": event.preventDefault(); focusRow(visibleIds[last]); return;
      case "Enter":
        event.preventDefault();
        if (event.repeat) return;
        setInternalSelectedRowId(rowId);
        if (onRowOpen) onRowOpen(row);
        else onRowClick(row);
        return;
      case " ":
        event.preventDefault();
        if (event.repeat) return;
        setInternalSelectedRowId(rowId);
        onRowClick(row);
        return;
    }
  };

  return (
    <div className={`w-full max-w-105${className ? ` ${className}` : ""}`}>
      {/* filter chips — the padding leaves room for the 5px focus ring inside the scroll clip */}
      <div
        className="-mx-1.5 -mt-0.5 mb-0.5 flex items-center gap-1 overflow-x-auto px-1.5 py-1.5"
        style={{ scrollbarWidth: "none" }}
      >
        {FILTERS.map((f) => {
          const active = filter === f.key;
          return (
            <button
              key={f.key}
              type="button"
              aria-pressed={active}
              onClick={() => { setFilter(f.key); onFilterChange?.(f.key); }}
              className={`flex h-6.5 shrink-0 items-center gap-1.5 rounded-full px-2.5 text-[12px]
                font-medium transition-[background-color,box-shadow,color] duration-200
                ${active ? "bg-surface text-ink shadow-btn" : "text-ink-2 hover:bg-hover"}`}
            >
              {f.dot && <span className="size-1.5 rounded-full" style={{ background: f.dot }} />}
              {filterLabels[f.key] ?? f.label}
              <span
                className={`rounded-[4px] px-1 text-[11px] tabular-nums
                  ${active ? "bg-field text-ink-2" : "text-ink-3"}`}
              >
                {countFor(f.key)}
              </span>
            </button>
          );
        })}
        {sortControl}
      </div>

      {/* table — rows are the focus stops, so the scroller itself only needs one when there are none;
          the header row is sticky, and the scroll padding keeps a row that is scrolled to out from under it */}
      <div
        aria-label={tableLabel}
        className="overflow-x-auto rounded-card bg-surface shadow-card"
        role="region"
        tabIndex={interactive ? undefined : 0}
        style={{ scrollbarWidth: "none", scrollPaddingTop: "2.25rem" }}
      >
        <div className="min-w-[420px]">
          {/* How to use the rows, read with the grid's name; a tooltip on every row said it to a pointer only. */}
          {interactive && (
            <span id={keysHintId} className="sr-only">
              Use the arrow keys to move between rows. Press Space to select a row{openable ? " and Enter to open its details" : ""}.
            </span>
          )}
          <div role={interactive ? "grid" : "table"} aria-label={tableLabel} aria-describedby={interactive ? keysHintId : undefined}>
            <div
              role="row"
              className={`sticky top-0 z-[1] grid ${grid} border-b border-[var(--grid-line)] bg-surface text-[13px] font-medium text-ink-2`}
            >
              <span role="columnheader" className="border-r border-[var(--grid-line)] px-3 py-2">{labels.columns.task}</span>
              <span role="columnheader" className="border-r border-[var(--grid-line)] px-3 py-2">{labels.columns.date}</span>
              <span role="columnheader" className="border-r border-[var(--grid-line)] px-3 py-2">{labels.columns.status}</span>
              <span role="columnheader" className="px-3 py-2">{labels.columns.owner}</span>
              {openable && <span role="columnheader" className="px-1 py-2"><span className="sr-only">{openLabel}</span></span>}
            </div>
            {rows.map((row, index) => {
              const shown = filter === "all" || row.status === filter;
              const pill = { ...PILLS[row.status], label: row.statusLabel ?? statusLabels[row.status] ?? PILLS[row.status].label };
              const PillIcon = pill.Icon;
              const rowId = rowIdFor(row, index);
              const selected = resolvedSelectedRowId === rowId;
              return (
                <div
                  key={rowId}
                  role="presentation"
                  aria-hidden={!shown}
                  inert={!shown}
                  className="grid transition-[grid-template-rows,opacity] duration-300"
                  style={{
                    gridTemplateRows: shown ? "1fr" : "0fr",
                    opacity: shown ? 1 : 0,
                    transitionTimingFunction: "cubic-bezier(0.23, 1, 0.32, 1)",
                  }}
                >
                  <div role="presentation" className="overflow-hidden">
                    <div
                      ref={(element) => {
                        if (element) rowRefs.current.set(rowId, element);
                        else rowRefs.current.delete(rowId);
                      }}
                      role="row"
                      className={`filter-table-row group/row grid ${grid} border-b
                        border-[var(--grid-line)] text-[13px] transition-colors duration-100 hover:bg-hover ${selected ? "bg-hover" : ""}`}
                      tabIndex={interactive && shown && rowId === tabStopId ? 0 : -1}
                      aria-selected={interactive ? selected : undefined}
                      onFocus={() => setFocusedRowId(rowId)}
                      onDoubleClick={() => onRowOpen?.(row)}
                      onClick={() => {
                        setInternalSelectedRowId(rowId);
                        onRowClick?.(row);
                      }}
                      onKeyDown={(event) => onRowKeyDown(event, row, rowId)}
                    >
                      <span role={cellRole} className="flex min-w-0 items-center border-r border-[var(--grid-line)] px-3 py-2">
                        <span className="truncate font-medium text-ink tabular-nums" title={row.task}>{row.task}</span>
                      </span>
                      <span role={cellRole} className="flex items-center whitespace-nowrap border-r border-[var(--grid-line)] px-3 py-2 text-ink-2 tabular-nums">
                        {row.date}
                      </span>
                      <span role={cellRole} className="flex min-w-0 items-center border-r border-[var(--grid-line)] px-3 py-2">
                        <span
                          className={`inline-flex h-[23px] min-w-0 max-w-full items-center gap-1 whitespace-nowrap rounded-[8px] border px-[7px]
                            text-[13px] font-medium ${pill.cls}`}
                        >
                          <PillIcon aria-hidden="true" size={12} strokeWidth={2.5} className="shrink-0" />
                          <span className="truncate">{pill.label}</span>
                        </span>
                      </span>
                      <span role={cellRole} className="flex min-w-0 items-center px-3 py-2 text-ink-2">
                        <span className="truncate tabular-nums" title={row.owner}>{row.owner}</span>
                      </span>
                      {openable && (
                        <span role={cellRole} className="flex items-center justify-center px-1">
                          <button
                            type="button"
                            tabIndex={-1}
                            aria-label={`${openLabel} for ${row.task}`}
                            title={openLabel}
                            onClick={(event) => {
                              event.stopPropagation();
                              /* The second click of a double-click would send the same two commands again. */
                              if (event.detail > 1) return;
                              setInternalSelectedRowId(rowId);
                              onRowClick?.(row);
                              onRowOpen?.(row);
                            }}
                            className="flex size-6 items-center justify-center rounded-full text-ink-3
                              transition-[background-color,color] duration-150 hover:bg-hover-2 hover:text-ink
                              group-hover/row:text-ink group-aria-selected/row:text-accent-ink"
                          >
                            <ChevronRight size={15} aria-hidden="true" />
                          </button>
                        </span>
                      )}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
          {countFor(filter) === 0 && emptyContent}
        </div>
      </div>
    </div>
  );
}

/* The history table can hold hundreds of rows and its parent re-renders with every state update from the
   host, so callers that pass stable props skip those renders. */
export default memo(FilterTable);
