import type { RestoreFileSearch, RestoreSearchOutcome, RestoreSearchResult, RestoreSearchStatus, RestoreSearchVersion } from './native-types';

// Find a file in every backup: the words, the rules for the text and the lines of a result, apart from the component that draws them
// (components/primitives/RestoreFileSearch.tsx), so tests/test_dashboard_file_search.py can run this file with Node as it is.
// Erasable TypeScript only, with no imports but types. The host checks every text and every pick again
// (DashboardWindow.RestoreSearch.cs), and its own sentences reach the page as `message` and `error`.

const BACKSLASH = String.fromCharCode(92);

/** Every sentence the page itself says about a search. {name} marks where a value goes. Kept in one table so the wording test reads it. */
export const FIND_TEXT = {
  tabs: 'How to choose a backup',
  tabByDate: 'Choose by date',
  tabFind: 'Find a file',
  heading: 'Find a file in your backups',
  intro: 'Type the name of a file or folder, or part of it. Rewindle looks through your backups, newest first, and lists each version it finds. Looking does not change anything.',
  fieldLabel: 'File or folder name',
  placeholder: 'For example Budget.xlsx',
  find: 'Find',
  lookFurther: 'Look further back',
  tryAgain: 'Try again',
  clear: 'Clear results',
  reload: 'Reload backups',
  restoreThis: 'Restore this',
  chooseByDate: 'Choose by date',
  searching: 'Looking through your backups…',
  searchingLine: 'Newest first. This only reads your backups, so nothing is changed. It takes up to about half a minute.',
  waiting: 'Waiting for Windows permission…',
  failedTitle: 'The search did not finish.',
  found: '{count} found',
  results: 'Files and folders found',
  folder: 'Folder',
  inFolder: 'In {folder}',
  topLevel: 'At the top level of your backup',
  missing: 'Not in your backups after {when}. It may have been moved, renamed or deleted.',
  changed: 'Changed {when}',
  changeUnknown: 'Change date unknown',
  oneBackup: 'In the backup from {when}',
  someBackups: 'In {count} backups, {first} to {last}',
  backupsUndated: 'In {count} backups',
  oneBackupUndated: 'In one backup',
  manyBackups: 'In {count} or more backups, up to {last}',
  restoreFileLabel: 'Restore {name} as changed {modified}, from the backup of {when}',
  restoreItemLabel: 'Restore {name} from the backup of {when}',
  olderSetup: 'Older setup',
  olderSetupTitle: 'Made before your current backup settings. You will be asked to confirm before restoring from it.',
  moreVersions: 'Older versions are not listed. Choose by date to get one of them.',
  showMore: 'Show more',
  notShown: '{count} not shown',
  noBackups: 'There are no backups to search yet.',
  listLoading: 'Wait for your list of backups to open.',
  suggest: 'Find a file named “{query}”',
  problems: {
    EMPTY: 'Type a file or folder name first.',
    SHORT: 'Type at least 2 characters of the name.',
    LONG: 'That is too long for a name. Type up to 200 characters.',
    FORBIDDEN: `Type just the name, for example Budget.xlsx. A name cannot contain ${BACKSLASH} / : * ? " < > |.`,
    CONTROL: 'That name has characters a file name cannot have. Type it again.',
  },
  hints: {
    idle: 'Type a name, then choose Find. Or choose a backup by date.',
    searching: 'Searching your backups… Nothing is changed.',
    results: 'Choose Restore this next to the version you want.',
    none: 'Nothing found. Check the spelling, or type a shorter part of the name.',
    failed: 'Nothing was changed. Try again, or choose a backup by date.',
  },
} as const;

export type SearchTextProblem = '' | keyof typeof FIND_TEXT.problems;

/** `template` with each {name} replaced by its value. */
export function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => name in values ? String(values[name]) : whole);
}

const FORBIDDEN = BACKSLASH + '/:*?"<>|';
export const MIN_SEARCH_TEXT = 2;
export const MAX_SEARCH_TEXT = 200;

/** Only spaces are trimmed (the host, the backup service and restore.py trim the same). */
export function normalizeSearchText(value: string): string {
  return (value ?? '').replace(/^ +| +$/g, '');
}

/**
 * The first rule the text breaks, in the order every part checks them: EMPTY, CONTROL (a control character or an unpaired
 * surrogate, checked before the length), FORBIDDEN, SHORT, LONG. The length is in UTF-16 code units. The cases all four parts
 * pass are tests/fixtures/file-search-text-cases.json.
 */
export function searchTextProblem(value: string): SearchTextProblem {
  const text = normalizeSearchText(value);
  if (!text) return 'EMPTY';
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (code < 0x20 || code === 0x7f) return 'CONTROL';
    if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) { index++; continue; }
    }
    if (code >= 0xd800 && code <= 0xdfff) return 'CONTROL';
  }
  for (const character of FORBIDDEN) if (text.includes(character)) return 'FORBIDDEN';
  if (text.length < MIN_SEARCH_TEXT) return 'SHORT';
  if (text.length > MAX_SEARCH_TEXT) return 'LONG';
  return '';
}

export function checkSearchText(value: string): { normalized: string; error: SearchTextProblem; message: string } {
  const error = searchTextProblem(value);
  return { normalized: normalizeSearchText(value), error, message: error ? FIND_TEXT.problems[error] : '' };
}

const STATUSES: readonly RestoreSearchStatus[] = ['idle', 'searching', 'done', 'failed'];
const OUTCOMES: readonly RestoreSearchOutcome[] = ['', 'complete', 'more', 'tooMany', 'tooBroad', 'tooSlow'];
/** A status this page does not know (from a newer or an older host) is taken as idle. */
export function statusFrom(value: unknown): RestoreSearchStatus {
  return STATUSES.includes(value as RestoreSearchStatus) ? value as RestoreSearchStatus : 'idle';
}
export function outcomeFrom(value: unknown): RestoreSearchOutcome {
  return OUTCOMES.includes(value as RestoreSearchOutcome) ? value as RestoreSearchOutcome : '';
}

/** A moment in the page's words (the modal's backup dates): the ISO time, else the host's text, else ''. */
export type WhenText = (iso: string, fallback: string) => string;

const isFolder = (result: RestoreSearchResult) => result.type === 'dir';

/** Where the item was: its folder, or the top of the backup. */
export function folderLine(result: RestoreSearchResult): string {
  return result.folderDisplay ? fill(FIND_TEXT.inFolder, { folder: result.folderDisplay }) : FIND_TEXT.topLevel;
}

/** For an item the newer backups that were looked through do not have; '' otherwise. */
export function missingLine(result: RestoreSearchResult, whenText: WhenText): string {
  if (!result.missingFromNewer) return '';
  const when = whenText(result.lastSeen, result.lastSeenDisplay);
  return when ? fill(FIND_TEXT.missing, { when }) : '';
}

/** The two lines of a version: what it is (changed when, how large; a folder is one row) and which backups hold it. */
export function versionLines(version: RestoreSearchVersion, result: RestoreSearchResult, whenText: WhenText): [string, string] {
  let first: string;
  if (isFolder(result)) first = FIND_TEXT.folder;
  else {
    const modified = whenText(version.modified, version.modifiedDisplay);
    first = [modified ? fill(FIND_TEXT.changed, { when: modified }) : FIND_TEXT.changeUnknown, version.sizeDisplay].filter(Boolean).join(' · ');
  }
  const last = whenText(version.when, version.whenDisplay);
  const earliest = whenText(version.firstWhen, version.firstWhenDisplay);
  const count = version.backups.toLocaleString();
  let second: string;
  if (isFolder(result) && result.hasMoreVersions) second = last ? fill(FIND_TEXT.manyBackups, { count, last }) : fill(FIND_TEXT.backupsUndated, { count });
  else if (version.backups <= 1 && last) second = fill(FIND_TEXT.oneBackup, { when: last });
  else if (last && earliest && earliest !== last) second = fill(FIND_TEXT.someBackups, { count, first: earliest, last });
  else if (version.backups <= 1) second = FIND_TEXT.oneBackupUndated;
  else second = fill(FIND_TEXT.backupsUndated, { count });
  return [first, second];
}

/** What Restore this says to a screen reader: which item, which version and which backup. */
export function versionLabel(version: RestoreSearchVersion, result: RestoreSearchResult, whenText: WhenText): string {
  const when = whenText(version.when, version.whenDisplay) || version.snapshotId.slice(0, 8);
  const modified = isFolder(result) ? '' : whenText(version.modified, version.modifiedDisplay);
  return modified
    ? fill(FIND_TEXT.restoreFileLabel, { name: result.name, modified, when })
    : fill(FIND_TEXT.restoreItemLabel, { name: result.name, when });
}

/** The footer's line while the Find tab is shown. */
export function footerHint(search: RestoreFileSearch): string {
  const status = statusFrom(search.status);
  if (status === 'searching') return FIND_TEXT.hints.searching;
  if (status === 'failed') return FIND_TEXT.hints.failed;
  if (status === 'done') return search.resultsTotal > 0 ? FIND_TEXT.hints.results : FIND_TEXT.hints.none;
  if (search.blocked) return search.blocked;
  return FIND_TEXT.hints.idle;
}

/** The button that goes on from the last page: Try again when that page looked through nothing, else Look further back. */
export function continueLabel(search: RestoreFileSearch): string {
  return search.nothingSearched ? FIND_TEXT.tryAgain : FIND_TEXT.lookFurther;
}
