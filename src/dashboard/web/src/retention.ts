import type { RetentionAbility, RetentionBlocked, RetentionEarlierChange, RetentionLastRun, RetentionReviewState, RetentionState } from './native-types';

// Everything the Old backups card and its dialogs say, worked out from the host's state. The host reports codes and counts; the words
// are here, so they can be checked in one place: plain language, the person's words (backup, backup location, backup service), and a
// next step for anything that is not plain good news. Nothing here sends a command.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_retention.py runs this file with Node as it is.

export type CardCommand = 'configure' | 'turnOff' | 'review' | 'checkNow' | 'refresh';
export type CardButton = { command: CardCommand; label: string; primary: boolean; ability: RetentionAbility | null };
export type CardModel = {
  main: string;
  lines: string[];
  tone: 'neutral' | 'success' | 'warning' | 'error' | 'active';
  buttons: CardButton[];
  busy: boolean;
};

const plural = (count: number, one: string, many: string) => `${count.toLocaleString('en-US')} ${count === 1 ? one : many}`;

/** A day ("3 Sep 2025"), in the viewer's region, from the backup's own recorded time. Empty when the time cannot be read. */
export function formatDay(iso: string, locale?: string): string {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return '';
  try { return date.toLocaleDateString(locale, { day: 'numeric', month: 'short', year: 'numeric' }); } catch { return date.toISOString().slice(0, 10); }
}

/** A day and time ("Wed 3 Sep 2025, 02:00") for a row of the list. */
export function formatMoment(iso: string, locale?: string): string {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return '';
  try {
    return date.toLocaleString(locale, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch { return date.toISOString().slice(0, 16).replace('T', ' '); }
}

/** "September 2025" for a month key ("2025-09"). */
export function monthLabel(key: string, locale?: string): string {
  const match = /^(\d{4})-(\d{2})$/.exec(key);
  if (!match) return key;
  const date = new Date(Number(match[1]), Number(match[2]) - 1, 1);
  try { return date.toLocaleDateString(locale, { month: 'long', year: 'numeric' }); } catch { return key; }
}

/** Rows grouped by the month of their own recorded time, newest month first, in the order they came. */
export function groupByMonth<T extends { when: string }>(rows: T[], locale?: string): { key: string; label: string; items: T[] }[] {
  const groups = new Map<string, T[]>();
  for (const row of rows) {
    const key = /^\d{4}-\d{2}/.test(row.when) ? row.when.slice(0, 7) : '';
    const list = groups.get(key);
    if (list) list.push(row); else groups.set(key, [row]);
  }
  return [...groups.entries()].sort((a, b) => (a[0] < b[0] ? 1 : a[0] > b[0] ? -1 : 0))
    .map(([key, items]) => ({ key, label: key ? monthLabel(key, locale) : 'Unknown date', items }));
}

function daysPhrase(days: number): string {
  if (days >= 14 && days % 7 === 0) return plural(days / 7, 'week', 'weeks');
  return plural(days, 'day', 'days');
}

function weeksPhrase(weeks: number): string {
  if (weeks < 8) return `the last ${plural(weeks, 'week', 'weeks')}`;
  return `roughly the last ${plural(Math.round(weeks / 4.35), 'month', 'months')}`;
}

function monthsPhrase(months: number): string {
  if (months >= 24 && months % 12 === 0) return plural(months / 12, 'year', 'years');
  return plural(months, 'month', 'months');
}

/** What the three counts mean, as one sentence for the counts dialog. */
export function historySummary(daily: number, weekly: number, monthly: number): string {
  return `You can go back to any day in the last ${daysPhrase(daily)}, any week in ${weeksPhrase(weekly)} and any month in the last ${monthsPhrase(monthly)}.`;
}

export type CountKind = 'daily' | 'weekly' | 'monthly';

/** A whole number within its limits, or null for anything else (empty, a fraction, out of range). */
export function parseCount(kind: CountKind, text: string, limits: RetentionState['limits']): number | null {
  if (!/^[1-9]\d{0,2}$/.test(text.trim())) return null;
  const value = Number(text.trim());
  const [low, high] = limits[kind];
  return value >= low && value <= high ? value : null;
}

/** The nearest allowed count. */
export function clampCount(kind: CountKind, value: number, limits: RetentionState['limits']): number {
  const [low, high] = limits[kind];
  if (!Number.isFinite(value)) return low;
  return Math.min(high, Math.max(low, Math.round(value)));
}

export function countError(kind: CountKind, limits: RetentionState['limits']): string {
  const [low, high] = limits[kind];
  return `Choose a number from ${low} to ${high}.`;
}

/** Why clean-up has to wait, with what to do about it. */
export function blockedSentence(code: RetentionBlocked | string, futureDatedAt = '', locale?: string): string {
  switch (code) {
    case 'no_verified_backup': return 'Clean-up starts after your first backup has been made and checked.';
    case 'last_backup_not_verified': return 'The last backup didn’t finish, so nothing is removed until a backup finishes and is checked. Choose Back up now on Protection.';
    case 'folders_changed': return 'Your backed-up folders changed since the last backup, so clean-up waits for the next one. Choose Back up now on Protection, or wait for the next scheduled backup.';
    case 'change_review_open': return 'Your latest backup changed far more files than usual, so clean-up waits. Look at it on Protection. Clean-up can continue after the next backup that looks normal.';
    case 'pending_change': return 'Clean-up waits until an unfinished change to your backups is completed. Protection shows what to do.';
    case 'clock_problem': return 'Your PC’s date or time looks wrong, so clean-up waits. Correct it in Windows Settings under Time & language, then run a backup.';
    case 'future_dated_backup': {
      const day = formatDay(futureDatedAt, locale);
      return `One of your backups is dated ${day || 'in the future'}${day ? ', which is in the future' : ''}, so clean-up waits until then and can’t remove the wrong backups. If that date is far away, save a problem report from Help and about.`;
    }
    case 'backup_location_unavailable': return 'Rewindle can’t reach your backup location, so clean-up waits. Protection shows what to do.';
    case 'google_drive_not_supported': return 'Clean-up isn’t available yet for backups kept in Google Drive. Your backups stay where they are.';
    case 'policy_inactive': return 'Clean-up is off for this backup plan. Choose Change to turn it on again.';
    default: return 'Clean-up waits until your backups are ready. Choose Check now later.';
  }
}

/** Why the list could not be made, without any of the backup service's own words. */
export function errorSentence(code: string): string {
  const lead = 'Rewindle couldn’t check for old backups. Nothing was removed.';
  switch (code) {
    case 'records_unprotected': return `${lead} Its clean-up records aren’t protected the way they should be, so it stopped. If this keeps happening, save a problem report from Help and about.`;
    case 'listing_failed': return `${lead} Your backup location didn’t answer. Choose Check now to try again.`;
    case 'latest_backup_missing': return `${lead} Your latest backup wasn’t in the list, so nothing is offered for removal. On Protection, choose Check recovery readiness.`;
    default: return `${lead} Choose Check now to try again. If it keeps happening, save a problem report from Help and about.`;
  }
}

/** The reason a request was refused, to follow "because". */
export function refusalReason(code: string): string {
  switch (code) {
    case 'busy': return 'a backup or another change was running';
    case 'google_drive_not_supported': return 'clean-up isn’t available yet for backups kept in Google Drive';
    case 'pending_change': return 'an unfinished change to your backups must be completed first';
    case 'no_verified_backup': return 'there is no checked backup yet';
    case 'last_backup_not_verified': return 'the last backup didn’t finish';
    case 'folders_changed': return 'your folders changed since the last backup';
    case 'change_review_open': return 'your latest backup needs a look first';
    case 'earlier_changes_not_confirmed': return 'your files need checking first';
    case 'clock_problem': return 'your PC’s date or time looks wrong';
    case 'future_dated_backup': return 'one of your backups is dated in the future';
    case 'backup_location_unavailable': return 'Rewindle can’t reach your backup location';
    case 'policy_inactive': return 'clean-up is off';
    case 'preview_mismatch': return 'the list is out of date';
    default: return 'something it needs wasn’t ready';
  }
}

export function refusalNextStep(code: string): string {
  switch (code) {
    case 'busy': return 'Try again when it has finished.';
    case 'google_drive_not_supported': return 'Your backups stay where they are.';
    case 'pending_change': return 'Protection shows what to do.';
    case 'no_verified_backup': return 'Clean-up starts after your first backup has been made and checked.';
    case 'last_backup_not_verified': return 'Choose Back up now on Protection.';
    case 'folders_changed': return 'Choose Back up now on Protection, or wait for the next scheduled backup.';
    case 'change_review_open': return 'Look at it on Protection.';
    case 'earlier_changes_not_confirmed': return 'Tick the box to say your files look right, then try again.';
    case 'clock_problem': return 'Correct it in Windows Settings under Time & language, then run a backup.';
    case 'future_dated_backup': return 'If that date is far away, save a problem report from Help and about.';
    case 'backup_location_unavailable': return 'Protection shows what to do.';
    case 'policy_inactive': return 'Turn it on again to use it.';
    case 'preview_mismatch': return 'Close this list and choose Check now.';
    default: return 'Try again later.';
  }
}

/** What a running step is doing, in one line. */
export function stageSentence(stage: string, count: number): string {
  switch (stage) {
    case 'approval': return 'Windows is asking for your permission…';
    case 'listing': return 'Checking which old backups can be removed…';
    case 'checking': return count > 0 ? `Checking the list, then removing ${plural(count, 'old backup', 'old backups')}…` : 'Checking the list…';
    case 'freeing': return 'Freeing space on your backup location. This can take a while.';
    case 'verifying': return 'Checking your remaining backups…';
    default: return 'Working…';
  }
}

export function lastRunSentence(run: RetentionLastRun, locale?: string): string {
  const when = formatDay(run.finishedAt, locale) || 'recently';
  switch (run.outcome) {
    case 'removed': return run.freedDisplay
      ? `Last clean-up ${when}: removed ${plural(run.removedCount, 'backup', 'backups')} and freed ${run.freedDisplay}.`
      : `Last clean-up ${when}: removed ${plural(run.removedCount, 'backup', 'backups')}.`;
    case 'nothing_to_remove': return `Last clean-up ${when}: nothing needed removing.`;
    case 'space_pending': return `Last clean-up ${when} removed ${plural(run.removedCount, 'backup', 'backups')}, but the space wasn’t freed yet. The next clean-up frees it.`;
    case 'partial': return `Last clean-up ${when} stopped after removing ${run.removedCount.toLocaleString('en-US')} of ${plural(run.confirmedCount, 'backup', 'backups')}. The rest are still there. Choose Review and remove to try again.`;
    case 'check_failed': return `Last clean-up ${when} removed ${plural(run.removedCount, 'backup', 'backups')}, but the check afterwards found a problem with your backups. On Protection, choose Check recovery readiness.`;
    default: return `Last clean-up ${when} didn’t finish. Nothing outside the list you confirmed was removed. Choose Review and remove to try again.`;
  }
}

/**
 * Why the person is asked to check their files before old backups go, for the card (one line, or empty when there is nothing to
 * add) or for the list of old backups (always a sentence: the list shows it only when it asks for the tick). Only a backup that
 * changed far more files than usual is described that way. One that couldn't be compared with the backup before it (the first
 * backup, or the first after a folder change) or whose record doesn't say (an older backup service) gets a calm sentence instead.
 */
export function filesCheckSentence(changes: RetentionEarlierChange[] | null | undefined, recordUnknown: boolean, place: 'card' | 'list', locale?: string): string {
  const list = changes ?? [];
  const hold = list.find(change => change.kind === 'hold');
  const ask = 'Before anything is removed, you’ll be asked to check that your files look right.';
  if (hold) {
    const day = formatDay(hold.at, locale);
    const which = day ? `A backup on ${day}` : 'A recent backup';
    return place === 'card'
      ? `${which} changed far more files than usual. ${ask}`
      : `${which} changed far more files than usual, and those changes weren’t confirmed. If you didn’t expect them, some files may be missing or damaged, and these old backups may hold the only good copies. Open your folders and check them before you continue.`;
  }
  if (list.length > 0) {
    return place === 'card'
      ? `Rewindle couldn’t compare some recent backups with the ones before them. ${ask}`
      : 'Rewindle couldn’t compare some recent backups with the ones before them, so check that your files look right before you continue.';
  }
  if (recordUnknown) {
    return place === 'card' ? ask : 'Rewindle couldn’t read all its records of earlier backups, so check that your files look right before you continue.';
  }
  return place === 'card' ? '' : 'This is the first clean-up, so check that your files look right before you continue: these old backups may hold the only copies of files that changed or were deleted since.';
}

/** The card: one main line, the lines under it, its buttons, and how loud it is. */
export function cardModel(state: RetentionState, locale?: string): CardModel {
  const model: CardModel = { main: '', lines: [], tone: 'neutral', buttons: [], busy: false };
  if (state.mode === 'unsupported') {
    model.main = 'Rewindle keeps every backup.';
    model.lines.push(state.unsupportedReason === 'legacy'
      ? 'The backup service on this PC (the earlier personal edition) has no clean-up of old backups. Your backups stay where they are.'
      : state.unsupportedReason === 'google_drive'
        ? 'Clean-up isn’t available yet for backups kept in Google Drive. Your backups stay where they are.'
        : 'This version of the backup service can’t clean up old backups. To get clean-up, open Rewindle Setup and choose Reinstall or repair.');
    return model;
  }
  const operation = state.operation;
  if (operation.active) {
    model.busy = true;
    model.tone = 'active';
    model.main = operation.action === 'apply' ? 'Removing old backups…' : operation.action === 'configure' ? 'Saving your clean-up setting…' : 'Checking for old backups…';
    model.lines.push(stageSentence(operation.stage, operation.count));
    if (operation.action === 'apply') model.lines.push('A backup that’s due while old backups are being removed is skipped; you can back up again as soon as this finishes.');
    return model;
  }
  if (state.mode === 'unknown' && (state.problem === 'not_read' || state.problem === 'plan_unavailable')) {
    // The first read after the page opens, or the backup plan is still loading: nothing is wrong yet.
    model.main = 'Checking the clean-up setting…';
    return model;
  }
  if (state.mode === 'unknown') {
    model.main = 'Rewindle couldn’t read the clean-up setting.';
    model.tone = 'warning';
    model.lines.push('Nothing is removed while it can’t be read. Choose Try again. If it keeps happening, save a problem report from Help and about.');
    model.buttons.push({ command: 'refresh', label: 'Try again', primary: false, ability: null });
    return model;
  }
  if (state.mode === 'off') {
    if (state.resetByReinstall) {
      model.main = 'Clean-up is off.';
      model.lines.push('It was turned off when Rewindle was reinstalled or updated. Nothing was removed. Turn it on again to keep using it.');
    } else {
      model.main = 'Rewindle keeps every backup.';
      model.lines.push('Over time they fill your backup location. Clean-up keeps one backup for each recent day, week and month and offers to remove the rest, but only after you check the list and confirm it.');
    }
    if (state.lastRun) model.lines.push(lastRunSentence(state.lastRun, locale));
    model.buttons.push({ command: 'configure', label: 'Turn on clean-up…', primary: true, ability: state.canConfigure });
    return model;
  }
  model.main = `Clean-up is on: keeping a backup for each of the last ${plural(state.keepDaily, 'day', 'days')}, ${plural(state.keepWeekly, 'week', 'weeks')} and ${plural(state.keepMonthly, 'month', 'months')}.`;
  const preview = state.preview;
  let reviewButton: CardButton | null = null;
  let checkButton = false;
  if (!preview || preview.status === 'none' || preview.status === 'stale') {
    model.lines.push('Rewindle hasn’t checked for old backups since your last backup. Choose Check now to see which can be removed.');
    checkButton = true;
  } else if (preview.status === 'error') {
    model.lines.push(errorSentence(preview.errorCode));
    model.tone = 'warning';
    checkButton = true;
  } else if (preview.status === 'blocked') {
    model.lines.push(blockedSentence(preview.blocked, preview.futureDatedAt, locale));
    model.tone = preview.blocked === 'no_verified_backup' ? 'neutral' : 'warning';
  } else if (preview.removeCount > 0) {
    const oldest = formatDay(preview.oldestRemoveAt, locale), newest = formatDay(preview.newestRemoveAt, locale);
    const span = oldest && newest ? (oldest === newest ? `, from ${oldest}` : `, from ${oldest} to ${newest}`) : '';
    model.lines.push(`${plural(preview.removeCount, 'old backup', 'old backups')} can be removed${span}. ${plural(preview.keepCount, 'backup stays', 'backups stay')}.`);
    const check = filesCheckSentence(preview.earlierChanges, preview.earlierChangesUnknown, 'card', locale);
    if (check) model.lines.push(check);
    reviewButton = { command: 'review', label: 'Review and remove…', primary: true, ability: state.canReview };
  } else if (preview.prunePending) {
    model.lines.push('The backups removed last time still take up space. Choose Finish freeing space.');
    reviewButton = { command: 'review', label: 'Finish freeing space', primary: true, ability: state.canReview };
  } else {
    model.lines.push('Nothing to remove right now. Rewindle offers to check again after your next backup.');
  }
  if (state.lastRun) model.lines.push(lastRunSentence(state.lastRun, locale));
  if (reviewButton) model.buttons.push(reviewButton);
  if (checkButton) model.buttons.push({ command: 'checkNow', label: 'Check now', primary: true, ability: state.canCheckNow });
  model.buttons.push({ command: 'configure', label: 'Change…', primary: false, ability: state.canConfigure });
  model.buttons.push({ command: 'turnOff', label: 'Turn off', primary: false, ability: state.canTurnOff });
  return model;
}

/** The result screen of the review dialog: its title and text. */
export function resultScreen(review: RetentionReviewState): { title: string; text: string; tone: 'success' | 'warning' | 'error' | 'info' } | null {
  const result = review.result;
  if (!result) return null;
  const removed = result.removedCount, confirmed = result.confirmedCount;
  switch (result.status) {
    case 'removed': return {
      title: 'Old backups removed', tone: 'success',
      text: `Removed ${plural(removed, 'old backup', 'old backups')}${result.freedDisplay ? ` and freed ${result.freedDisplay}` : ''}. Your remaining backups were checked and are fine.`,
    };
    case 'nothing_to_remove': return {
      title: 'Space freed', tone: 'success',
      text: 'The space of the backups removed earlier was freed, and your remaining backups were checked and are fine.',
    };
    case 'declined': return {
      title: 'Nothing was removed', tone: 'info',
      text: 'You didn’t allow it in the Windows permission prompt, so nothing was removed.',
    };
    case 'preview_changed': return {
      title: 'Your backups changed', tone: 'info',
      text: 'Your backups changed since this list was made, so nothing was removed. Here is the new list.',
    };
    case 'refused': return {
      title: 'Nothing was removed', tone: 'warning',
      text: `Nothing was removed because ${refusalReason(result.reason)}. ${refusalNextStep(result.reason)}`,
    };
    case 'partial': return result.reason === 'unverified' ? {
      title: 'Clean-up stopped', tone: 'warning',
      text: 'Some backups on the list may have been removed, then Rewindle couldn’t read back what is left on your backup location. Nothing outside the list you confirmed was removed. Choose Check now later to see what’s there.',
    } : {
      title: 'Clean-up stopped', tone: 'warning',
      text: `Removed ${removed.toLocaleString('en-US')} of ${plural(confirmed, 'backup', 'backups')}, then stopped. The other ${(confirmed - removed).toLocaleString('en-US')} are still there, and nothing else was touched. Choose Review and remove later to try again.`,
    };
    case 'space_pending': return {
      title: 'Backups removed, space not freed yet', tone: 'warning',
      text: `Removed ${plural(removed, 'old backup', 'old backups')}, but the space wasn’t freed yet. Choose Finish freeing space in Settings to try again.`,
    };
    case 'check_failed': return {
      title: 'Backups removed, check found a problem', tone: 'error',
      text: `Removed ${plural(removed, 'old backup', 'old backups')}, but the check of your remaining backups found a problem. On Protection, choose Check recovery readiness to see what to do.`,
    };
    case 'failed': return {
      title: 'Clean-up didn’t finish', tone: 'warning',
      text: 'Nothing outside the list you confirmed was removed. Close this, choose Check now, then Review and remove to try again.',
    };
    default: return {
      title: 'Rewindle couldn’t confirm how clean-up went', tone: 'warning',
      text: 'It can only remove backups on the list you saw. Settings shows what’s there now.',
    };
  }
}

/** The label a screen reader gives a staying backup's tags. */
export function reasonsLabel(reasons: string[]): string {
  const words: string[] = [];
  for (const reason of reasons) {
    if (reason === 'latest') words.push('your newest backup');
    else if (reason === 'day') words.push('the last backup of its day');
    else if (reason === 'week') words.push('the last backup of its week');
    else if (reason === 'month') words.push('the last backup of its month');
    else if (reason === 'checked') words.push('a checked backup of its period');
    else if (reason === 'before_change') words.push('the last backup before an unusual change');
  }
  return words.length ? `Kept as ${words.join(', ')}` : 'Kept';
}

/** The short tag a staying backup shows for each reason. */
export function reasonTag(reason: string): string {
  switch (reason) {
    case 'latest': return 'Newest';
    case 'day': return 'Day';
    case 'week': return 'Week';
    case 'month': return 'Month';
    case 'checked': return 'Checked';
    case 'before_change': return 'Before a change';
    default: return '';
  }
}

/** The busy note the page shows once while a clean-up step runs, or empty. */
export function retentionBusyNote(state: RetentionState | null | undefined): string {
  if (!state?.operation.active) return '';
  return state.operation.action === 'apply'
    ? 'Old backups are being removed. Other changes wait until it finishes, and a backup that’s due meanwhile is skipped.'
    : 'Rewindle is checking for old backups. Other changes wait until it finishes.';
}
