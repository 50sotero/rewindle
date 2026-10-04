// The wizard's state: what the person chose, what the installer said about it, the folder sizes the host measured, and the
// install or uninstall that is running. The screens only read it and call its actions.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ContractError, INSTALL_PHASES, UNINSTALL_PHASES, isUnsupported, parsePlan, parseProgressLine,
  type InstallPlan, type InstallResult, type KnownFolderKey, type PlanInputs, type PlanVolume, type ProgressPhase, type StorageMode,
} from './contract';
import {
  bridge, messageOf, type HostEvent, type HostInfo, type MeasureUpdate, type Operation, type OperationFinished,
  type OperationStage, type ProjectLink, type ThemeInfo,
} from './bridge';
import { driveRoot, isUsablePath, isWithin, joinPath, samePath } from './format';

export type Screen =
  | 'loading' | 'hostError' | 'unsupported' | 'maintenance'
  | 'welcome' | 'folders' | 'location' | 'schedule' | 'review'
  | 'installing' | 'recovery' | 'done' | 'uninstalling' | 'uninstalled';

/** The steps the person moves through, in order. The rail shows them; the first five can be revisited until Install. */
export const STEPS: readonly { screen: Screen; label: string }[] = [
  { screen: 'welcome', label: 'Welcome' },
  { screen: 'folders', label: 'What to protect' },
  { screen: 'location', label: 'Backup location' },
  { screen: 'schedule', label: 'Schedule' },
  { screen: 'review', label: 'Review' },
  { screen: 'installing', label: 'Install' },
  { screen: 'recovery', label: 'Recovery key' },
  { screen: 'done', label: 'Done' },
];
export const CHOICE_STEPS: readonly Screen[] = ['welcome', 'folders', 'location', 'schedule', 'review'];

export interface FolderChoice { path: string; key: KnownFolderKey | null; selected: boolean; exists: boolean; custom: boolean }

export interface Choices {
  folders: FolderChoice[];
  storageMode: StorageMode;
  /** The drive the backups go to, "E:\" (empty for Google Drive). */
  driveRoot: string;
  repository: string;
  /** True once "Choose a different folder…" picked the folder; choosing a drive card again goes back to its default folder. */
  customRepository: boolean;
  schedule: string;
  vss: boolean;
  startBackup: boolean;
}

export interface FolderSize {
  bytes: number; files: number; placeholderFiles: number; placeholderBytes: number; skippedFolders: number; done: boolean; error: string | null;
}

export interface OperationState {
  operation: Operation;
  stage: OperationStage | 'finished';
  /** Every phase the installer reported, latest state of each, in the order they first appeared. */
  phases: ProgressPhase[];
  lines: string[];
  result: InstallResult | null;
  finished: OperationFinished | null;
  cancelling: boolean;
  /** Whether the person asked for the first backup (decides whether that phase is listed before it is reported). */
  startBackup: boolean;
  /** An uninstall that is the first half of a reinstall: when it succeeds, Setup goes on to the setup steps instead of ending. */
  reinstall: boolean;
}

export interface Validation { plan: InstallPlan | null; checking: boolean; error: string | null }

// A parent folder of its own: the installer creates RecoveryTools beside the backup folder, so both stay inside <drive>\Rewindle.
const DEFAULT_FOLDER_NAME = 'Rewindle\\Backups';
const VALIDATE_AFTER_MS = 450;
const MAX_SOURCES = 64;

export const selectedPaths = (choices: Choices) => choices.folders.filter(folder => folder.selected && folder.exists).map(folder => folder.path);

export function inputsOf(choices: Choices, plan: InstallPlan | null): PlanInputs {
  const myDrive = plan?.environment.drivefs.myDriveRoot ?? undefined;
  return {
    repository: choices.repository,
    storageMode: choices.storageMode,
    ...(choices.storageMode === 'google_drivefs_stream' && myDrive ? { driveFsMyDriveRoot: myDrive } : {}),
    sources: selectedPaths(choices),
    schedule: choices.schedule,
    vss: choices.vss,
  };
}

/**
 * The folder a drive card stands for: "<drive>\Rewindle\Backups". (The installer's own suggestion, ResticBackups\Personal, is only
 * used to pick the drive; a reinstall goes back to the folder the removed copy kept, see initialChoices.)
 */
export function defaultRepositoryFor(root: string, _plan: InstallPlan | null): string {
  return joinPath(root, DEFAULT_FOLDER_NAME);
}

function initialDrive(plan: InstallPlan): PlanVolume | undefined {
  const eligible = plan.environment.volumes.filter(volume => volume.eligible);
  const suggested = plan.defaults.repository ? driveRoot(plan.defaults.repository) : '';
  return eligible.find(volume => volume.recommended)
    ?? eligible.find(volume => samePath(volume.root, suggested))
    ?? eligible.find(volume => !volume.isSystem && !volume.sameDiskAsSystem)
    ?? eligible.find(volume => !volume.isSystem)
    ?? eligible[0];
}

function initialChoices(plan: InstallPlan, preferredRepository?: string): Choices {
  const defaults = plan.defaults.sources;
  const folders: FolderChoice[] = plan.environment.knownFolders.map(folder => ({
    path: folder.path, key: folder.key, exists: folder.exists, custom: false,
    selected: folder.exists && (folder.defaultSelected || defaults.some(path => samePath(path, folder.path))),
  }));
  for (const path of defaults) {
    if (!folders.some(folder => samePath(folder.path, path))) folders.push({ path, key: null, exists: true, custom: true, selected: true });
  }
  // A reinstall carries on with the backups the removed copy kept, when the drive that holds them is there. Backups in Google
  // Drive for desktop sit on a drive that is never an eligible local volume (DriveFS reports FAT32), so they are recognized by
  // the My Drive folder instead, as browseRepository does.
  const myDrive = plan.environment.drivefs.detected ? plan.environment.drivefs.myDriveRoot : null;
  const keptInDriveFs = !!(preferredRepository && myDrive && isWithin(preferredRepository, myDrive) && !samePath(preferredRepository, myDrive));
  if (preferredRepository && keptInDriveFs) {
    return {
      folders: folders.slice(0, MAX_SOURCES),
      storageMode: 'google_drivefs_stream',
      driveRoot: '',
      repository: preferredRepository,
      customRepository: true,
      schedule: plan.defaults.schedule,
      vss: true,
      startBackup: true,
    };
  }
  const keptDrive = preferredRepository ? plan.environment.volumes.find(volume => volume.eligible && samePath(volume.root, driveRoot(preferredRepository))) : undefined;
  const drive = keptDrive ?? initialDrive(plan);
  const repository = keptDrive && preferredRepository ? preferredRepository : drive ? defaultRepositoryFor(drive.root, plan) : '';
  return {
    folders: folders.slice(0, MAX_SOURCES),
    storageMode: 'local_ntfs',
    driveRoot: drive?.root ?? '',
    repository,
    customRepository: !!(keptDrive && preferredRepository),
    schedule: plan.defaults.schedule,
    vss: true,
    startBackup: true,
  };
}

function firstScreen(plan: InstallPlan): Screen {
  if (isUnsupported(plan)) return 'unsupported';
  if (plan.environment.existingInstall.rewindle) return 'maintenance';
  return 'welcome';
}

/** The measured total of the chosen folders, and whether every one of them has finished. */
export function selectedTotal(choices: Choices, sizes: Record<string, FolderSize>) {
  let bytes = 0, files = 0, placeholderFiles = 0, measuring = false;
  for (const path of selectedPaths(choices)) {
    const size = sizes[path.toLowerCase()];
    if (!size) { measuring = true; continue; }
    bytes += size.bytes; files += size.files; placeholderFiles += size.placeholderFiles;
    if (!size.done) measuring = true;
  }
  return { bytes, files, placeholderFiles, measuring };
}

/** Overall progress of an install, 0 to 1, from the phases' weights. */
export function operationProgress(operation: OperationState): number {
  if (operation.finished?.outcome === 'succeeded') return 1;
  const phases = listedPhases(operation);
  const total = phases.reduce((sum, phase) => sum + phase.weight, 0) || 1;
  const reached = phases.reduce((sum, phase) => sum + (phase.state === 'pending' ? 0 : phase.state === 'started' ? phase.weight / 2 : phase.weight), 0);
  return Math.min(0.99, reached / total);
}

/** A phase's title in the wizard's words, or the installer's own for a phase the wizard does not know. */
export function phaseTitle(kind: Operation, id: string, reported: string): string {
  return (kind === 'uninstall' ? UNINSTALL_PHASES : INSTALL_PHASES).find(phase => phase.id === id)?.title ?? (reported || id);
}

export interface ListedPhase { id: string; title: string; state: ProgressPhase['state'] | 'pending'; detail: string | null; weight: number }

/** The phases to list: the installer's known ones (pending until reported), then any others it reported, in order. */
export function listedPhases(operation: OperationState): ListedPhase[] {
  const reported = new Map(operation.phases.map(phase => [phase.phase, phase]));
  const table = operation.operation === 'uninstall' ? UNINSTALL_PHASES : INSTALL_PHASES;
  const known = table
    .filter(phase => phase.id !== 'first_backup' || operation.startBackup || reported.has(phase.id))
    .map(phase => {
      const report = reported.get(phase.id);
      // The wizard's own words for the phases it knows (the installer's titles say "repository" and "dashboard"); the installer's
      // title is used only for a phase this version does not know.
      return { id: phase.id, title: phase.title, state: report?.state ?? 'pending' as const, detail: report?.detail ?? null, weight: phase.weight };
    });
  const extra = operation.phases.filter(phase => !table.some(known => known.id === phase.phase))
    .map(phase => ({ id: phase.phase, title: phase.title || phase.phase, state: phase.state, detail: phase.detail, weight: 4 }));
  return [...known, ...extra];
}

export function useWizard() {
  const [host, setHost] = useState<HostInfo | null>(null);
  const [theme, setTheme] = useState<ThemeInfo | null>(null);
  const [screen, setScreenState] = useState<Screen>('loading');
  const [furthest, setFurthest] = useState(0);
  const [base, setBase] = useState<InstallPlan | null>(null);
  const [hostError, setHostError] = useState<string | null>(null);
  const [choices, setChoices] = useState<Choices | null>(null);
  const [validation, setValidation] = useState<Validation>({ plan: null, checking: false, error: null });
  const [sizes, setSizes] = useState<Record<string, FolderSize>>({});
  const [operation, setOperation] = useState<OperationState | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [maintenance, setMaintenance] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshNote, setRefreshNote] = useState<string | null>(null);
  // Whether the time field on the Schedule page currently holds a valid time; choices.schedule keeps the last valid one.
  const [scheduleDraftValid, setScheduleDraftValid] = useState(true);
  const measureSequence = useRef(0);
  const planSequence = useRef(0);
  const measured = useRef(new Set<string>());
  // Set when the uninstall under way is the first half of a reinstall (read in the host's events, so a ref).
  const reinstalling = useRef(false);

  const setScreen = useCallback((next: Screen) => {
    setScreenState(next);
    const index = CHOICE_STEPS.indexOf(next);
    if (index >= 0) setFurthest(current => Math.max(current, index));
  }, []);

  // Events from the host: theme changes, folder sizes and installer progress.
  useEffect(() => bridge.subscribe((message: HostEvent) => {
    if (message.event === 'theme') setTheme(message.data);
    else if (message.event === 'measure') {
      const update: MeasureUpdate = message.data;
      setSizes(current => ({ ...current, [update.path.toLowerCase()]: {
        bytes: update.bytes, files: update.files, placeholderFiles: update.placeholderFiles, placeholderBytes: update.placeholderBytes,
        skippedFolders: update.skippedFolders, done: update.done, error: update.error,
      } }));
    } else if (message.event === 'operationStage') {
      setOperation(current => current && current.operation === message.data.operation ? { ...current, stage: message.data.stage, cancelling: false } : current);
    } else if (message.event === 'operationLine') {
      const parsed = parseProgressLine(message.data.line);
      setOperation(current => {
        if (!current || current.operation !== message.data.operation) return current;
        const lines = [...current.lines, message.data.raw].slice(-2000);
        if (!parsed) return { ...current, lines };
        if (parsed.kind === 'result') return { ...current, lines, result: parsed.result };
        const phases = current.phases.some(phase => phase.phase === parsed.phase.phase)
          ? current.phases.map(phase => phase.phase === parsed.phase.phase ? parsed.phase : phase)
          : [...current.phases, parsed.phase];
        return { ...current, lines, phases };
      });
    } else if (message.event === 'operationFinished') {
      const finished = message.data;
      setOperation(current => {
        if (!current || current.operation !== finished.operation) return current;
        let result = current.result;
        if (!result && finished.result) {
          const parsed = parseProgressLine(finished.result);
          if (parsed?.kind === 'result') result = parsed.result;
        }
        return { ...current, stage: 'finished', finished, result, cancelling: false };
      });
      if (finished.outcome === 'blocked' && finished.plan) {
        try {
          setValidation({ plan: parsePlan(finished.plan), checking: false, error: null });
        } catch { /* the review screen still shows the host's message */ }
        setNotice(finished.message || 'Setup found a problem with your choices. Nothing was changed.');
        setScreen('review');
        setOperation(null);
      } else if (finished.outcome === 'succeeded' && finished.operation === 'uninstall') {
        if (reinstalling.current) {
          // The old copy is gone; ask the installer about this PC again (it reports no installation now) and start the steps.
          reinstalling.current = false;
          setOperation(null);
          const parsed = finished.result ? parseProgressLine(finished.result) : null;
          void startRef.current(parsed?.kind === 'result' ? parsed.result.kept?.repository ?? undefined : undefined);
        } else {
          setScreen('uninstalled');
        }
      } else if (finished.operation === 'uninstall') {
        reinstalling.current = false;
      }
    }
  }), [setScreen]);

  const measure = useCallback((paths: string[]) => {
    const fresh = paths.filter(path => !measured.current.has(path.toLowerCase()));
    if (fresh.length === 0) return;
    fresh.forEach(path => measured.current.add(path.toLowerCase()));
    const request = `m${++measureSequence.current}`;
    bridge.request('measureFolders', { request, paths: fresh }).catch(() => {
      // Sizes are a convenience: a folder that cannot be measured just shows no size.
      setSizes(current => {
        const next = { ...current };
        fresh.forEach(path => { next[path.toLowerCase()] = { bytes: 0, files: 0, placeholderFiles: 0, placeholderBytes: 0, skippedFolders: 0, done: true, error: 'Size unavailable' }; });
        return next;
      });
    });
  }, []);

  const startRef = useRef<(preferredRepository?: string) => Promise<void>>(async () => undefined);
  const start = useCallback(async (preferredRepository?: string) => {
    setHostError(null);
    setScreenState('loading');
    try {
      const info = await bridge.request<HostInfo>('hello');
      setHost(info);
      setTheme(current => current ?? { dark: info.dark, highContrast: info.highContrast, reducedMotion: info.reducedMotion });
      const plan = parsePlan(await bridge.request('getPlan', { inputs: {} }));
      setBase(plan);
      const initial = initialChoices(plan, preferredRepository);
      setChoices(initial);
      setValidation({ plan, checking: false, error: null });
      setScreen(firstScreen(plan));
      setMaintenance(!!plan.environment.existingInstall.rewindle);
      measure(initial.folders.filter(folder => folder.exists).map(folder => folder.path));
    } catch (error) {
      setHostError(error instanceof ContractError ? error.message : messageOf(error));
      setScreenState('hostError');
    }
  }, [measure, setScreen]);

  startRef.current = start;
  useEffect(() => { void start(); }, [start]);

  // Every change to the choices is checked again by the installer, a moment after the last change.
  const inputsKey = useMemo(() => choices ? JSON.stringify(inputsOf(choices, base)) : '', [choices, base]);
  useEffect(() => {
    if (!choices || !base || !inputsKey) return;
    const id = ++planSequence.current;
    setValidation(current => ({ ...current, checking: true }));
    const timer = window.setTimeout(() => {
      bridge.request('getPlan', { inputs: JSON.parse(inputsKey) }).then(raw => {
        if (id !== planSequence.current) return;
        setValidation({ plan: parsePlan(raw), checking: false, error: null });
      }).catch(error => {
        if (id !== planSequence.current) return;
        setValidation(current => ({ ...current, checking: false, error: messageOf(error) }));
      });
    }, VALIDATE_AFTER_MS);
    return () => window.clearTimeout(timer);
    // `choices` and `base` are read through inputsKey; the check runs when what is sent changes, not on every keystroke elsewhere.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inputsKey]);

  const update = useCallback((change: (current: Choices) => Choices) => setChoices(current => current ? change(current) : current), []);

  const actions = useMemo(() => ({
    retry: () => void start(),
    goTo: (next: Screen) => setScreen(next),
    toggleFolder: (path: string) => update(current => ({
      ...current, folders: current.folders.map(folder => samePath(folder.path, path) && folder.exists ? { ...folder, selected: !folder.selected } : folder),
    })),
    removeFolder: (path: string) => update(current => ({ ...current, folders: current.folders.filter(folder => !samePath(folder.path, path)) })),
    addFolder: async () => {
      setNotice(null);
      try {
        const answer = await bridge.request<{ path: string | null }>('browseFolder');
        const path = answer?.path;
        if (!path) return;
        if (!isUsablePath(path)) { setNotice('That folder can’t be backed up. Choose a folder on a drive with a letter, like C: or D:.'); return; }
        if (path.includes(';')) { setNotice('Folders with a semicolon (;) in their name can’t be backed up yet.'); return; }
        if (choices && !choices.folders.some(folder => samePath(folder.path, path)) && choices.folders.length >= MAX_SOURCES) {
          setNotice(`Rewindle can protect up to ${MAX_SOURCES} folders. Remove one before adding another.`);
          return;
        }
        update(current => {
          const existing = current.folders.find(folder => samePath(folder.path, path));
          if (existing) return { ...current, folders: current.folders.map(folder => folder === existing ? { ...folder, selected: true, exists: true } : folder) };
          return { ...current, folders: [...current.folders, { path, key: null, exists: true, custom: true, selected: true }] };
        });
        // Measured once per path; asking again for one already measured does nothing.
        measure([path]);
      } catch (error) { setNotice(messageOf(error)); }
    },
    chooseDrive: (root: string) => update(current => ({
      ...current, storageMode: 'local_ntfs', driveRoot: root, customRepository: false, repository: defaultRepositoryFor(root, base),
    })),
    /** Asks the installer to describe this PC again, for a drive that was connected after Setup started. */
    refreshDrives: async () => {
      setRefreshing(true); setRefreshNote(null);
      try {
        const plan = parsePlan(await bridge.request('getPlan', { inputs: {}, refresh: true }));
        const before = base?.environment.volumes.filter(volume => volume.eligible).length ?? 0;
        const after = plan.environment.volumes.filter(volume => volume.eligible).length;
        setBase(plan);
        // Unless the person chose a folder themselves, a drive that is now better than the one chosen (a separate one, not Windows') is taken.
        update(current => {
          if (current.storageMode !== 'local_ntfs' || current.customRepository) return current;
          const drive = initialDrive(plan);
          const chosen = plan.environment.volumes.find(volume => samePath(volume.root, current.driveRoot) && volume.eligible);
          const better = drive && !drive.isSystem && !drive.sameDiskAsSystem && (!chosen || chosen.isSystem || chosen.sameDiskAsSystem);
          if (!drive || !better || samePath(drive.root, current.driveRoot)) return current;
          return { ...current, driveRoot: drive.root, repository: defaultRepositoryFor(drive.root, plan) };
        });
        setRefreshNote(after > before ? 'Found a new drive.' : 'No new drives found.');
      } catch (error) {
        setRefreshNote(messageOf(error));
      } finally { setRefreshing(false); }
    },
    chooseDriveFs: () => update(current => {
      const myDrive = base?.environment.drivefs.myDriveRoot;
      if (!myDrive) return current;
      return { ...current, storageMode: 'google_drivefs_stream', driveRoot: '', customRepository: false, repository: joinPath(myDrive, DEFAULT_FOLDER_NAME) };
    }),
    browseRepository: async () => {
      setNotice(null);
      try {
        const answer = await bridge.request<{ path: string | null }>('browseRepositoryFolder');
        const path = answer?.path;
        if (!path) return;
        if (!isUsablePath(path)) { setNotice('Choose a folder on a drive with a letter, like D: or E:.'); return; }
        const myDrive = base?.environment.drivefs.myDriveRoot;
        if (myDrive && isWithin(path, myDrive) && !samePath(path, myDrive)) {
          update(current => ({ ...current, storageMode: 'google_drivefs_stream', driveRoot: '', repository: path, customRepository: true }));
        } else {
          update(current => ({ ...current, storageMode: 'local_ntfs', driveRoot: driveRoot(path), repository: path, customRepository: true }));
        }
      } catch (error) { setNotice(messageOf(error)); }
    },
    setSchedule: (schedule: string) => update(current => ({ ...current, schedule })),
    setScheduleDraftValid,
    setVss: (vss: boolean) => update(current => ({ ...current, vss })),
    setStartBackup: (startBackup: boolean) => update(current => ({ ...current, startBackup })),
    dismissNotice: () => setNotice(null),
  }), [base, choices, measure, setScreen, start, update]);

  const runOperation = useCallback(async (kind: Operation, options: { reinstall?: boolean } = {}) => {
    if (!choices) return;
    setNotice(null);
    reinstalling.current = kind === 'uninstall' && !!options.reinstall;
    setOperation({ operation: kind, stage: 'preparing', phases: [], lines: [], result: null, finished: null, cancelling: false, startBackup: choices.startBackup, reinstall: reinstalling.current });
    setScreenState(kind === 'install' ? 'installing' : 'uninstalling');
    try {
      if (kind === 'install') {
        await bridge.request('install', { choices: { ...inputsOf(choices, base), startBackup: choices.startBackup } });
      } else {
        await bridge.request('uninstall');
      }
    } catch (error) {
      setOperation(current => current ? {
        ...current, stage: 'finished',
        finished: { operation: kind, outcome: 'failed', result: null, message: messageOf(error), exitCode: null },
      } : current);
    }
  }, [base, choices]);

  const cancelOperation = useCallback(async () => {
    setOperation(current => current ? { ...current, cancelling: true } : current);
    try {
      const answer = await bridge.request<{ cancelled: boolean }>('cancelInstall');
      if (!answer?.cancelled) setOperation(current => current ? { ...current, cancelling: false } : current);
    } catch {
      setOperation(current => current ? { ...current, cancelling: false } : current);
    }
  }, []);

  return {
    host, theme, screen, furthest, base, hostError, choices, validation, sizes, operation, notice, maintenance, refreshing, refreshNote,
    scheduleDraftValid,
    actions, setNotice,
    goTo: setScreen,
    install: () => runOperation('install'),
    uninstall: () => runOperation('uninstall'),
    /** Removes the installed copy (keeping backups and the recovery key), then goes through the setup steps again. */
    reinstall: () => runOperation('uninstall', { reinstall: true }),
    cancelOperation,
    clearOperation: () => setOperation(null),
    request: bridge.request.bind(bridge),
    openLink: (link: ProjectLink) => { void bridge.request('openUrl', { target: link }).catch(() => undefined); },
  };
}

export type Wizard = ReturnType<typeof useWizard>;
