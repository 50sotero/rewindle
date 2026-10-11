import type { RunState } from './native-types';

// Which runs did not succeed, and which of those still ask for something. A run that failed or was incomplete is resolved once
// a later one succeeded: a backup that succeeds has saved everything an earlier failed one missed, and it covers a check-only run
// as well. A resolved run stays in the history as a record of what happened, but it is not something to act on.
// The history only holds runs the app saw, so the host's own "last verified backup" settles what the list cannot: a problem older
// than it is resolved too, even when the backup that did it is not in the list.
// The words a run is shown with live here too (resultLabel, typeLabel), so the table, the details and the sentences agree.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_run_problems.py runs this file with Node as it is.

/** Stopped on request: not a problem, and never one to resolve. */
export const isCancelled = (run: Pick<RunState, 'result'>) => /^(cancelled|canceled)$/i.test(run.result.trim());
/** Failed, incomplete, or any other result that is not a success and was not asked for. */
export const isProblem = (run: Pick<RunState, 'success' | 'result'>) => !run.success && !isCancelled(run);

const startOf = (run: Pick<RunState, 'started'>) => Date.parse(run.started);

/** What put a problem right: a later run in the list, or (`finished`) the backup the host last verified, which is not in it. */
export type Resolver = Pick<RunState, 'type' | 'startedDisplay'> & { id?: string; finished?: boolean };
/** The host's last verified backup: when it finished (ISO) and that moment as the page writes it. */
export type Verified = { at: string; display: string };

/**
 * The host's last verified backup, when its time can be trusted: not while the clocks disagree or nothing is known, and not a time
 * in the future.
 */
export function lastVerified(freshness: { state: string; verifiedAt: string }, display: string, now = Date.now()): Verified | undefined {
  if (freshness.state === 'ClockAnomaly' || freshness.state === 'Unavailable') return undefined;
  const at = Date.parse(freshness.verifiedAt);
  return Number.isFinite(at) && at <= now + 5 * 60_000 ? { at: freshness.verifiedAt, display } : undefined;
}

/** For each problem run that a later run resolved, the nearest such later run, by the problem run's id. */
export function resolvedRuns(runs: readonly RunState[], verified?: Verified): Map<string, Resolver> {
  const resolved = new Map<string, Resolver>();
  // Walking from the newest run back, this holds the nearest later success of each type seen so far.
  const nearest = new Map<string, RunState>();
  const verifiedAt = verified ? Date.parse(verified.at) : Number.NaN;
  const dated = runs.filter(run => Number.isFinite(startOf(run))).sort((a, b) => startOf(b) - startOf(a));
  for (const run of dated) {
    if (run.success) { nearest.set(run.type, run); continue; }
    if (!isProblem(run)) continue;
    const own = nearest.get(run.type), backup = nearest.get('Backup');
    const by = own && backup ? (startOf(own) <= startOf(backup) ? own : backup) : own ?? backup;
    if (by) resolved.set(run.id, by);
    else if (verified && verifiedAt > startOf(run)) resolved.set(run.id, { type: 'Backup', startedDisplay: verified.display, finished: true });
  }
  return resolved;
}

/** The problem runs nothing has resolved yet, newest first. Each is newer than the last successful backup. */
export const unresolvedRuns = (runs: readonly RunState[], resolved: ReadonlyMap<string, Resolver>) =>
  runs.filter(run => isProblem(run) && !resolved.has(run.id) && Number.isFinite(startOf(run))).sort((a, b) => startOf(b) - startOf(a));

/** The newest successful backup: the newest one in the list, or the host's last verified one when that is newer. */
export function lastSuccessfulBackup(runs: readonly RunState[], verified?: Verified): Pick<RunState, 'startedDisplay'> | undefined {
  const listed = runs.filter(run => run.success && run.type === 'Backup' && Number.isFinite(startOf(run))).sort((a, b) => startOf(b) - startOf(a))[0];
  return verified && (!listed || Date.parse(verified.at) > startOf(listed)) ? { startedDisplay: verified.display } : listed;
}

/** "backup" or "check", to go after "the". */
export const runNoun = (type: string) => /^dry[\s_-]*run$/i.test(type.trim()) ? 'check' : type.trim() ? type.trim().toLowerCase() : 'backup';

/** The kind of run as the page says it: a dry run reads "Check only" (it looks through the folders and saves nothing). */
export const typeLabel = (type: string) => /^dry[\s_-]*run$/i.test(type.trim()) ? 'Check only' : type.trim() || 'Backup';

// The host's short result in plain words, with a sentence for a tooltip. The key is the host's word in lower case.
const RESULTS: Record<string, { label: string; hint: string }> = {
  verified: { label: 'Verified', hint: 'The backup was saved and checked, including a restore test.' },
  unchanged: { label: 'Up to date', hint: 'Nothing had changed since the last backup, so nothing new was saved.' },
  'clean baseline': { label: 'Check passed', hint: 'A check-only run looked through your folders and found nothing wrong. Nothing was saved.' },
  'source errors': { label: 'Check found problems', hint: 'A check-only run found files it could not read. Nothing was saved.' },
  incomplete: { label: 'Incomplete', hint: 'Some files could not be read, so this run does not count as a finished backup.' },
  failed: { label: 'Failed', hint: 'The run stopped with an error.' },
  cancelled: { label: 'Cancelled', hint: 'You stopped this run before it finished.' },
  canceled: { label: 'Cancelled', hint: 'You stopped this run before it finished.' },
  'cancellation failed': { label: 'Could not stop', hint: 'A request to stop this run did not go through.' },
};
/** The host's result in plain words ("Unchanged" reads "Up to date"). A result nobody has a word for is shown as it came. */
export const resultLabel = (result: string) => RESULTS[result.trim().toLowerCase()]?.label ?? (result.trim() || 'No result');
/** One sentence on what a result means, or undefined for one nobody has a word for. */
export const resultHint = (result: string): string | undefined => RESULTS[result.trim().toLowerCase()]?.hint;
/** A backup that found everything already saved. */
export const isUnchanged = (result: string) => /^unchanged$/i.test(result.trim());

// The host's short result, said as the end of a sentence about the run ("The backup on … failed").
const OUTCOMES: Record<string, string> = {
  failed: 'failed', canceled: 'cancelled', cancelled: 'cancelled', incomplete: 'was incomplete',
  'source errors': 'found files it could not read', 'cancellation failed': 'could not be cancelled', 'needs attention': 'needs attention',
};
/** A known result as a verb phrase, or undefined. */
export const knownOutcome = (result: string): string | undefined => OUTCOMES[result.trim().toLowerCase()];
export const runOutcome = (result: string) => knownOutcome(result) ?? `did not succeed (${result.trim() || 'no result recorded'})`;

/** Where a resolved run's resolution is named: "Resolved by the backup on Sun, 31 Aug 02:00". */
export const resolvedByText = (by: Resolver) => `Resolved by the ${runNoun(by.type)} ${by.finished ? 'that finished on' : 'on'} ${by.startedDisplay}`;

/** The middle value of the successful backups' durations, in seconds, or 0 when there are none. */
export function usualSeconds(runs: readonly Pick<RunState, 'success' | 'result' | 'durationSeconds'>[]): number {
  const done = runs.filter(run => run.success && Number.isFinite(run.durationSeconds));
  // A backup that found nothing new takes seconds; it would pull "usual" down, so it only counts when there is nothing else.
  const real = done.filter(run => !isUnchanged(run.result));
  const sorted = (real.length ? real : done).map(run => run.durationSeconds).sort((a, b) => a - b);
  if (sorted.length === 0) return 0;
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

/**
 * The one thing the history asks for, or undefined when it asks for nothing: what has not succeeded since the last successful
 * backup. `lastSuccess` is the newest successful backup there is (see lastSuccessfulBackup).
 */
export function attentionText(unresolved: readonly RunState[], lastSuccess: Pick<RunState, 'startedDisplay'> | undefined): string | undefined {
  const latest = unresolved[0];
  if (!latest) return undefined;
  const run = `the ${runNoun(latest.type)} on ${latest.startedDisplay}`, outcome = runOutcome(latest.result);
  if (unresolved.length === 1) return `${run.charAt(0).toUpperCase()}${run.slice(1)} ${outcome}, and no backup has succeeded since.`;
  return lastSuccess
    ? `No backup has succeeded since ${lastSuccess.startedDisplay}. ${unresolved.length} runs since then did not succeed; the latest, ${run}, ${outcome}.`
    : `None of the backups listed here has succeeded. ${unresolved.length} runs did not; the latest, ${run}, ${outcome}.`;
}
