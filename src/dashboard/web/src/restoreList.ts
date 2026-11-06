import type { RestoreSnapshot } from './native-types';

// The list of backups on Restore's first step. Nothing ever prunes them, so a computer backed up every hour has thousands after a few
// months, and a card for every one of them was drawn again for every state the host publishes (about once a second) and every key
// typed in the search. The list now draws the newest page of them and offers the older ones a page at a time; the search and the dates
// still look through all of them.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_ui_actions.py runs this file with Node as it is.

/** How many backups the list draws at first, and how many more each "Show older backups" adds. */
export const SNAPSHOT_PAGE = 50;

/** What the paging needs of a backup: its id and the ISO 8601 time it was made. */
export type ListedBackup = { id: string; when: string };

export type BackupPage<T extends ListedBackup> = {
  /** The backups to draw, newest first: the first `limit`, then the chosen one when it is older than those. */
  shown: T[];
  /** How many backups are not drawn. */
  hidden: number;
  /** The newest backup that is not drawn, where focus goes once "Show older backups" draws it; empty when none is hidden. */
  nextId: string;
};

const timeOf = (backup: ListedBackup) => {
  const time = Date.parse(backup.when);
  return Number.isNaN(time) ? Number.NEGATIVE_INFINITY : time;
};

/** Newest first. A backup whose time cannot be read goes last, and backups made at the same moment keep the order they came in. */
export function newestFirst<T extends ListedBackup>(backups: readonly T[]): T[] {
  return backups
    .map((backup, index) => ({ backup, index, time: timeOf(backup) }))
    .sort((a, b) => (a.time === b.time ? a.index - b.index : a.time > b.time ? -1 : 1))
    .map(entry => entry.backup);
}

/**
 * The page of `backups` to draw: the newest `limit` of them. The backup chosen earlier stays in view even when it is older than those,
 * so going back from Choose files still shows which one is chosen.
 */
export function pageSnapshots<T extends ListedBackup>(backups: readonly T[], limit: number, selectedId = ''): BackupPage<T> {
  const ordered = newestFirst(backups);
  const count = Math.max(0, Math.floor(limit));
  const shown = ordered.slice(0, count);
  const rest = ordered.slice(count);
  const chosen = selectedId ? rest.find(backup => backup.id === selectedId) : undefined;
  if (chosen) shown.push(chosen);
  const next = rest.find(backup => backup !== chosen);
  return { shown, hidden: ordered.length - shown.length, nextId: next ? next.id : '' };
}

/**
 * A key that changes only when something drawn on a backup's card or looked through by the search does. The host sends the whole list
 * with every state, as new objects each time, so the cards and their dates are worked out again only when this changes.
 */
export function snapshotListSignature(backups: readonly RestoreSnapshot[]): string {
  return backups.map(backup => [
    backup.id, backup.shortId, backup.when, backup.whenDisplay, backup.hostname, backup.sourceSummary,
    backup.fileCount, backup.fileCountDisplay, backup.byteCount, backup.sizeDisplay, backup.isLegacyUnbound ? 1 : 0,
  ].join('\u001f')).join('\u001e');
}
