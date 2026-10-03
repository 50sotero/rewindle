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
  | 'openLicensesFolder';
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
  snapshotId: string;
  title?: string;
  message?: string;
  retryable?: boolean;
  /** Names the recovery action when it is not a plain retry (for example 'Reload Restore'). */
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
   * The backup engine this window reports on: its name ("Rewindle engine" or "Legacy personal edition"), its profile id, the version its
   * install states (empty while it is not installed), whether --engine or the install roots chose it, and every configuration path an
   * engine was looked for at. Additive: an older host does not send them.
   */
  engine?: string;
  engineProfile?: 'rewindle' | 'legacy';
  engineVersion?: string;
  engineChosenBy?: 'install-root' | '--engine';
  searchedConfigs?: string[];
}
export interface DashboardState {
  page: DashboardPage; demo: boolean; preview: boolean; theme: ThemePreference; motion: MotionPreference;
  dark: boolean; reducedMotion: boolean; highContrast: boolean; updated: string; subtitle: string; dataError?: string;
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
  schedule: { summary: string; nextRun: string; detail: string; error?: string; notice?: { text: string; tone: 'info' | 'success' | 'warning' | 'error' } | null };
  /** `volumeReady` is false only when the drive itself answered that it is not ready (unplugged, disconnected); true or absent means no such answer. */
  repository: { path: string; volume: string; volumeReady?: boolean };
  freshness: { title: string; detail: string; state: 'Unavailable' | 'Healthy' | 'NoVerifiedBackup' | 'Overdue' | 'Paused' | 'ClockAnomaly'; verifiedAt: string };
  offsite: {
    title: string; detail: string; evidence: string; kind: 'NotConfigured' | 'StatusUnavailable' | 'Failed' | 'InProgress' | 'LocalVerifiedProviderPending' | 'ProviderConfirmed' | 'RestoreVerified'; checkedAt: string; providerConfirmed: boolean; restoreVerified: boolean;
    /** The provider the off-site evidence comes from ("Google Drive"), only when the host's evidence names one. Absent or empty otherwise. */
    provider?: string;
  };
  recovery: { title: string; detail: string; repairNeeded: boolean; repairMessage: string; repairState: string; repairBusy: boolean; repairPercent: number | null };
  actions: Partial<Record<CommandName, ActionState>>;
  runDetails?: RunDetailsState | null;
  restoreFlow?: RestoreFlowState | null;
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