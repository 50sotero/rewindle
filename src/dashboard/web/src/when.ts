// One way to write a moment everywhere on the page, so a run in the table, the time of the last verified backup and a backup to
// restore from read alike: the viewer's region decides the order and the clock ("Fri, Oct 2, 2:00 AM" or "Fri 2 Oct, 02:00"),
// a 12-hour clock drops the leading zero, and the year is added only for a moment from another year. Formats come from an ISO
// timestamp; the host's own display strings are only a fallback. Formatters are cached: the host publishes about once a second.
// Erasable TypeScript only, with no imports: tests can run this file with Node as it is.

export type WhenOptions = {
  /** Include the short weekday ("Fri"). Default true. */
  weekday?: boolean;
  /** Include the time of day. Default true. */
  time?: boolean;
};

const formats = new Map<string, Intl.DateTimeFormat>();
const twelveHourClock = new Map<string, boolean>();

/** Whether the region writes times on a 12-hour clock ("2:00 AM") rather than a 24-hour one ("02:00"). */
export function usesTwelveHourClock(locale?: string): boolean {
  const key = locale ?? '';
  let twelve = twelveHourClock.get(key);
  if (twelve === undefined) {
    twelve = !!new Intl.DateTimeFormat(locale, { hour: 'numeric' }).resolvedOptions().hour12;
    twelveHourClock.set(key, twelve);
  }
  return twelve;
}

/** A moment from an ISO 8601 timestamp, or `fallback` when it cannot be read. */
export function formatWhen(iso: string | undefined | null, locale?: string, fallback = '', options: WhenOptions = {}): string {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return fallback;
  const weekday = options.weekday ?? true, time = options.time ?? true;
  const withYear = date.getFullYear() !== new Date().getFullYear();
  const key = `${locale ?? ''}|${withYear}|${weekday}|${time}`;
  let format = formats.get(key);
  if (!format) {
    // A 24-hour clock keeps its leading zero ("02:00") so times line up in a column; a 12-hour one reads "2:00 AM".
    const clock: Intl.DateTimeFormatOptions = time ? { hour: usesTwelveHourClock(locale) ? 'numeric' : '2-digit', minute: '2-digit' } : {};
    format = new Intl.DateTimeFormat(locale, { weekday: weekday ? 'short' : undefined, day: 'numeric', month: 'short', year: withYear ? 'numeric' : undefined, ...clock });
    formats.set(key, format);
  }
  return format.format(date);
}

/** Only the time of day ("2:05 AM" or "02:05"). */
export function formatClock(iso: string | undefined | null, locale?: string, fallback = ''): string {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return fallback;
  return date.toLocaleTimeString(locale, { hour: usesTwelveHourClock(locale) ? 'numeric' : '2-digit', minute: '2-digit' });
}

const DAY_MS = 86_400_000;

/** How many calendar days (local) `date` is before `now`: 0 today, 1 yesterday, negative for a moment still to come. */
function daysBefore(date: Date, now: Date): number {
  const startOf = (value: Date) => new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
  return Math.round((startOf(now) - startOf(date)) / DAY_MS);
}

/**
 * A moment with its age in words, for a time whose age is the point ("Last verified yesterday at 2:03 AM"): today and yesterday by name,
 * up to two weeks as "3 days ago" with the date in brackets, and the plain `formatWhen` after that (or for a moment still to come).
 * `now` is only for tests.
 */
export function formatWhenAgo(iso: string | undefined | null, locale?: string, fallback = '', now: Date = new Date()): string {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return fallback;
  const days = daysBefore(date, now);
  if (days === 0 || days === 1) return `${days === 0 ? 'today' : 'yesterday'} at ${formatClock(iso, locale, fallback)}`;
  if (days > 1 && days <= 14) return `${days} days ago (${formatWhen(iso, locale, fallback)})`;
  return formatWhen(iso, locale, fallback);
}
