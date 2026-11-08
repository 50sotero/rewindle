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
    // Google Drive for desktop's drive is not unplugged: it answers "not ready" when the app is not running or not signed in.
    if (repository.space?.kind === 'googleDrive') return { tone: 'danger', text: 'Google Drive for desktop isn’t running, so the next backup can’t run. Start it and sign in.' };
    const drive = driveOf(repository.path);
    return { tone: 'danger', text: `The backup drive${drive ? ` (${drive})` : ''} isn’t connected, so the next backup can’t run. Plug it back in.` };
  }
  // Too little space for the next backup comes right after the drive itself; space that is running low comes last.
  const space = spaceConcern(repository);
  if (space?.tone === 'danger') return space;
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
  return alertConcern(state) ?? space;
}

// Missed-run explanations the page already says elsewhere: the hero's own overdue words ('unknown'), its failed run with its button
// ('ranAndFailed'), the drive concern above ('driveMissing') and the repair banner ('repairPending').
const SAID_ELSEWHERE: ReadonlySet<string> = new Set(['unknown', 'ranAndFailed', 'driveMissing', 'repairPending']);

/**
 * What the backup alerts add under the hero: how many backups in a row didn't finish while that count has turned the mark red, or
 * why the overdue backup didn't happen, with its next step when that is not the hero's own Back up now (the host leaves it empty
 * then). Paused and the clock are said by the host's own title. Times are 24-hour; the page puts them in the viewer's clock.
 */
export function alertConcern(state: DashboardState): HeroConcern | null {
  const alerts = state.alerts;
  if (!alerts) return null;
  if (alerts.level === 'failing' && alerts.failedRuns > 0) {
    const count = `The last ${alerts.failedRuns} backups didn’t finish.`;
    return { tone: 'danger', text: heroOffersRunDetails(state)
      ? `${count} Choose See what happened to find out why, then Back up now to try again.`
      : `${count} Open Activity and choose the latest failed backup to see why, then choose Back up now to try again.` };
  }
  const missed = alerts.missedRun;
  if (!missed || state.freshness.state !== 'Overdue' || SAID_ELSEWHERE.has(missed.kind)) return null;
  return { tone: missed.tone === 'danger' ? 'danger' : 'warning', text: missed.nextStep ? `${missed.text} ${missed.nextStep}` : missed.text };
}

/** When Windows last started the backup, for a quiet line on the schedule card; null when that is unknown or it never ran. */
export const lastStartedAt = (state: Pick<DashboardState, 'alerts'>): string | null => state.alerts?.lastRun?.at || null;

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

/**
 * Whether the time of the last verified backup can be shown: not when the backup status could not be read (the page lost the host's
 * answer, or the host could read no status file) or the clocks disagree. Then "No verified backup yet" would be a guess, said under
 * a title that already says the status is unavailable.
 */
export const verifiedTimeKnown = (state: Pick<DashboardState, 'dataError' | 'status' | 'freshness'>): boolean =>
  !state.dataError && !state.status.unavailable && state.freshness.state !== 'ClockAnomaly';

/** Whether the run history the host sent has this run. A failed run that never reached the history has no details to open. */
export const runInHistory = (state: Pick<DashboardState, 'history'>, runId: string | undefined): boolean =>
  !!runId && state.history.some(run => run.id === runId);

/** Whether the Protection hero offers "See what happened": the latest run failed, it is in the history, and run details exist at all. */
export function heroOffersRunDetails(state: Pick<DashboardState, 'status' | 'history' | 'actions'>): boolean {
  const s = state.status, action = state.actions.viewRunDetails;
  return !!s.failure && !s.active && !!action && action.visible !== false && runInHistory(state, s.runId);
}

/**
 * Whether a run's details can be opened from a button outside Activity's table. The host turns its own Open details on only once a
 * run is selected in its table, and nothing selects one when Rewindle starts; but it takes the run's id and selects that run itself.
 * So the page goes by the link to the host and by the run being in the history, as Activity's Open details does.
 */
export const canOpenRunDetails = (state: Pick<DashboardState, 'history' | 'actions'>, runId: string | undefined, connected: boolean): boolean =>
  connected && !!state.actions.viewRunDetails && state.actions.viewRunDetails.visible !== false && runInHistory(state, runId);

// ---- Backup drive space ---------------------------------------------------------------------------------------------------------------
// How full the backup location is, worded for the Backup location card (Protection and Settings) and the Protection hero. The host decides
// the level (BackupSpace.cs); these only word it. Every sentence that asks the person to free space also says never to delete anything
// inside the backup folder: on a full drive (and in Google storage, whose own page lists the backup folder first) that is the one thing
// that would lose backups. The words never say repository, snapshot, engine or volume.

export type SpaceTone = 'muted' | 'warning' | 'danger';
/**
 * The card's lines. `usage`: used and free space (muted, never announced: it moves every minute). `status`: the forecast (muted) or the
 * problem (amber or red, with `nextStep`). `how`: how the forecast is worked out, only when there is one. Empty strings are not shown.
 */
export type SpaceView = { usage: string; status: string; tone: SpaceTone; nextStep: string; how: string };
type SpaceRepository = Pick<DashboardState['repository'], 'path' | 'volume' | 'volumeReady' | 'space'>;

/** "about 3 weeks", "about 13 months"... for weeks until the drive is full. `rounded` is the host's whole number of weeks, which the level was judged on. */
export function forecastWords(weeks: number, rounded?: number | null): string {
  if (!Number.isFinite(weeks) || weeks < 0) return '';
  if (weeks < 1) {
    const days = Math.max(1, Math.round(weeks * 7));
    return days === 1 ? 'about 1 day' : `about ${days} days`;
  }
  if (weeks < 26) {
    const whole = Math.max(1, rounded ?? Math.round(weeks));
    return whole === 1 ? 'about 1 week' : `about ${whole} weeks`;
  }
  if (weeks < 78) return `about ${Math.round(weeks * 7 / 30.44)} months`;
  if (weeks < 104) return 'about 2 years';
  return 'more than 2 years';
}

const NEVER_INSIDE = '(never anything inside the backup folder)';
const ONCE_THERES_ROOM = 'Once there’s room, the next scheduled backup runs, or choose Back up now.';

function freeUpStep(google: boolean, onDrive: string): string {
  return google
    ? `Free up Google storage by removing other files ${NEVER_INSIDE}, get more storage from Google, or choose Change location to move your backups to a drive.`
    : `Free up space on ${onDrive} by removing other files ${NEVER_INSIDE}, or choose Change location to move your backups to a bigger drive.`;
}

/** Every line the Backup location card shows about space. Without `space` (an older host) it is today's volume text. */
export function describeSpace(repository: SpaceRepository): SpaceView {
  const quiet: SpaceView = { usage: '', status: '', tone: 'muted', nextStep: '', how: '' };
  const space = repository.space;
  if (!space) return { ...quiet, usage: repository.volume };
  const google = space.kind === 'googleDrive';
  const onDrive = space.drive || 'the backup drive';
  if (repository.volumeReady === false) {
    return google
      ? { ...quiet, status: 'Google Drive for desktop isn’t running.', tone: 'danger', nextStep: 'Start Google Drive for desktop and sign in.' }
      : { ...quiet, status: `The backup drive${space.drive ? ` (${space.drive})` : ''} isn’t connected.`, tone: 'danger', nextStep: 'Plug it back in.' };
  }
  if (space.reading === 'checking') return { ...quiet, status: google ? 'Checking your Google storage…' : 'Checking the backup drive…' };
  if (space.reading !== 'ready') {
    return { ...quiet, status: google
      ? 'Rewindle can’t read your Google storage right now. It tries again in a minute.'
      : 'Rewindle can’t read the free space on the backup drive right now. It tries again in a minute.' };
  }
  const free = `${space.freeDisplay} free of ${space.totalDisplay}`;
  const backups = space.backupsBytes >= 0 && space.backupsDisplay ? `Backups use ${space.backupsEstimated ? 'about ' : ''}${space.backupsDisplay} • ` : '';
  const usage = `${backups}${google ? 'Google storage: ' : ''}${free}`;
  const reserve = space.reserveBytes > 0 && space.reserveDisplay ? space.reserveDisplay : '';
  const forecast = space.forecast;
  const weeks = forecast.weeksLeft;
  const when = weeks == null ? '' : forecastWords(weeks, forecast.weeksRounded);

  if (space.level === 'full') {
    const status = google
      ? reserve ? `Your Google storage is too full to back up. Rewindle needs at least ${reserve} of it free, and ${space.freeDisplay} is free.` : 'Your Google storage is full, so backups can’t run.'
      : reserve ? `The backup drive is too full to back up. Rewindle needs at least ${reserve} free on ${onDrive}, and ${space.freeDisplay} is free.` : 'The backup drive is full, so backups can’t run.';
    return { ...quiet, usage, status, tone: 'danger', nextStep: `${freeUpStep(google, onDrive)} ${ONCE_THERES_ROOM}` };
  }
  if (space.level === 'low') {
    const status = space.reason === 'forecast' && when
      ? `Space is running low: ${google ? 'your Google storage' : 'the backup drive'} will be full in ${when} at this rate.`
      : `Space is running low: only ${space.freeDisplay} is free ${google ? 'in your Google storage' : `on ${onDrive}`}${reserve ? `, and backups stop below ${reserve}` : ''}.`;
    return { ...quiet, usage, status, tone: 'warning', nextStep: freeUpStep(google, onDrive), how: spaceHow(space) };
  }
  if (space.level !== 'ok') return { ...quiet, usage };
  const fills = google ? 'your Google storage will be full' : 'the drive will be full';
  let status = '';
  switch (forecast.state) {
    case 'growing':
      if (weeks == null) break;
      status = weeks >= 104
        ? `Enough ${google ? 'Google storage' : 'space'} for more than 2 years at this rate.`
        : google ? `Your Google storage will be full in ${when} at this rate.` : `Full in ${when} at this rate.`;
      break;
    case 'flat': status = `Your backups haven’t grown lately, so they aren’t filling ${google ? 'your Google storage' : 'the drive'}.`; break;
    case 'learning': status = forecast.cleanUp === 'unmeasured'
      ? `Old backups were removed lately, so Rewindle needs up to 8 more weeks of backups to tell when ${fills}.`
      : `After a few more backups, Rewindle can tell when ${fills}.`; break;
    case 'unavailable': status = `With this backup program, Rewindle can’t forecast when ${fills}.`; break;
  }
  return { ...quiet, usage, status, how: spaceHow(space) };
}

/** "How this is worked out", only for a forecast that was worked out (growing or flat). */
function spaceHow(space: NonNullable<SpaceRepository['space']>): string {
  const state = space.forecast.state;
  if (state !== 'growing' && state !== 'flat') return '';
  const google = space.kind === 'googleDrive';
  const reserve = space.reserveBytes > 0 && space.reserveDisplay ? space.reserveDisplay : '';
  // With clean-up of old backups in those weeks, the rate is net: what the backups added less the space that removing old ones freed.
  const counted = space.forecast.cleanUp === 'counted';
  const lately = state === 'growing' && space.forecast.weeklyDisplay ? `Lately that is about ${space.forecast.weeklyDisplay} a week.`
    : counted ? 'Lately removing old backups has freed as much space as they added, or more.' : 'Lately they have added almost nothing.';
  const others = google
    ? 'Google storage is shared with Gmail and Google Photos, so they can fill it sooner.'
    : 'It counts only your backups, so other files on the drive can fill it sooner.';
  const full = !reserve ? ''
    : google ? ` “Full” means less than ${reserve} of it free: below that Rewindle stops backing up.`
    : ` “Full” means less than ${reserve} free: below that Rewindle stops backing up, so Windows and your other programs keep some room.`;
  const cleanedUp = counted ? ' takes away the space that removing old backups freed,' : '';
  return `Rewindle looks at what each backup added over the last 8 weeks, leaves out the single biggest one (such as a folder added once),${cleanedUp} and assumes backups keep running as often as they have. ${lately} ${others}${full}`;
}

/**
 * The Protection hero's sentence about space, or null. Too full for the next backup is red (unless the latest run already failed for that
 * reason, which the hero's own detail says); full within the Low space warning is amber. Little room with no forecast stays on the card.
 */
export function spaceConcern(repository: SpaceRepository): HeroConcern | null {
  const space = repository.space;
  if (!space || repository.volumeReady === false || space.reading !== 'ready') return null;
  const google = space.kind === 'googleDrive';
  if (space.level === 'full') {
    if (space.runStoppedForSpace) return null;
    return { tone: 'danger', text: google
      ? `Your Google storage is too full for the next backup. Free some up by removing other files ${NEVER_INSIDE}, or get more storage from Google (see Backup location below).`
      : `The backup drive is too full for the next backup. Free up space on ${space.drive || 'it'} by removing other files ${NEVER_INSIDE}, or move your backups to a bigger drive (see Backup location below).` };
  }
  const weeks = space.forecast.weeksLeft;
  if (space.level === 'low' && space.reason === 'forecast' && weeks != null) {
    const when = forecastWords(weeks, space.forecast.weeksRounded);
    return { tone: 'warning', text: `${google ? 'Your Google storage' : 'The backup drive'} will be full in ${when} at this rate. See Backup location below for what to do.` };
  }
  return null;
}
