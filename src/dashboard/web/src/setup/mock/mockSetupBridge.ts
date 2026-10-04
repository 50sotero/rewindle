// A stand-in for Rewindle Setup's desktop host, answering the wizard with the invented computers in scenarios.ts. It lets the
// wizard run in an ordinary browser (`npm run dev:setup`) without installing anything: no command it answers reads or changes
// this computer. Choose a sample computer with ?scenario=<name> (see SCENARIOS), a theme with ?theme=dark|light and reduced motion with ?motion=reduced.
//
// This module is reached only through the guarded dynamic import in ../main.tsx, so the setup program's own build does not
// contain it (build.ps1 in installer/setup checks the built bundle for SETUP_SAMPLE_MARKER).
import type { HostMessage, PageRequest, SetupWebView } from '../bridge';
import { GIB, HOME, SCENARIOS, SPARE_DRIVE, scenario, type Scenario, type ScenarioName } from './scenarios';

export const SETUP_SAMPLE_MARKER = 'rewindle-setup-sample-bridge';

type Listener = (event: MessageEvent<HostMessage>) => void;
type Payload = Record<string, unknown> | undefined;

const MINIMUM_FREE = 10 * GIB;
const lower = (path: string) => path.replace(/[\\/]+$/, '').toLowerCase();
const within = (child: string, parent: string) => (lower(child) + '\\').startsWith(lower(parent) + '\\');
const rootOf = (path: string) => /^[A-Za-z]:/.test(path) ? `${path[0].toUpperCase()}:\\` : '';
const wait = (ms: number) => new Promise(resolve => window.setTimeout(resolve, ms));
const prefers = (query: string) => typeof window.matchMedia === 'function' && window.matchMedia(query).matches;

class Refusal extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export function installSetupSampleBridge(): void {
  const params = new URLSearchParams(window.location.search);
  const requested = params.get('scenario') as ScenarioName | null;
  const sample: Scenario = scenario(requested && SCENARIOS.includes(requested) ? requested : 'fresh');
  const theme = params.get('theme');
  const listeners = new Set<Listener>();
  const measures = new Map<string, { cancelled: boolean }>();
  let browseIndex = 0, repositoryIndex = 0;
  let operation: { cancelled: boolean; elevated: boolean } | null = null;
  let recoveryKeySaved = false;
  let declinedOnce = false;

  const post = (message: HostMessage) => {
    // The wire carries JSON, so the page always receives a fresh copy.
    const data = JSON.parse(JSON.stringify(message)) as HostMessage;
    listeners.forEach(listener => listener({ data } as MessageEvent<HostMessage>));
  };
  const event = (name: string, data: unknown) => post({ type: 'event', event: name, data } as HostMessage);

  // ?motion=reduced asks for the reduced-motion page without changing Windows' setting, for stable screenshots.
  const reduceMotion = () => params.get('motion') === 'reduced' || prefers('(prefers-reduced-motion: reduce)');
  const dark = () => theme === 'dark' ? true : theme === 'light' ? false : prefers('(prefers-color-scheme: dark)');
  const sendTheme = () => event('theme', { dark: dark(), highContrast: prefers('(forced-colors: active)'), reducedMotion: reduceMotion() });
  if (typeof window.matchMedia === 'function' && !theme) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', sendTheme);
  }

  // Whether the person has "connected" the spare drive: in the no-second-drive sample it appears once Setup is asked to look again.
  let spareDriveConnected = false;
  const volumesNow = () => spareDriveConnected && sample.name === 'no-second-drive' ? [...sample.volumes, SPARE_DRIVE] : sample.volumes;
  const volumeOf = (path: string) => volumesNow().find(volume => volume.root.toLowerCase() === rootOf(path).toLowerCase());
  const exists = (path: string) => !sample.missing.includes(lower(path));
  // Whether the sample has been uninstalled: a reinstall starts from a PC without Rewindle on it.
  let uninstalled = false;
  const existingNow = () => uninstalled ? { ...sample.existing, rewindle: null } : sample.existing;

  // The checks the real installer makes in plan mode, imitated closely enough to show every message the wizard can get.
  type Finding = { code: string; field: string; message: string; path: string | null; detail: string | null };
  const finding = (code: string, field: string, message: string, path: string | null = null): Finding => ({ code, field, message, path, detail: null });

  function plan(inputs: Payload) {
    const errors: Finding[] = [];
    const warnings: Finding[] = [];
    for (const error of sample.environmentErrors ?? []) errors.push(finding(error.code, 'environment', error.message));
    // While Rewindle is installed the installer refuses a second installation (this alpha does not upgrade in place).
    if (existingNow().rewindle) errors.push(finding('already_installed', 'environment', 'Rewindle is already installed on this PC. Remove it first; your backups and recovery key are kept.', 'C:\\Program Files\\ResticBackuper'));

    const mode = inputs?.storageMode === 'google_drivefs_stream' ? 'google_drivefs_stream' : 'local_ntfs';
    const repository = typeof inputs?.repository === 'string' ? inputs.repository : sample.defaultRepository;
    const sources = Array.isArray(inputs?.sources) ? inputs.sources as string[] : sample.defaultSources;
    const vss = inputs?.vss !== false;
    const schedule = typeof inputs?.schedule === 'string' ? inputs.schedule : '02:00';

    if (inputs && typeof inputs.schedule === 'string' && !/^([01]\d|2[0-3]):[0-5]\d$/.test(schedule)) {
      errors.push(finding('schedule_invalid', 'schedule', 'Choose a time between 00:00 and 23:59.'));
    }
    if (mode === 'google_drivefs_stream') {
      if (!sample.drivefs.detected) {
        errors.push(finding('drivefs_not_running', 'storage_mode', 'Google Drive for desktop isn’t running on this PC.'));
      }
    } else if (repository) {
      const volume = volumeOf(repository);
      if (!volume) {
        errors.push(finding('repository_drive_unavailable', 'repository', `There is no drive ${rootOf(repository) || 'with that name'} on this PC.`, repository));
      } else if (!volume.eligible) {
        errors.push(finding(volume.ineligible_reason === 'not_ntfs' ? 'repository_not_ntfs' : 'repository_drive_unavailable', 'repository', volume.ineligible_message ?? 'Backups can’t be kept on this drive.', volume.root));
      } else {
        if (volume.free_bytes < MINIMUM_FREE) {
          errors.push(finding('repository_low_space', 'repository', `${volume.root} has less than 10 GB free. Backups need at least 10 GB of room to start.`, volume.root));
        }
        if (sample.nonEmpty.includes(lower(repository))) {
          errors.push(finding('repository_not_empty', 'repository', 'This folder already has files in it that aren’t a Rewindle backup. Choose an empty folder or a new one.', repository));
        }
        // The backups a removed copy kept are found again when the same folder is chosen.
        if (uninstalled && sample.defaultRepository && lower(repository) === lower(sample.defaultRepository)) {
          warnings.push(finding('repository_exists', 'repository', 'This folder already holds Rewindle backups. Setup carries on with them and keeps your earlier snapshots.', repository));
        }
        if (volume.is_system) {
          warnings.push(finding('repository_on_system_disk', 'repository', 'Your backups would be on the same drive as Windows. If that drive fails, you lose your files and their backups together.', repository));
        } else if (volume.same_physical_disk_as_system) {
          warnings.push(finding('repository_on_system_disk', 'repository', 'This drive is part of the same physical disk as Windows. If that disk fails, your files and their backups are lost together.', repository));
        }
      }
    }

    if (inputs && sources.length === 0) {
      errors.push(finding('sources_required', 'sources', 'Choose at least one folder to protect.'));
    }
    sources.forEach((source, index) => {
      const name = source.split('\\').pop();
      if (!exists(source)) {
        errors.push(finding('source_not_found', 'sources', `“${name}” can’t be found. It may have been moved or deleted (${source}).`, source));
      }
      const parent = sources.find((other, otherIndex) => otherIndex !== index && within(source, other) && lower(source) !== lower(other));
      if (parent) {
        errors.push(finding('sources_overlap', 'sources', `“${name}” is inside “${parent.split('\\').pop()}”, which is already protected. Remove one of them.`, source));
      }
      if (repository && mode === 'local_ntfs' && (within(source, repository) || within(repository, source))) {
        errors.push(finding('source_overlaps_repository', 'sources', `“${name}” and your backup location overlap. Backups can’t be kept inside a folder they protect.`, source));
      }
      const volume = volumeOf(source);
      if (vss && volume && (volume.drive_type !== 'fixed' || volume.filesystem !== 'NTFS')) {
        errors.push(finding('source_vss_unsupported', 'sources', `The folder ${source} is on a drive that can’t be backed up while files are open (it must be a fixed NTFS drive). Choose a folder on your main drives, or turn off open-file backup.`, source));
      }
    });

    return {
      schema: 'Rewindle.InstallPlan.v1',
      ok: errors.length === 0,
      errors,
      warnings,
      resolved: {
        repository: mode === 'google_drivefs_stream' ? (repository ?? `${sample.drivefs.my_drive_root}\\Rewindle\\Backups`) : repository,
        storage_mode: mode,
        drivefs_my_drive_root: mode === 'google_drivefs_stream' ? sample.drivefs.my_drive_root : null,
        sources,
        canary_source: 'C:\\ProgramData\\ResticBackuper\\Canary',
        schedule,
        vss,
        minimum_free_bytes: MINIMUM_FREE,
        estimated_source_bytes: null,
      },
      defaults: { repository: sample.defaultRepository, storage_mode: 'local_ntfs', sources: sample.defaultSources, schedule: '02:00' },
      environment: {
        version: '0.2.0-alpha.1',
        os: sample.os,
        powershell: '5.1',
        dotnet_framework_48: sample.dotnet,
        elevated: false,
        webview2: '141.0.3537.71',
        existing_install: existingNow(),
        volumes: volumesNow(),
        drivefs: sample.drivefs,
        known_folders: sample.knownFolders,
      },
    };
  }

  async function measure(request: string, paths: string[]) {
    const job = { cancelled: false };
    measures.set(request, job);
    await Promise.all(paths.map(async (path, index) => {
      const known = sample.sizes[lower(path)] ?? { bytes: 120 * 1024 ** 2, files: 240 };
      if (!exists(path)) {
        await wait(300 + index * 80);
        if (!job.cancelled) event('measure', { request, path, bytes: 0, files: 0, placeholderFiles: 0, placeholderBytes: 0, skippedFolders: 0, done: true, error: 'This folder can’t be found.' });
        return;
      }
      // Larger folders take longer, and report partial totals on the way, as the host does.
      const steps = Math.min(8, Math.max(2, Math.round(Math.log2(known.bytes / 1e8 + 2) * 1.6)));
      for (let step = 1; step <= steps; step++) {
        await wait(220 + index * 40 + Math.random() * 160);
        if (job.cancelled) return;
        const share = step / steps;
        event('measure', {
          request, path,
          bytes: Math.round(known.bytes * share), files: Math.round(known.files * share),
          placeholderFiles: Math.round((known.placeholderFiles ?? 0) * share), placeholderBytes: Math.round((known.placeholderBytes ?? 0) * share),
          skippedFolders: step === steps ? known.deniedFolders ?? 0 : 0,
          done: step === steps, error: null,
        });
      }
    }));
    measures.delete(request);
  }

  async function runOperation(kind: 'install' | 'uninstall', choices: Payload) {
    const job = { cancelled: false, elevated: false };
    operation = job;
    const stage = (name: string) => event('operationStage', { operation: kind, stage: name });
    const finish = (outcome: string, message: string, result: unknown = null, exitCode: number | null = null, finalPlan?: unknown) => {
      operation = null;
      event('operationFinished', { operation: kind, outcome, result, message, exitCode, ...(finalPlan ? { plan: finalPlan } : {}) });
    };
    let seq = 0;
    const line = (value: Record<string, unknown>) => {
      const full = value.type === 'result' ? value : { schema: 'Rewindle.InstallProgress.v1', seq: ++seq, time: new Date().toISOString(), type: 'phase', detail: null, ...value };
      const raw = JSON.stringify(full);
      event('operationLine', { operation: kind, raw, line: full });
    };

    stage('preparing');
    await wait(1300);
    if (job.cancelled) return finish('cancelled', 'Setup was cancelled before anything was changed.');
    if (kind === 'install') {
      const finalPlan = plan(choices);
      if (!finalPlan.ok) return finish('blocked', 'Setup found a problem with your choices before changing anything.', null, null, finalPlan);
    }
    stage('elevating');
    await wait(1700);
    // The first prompt is declined; trying again shows the rest of the flow.
    if (sample.install === 'declined' && kind === 'install' && !declinedOnce) {
      declinedOnce = true;
      return finish('cancelled', 'Windows permission was not given, so nothing was changed.');
    }
    job.elevated = true;
    stage('running');

    // The installer's own phases and titles, as docs/setup-contract.md lists them (the wizard shows its own plainer words for them).
    const steps: [string, string, number, ('skipped' | 'fail')?, string?][] = kind === 'install' ? [
      ['preflight', 'Checking your PC and the choices you made', 700],
      ['webview2', 'Making sure Microsoft Edge WebView2 is available', 250],
      ['payload', 'Copying Rewindle onto this PC', 1100],
      ['canary', 'Preparing the restore test file', 500],
      ['credential', 'Creating the backup password and storing it for your account', 500],
      ['repository', 'Creating the encrypted backup repository', 1500, sample.install === 'failure' ? 'fail' : undefined,
        'The drive E: stopped responding while the backup location was being prepared. Setup removed what it had installed and kept your backups and recovery key.'],
      ['recovery_key', 'Writing your recovery key', 500],
      ['permissions', 'Locking the Rewindle folders so only administrators can change them', 600],
      ['tasks', 'Scheduling the daily backup and registering Rewindle with Windows', 800],
      ['dashboard', 'Setting up the Rewindle dashboard', 700],
      ['verification', 'Checking that everything was installed correctly', 1600],
      ['first_backup', 'Starting the first backup', 800, choices?.startBackup === false ? 'skipped' : undefined],
    ] : [
      ['preflight', 'Checking what is installed', 700],
      ['stop', 'Stopping Rewindle', 900],
      ['tasks', 'Removing the scheduled tasks', 900],
      ['program_files', 'Removing the Rewindle program files', 1200],
      ['shortcut', 'Removing the Start menu shortcut', 400],
      ['registration', 'Removing Rewindle from Installed apps', 400],
      ['verification', 'Checking that Rewindle was removed', 800],
    ];
    const KEY_PATH = `${HOME}\\ResticBackuper-RecoveryKey.txt`;
    for (const [phase, title, duration, outcome, failure] of steps) {
      if (outcome === 'skipped') { line({ phase, state: 'skipped', title }); await wait(duration); continue; }
      line({ phase, state: 'started', title });
      await wait(duration);
      if (outcome === 'fail') {
        line({ phase, state: 'failed', title, detail: failure ?? null });
        const failed = { type: 'result', ok: false, error: { code: 'repository_initialization_failed', message: failure, detail: null }, install_root: null, recovery_key_path: null, recovery_key_readable_by_user: null, dashboard_executable: null, version: '0.2.0-alpha.1', warnings: [] };
        line(failed);
        await wait(300);
        return finish('failed', failure ?? 'Setup could not finish.', failed, 1);
      }
      line({
        phase, state: 'completed', title,
        detail: phase === 'webview2' ? 'Already installed' : phase === 'repository' ? 'Created a new, empty backup location' : phase === 'first_backup' ? 'Windows started your first backup.' : null,
      });
    }
    const result = kind === 'install' ? {
      type: 'result', ok: true, error: null, install_root: 'C:\\Program Files\\ResticBackuper',
      recovery_key_path: KEY_PATH,
      recovery_key_readable_by_user: sample.install !== 'key-unreadable',
      dashboard_executable: 'C:\\Program Files\\ResticBackuper\\ResticBackuperDashboard.exe', version: '0.2.0-alpha.1',
      warnings: sample.install === 'key-unreadable' ? [{ code: 'recovery_key_not_readable_by_user', message: 'The recovery key can only be opened by administrators.' }] : [],
    } : {
      type: 'result', ok: true, error: null, operation: 'uninstall', install_root: 'C:\\Program Files\\ResticBackuper',
      removed: { install_root: true, scheduled_tasks: ['ResticBackuper', 'ResticBackuperDashboard'], start_menu_shortcut: true, installed_apps_entry: true },
      kept: { state_root: 'C:\\ProgramData\\ResticBackuper', repository: sample.defaultRepository, recovery_key: KEY_PATH, recovery_tools: sample.defaultRepository ? `${sample.defaultRepository.replace(/\\[^\\]*$/, '')}\\RecoveryTools` : null, cloud_verification_root: null },
      warnings: [],
    };
    line(result);
    await wait(250);
    if (kind === 'uninstall') uninstalled = true;
    finish('succeeded', '', result, 0);
  }

  async function handle(command: string, payload: Payload): Promise<unknown> {
    switch (command) {
      case 'hello':
        return { protocol: 1, version: '0.2.0-alpha.1', dark: dark(), highContrast: prefers('(forced-colors: active)'), reducedMotion: reduceMotion(), host: 'sample', scenario: sample.name, locale: navigator.language };
      case 'getPlan':
        await wait(450 + Math.random() * 350);
        if (payload?.refresh === true) spareDriveConnected = true;
        return plan(payload?.inputs as Payload);
      case 'browseFolder': {
        await wait(300);
        const path = sample.browseFolders[browseIndex % sample.browseFolders.length];
        browseIndex++;
        return { path };
      }
      case 'browseRepositoryFolder': {
        await wait(300);
        const path = sample.browseRepositories[repositoryIndex % sample.browseRepositories.length];
        repositoryIndex++;
        return { path };
      }
      case 'measureFolders': {
        const request = String(payload?.request ?? '');
        const paths = Array.isArray(payload?.paths) ? (payload.paths as unknown[]).filter((p): p is string => typeof p === 'string') : [];
        if (!request || paths.length === 0) throw new Refusal('invalid', 'Nothing to measure.');
        void measure(request, paths);
        return { accepted: true };
      }
      case 'cancelMeasure': {
        const job = measures.get(String(payload?.request ?? ''));
        if (job) job.cancelled = true;
        return { cancelled: !!job };
      }
      case 'install':
      case 'uninstall':
        if (operation) throw new Refusal('busy', 'Setup is already working on something.');
        void runOperation(command, payload?.choices as Payload);
        return { started: true };
      case 'cancelInstall':
        if (!operation || operation.elevated) return { cancelled: false };
        operation.cancelled = true;
        return { cancelled: true };
      case 'saveRecoveryKeyCopy':
        await wait(500);
        if (sample.install === 'key-unreadable') throw new Refusal('recovery_key_unreadable', 'Setup can’t open your recovery key, because only administrators can read it.');
        recoveryKeySaved = true;
        return { saved: recoveryKeySaved, path: 'E:\\Rewindle recovery key.txt' };
      case 'setZoom':
        return { message: 'Zoom 100%' };
      case 'showRecoveryKey':
      case 'openDashboard':
      case 'openUrl':
      case 'close':
        // Nothing on this computer is opened or closed by the sample.
        return { done: true };
      case 'copyText':
        try { await navigator.clipboard.writeText(String(payload?.text ?? '')); } catch { /* the sample has no clipboard permission everywhere */ }
        return { done: true };
      default:
        throw new Refusal('unknown_command', 'The sample does not know that command.');
    }
  }

  const receive = async (request: PageRequest) => {
    try {
      const result = await handle(request.command, request.payload);
      post({ type: 'response', id: request.id, ok: true, result });
    } catch (error) {
      const refusal = error instanceof Refusal ? error : new Refusal('failed', 'The sample could not do that.');
      post({ type: 'response', id: request.id, ok: false, error: { code: refusal.code, message: refusal.message } });
    }
  };

  const bridge: SetupWebView = {
    postMessage(message) { window.setTimeout(() => void receive(message), 0); },
    addEventListener(_type, listener) { listeners.add(listener); },
    removeEventListener(_type, listener) { listeners.delete(listener); },
  };
  window.rewindleSetupNative = bridge;
  document.documentElement.dataset.sample = SETUP_SAMPLE_MARKER;
}
