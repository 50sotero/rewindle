import type { DashboardState } from './native-types';

// What the Protection hero's colour and emblem stand for, and the one sentence that says why when the host's own title does not. The
// host writes the title, detail and badge from the latest run, the schedule and a pending repair; it knows nothing of a backup drive
// that is unplugged, a protected folder that is gone or a schedule it could not read, which the page learns from other fields. So
// the page words those itself, and the colour is never louder than the words under it. The Off-site copy card's colour, and its words
// for a check that is overdue, are decided here too.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_protection_ui.py runs this file with Node as it is.

export type HeroTone = 'active' | 'danger' | 'warning' | 'success' | 'neutral';
export type HeroConcern = { tone: 'danger' | 'warning'; text: string };

/** The drive a path is on ("D:" or "\\server\share"), or '' when the path names none. */
export const driveOf = (path: string | undefined): string => /^[A-Za-z]:|^\\\\[^\\]+\\[^\\]+/.exec(path ?? '')?.[0] ?? '';

/** How a missing part of the installation is put back. Rewindle Setup repairs only its own engine; the earlier personal edition is
 *  reinstalled (the host's EngineProfile.ReinstallAdvice says the same). */
export const reinstallAdvice = (state: Pick<DashboardState, 'setup'>): string => state.setup?.engineProfile === 'legacy'
  ? 'Reinstall the backup program to put it back.'
  : 'Open Rewindle Setup and choose Reinstall or repair to put it back.';

/** Something that stops the next backup, or leaves the page unable to judge it, that the host's title does not say. At most one: the most urgent. */
export function heroConcern(state: DashboardState): HeroConcern | null {
  if (state.status.active || state.recovery.repairNeeded || state.recovery.moveRunning) return null;
  const { repository, sources, freshness } = state;
  if (repository.volumeReady === false) {
    const drive = driveOf(repository.path);
    return { tone: 'danger', text: `The backup drive${drive ? ` (${drive})` : ''} isn’t connected, so the next backup can’t run. Plug it back in.` };
  }
  const missing = sources.filter(source => !source.exists);
  // The folder that holds the restore test file can't be taken out of the backup, so reconnecting or removing it is no remedy.
  if (missing.some(source => source.isCanary)) return { tone: 'danger', text: `The restore test file is missing, so backups can’t be checked. ${reinstallAdvice(state)}` };
  const gone = missing.length;
  if (gone) return { tone: 'danger', text: `${gone === 1 ? 'A protected folder' : `${gone} protected folders`} can’t be found. Backups can’t run until ${gone === 1 ? 'it is' : 'they are'} reconnected or removed (see Protected folders below).` };
  // A host that could not read its folders (the setup problem) is not a plan with nothing in it.
  if (!sources.length && !state.setup?.problem && !state.dataError) return { tone: 'warning', text: 'No folders are being backed up yet. Add a folder below.' };
  if (freshness.state === 'Unavailable' && !state.dataError && !state.status.unavailable) {
    return { tone: 'warning', text: 'Rewindle can’t read the Windows backup schedule, so it can’t tell whether backups are on time.' };
  }
  // While the schedule has the hero's words (an overdue or paused backup), the change review would be a button with nothing
  // above it to say why. With the backups on time the host's own title and detail are about the review.
  if (state.actions.reviewChanges?.visible && freshness.state !== 'Healthy') {
    return { tone: 'warning', text: 'Your last backup also found far more changes than usual. Look them over, then choose Confirm these changes.' };
  }
  return null;
}

/**
 * One tone for the whole hero. The host overrides the title for an overdue or paused schedule, a repair, a running move of the backup
 * location, or a pending change review, but status.success still describes the last run, so the emblem, tag icon and step rows derive
 * their look from everything the page knows. A running move is `active` like a running backup: things are happening and nothing is
 * wrong. A backup the person stopped, with the backups still on time, is `neutral`: nothing is wrong and nothing is asked. So is a
 * backup that was missed while the PC was off or asleep and that Windows is about to start (`CatchingUp`; the host calls it overdue if
 * it has not started 45 minutes after the PC came back), though it is not green either: the latest backup is not done yet.
 */
export function heroTone(state: DashboardState): HeroTone {
  const s = state.status, freshness = state.freshness.state, concern = heroConcern(state);
  if (s.active || state.recovery.repairBusy || state.recovery.moveRunning) return 'active';
  if (s.failure || state.recovery.repairNeeded || freshness === 'Overdue' || freshness === 'ClockAnomaly' || concern?.tone === 'danger') return 'danger';
  const catchingUp = freshness === 'CatchingUp';
  const warning = (freshness !== 'Healthy' && !catchingUp) || !!state.actions.reviewChanges?.visible || !!state.dataError || !!concern || !!s.unavailable;
  if ((s.cancelled || catchingUp) && !warning) return 'neutral';
  return !s.success || s.cancelled || warning ? 'warning' : 'success';
}

type Offsite = Pick<DashboardState['offsite'], 'kind' | 'checkOverdue' | 'provider'>;

/** A check that is waiting for its next run (`Stale`) or shown as running (`InProgress`), when none has worked for about two days (the
 *  host's checkOverdue). Rewindle checks the off-site copy every night, so by then it is no longer a wait. */
export const offsiteCheckOverdue = (offsite: Offsite): boolean => !!offsite.checkOverdue && (offsite.kind === 'Stale' || offsite.kind === 'InProgress');

/** The Off-site copy card's colour. Waiting for the next check is neutral and a check that is running is active, since Rewindle does both by
 *  itself, until the check is overdue: then it is a warning, with a next step (see offsiteOverdueWords). */
export function offsiteTone(offsite: Offsite): HeroTone {
  if (offsiteCheckOverdue(offsite)) return 'warning';
  switch (offsite.kind) {
    case 'RestoreVerified': case 'ProviderConfirmed': return 'success';
    case 'Failed': return 'danger';
    case 'InProgress': return 'active';
    case 'NotConfigured': case 'Stale': return 'neutral';
    default: return 'warning';
  }
}

/** The card's title, description and next step for an overdue check, or null when the check is not overdue. The provider is named only
 *  when the host's evidence names one. */
export function offsiteOverdueWords(offsite: Offsite): { title: string; detail: string; nextStep: string } | null {
  if (!offsiteCheckOverdue(offsite)) return null;
  const provider = (offsite.provider ?? '').trim();
  const copy = provider ? `the copy in ${provider}` : 'the off-site copy';
  const nextStep = `Leave this PC on and signed in overnight${provider ? `, with ${provider} running` : ''}. If it still isn’t checked after that, choose Save problem report in Settings.`;
  return offsite.kind === 'InProgress'
    ? { title: 'Check didn’t finish', detail: `A check of ${copy} started more than two days ago and never finished, so Rewindle can’t confirm the copy has your latest backups.`, nextStep }
    : { title: 'Not checked lately', detail: `Rewindle checks ${copy} every night, but no check has worked in more than two days, so it can’t confirm the copy has your latest backups.`, nextStep };
}
