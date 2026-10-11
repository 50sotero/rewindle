import type { DashboardState } from './native-types';

// What the Protection hero's colour and emblem stand for, and the one sentence that says why when the host's own title does not. The
// host writes the title, detail and badge from the latest run, the schedule and a pending repair; it knows nothing of a backup drive
// that is unplugged, a protected folder that is gone or a schedule it could not read, which the page learns from other fields. So
// the page words those itself, and the colour is never louder than the words under it.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_protection_ui.py runs this file with Node as it is.

export type HeroTone = 'active' | 'danger' | 'warning' | 'success' | 'neutral';
export type HeroConcern = { tone: 'danger' | 'warning'; text: string };

/** The drive a path is on ("D:" or "\\server\share"), or '' when the path names none. */
export const driveOf = (path: string | undefined): string => /^[A-Za-z]:|^\\\\[^\\]+\\[^\\]+/.exec(path ?? '')?.[0] ?? '';

/** Something that stops the next backup, or leaves the page unable to judge it, that the host's title does not say. At most one: the most urgent. */
export function heroConcern(state: DashboardState): HeroConcern | null {
  if (state.status.active || state.recovery.repairNeeded) return null;
  const { repository, sources, freshness } = state;
  if (repository.volumeReady === false) {
    const drive = driveOf(repository.path);
    return { tone: 'danger', text: `The backup drive${drive ? ` (${drive})` : ''} isn’t connected, so the next backup can’t run. Plug it back in.` };
  }
  const gone = sources.filter(source => !source.exists).length;
  if (gone) return { tone: 'danger', text: `${gone === 1 ? 'A protected folder' : `${gone} protected folders`} can’t be found. Backups can’t run until ${gone === 1 ? 'it is' : 'they are'} reconnected or removed (see Protected folders below).` };
  // A host that could not read its folders (the setup problem) is not a plan with nothing in it.
  if (!sources.length && !state.setup?.problem && !state.dataError) return { tone: 'warning', text: 'No folders are being backed up yet. Add a folder below.' };
  if (freshness.state === 'Unavailable' && !state.dataError && !state.status.unavailable) {
    return { tone: 'warning', text: 'Rewindle can’t read the Windows backup schedule, so it can’t tell whether backups are on time.' };
  }
  return null;
}

/**
 * One tone for the whole hero. The host overrides the title for an overdue or paused schedule, a repair, or a pending change review,
 * but status.success still describes the last run, so the emblem, tag icon and step rows derive their look from everything the page
 * knows. A backup the person stopped, with the backups still on time, is `neutral`: nothing is wrong and nothing is asked.
 */
export function heroTone(state: DashboardState): HeroTone {
  const s = state.status, freshness = state.freshness.state, concern = heroConcern(state);
  if (s.active || state.recovery.repairBusy) return 'active';
  if (s.failure || state.recovery.repairNeeded || freshness === 'Overdue' || freshness === 'ClockAnomaly' || concern?.tone === 'danger') return 'danger';
  const warning = freshness !== 'Healthy' || !!state.actions.reviewChanges?.visible || !!state.dataError || !!concern || !!s.unavailable;
  if (s.cancelled && !warning) return 'neutral';
  return !s.success || s.cancelled || warning ? 'warning' : 'success';
}
