// The Activity page's date menu. "Last 7 days" is kept as that choice, not as the date it meant when it was picked: the page stays
// open for days in the notification area, and a stored date would stop the range from moving at midnight (and turn the menu into
// "Pick dates…" with a range that grows by a day every night). Dates typed into the two fields stay exactly as typed.
// Erasable TypeScript only, with no imports: tests/test_dashboard_ui_actions.py runs this file with Node as it is.

/** A range the menu offers, as the number of days it reaches back (today counts as the first), or '' for none. */
export type RangePreset = '' | '7' | '30' | '365';
export type ActivityDateFilter = { from: string; to: string; preset: RangePreset };

const pad = (value: number) => String(value).padStart(2, '0');
/** A day in local time the way a date field writes it (2026-11-06). */
const dayKey = (day: Date) => `${day.getFullYear()}-${pad(day.getMonth() + 1)}-${pad(day.getDate())}`;

/** The first day a preset covers on the local date of `now`: "Last 7 days" on 2026-11-06 starts on 2026-10-31. '' for no preset. */
export function presetStart(preset: RangePreset, now: Date): string {
  const days = Number(preset);
  if (!preset || !Number.isInteger(days) || days < 1) return '';
  return dayKey(new Date(now.getFullYear(), now.getMonth(), now.getDate() - (days - 1)));
}

/** The first day the filter lets through at `now`: a preset's start moves with the calendar, a date typed in stays put. */
export const effectiveFrom = (view: ActivityDateFilter, now: Date): string => view.preset ? presetStart(view.preset, now) : view.from;

/** What the date menu shows: the preset, "any" with no dates at all, or "custom" for dates picked by hand. */
export const rangeMenuValue = (view: ActivityDateFilter): RangePreset | 'any' | 'custom' =>
  view.preset ? view.preset : !view.from && !view.to ? 'any' : 'custom';
