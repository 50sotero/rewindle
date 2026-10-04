// The wizard's half of the installer contract (docs/setup-contract.md, owned by the installer): the shapes of the plan file
// that `Install-ResticBackuper.ps1 -PlanOnly` writes, and of the progress lines `-ProgressPath` receives. Every read of those
// shapes is in this one module, so a change to the contract is a change here. The parsers are deliberately forgiving about
// what they do not need (an unknown field, a missing optional one) and strict about what they do (the schema names, the
// enumerations, the types): a plan the wizard cannot trust is reported as one, never half-shown.
//
// The desktop host checks the schema name and the size of what it forwards, and builds the installer's command line itself;
// see installer/setup/InstallerContract.cs, the host's half.

export const PLAN_SCHEMA = 'Rewindle.InstallPlan.v1';
export const PROGRESS_SCHEMA = 'Rewindle.InstallProgress.v1';

export type IssueField = 'repository' | 'sources' | 'schedule' | 'storage_mode' | 'environment';
export type StorageMode = 'local_ntfs' | 'google_drivefs_stream';
export type DriveType = 'fixed' | 'removable' | 'network' | 'cdrom' | 'ram' | 'unknown';
export type KnownFolderKey = 'Desktop' | 'Documents' | 'Pictures' | 'Music' | 'Videos' | 'Downloads' | 'Favorites';

/** One finding of the plan. `path` is the folder, file or task it is about (for a source folder, the folder itself); `detail` is for a log. */
export interface PlanIssue { code: string; field: IssueField; message: string; path: string | null; detail: string | null }

export interface PlanVolume {
  root: string;
  label: string;
  filesystem: string;
  driveType: DriveType;
  sizeBytes: number;
  freeBytes: number;
  isSystem: boolean;
  sameDiskAsSystem: boolean;
  eligible: boolean;
  /** A code (`not_ntfs`, `low_free_space`, `network_drive`, ...) when the drive cannot hold backups. */
  ineligibleReason: string | null;
  /** The installer's own plain sentence for it, when it sent one. */
  ineligibleMessage: string | null;
  recommended: boolean;
}

export interface KnownFolder { key: KnownFolderKey; path: string; exists: boolean; defaultSelected: boolean }

/** What an existing Rewindle installation reported about itself. Every field is optional: the contract only promises null or an object. */
export interface ExistingRewindle { version: string | null; installRoot: string | null }

export interface PlanEnvironment {
  version: string;
  os: { caption: string; build: string; x64: boolean; supported: boolean };
  powershell: string;
  dotnetFramework48: boolean;
  elevated: boolean;
  webview2: string | null;
  existingInstall: { rewindle: ExistingRewindle | null; legacyPersonalEdition: boolean };
  volumes: PlanVolume[];
  drivefs: { detected: boolean; myDriveRoot: string | null };
  knownFolders: KnownFolder[];
}

export interface InstallPlan {
  ok: boolean;
  errors: PlanIssue[];
  warnings: PlanIssue[];
  resolved: {
    repository: string | null;
    storageMode: StorageMode;
    driveFsMyDriveRoot: string | null;
    sources: string[];
    canarySource: string | null;
    schedule: string;
    vss: boolean;
    minimumFreeBytes: number;
    estimatedSourceBytes: number | null;
  };
  defaults: { repository: string | null; storageMode: StorageMode; sources: string[]; schedule: string };
  environment: PlanEnvironment;
}

/** What the wizard asks the installer to plan or install with. The host turns it into installer parameters. */
export interface PlanInputs {
  repository?: string;
  storageMode?: StorageMode;
  driveFsMyDriveRoot?: string;
  sources?: string[];
  schedule?: string;
  vss?: boolean;
}

export interface InstallChoices extends Required<Pick<PlanInputs, 'repository' | 'storageMode' | 'sources' | 'schedule' | 'vss'>> {
  driveFsMyDriveRoot?: string;
  startBackup: boolean;
}

export type PhaseState = 'started' | 'completed' | 'skipped' | 'failed';

export interface ProgressPhase {
  seq: number;
  time: string;
  phase: string;
  state: PhaseState;
  title: string;
  detail: string | null;
}

export interface InstallResult {
  ok: boolean;
  error: { code: string; message: string } | null;
  installRoot: string | null;
  recoveryKeyPath: string | null;
  /** True or false as the installer worked it out; null when there is no key or it could not tell. Only an explicit false stops a copy. */
  recoveryKeyReadableByUser: boolean | null;
  dashboardExecutable: string | null;
  version: string | null;
  /** Non-fatal findings: `dashboard_autostart_failed`, `first_backup_not_started`, `recovery_key_not_readable_by_user`. */
  warnings: { code: string; message: string }[];
  /** After an uninstall: what it deliberately kept, so the person can be told where. */
  kept: KeptPaths | null;
  /** After an uninstall: what it actually removed. A shortcut or Installed apps entry that wasn't Rewindle's is kept (with a warning). */
  removed: RemovedParts | null;
}

export interface RemovedParts { installRoot: boolean; scheduledTasks: string[]; startMenuShortcut: boolean; installedAppsEntry: boolean }

export interface KeptPaths { stateRoot: string | null; repository: string | null; recoveryKey: string | null; recoveryTools: string | null }

export type ProgressLine = { kind: 'phase'; phase: ProgressPhase } | { kind: 'result'; result: InstallResult };

/**
 * The installer's phases, in the order it emits them (docs/setup-contract.md, section 3.3: the restore test file comes before the
 * password, and locking the folders comes last of the ones that write), with the words the wizard shows until the installer's own
 * title arrives. The weights only shape the overall bar; the installer reports no percentages.
 */
export const INSTALL_PHASES: readonly { id: string; title: string; weight: number }[] = [
  { id: 'preflight', title: 'Checking your PC and your choices', weight: 6 },
  { id: 'webview2', title: 'Making sure the display component is there', weight: 6 },
  { id: 'payload', title: 'Copying Rewindle onto this PC', weight: 12 },
  { id: 'canary', title: 'Preparing the restore test file', weight: 4 },
  { id: 'credential', title: 'Creating your encryption password', weight: 4 },
  { id: 'repository', title: 'Creating the backup location', weight: 14 },
  { id: 'recovery_key', title: 'Writing your recovery key', weight: 5 },
  { id: 'permissions', title: 'Protecting Rewindle’s files', weight: 6 },
  { id: 'tasks', title: 'Scheduling the daily backup', weight: 8 },
  { id: 'dashboard', title: 'Setting up the Rewindle app', weight: 6 },
  { id: 'verification', title: 'Checking that everything works', weight: 15 },
  { id: 'first_backup', title: 'Starting your first backup', weight: 8 },
];

/** The uninstaller's phases (section 4 of the contract). The last two may be skipped when there is nothing to remove. */
export const UNINSTALL_PHASES: readonly { id: string; title: string; weight: number }[] = [
  { id: 'preflight', title: 'Checking what is installed', weight: 8 },
  { id: 'stop', title: 'Stopping Rewindle', weight: 14 },
  { id: 'tasks', title: 'Removing the scheduled backups', weight: 14 },
  { id: 'program_files', title: 'Removing the Rewindle program files', weight: 30 },
  { id: 'shortcut', title: 'Removing the Start menu shortcut', weight: 6 },
  { id: 'registration', title: 'Removing Rewindle from Installed apps', weight: 8 },
  { id: 'verification', title: 'Checking that Rewindle was removed', weight: 20 },
];

/** Plain sentences for the codes a drive's `ineligible_reason` can be, for when the installer sent no sentence of its own. */
const INELIGIBLE_TEXT: Record<string, string> = {
  network_drive: 'Network drives can’t hold backups.',
  optical_drive: 'Discs can’t hold backups that change every day.',
  ram_disk: 'A RAM disk is emptied when the PC restarts.',
  unknown_drive_type: 'Windows doesn’t say what kind of drive this is.',
  not_ready: 'This drive isn’t ready. Check that it is connected and unlocked.',
  not_ntfs: 'Backups need a drive formatted as NTFS.',
  low_free_space: 'This drive doesn’t have enough free space.',
};

/** Why a drive can't be used, in words for the person. */
export function ineligibleText(volume: PlanVolume): string {
  return volume.ineligibleMessage ?? (volume.ineligibleReason ? INELIGIBLE_TEXT[volume.ineligibleReason] : undefined) ?? 'Backups can’t be kept on this drive.';
}

const FIELDS: readonly IssueField[] = ['repository', 'sources', 'schedule', 'storage_mode', 'environment'];
const DRIVE_TYPES: readonly DriveType[] = ['fixed', 'removable', 'network', 'cdrom', 'ram', 'unknown'];
const KNOWN_KEYS: readonly KnownFolderKey[] = ['Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads', 'Favorites'];
const PHASE_STATES: readonly PhaseState[] = ['started', 'completed', 'skipped', 'failed'];
const MAX_TEXT = 4096;

export class ContractError extends Error {
  constructor(message: string) { super(message); this.name = 'ContractError'; }
}

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
const object = (value: unknown, what: string): Json => {
  if (!isObject(value)) throw new ContractError(`${what} is missing from the installer's plan.`);
  return value;
};
const text = (value: unknown, fallback = ''): string => typeof value === 'string' ? value.slice(0, MAX_TEXT) : fallback;
const textOrNull = (value: unknown): string | null => typeof value === 'string' && value.length > 0 ? value.slice(0, MAX_TEXT) : null;
const bool = (value: unknown, fallback = false): boolean => typeof value === 'boolean' ? value : fallback;
const count = (value: unknown): number => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : 0;
const countOrNull = (value: unknown): number | null => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
const list = (value: unknown): unknown[] => Array.isArray(value) ? value.slice(0, 256) : [];
const texts = (value: unknown): string[] => list(value).filter((item): item is string => typeof item === 'string').map(item => item.slice(0, MAX_TEXT));
const storageMode = (value: unknown): StorageMode => value === 'google_drivefs_stream' ? 'google_drivefs_stream' : 'local_ntfs';
const schedule = (value: unknown, fallback: string): string => typeof value === 'string' && SCHEDULE_PATTERN.test(value) ? value : fallback;

export const SCHEDULE_PATTERN = /^([01]\d|2[0-3]):[0-5]\d$/;
export const DEFAULT_SCHEDULE = '02:00';

function issues(value: unknown): PlanIssue[] {
  return list(value).filter(isObject).map(item => ({
    code: text(item.code, 'unknown'),
    // An issue about a field the wizard does not know is shown with the environment's: on the first screen, never lost.
    field: FIELDS.includes(item.field as IssueField) ? item.field as IssueField : 'environment',
    message: text(item.message, 'The installer reported a problem without describing it.'),
    path: textOrNull(item.path),
    detail: textOrNull(item.detail),
  }));
}

function volumes(value: unknown): PlanVolume[] {
  return list(value).filter(isObject).filter(item => typeof item.root === 'string').map(item => ({
    root: text(item.root),
    label: text(item.label),
    filesystem: text(item.filesystem),
    driveType: DRIVE_TYPES.includes(item.drive_type as DriveType) ? item.drive_type as DriveType : 'unknown',
    sizeBytes: count(item.size_bytes),
    freeBytes: count(item.free_bytes),
    isSystem: bool(item.is_system),
    sameDiskAsSystem: bool(item.same_physical_disk_as_system),
    eligible: bool(item.eligible),
    ineligibleReason: textOrNull(item.ineligible_reason),
    ineligibleMessage: textOrNull(item.ineligible_message),
    recommended: bool(item.recommended),
  }));
}

function knownFolders(value: unknown): KnownFolder[] {
  const seen = new Set<string>();
  return list(value).filter(isObject).filter(item => KNOWN_KEYS.includes(item.key as KnownFolderKey) && typeof item.path === 'string')
    .filter(item => { const key = String(item.key); if (seen.has(key)) return false; seen.add(key); return true; })
    .map(item => ({ key: item.key as KnownFolderKey, path: text(item.path), exists: bool(item.exists), defaultSelected: bool(item.default_selected) }));
}

function existingRewindle(value: unknown): ExistingRewindle | null {
  if (value === null || value === undefined || value === false) return null;
  // `true`, or an object without details, still means "installed".
  if (!isObject(value)) return { version: null, installRoot: null };
  return { version: textOrNull(value.version), installRoot: textOrNull(value.install_root) };
}

/** Reads a plan file's JSON. Throws ContractError when it is not a plan this wizard understands. */
export function parsePlan(raw: unknown): InstallPlan {
  const plan = object(raw, 'The plan');
  if (plan.schema !== PLAN_SCHEMA) throw new ContractError(`The installer answered with an unknown plan format (${text(plan.schema, 'none')}).`);
  const resolved = isObject(plan.resolved) ? plan.resolved : {};
  const defaults = isObject(plan.defaults) ? plan.defaults : {};
  const environment = object(plan.environment, 'The description of this PC');
  const os = isObject(environment.os) ? environment.os : {};
  const existing = isObject(environment.existing_install) ? environment.existing_install : {};
  const drivefs = isObject(environment.drivefs) ? environment.drivefs : {};
  const errors = issues(plan.errors);
  return {
    // A plan with errors is never ok, whatever its flag says.
    ok: bool(plan.ok) && errors.length === 0,
    errors,
    warnings: issues(plan.warnings),
    resolved: {
      repository: textOrNull(resolved.repository),
      storageMode: storageMode(resolved.storage_mode),
      driveFsMyDriveRoot: textOrNull(resolved.drivefs_my_drive_root),
      sources: texts(resolved.sources),
      canarySource: textOrNull(resolved.canary_source),
      schedule: schedule(resolved.schedule, DEFAULT_SCHEDULE),
      vss: bool(resolved.vss, true),
      minimumFreeBytes: count(resolved.minimum_free_bytes),
      estimatedSourceBytes: countOrNull(resolved.estimated_source_bytes),
    },
    defaults: {
      repository: textOrNull(defaults.repository),
      storageMode: storageMode(defaults.storage_mode),
      sources: texts(defaults.sources),
      schedule: schedule(defaults.schedule, DEFAULT_SCHEDULE),
    },
    environment: {
      version: text(environment.version),
      os: { caption: text(os.caption, 'Windows'), build: text(os.build), x64: bool(os.x64, true), supported: bool(os.supported, true) },
      powershell: text(environment.powershell),
      dotnetFramework48: bool(environment.dotnet_framework_48, true),
      elevated: bool(environment.elevated),
      webview2: textOrNull(environment.webview2),
      existingInstall: { rewindle: existingRewindle(existing.rewindle), legacyPersonalEdition: bool(existing.legacy_personal_edition) },
      volumes: volumes(environment.volumes),
      drivefs: { detected: bool(drivefs.detected), myDriveRoot: textOrNull(drivefs.my_drive_root) },
      knownFolders: knownFolders(environment.known_folders),
    },
  };
}

/** Reads one progress line the host forwarded (already JSON-decoded). Returns null for a line this wizard does not understand. */
export function parseProgressLine(raw: unknown): ProgressLine | null {
  if (!isObject(raw)) return null;
  if (raw.type === 'result') {
    const error = isObject(raw.error) ? { code: text(raw.error.code, 'unknown'), message: text(raw.error.message, 'Setup could not finish.') } : null;
    return {
      kind: 'result',
      result: {
        ok: bool(raw.ok) && error === null,
        error,
        installRoot: textOrNull(raw.install_root),
        recoveryKeyPath: textOrNull(raw.recovery_key_path),
        recoveryKeyReadableByUser: typeof raw.recovery_key_readable_by_user === 'boolean' ? raw.recovery_key_readable_by_user : null,
        dashboardExecutable: textOrNull(raw.dashboard_executable),
        version: textOrNull(raw.version),
        warnings: list(raw.warnings).filter(isObject).map(item => ({ code: text(item.code, 'unknown'), message: text(item.message) })),
        kept: isObject(raw.kept)
          ? { stateRoot: textOrNull(raw.kept.state_root), repository: textOrNull(raw.kept.repository), recoveryKey: textOrNull(raw.kept.recovery_key), recoveryTools: textOrNull(raw.kept.recovery_tools) }
          : null,
        removed: isObject(raw.removed)
          ? {
            installRoot: bool(raw.removed.install_root),
            scheduledTasks: list(raw.removed.scheduled_tasks).filter((name): name is string => typeof name === 'string'),
            startMenuShortcut: bool(raw.removed.start_menu_shortcut),
            installedAppsEntry: bool(raw.removed.installed_apps_entry),
          }
          : null,
      },
    };
  }
  if (raw.type !== 'phase' || raw.schema !== PROGRESS_SCHEMA) return null;
  if (typeof raw.phase !== 'string' || !PHASE_STATES.includes(raw.state as PhaseState)) return null;
  return {
    kind: 'phase',
    phase: {
      seq: typeof raw.seq === 'number' ? raw.seq : 0,
      time: text(raw.time),
      phase: text(raw.phase).slice(0, 64),
      state: raw.state as PhaseState,
      title: text(raw.title),
      detail: textOrNull(raw.detail),
    },
  };
}

/** The installer's errors and warnings that belong to one screen. */
export const issuesFor = (plan: InstallPlan | null, ...fields: IssueField[]) => ({
  errors: plan?.errors.filter(issue => fields.includes(issue.field)) ?? [],
  warnings: plan?.warnings.filter(issue => fields.includes(issue.field)) ?? [],
});

/** True when the plan says this PC cannot run Rewindle at all, whatever is chosen. */
export function isUnsupported(plan: InstallPlan): boolean {
  const os = plan.environment.os;
  return !os.supported || !os.x64 || !plan.environment.dotnetFramework48;
}
