export type DashboardPage = 'Protection' | 'Activity' | 'Restore' | 'Settings';
export type ThemePreference = 'System' | 'Midnight' | 'Daylight';
export type MotionPreference = 'System' | 'Full' | 'Reduced';
export type CommandName = 'ready' | 'refresh' | 'navigate' | 'setTheme' | 'togglePreview'
  | 'setMotion' | 'setZoom'
  | 'backupNow' | 'cancelBackup' | 'addSource' | 'removeSource' | 'editSchedule'
  | 'changeRepository' | 'repairRepository' | 'reviewChanges' | 'openRestore'
  | 'checkReadiness' | 'selectRun' | 'viewRunDetails' | 'exportDiagnostics'
  | 'retrySourceChange' | 'dismissSourceChange' | 'closeRunDetails'
  | 'copyRunSummary' | 'copyRunEvents' | 'copyRunSnapshot' | 'openRunLogLocation'
  | 'browseSourcePicker' | 'validateSourcePath' | 'confirmSourcePicker' | 'closeSourcePicker'
  | 'restoreFlowBrowseSnapshots' | 'restoreFlowBrowseFiles' | 'restoreFlowBrowseDestination'
  | 'restoreFlowValidateDestination' | 'restoreFlowSelectPaths' | 'restoreFlowReview' | 'restoreFlowStart'
  | 'restoreFlowCancel' | 'restoreFlowRetry' | 'restoreFlowClose' | 'restoreFlowNavigate'
  | 'restoreFlowOpenDestination' | 'restoreFlowCopyDestination'
  // Settings > About: opens the licenses folder beside the app. The host builds the path itself; the page sends none.
  | 'openLicensesFolder'
  // Settings > Old backups (clean-up of old backups). Only the dialogs' own buttons send retentionConfigure and retentionApply.
  | 'retentionConfigure' | 'retentionCheckNow' | 'retentionOpenReview' | 'retentionReviewPage' | 'retentionApply'
  | 'retentionCloseReview'
  // Settings > Backup alerts: notifications on or off ({ notify: 'on' | 'off' }). A per-user preference like the theme, not protected.
  | 'setAlerts'
  // Settings > Backup location > Low space warning: { weeks: '4' | '8' | '12' }. Only changes when the page warns, so it is not protected.
  | 'setSpaceWarning';
/**
 * The commands that change the backup plan, the schedule, the repository or a restore, or ask the host to read them.
 * They need a live link and readable backup status, and the animation preview pauses them. Everything else (moving
 * between pages, theme and motion, picking a run, copying run details, closing a dialog, exporting diagnostics, opening or
 * copying the folder a finished restore reported) only touches what the page shows or what is already on disk, so it keeps
 * working when the link looks stale.
 * The host still checks every one of them again.
 */
export const PROTECTED_COMMANDS: ReadonlySet<CommandName> = new Set<CommandName>([
  'backupNow', 'cancelBackup', 'addSource', 'removeSource', 'editSchedule', 'changeRepository', 'repairRepository',
  'reviewChanges', 'openRestore', 'checkReadiness', 'retrySourceChange',
  'browseSourcePicker', 'validateSourcePath', 'confirmSourcePicker',
  'restoreFlowBrowseSnapshots', 'restoreFlowBrowseFiles', 'restoreFlowBrowseDestination', 'restoreFlowValidateDestination',
  'restoreFlowSelectPaths', 'restoreFlowReview', 'restoreFlowStart', 'restoreFlowCancel', 'restoreFlowRetry', 'restoreFlowNavigate',
  'retentionConfigure', 'retentionCheckNow', 'retentionOpenReview', 'retentionApply',
]);
/** Why protected controls are on or off: the link works and the status reads (`ok`), or one of the reasons it does not. */
export type Availability = 'ok' | 'offline' | 'dataError' | 'preview';
/**
 * A short message about what a command did, or why it did not work: the host's answer, or the page's own refusal. `id` is new for
 * each one, so the same words said twice (a second "Run summary copied.") are still a new notice that is drawn and announced again.
 * It lasts a few seconds, longer for a longer text, and waits while it is hovered or focused; an error stays until it is dismissed.
 */
export interface Notice { id: number; text: string; error: boolean }
export interface ActionState { enabled: boolean; visible: boolean; label: string; help: string }
export interface SourceState { path: string; name: string; isCanary: boolean; exists: boolean; canRemove: boolean; detail: string }
export interface SourcePickerState {
  open: boolean; path: string; name: string;
  status: 'idle' | 'checking' | 'ready' | 'duplicate' | 'covered' | 'invalid' | 'busy' | 'succeeded' | 'cancelled' | 'failed';
  message: string;
  suggestions: { name: string; path: string; protected: boolean }[];
}
export type RestoreFlowStep = 'backup' | 'files' | 'destination' | 'review' | 'progress' | 'success' | 'partial' | 'error';
export interface RestoreSnapshot {
  id: string;
  shortId: string;
  when: string;
  whenDisplay: string;
  hostname: string;
  configGeneration: string;
  fileCount: number;
  fileCountDisplay: string;
  byteCount: number;
  sizeDisplay: string;
  sourceSummary: string;
  bindingState: string;
  isLegacyUnbound: boolean;
}
export interface RestoreEntry {
  name: string;
  path: string;
  type: 'file' | 'dir' | string;
  size: number;
  sizeDisplay: string;
}
export interface RestoreValidation {
  ready: boolean;
  errors: string[];
  warnings: string[];
  /** The one warning in `warnings` that is about free space (a whole snapshot is larger than the room left on the destination drive), or empty. Only a warning: it never stops a restore. */
  spaceWarning?: string;
  scopeLabel: string;
}
export interface RestoreProgress {
  stage: string;
  message: string;
  percent: number;
  /** True until Windows has approved the protected step, so the page can say it is waiting for the prompt. */
  awaitingApproval?: boolean;
}
export interface RestoreResult {
  status: 'success' | 'partial' | 'error' | 'cancelled' | null;
  target: string;
  verified: boolean;
  error: string | null;
  /** An incomplete restore that brought back none of the chosen items, so the page does not say some files were copied. */
  nothingRestored?: boolean;
  snapshotId: string;
  title?: string;
  message?: string;
  retryable?: boolean;
  /** Names the recovery action when it is not a plain retry (for example 'Start again'). */
  retryLabel?: string;
}
export interface RestoreFlowState {
  open: boolean;
  busy: boolean;
  step: RestoreFlowStep;
  status: 'idle' | 'loading' | 'ready' | 'running' | 'canceling' | 'succeeded' | 'partial' | 'failed';
  canCancel: boolean;
  /** Why a restore cannot start right now (a backup or another protected change is running), or empty. Only a hint: the host checks again when Restore now is pressed. */
  startBlocked?: string;
  message: { title: string; detail: string };
  snapshots: RestoreSnapshot[];
  selectedSnapshotId: string;
  /** What the host will accept, so the page stops offering more before the host would refuse it. The host stays the authority. */
  limits?: { maxPaths: number };
  /**
   * `entries` is the folder's listing, and only while the step is "files". A large folder is cut short: `total` is how many
   * entries it holds and `truncated` says `entries` is not all of them (folders come first, so every subfolder can still be opened).
   * `error` is set when a folder could not be read; the previous listing stays and `errorPath` is the folder to retry.
   */
  tree: { path: string; entries: RestoreEntry[]; total?: number; truncated?: boolean; loading: boolean; error?: string; errorPath?: string; loaded?: boolean };
  selectedPaths: string[];
  wholeSnapshotSelected: boolean;
  /**
   * `status` is a sentence for the person, not a code: a verdict is read from `valid`, `checking` and `error`. `freeDisplay` and `drive`
   * ("41.2 GiB", "E:") say how much room the checked destination's drive had when it was checked; both are empty when that was not read.
   */
  destination: { path: string; valid: boolean; checking: boolean; status: string; error: string; freeDisplay?: string; drive?: string };
  validation: RestoreValidation;
  progress: RestoreProgress;
  result: RestoreResult;
  approval?: RestoreFlowApproval;
}
export interface RunState {
  id: string; started: string; startedDisplay: string; type: string; result: string;
  success: boolean; durationSeconds: number; durationDisplay: string; files: number;
  filesDisplay: string; processedBytes: number; processedDisplay: string;
  storedBytes: number; storedDisplay: string; snapshot: string;
  /**
   * What the backup found compared with the previous backup of the same folders, in the host's words ("312 new, 41 changed,
   * 12,040 unchanged"). Absent for a check-only run, a run that stopped before it read the files, a run recorded before this
   * version, and from an older host: never a zero that stands for "not known".
   */
  changesDisplay?: string;
}
export interface RunDetailsState {
  id: string;
  type: string;
  result: string;
  success: boolean;
  /** The run's start as an ISO 8601 timestamp, so the page can format it the way it formats every other run time. */
  started?: string;
  startedDisplay: string;
  durationDisplay: string;
  filesDisplay: string;
  processedDisplay: string;
  storedDisplay: string;
  /** The run's new, changed and unchanged files ("312 new, 41 changed, 12,040 unchanged"), or empty or absent when not known. */
  changesDisplay?: string;
  phase: string;
  failureCode: string;
  exitCode: string;
  snapshotId: string;
  failure: string;
  remediation: string;
  affectedPaths: string[];
  events: string[];
  /** True when the log was longer than the part that is read, so the oldest events are not listed. */
  eventsTruncated?: boolean;
  /** Set when part of the log could not be read; the rest of the details are still shown. */
  logNote?: string;
  hasLog: boolean;
}
/**
 * How many backups the backup location holds and when the oldest was made (ISO 8601), as one source counted them: `backup`, the
 * backup service during the last verified backup, or `restore`, the Restore list when it was last read (`countedAt`). Only shown,
 * never acted on.
 */
export interface BackupRangeState { count: number; oldestAt: string; countedAt: string; source: 'backup' | 'restore' }
/**
 * Whether the backup service this dashboard reports on is installed, and enough about this computer for a bug report. Additive: a host that
 * does not send it (and the sample data) is taken to have found its service. Nothing here changes what any action may do.
 */
export interface SetupState {
  /** False only once the host is sure the backup service is not installed on this computer. The page then explains that once, instead of an "unavailable" in every widget. */
  engineFound: boolean;
  /** Why the installed configuration is not in use right now, as one sentence, or empty while it is in use. */
  problem: string;
  /** Where the host looks for the installed configuration, and the folder it reads backup status from. */
  expectedConfig: string;
  stateFolder: string;
  /** For a bug report: this app's version, Windows' version and the WebView2 Runtime's (any of them can be empty). */
  appVersion: string;
  os: string;
  webView2: string;
  /**
   * The backup engine this window reports on: its name ("Rewindle backup service" or "Rewindle backup service (earlier personal edition)"), its profile id, the version its
   * install states (empty while it is not installed), whether --engine or the install roots chose it, and every configuration path an
   * engine was looked for at. Additive: an older host does not send them.
   */
  engine?: string;
  engineProfile?: 'rewindle' | 'legacy';
  engineVersion?: string;
  engineChosenBy?: 'install-root' | '--engine';
  searchedConfigs?: string[];
}
/**
 * How full the backup location is and when it fills (Protection and Settings > Backup location). The host decides `level`; the page only
 * words it (protectionTone.ts describeSpace). Every byte count is -1, and its display '', when unknown. Additive: an older host does not
 * send it, and the card then shows `volume` as before.
 */
export interface BackupSpaceState {
  /** 'drive': a drive on or plugged into this computer. 'googleDrive': Google Drive for desktop, so the figures are the Google account's storage. */
  kind: 'drive' | 'googleDrive';
  /** 'checking' until the first reading; 'unknown' when Windows would not say. A drive that said it is not ready is `volumeReady: false`. */
  reading: 'checking' | 'ready' | 'unknown';
  /** "D:", or '' when the path names no drive letter. */
  drive: string;
  freeBytes: number; freeDisplay: string;
  totalBytes: number; totalDisplay: string;
  /** What the backups take after the latest verified backup; -1 when nothing recorded it (the earlier personal edition on a drive, or no backup yet). */
  backupsBytes: number; backupsDisplay: string;
  /** True when worked out from Google Drive's count before that backup plus what it added, rather than measured after it. */
  backupsEstimated: boolean;
  /** The free space the backup service keeps; below it, a backup is refused. */
  reserveBytes: number; reserveDisplay: string;
  forecast: {
    /** 'unavailable': the backup service in use (the earlier personal edition) records no size, so there is no forecast with it. */
    state: 'unknown' | 'learning' | 'flat' | 'growing' | 'unavailable';
    /** Weeks until free space reaches the reserve at the recent rate, rounded to 2 decimals; null unless growing and the free space is known. */
    weeksLeft: number | null;
    /** `weeksLeft` in whole weeks: the number the words use and the host judged `level` on, so the page never rounds it again. */
    weeksRounded: number | null;
    weeklyBytes: number; weeklyDisplay: string;
  };
  level: 'unknown' | 'ok' | 'low' | 'full';
  /** 'percent': little room now (under 1.5 times the reserve, or, while the forecast is learning or unknown, under a tenth of the drive above it). */
  reason: '' | 'forecast' | 'percent' | 'reserve';
  /** The person's Low space warning, in weeks: 4, 8 or 12. */
  warnWeeks: number;
  /** The latest run failed because there was too little space, so the Protection hero already says so. */
  runStoppedForSpace?: boolean;
}
export interface DashboardState {
  page: DashboardPage; demo: boolean; preview: boolean; theme: ThemePreference; motion: MotionPreference;
  dark: boolean; reducedMotion: boolean; highContrast: boolean; updated: string; subtitle: string; dataError?: string;
  /** When the figures on screen were read, as an ISO 8601 timestamp, so the page writes the time of day the way the viewer's region does. Empty while the host is retrying (then `updated` says so in words); absent from an older host. */
  updatedAt?: string;
  /** The host's regional format (for example "en-GB"), so figures and dates the page formats itself read like the host's. */
  locale?: string;
  setup?: SetupState;
  status: {
    key: string; title: string; detail: string; badge: string; active: boolean;
    success: boolean; failure: boolean; cancelled: boolean;
    /** True when the host could read no backup status (the state folder is missing or refuses access, or status.json cannot be used right now). Neither a failed run nor a healthy one. */
    unavailable?: boolean;
    phaseIndex: number;
    phaseLabel: string; progress: number; estimated: boolean; runId: string;
    files: string; bytes: string; speed: string; elapsed: string; errors: string;
    etaTitle: string; eta: string; etaHint: string;
    /** Why a backup that was asked for has not started (Windows accepted the request and the task did not run), or empty. Gone once a run appears. */
    backupNote?: string;
  };
  sources: SourceState[]; sourceStatus: string;
  /** A short-lived outcome of a folder change ("Folder removed…", "Windows approval was cancelled…"); null once it expires. */
  sourceNotice?: { text: string; tone: 'info' | 'success' | 'warning' | 'error' } | null;
  sourcePicker?: SourcePickerState | null;
  sourceOperation: { active: boolean; stage: string; message: string; path: string };
  history: RunState[]; historyTruncated?: boolean;
  /** How many runs the host keeps (its own limit, sent so the page names it instead of copying the number). Absent from a host that does not say. */
  historyLimit?: number;
  selectedRunId: string | null;
  /** `error` is why the installed schedule could not be read (empty when it could); `summary` then reads "Schedule unavailable". `notice` is the short-lived outcome of a schedule change; null once it expires. */
  schedule: { summary: string; nextRun: string; /** The next run as an ISO 8601 timestamp, or empty/absent when there is none; the page formats it like every other time. */ nextRunAt?: string; detail: string; /** Set while Windows keeps the run at a fixed UTC time, so it moves an hour when the clocks change; says how to keep it fixed. Additive. */ clockChange?: string; error?: string; notice?: { text: string; tone: 'info' | 'success' | 'warning' | 'error' } | null };
  /** `volumeReady` is false only when the drive itself answered that it is not ready (unplugged, disconnected); true or absent means no such answer. */
  repository: { path: string; volume: string; volumeReady?: boolean; space?: BackupSpaceState | null };
  /** How far back the backups in the backup location go, or null when that is not known for the plan and location in use. Additive: an older host sends nothing. */
  backupRange?: BackupRangeState | null;
  /** `CatchingUp`: a backup was missed while the PC was off, asleep or signed out, and Windows starts it by itself shortly (not a problem; an older host never sends it). */
  freshness: { title: string; detail: string; state: 'Unavailable' | 'Healthy' | 'NoVerifiedBackup' | 'Overdue' | 'Paused' | 'ClockAnomaly' | 'CatchingUp'; verifiedAt: string };
  /** Backup alerts (the Settings switch, the tray mark, what Windows last did with the backup). Additive: an older host does not send it. */
  alerts?: AlertsState;
  offsite: {
    title: string; detail: string; evidence: string; kind: 'NotConfigured' | 'StatusUnavailable' | 'Stale' | 'Failed' | 'InProgress' | 'LocalVerifiedProviderPending' | 'ProviderConfirmed' | 'RestoreVerified'; checkedAt: string; providerConfirmed: boolean; restoreVerified: boolean;
    /** The provider the off-site evidence comes from ("Google Drive"), only when the host's evidence names one. Absent or empty otherwise. */
    provider?: string;
    /** True when a check that is waiting (`Stale`) or running (`InProgress`) is overdue: none has worked for about two days. Additive. */
    checkOverdue?: boolean;
  };
  /**
   * `next` says what the Restore page offers when restoring is not available: 'refresh' (read the installation again), 'setup' (run
   * Rewindle Setup again; the detail says how), 'wait' (a backup or a change is running and it unlocks by itself), or empty when
   * there is nothing to do or the repair banner has the action. Additive: an older host does not send it.
   * `moveRunning` is true while a move of the backup location is still running: backups and changes wait for it, but nothing was
   * interrupted, so `repairNeeded` is false and nothing alarms. Additive: an older host does not send it.
   */
  recovery: { title: string; detail: string; repairNeeded: boolean; repairMessage: string; repairState: string; repairBusy: boolean; repairPercent: number | null; next?: 'refresh' | 'setup' | 'wait' | ''; moveRunning?: boolean };
  actions: Partial<Record<CommandName, ActionState>>;
  runDetails?: RunDetailsState | null;
  restoreFlow?: RestoreFlowState | null;
  /** Clean-up of old backups (Settings > Old backups). Additive: an older host and the sample bridge may not send it; the card is then not drawn. */
  retention?: RetentionState | null;
}
/** Why a scheduled backup did not happen, as the host's MissedRunExplainer names it; `unknown` when nothing more is known. */
export type MissedRunKind = 'unknown' | 'driveMissing' | 'repairPending' | 'ranAndFailed' | 'cancelled' | 'busy' | 'programProblem'
  | 'couldNotStart' | 'waitingForPower' | 'noCatchUp' | 'pcOff';
export interface MissedRunState {
  kind: MissedRunKind;
  /** The moment the sentence is about (the slot, or when Windows or the backup started), ISO 8601 UTC, or empty. */
  at: string;
  /** The host's sentence, with 24-hour times for localClocks ("The PC was off, asleep or signed out today at 02:00, …"). */
  text: string;
  /** What to do when it is not the hero's own Back up now ("Plug the PC in, …"), or empty. */
  nextStep: string;
  /** "code 66" or "error 0x800710E0" when Windows recorded one, or empty. */
  code: string;
  tone: 'warning' | 'danger';
}
/** Backup alerts: whether Rewindle shows Windows notifications for them, what the tray mark shows, and why a scheduled backup was missed. */
export interface AlertsState {
  /** Whether alerts are told with a Windows notification (Settings > Backup alerts). The tray mark shows either way. */
  notify: boolean;
  level: 'none' | 'attention' | 'failing';
  reason: '' | 'overdue' | 'paused' | 'failing' | 'clock' | 'schedule';
  /** Failed backups in a row since the last verified one, as far as the run history shows (0 when none). */
  failedRuns: number;
  /** How many failed backups in a row turn the mark red (the host's own number). */
  failingAfter: number;
  /** When Windows last started the backup task (ISO UTC) and what it recorded; null when that can't be read, it never ran, or Windows waited for a sign-in. */
  lastRun: { at: string; ok: boolean; code: string } | null;
  /** Set while the backup is overdue; null otherwise. */
  missedRun: MissedRunState | null;
}
export interface NativeCommand { type: 'command'; id: string; command: CommandName; payload?: Record<string, string | boolean> }
/** `heartbeat` carries no state: it says the app is alive when there is nothing new to show (an unchanged state, or a hidden window). */
export type NativeMessage = { type: 'state'; state: DashboardState } | { type: 'result'; id: string; ok: boolean; message?: string } | { type: 'heartbeat' };
export interface NativeWebView {
  postMessage(message: NativeCommand): void;
  addEventListener(type: 'message', listener: (event: MessageEvent<NativeMessage>) => void): void;
  removeEventListener(type: 'message', listener: (event: MessageEvent<NativeMessage>) => void): void;
}
declare global { interface Window { chrome?: { webview?: NativeWebView }; rewindleNative?: NativeWebView } }

/** The host's `locale` as one this browser can format with; anything it cannot use gives undefined, so formatting falls back to the page's own. */
export function usableLocale(value?: string): string | undefined {
  if (!value) return undefined;
  try { return Intl.DateTimeFormat.supportedLocalesOf(value).length > 0 ? value : undefined; } catch { return undefined; }
}

// ---- Restore approval session (one Windows approval per restore) -------------------------------------------------------
/**
 * Whether Windows is showing its approval prompt for the restore flow right now (`waiting`), whether the flow has one restore
 * session that every step goes through (`session`; false: each protected step asks on its own), and the sentence that says
 * so. `tree.loaded` is false until a folder of the chosen backup was read: choosing a backup reads nothing, and its root is
 * read only when the person asks to browse it. Both are additive: an older host sends neither, and is taken to have read the
 * folder it shows.
 */
export interface RestoreFlowApproval { waiting: boolean; session: boolean; notice: string }
// ---- end of the restore approval session block -------------------------------------------------------------------------
// ---- Clean-up of old backups ------------------------------------------------------------------------------------------
/** Why clean-up has to wait, as the backup service reports it. The page words each one (retention.ts). */
export type RetentionBlocked = '' | 'google_drive_not_supported' | 'pending_change' | 'no_verified_backup' | 'last_backup_not_verified'
  | 'folders_changed' | 'change_review_open' | 'clock_problem' | 'future_dated_backup' | 'backup_location_unavailable' | 'policy_inactive';
export type RetentionOutcome = 'removed' | 'nothing_to_remove' | 'partial' | 'space_pending' | 'check_failed' | 'failed';
/** A hint only: the host checks again when the button is pressed. `help` is why it is off. */
export interface RetentionAbility { enabled: boolean; help: string }
export interface RetentionPreviewState {
  /** `stale`: the list was made before the latest backup. `none`: there is no list yet. */
  status: 'none' | 'ready' | 'blocked' | 'error' | 'stale';
  blocked: RetentionBlocked;
  errorCode: string;
  checkedAt: string;
  removeCount: number; keepCount: number;
  /** ISO 8601 times of the oldest and newest backup that would go. */
  oldestRemoveAt: string; newestRemoveAt: string;
  /** Earlier backups to look over before anything is removed, newest first (see RetentionEarlierChange). */
  earlierChanges: RetentionEarlierChange[];
  earlierChangesUnknown: boolean;
  futureDatedAt: string;
  /** Backups were removed earlier and their space is not freed yet. */
  prunePending: boolean;
}
/**
 * An earlier checked backup the person is asked to look over before old backups go, and why. `hold`: it changed far more files than
 * usual and nobody confirmed it. `not_compared`: it couldn't be compared with the backup before it (the first backup, or the first
 * after a folder, exclusion or location change). `unknown`: its record doesn't say (an older backup service). Only `hold` is worded as
 * unusual changes.
 */
export interface RetentionEarlierChange { at: string; kind: 'hold' | 'not_compared' | 'unknown' }
/**
 * The newest recorded clean-up. `unverified`: it stopped before anyone could confirm which backups on the list were removed, so
 * `removedCount` is only what is certain. `checkUnfinished`: the space was freed, then the check of the remaining backups didn't
 * finish (it found no problem).
 */
export interface RetentionLastRun {
  finishedAt: string; outcome: RetentionOutcome; removedCount: number; confirmedCount: number; freedDisplay: string;
  unverified: boolean; checkUnfinished: boolean;
}
export interface RetentionOperationState {
  active: boolean;
  action: '' | 'configure' | 'preview' | 'apply';
  stage: '' | 'approval' | 'listing' | 'checking' | 'freeing' | 'verifying';
  count: number;
  percent: number | null;
}
/** One backup in the list: when it was made, how many files it had, and (staying list only) why it stays. */
export interface RetentionReviewRow { key: string; when: string; files: number | null; reasons: string[] }
export type RetentionResultStatus = 'removed' | 'nothing_to_remove' | 'declined' | 'preview_changed' | 'refused' | 'partial'
  | 'space_pending' | 'check_failed' | 'failed' | 'unconfirmed';
/**
 * The list of old backups while it is open. Only counts, month totals and one page of rows are sent; the host keeps the whole list
 * and is the one that binds the removal to it. `changed`: the list on disk is no longer the one shown, so nothing can be removed
 * until it is shown again. `result` replaces the list once a removal was asked for. Its `reason` is the refusal code for
 * `refused`, and otherwise says more about how it ended: `unverified` (partial: nobody knows which backups on the list went),
 * `unrecorded` (space_pending: the removal couldn't be recorded), `unfinished` (check_failed: the check didn't finish) or `closed`
 * (preview_changed: the new list has nothing to offer, so the dialog ends there).
 */
export interface RetentionReviewState {
  removeCount: number; keepCount: number; newestKeptAt: string;
  earlierChanges: RetentionEarlierChange[]; earlierChangesUnknown: boolean; needsFilesConfirmed: boolean;
  pruneOnly: boolean; changed: boolean; running: boolean;
  /** Changes whenever a different list is shown, so ticked boxes are cleared. */
  captureKey: string;
  months: { month: string; count: number }[];
  page: { list: 'remove' | 'keep'; offset: number; total: number; size: number; rows: RetentionReviewRow[] };
  result: null | { status: RetentionResultStatus; removedCount: number; confirmedCount: number; freedDisplay: string; reason: string };
}
export interface RetentionState {
  mode: 'unsupported' | 'unknown' | 'off' | 'on';
  unsupportedReason: '' | 'legacy' | 'older_service' | 'google_drive';
  /** The counts in force, or the ones the dialog suggests. */
  keepDaily: number; keepWeekly: number; keepMonthly: number;
  limits: { daily: [number, number]; weekly: [number, number]; monthly: [number, number] };
  recommended: { daily: number; weekly: number; monthly: number };
  /** It was on, and an update or reinstall turned it off. */
  resetByReinstall: boolean;
  problem: string;
  preview: RetentionPreviewState | null;
  lastRun: RetentionLastRun | null;
  operation: RetentionOperationState;
  notice: { text: string; tone: 'info' | 'success' | 'warning' | 'error' } | null;
  canConfigure: RetentionAbility; canTurnOff: RetentionAbility; canReview: RetentionAbility; canCheckNow: RetentionAbility;
  review: RetentionReviewState | null;
}
