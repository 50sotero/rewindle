import type { BackupRangeState } from './native-types';

// How far back the backups go, in one line for Protection and Restore: "412 backups, oldest 3 Mar 2025". It is a fact about the
// backups, shown only when it is known; anything that is not (no count, no backups, a date that cannot be read) gives no line at
// all, never a zero or a warning. Erasable TypeScript only, with no imports but types: tests/test_dashboard_backup_range.py runs
// this file with Node as it is.

/**
 * "412 backups, oldest 3 Mar 2025" or "1 backup, from 3 Mar 2025", plus " · as of 2 Nov" for a count the Restore list took before
 * the last verified backup (a newer backup has been made since, so the count may be one short); '' whenever anything is unknown.
 * `formatDate` writes a date the way the page does (App passes formatWhen without the weekday or the time); `verifiedAt` is the
 * trusted last verified backup (lastVerified), if there is one. The backup service's own count is taken during that verified
 * backup, so it never gets the suffix.
 */
export function backupRangeText(range: BackupRangeState | null | undefined, locale: string | undefined,
  formatDate: (iso: string) => string, verifiedAt?: string): string {
  if (!range || !Number.isSafeInteger(range.count) || range.count < 1) return '';
  const oldest = formatDate(range.oldestAt);
  if (!oldest) return '';
  const head = range.count === 1 ? `1 backup, from ${oldest}` : `${range.count.toLocaleString(locale)} backups, oldest ${oldest}`;
  if (range.source !== 'restore' || !verifiedAt) return head;
  const counted = Date.parse(range.countedAt), verified = Date.parse(verifiedAt), countedOn = formatDate(range.countedAt);
  return Number.isFinite(counted) && Number.isFinite(verified) && counted < verified && countedOn ? `${head} · as of ${countedOn}` : head;
}
