import type { RunState } from './native-types';

// Which runs did not succeed, and which of those still ask for something. A run that failed or was incomplete is resolved once
// a later one succeeded: a backup that succeeds has saved everything an earlier failed one missed, and it covers a dry run's
// check as well. A resolved run stays in the history as a record of what happened, but it is not something to act on.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_run_problems.py runs this file with Node as it is.

/** Stopped on request: not a problem, and never one to resolve. */
export const isCancelled = (run: Pick<RunState, 'result'>) => /^(cancelled|canceled)$/i.test(run.result.trim());
/** Failed, incomplete, or any other result that is not a success and was not asked for. */
export const isProblem = (run: Pick<RunState, 'success' | 'result'>) => !run.success && !isCancelled(run);

const startOf = (run: RunState) => Date.parse(run.started);

/** For each problem run that a later run resolved, the nearest such later run, by the problem run's id. */
export function resolvedRuns(runs: readonly RunState[]): Map<string, RunState> {
  const resolved = new Map<string, RunState>();
  // Walking from the newest run back, this holds the nearest later success of each type seen so far.
  const nearest = new Map<string, RunState>();
  const dated = runs.filter(run => Number.isFinite(startOf(run))).sort((a, b) => startOf(b) - startOf(a));
  for (const run of dated) {
    if (run.success) { nearest.set(run.type, run); continue; }
    if (!isProblem(run)) continue;
    const own = nearest.get(run.type), backup = nearest.get('Backup');
    const by = own && backup ? (startOf(own) <= startOf(backup) ? own : backup) : own ?? backup;
    if (by) resolved.set(run.id, by);
  }
  return resolved;
}

/** The problem runs nothing has resolved yet, newest first. Each is newer than the last successful backup. */
export const unresolvedRuns = (runs: readonly RunState[], resolved: ReadonlyMap<string, RunState>) =>
  runs.filter(run => isProblem(run) && !resolved.has(run.id) && Number.isFinite(startOf(run))).sort((a, b) => startOf(b) - startOf(a));

/** "backup" or "dry run", to go after "the". */
export const runNoun = (type: string) => type.trim() ? type.trim().toLowerCase() : 'backup';

// The host's short result, said as the end of a sentence about the run ("The backup on … failed").
const OUTCOMES: Record<string, string> = {
  failed: 'failed', canceled: 'cancelled', cancelled: 'cancelled', incomplete: 'was incomplete',
  'source errors': 'found source errors', 'cancellation failed': 'could not be cancelled', 'needs attention': 'needs attention',
};
/** A known result as a verb phrase, or undefined. */
export const knownOutcome = (result: string): string | undefined => OUTCOMES[result.trim().toLowerCase()];
export const runOutcome = (result: string) => knownOutcome(result) ?? `did not succeed (${result.trim() || 'no result recorded'})`;

/** Where a resolved run's resolution is named: "Resolved by the backup on Sun, 31 Aug 02:00". */
export const resolvedByText = (by: RunState) => `Resolved by the ${runNoun(by.type)} on ${by.startedDisplay}`;

/**
 * The one thing the history asks for, or undefined when it asks for nothing: what has not succeeded since the last successful
 * backup. `lastSuccess` is the newest successful backup the history holds.
 */
export function attentionText(unresolved: readonly RunState[], lastSuccess: RunState | undefined): string | undefined {
  const latest = unresolved[0];
  if (!latest) return undefined;
  const run = `the ${runNoun(latest.type)} on ${latest.startedDisplay}`, outcome = runOutcome(latest.result);
  if (unresolved.length === 1) return `${run.charAt(0).toUpperCase()}${run.slice(1)} ${outcome}, and no backup has succeeded since.`;
  return lastSuccess
    ? `No backup has succeeded since ${lastSuccess.startedDisplay}. ${unresolved.length} runs since then did not succeed; the latest, ${run}, ${outcome}.`
    : `None of the backups listed here has succeeded. ${unresolved.length} runs did not; the latest, ${run}, ${outcome}.`;
}
