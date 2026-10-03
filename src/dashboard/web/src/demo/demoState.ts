// Sample dashboard state for running the interface without the desktop app or a backup installation.
// Everything here is invented: the folders, the repository, the run history and the identifiers describe
// no real computer. Timestamps are computed from the current time so the charts and "last run" text
// always look recent. This file is only reachable from the dev server and the `demo` build mode; the
// build that ships inside the desktop app does not include it (see main.tsx).
import type { DashboardState, RunDetailsState, RunState } from '../native-types';

const MINUTE = 60_000;
const DAY = 86_400_000;
const numberFormat = new Intl.NumberFormat();

// The two formatters below follow the desktop host's (TelemetryFormat.FormatBytes and FormatDuration in
// Telemetry.cs), so the sample's figures read the way real ones do: KiB and TiB exist, bytes are whole numbers,
// larger units take 2, 1 or 0 decimals as they grow, and a duration over a day shows days.
const BYTE_UNITS = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
export const formatBytes = (n: number) => {
  let value = Math.max(0, n), unit = 0;
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) { value /= 1024; unit++; }
  const digits = unit === 0 ? 0 : value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits })} ${BYTE_UNITS[unit]}`;
};

export const formatDuration = (seconds: number) => {
  const total = Math.max(0, Math.floor(seconds));
  return total >= 86400 ? `${Math.floor(total / 86400)}d ${Math.floor(total % 86400 / 3600)}h`
    : total >= 3600 ? `${Math.floor(total / 3600)}h ${String(Math.floor(total % 3600 / 60)).padStart(2, '0')}m`
    : total >= 60 ? `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, '0')}s` : `${total}s`;
};

// The host shows run times as "Fri, 2 Oct 02:00" in the viewer's culture.
export const formatWhen = (date: Date) => date.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false });

const pad = (n: number) => String(n).padStart(2, '0');

// A small deterministic generator, so the sample looks the same on every load.
function sequence(seed: number) {
  let value = seed;
  return () => { value = (value * 1664525 + 1013904223) % 4294967296; return value / 4294967296; };
}

const RUN_COUNT = 30;
// Indexes counted back from the newest run.
const FAILED_RUN = 11;
const CANCELLED_RUN = 17;
const UNCHANGED_RUN = 5;

export function createSampleRuns(now: number): RunState[] {
  const random = sequence(7);
  const newest = new Date(now);
  newest.setHours(2, 0, 0, 0);
  if (newest.getTime() > now - 10 * MINUTE) newest.setDate(newest.getDate() - 1);
  const runs: RunState[] = [];
  for (let index = 0; index < RUN_COUNT - 1; index++) {
    const started = new Date(newest.getTime() - index * DAY + Math.floor(random() * 3) * MINUTE);
    const failed = index === FAILED_RUN, cancelled = index === CANCELLED_RUN, unchanged = index === UNCHANGED_RUN;
    const age = RUN_COUNT - 1 - index;
    const duration = failed ? 96 + Math.floor(random() * 40) : cancelled ? 61 + Math.floor(random() * 30) : unchanged ? 38 + Math.floor(random() * 12) : 205 + Math.floor(random() * 150);
    const files = 12100 + age * 14 + Math.floor(random() * 40);
    const processed = 4.55e9 + age * 1.3e7 + random() * 4e7;
    const stored = failed || cancelled || unchanged ? 0 : 2.4e7 + random() * 2.2e8;
    const success = !failed && !cancelled;
    const stamp = `${started.getFullYear()}${pad(started.getMonth() + 1)}${pad(started.getDate())}-${pad(started.getHours())}${pad(started.getMinutes())}`;
    const snapshot = success ? Math.floor(0x10000000 + random() * 0xefffffff).toString(16).slice(0, 8) : '';
    runs.push({
      id: `sample-run-${stamp}`, started: started.toISOString(), startedDisplay: formatWhen(started), type: 'Backup',
      result: failed ? 'Failed' : cancelled ? 'Canceled' : unchanged ? 'Unchanged' : 'Verified', success,
      durationSeconds: duration, durationDisplay: formatDuration(duration),
      files, filesDisplay: numberFormat.format(files), processedBytes: Math.round(processed), processedDisplay: formatBytes(processed),
      storedBytes: Math.round(stored), storedDisplay: formatBytes(stored), snapshot,
    });
  }
  const baseline = new Date(newest.getTime() - (RUN_COUNT - 1) * DAY + 5 * MINUTE);
  runs.push({
    id: 'sample-dry-run-baseline', started: baseline.toISOString(), startedDisplay: formatWhen(baseline), type: 'Dry run', result: 'Clean baseline', success: true,
    durationSeconds: 142, durationDisplay: formatDuration(142), files: 12100, filesDisplay: numberFormat.format(12100),
    processedBytes: 4.55e9, processedDisplay: formatBytes(4.55e9), storedBytes: 0, storedDisplay: formatBytes(0), snapshot: '',
  });
  return runs;
}

export function createSampleState(now = Date.now()): DashboardState {
  const history = createSampleRuns(now);
  const latest = history[0];
  const next = new Date(now);
  next.setHours(2, 0, 0, 0);
  if (next.getTime() <= now) next.setDate(next.getDate() + 1);
  const repositoryPath = 'D:\\Backups\\Rewindle-Demo';
  const action = (label: string, visible = true, help = '') => ({ enabled: true, visible, label, help });
  return {
    page: 'Protection', demo: true, preview: false, theme: 'System', motion: 'System',
    dark: false, reducedMotion: false, highContrast: false,
    updated: `Updated ${new Date(now).toLocaleTimeString(undefined, { hour12: false })}`, subtitle: '', dataError: '',
    status: {
      key: 'success', title: 'Backup verified',
      detail: `${latest.filesDisplay} files and ${latest.processedDisplay} are protected. The snapshot and a restore test file were checked.`,
      badge: 'VERIFIED', active: false, success: true, failure: false, cancelled: false, phaseIndex: 4, phaseLabel: 'Complete',
      progress: 1, estimated: false, runId: latest.id,
      files: latest.filesDisplay, bytes: latest.processedDisplay, speed: '—', elapsed: latest.durationDisplay, errors: '0',
      etaTitle: 'Next backup', eta: formatWhen(next), etaHint: '',
    },
    sources: [
      { path: 'C:\\Users\\you\\Documents', name: 'Documents', isCanary: false, exists: true, canRemove: true, detail: 'Protected  •  ~\\Documents' },
      { path: 'C:\\Users\\you\\Pictures', name: 'Pictures', isCanary: false, exists: true, canRemove: true, detail: 'Protected  •  ~\\Pictures' },
      { path: 'C:\\Users\\you\\Desktop', name: 'Desktop', isCanary: false, exists: true, canRemove: true, detail: 'Protected  •  ~\\Desktop' },
      { path: 'C:\\Users\\you\\Music', name: 'Music', isCanary: false, exists: true, canRemove: true, detail: 'Protected  •  ~\\Music' },
      { path: 'C:\\Users\\you\\Projects', name: 'Projects + restore canary', isCanary: true, exists: true, canRemove: false, detail: 'Required  •  ~\\Projects' },
    ],
    sourceStatus: 'Administrator approval is required to change protected folders.', sourceNotice: null, sourcePicker: null,
    sourceOperation: { active: false, stage: 'Idle', message: '', path: '' },
    history, historyTruncated: false, selectedRunId: latest.id,
    schedule: {
      summary: 'Daily at 02:00', nextRun: formatWhen(next),
      detail: 'Run missed backups • Wait for AC power',
    },
    repository: { path: repositoryPath, volume: '412 GiB free of 931 GiB  •  NTFS' },
    freshness: {
      title: 'Healthy', detail: `Last verified ${formatWhen(new Date(latest.started))}. Next scheduled ${formatWhen(next)}.`,
      state: 'Healthy', verifiedAt: new Date(Date.parse(latest.started) + latest.durationSeconds * 1000).toISOString(),
    },
    offsite: {
      title: 'Cloud verification not configured', detail: 'No cloud verification has been recorded for this backup.',
      evidence: '', kind: 'NotConfigured', checkedAt: '', providerConfirmed: false, restoreVerified: false,
    },
    recovery: {
      title: 'Restore Center ready', detail: `Plan 4e1b8c0a · generation 1 · ${repositoryPath}`,
      repairNeeded: false, repairMessage: '', repairState: '', repairBusy: false, repairPercent: null,
    },
    actions: {
      togglePreview: action('Preview animation'), backupNow: action('Back up now', true, 'Start a backup now. Windows will ask for approval.'),
      cancelBackup: action('Cancel backup'), addSource: action('Add folder'), retrySourceChange: action('Try again', false),
      dismissSourceChange: action('Dismiss', false), editSchedule: action('Edit schedule'), changeRepository: action('Change location'),
      repairRepository: action('Repair interrupted move', false), reviewChanges: action('Review changes', false), openRestore: action('Open Restore Center'),
      checkReadiness: action('Check recovery readiness'), viewRunDetails: action('View run details'), exportDiagnostics: action('Export diagnostics'),
    },
    runDetails: null, restoreFlow: null,
  };
}

// What "Open details" shows for a sample run. The text only imitates the shape of a real run's record.
export function createSampleRunDetails(run: RunState): RunDetailsState {
  const started = new Date(run.started);
  // The host lists events in local time, as 24-hour clock times.
  const at = (seconds: number) => {
    const when = new Date(started.getTime() + seconds * 1000);
    return `${pad(when.getHours())}:${pad(when.getMinutes())}:${pad(when.getSeconds())}`;
  };
  const failed = !run.success && run.result === 'Failed';
  const cancelled = run.result === 'Canceled';
  const events = failed ? [
    `${at(0)}  info   Backup started (5 protected locations)`,
    `${at(31)}  info   Reading C:\\Users\\you\\Documents`,
    `${at(88)}  error  Could not open a file that another program was using`,
    `${at(run.durationSeconds)}  error  Backup incomplete: 2 files were skipped`,
  ] : cancelled ? [
    `${at(0)}  info   Backup started (5 protected locations)`,
    `${at(44)}  info   Stop requested`,
    `${at(run.durationSeconds)}  info   Backup stopped safely. Earlier snapshots are unchanged.`,
  ] : [
    `${at(0)}  info   Backup started (5 protected locations)`,
    `${at(Math.round(run.durationSeconds * .78))}  info   ${run.filesDisplay} files read, ${run.storedDisplay} of new data saved`,
    `${at(Math.round(run.durationSeconds * .86))}  info   Snapshot ${run.snapshot || 'unchanged'} confirmed`,
    `${at(Math.round(run.durationSeconds * .93))}  info   Repository check passed`,
    `${at(run.durationSeconds)}  info   Restore test file recovered and verified`,
  ];
  return {
    id: run.id, type: run.type, result: run.result, success: run.success, started: run.started, startedDisplay: run.startedDisplay,
    durationDisplay: run.durationDisplay, filesDisplay: run.filesDisplay, processedDisplay: run.processedDisplay, storedDisplay: run.storedDisplay,
    phase: failed ? 'Backing up files' : cancelled ? 'Backing up files' : 'Complete', failureCode: failed ? 'source_read_error' : '', exitCode: failed ? '3' : '0',
    snapshotId: run.snapshot ? `${run.snapshot}${'0'.repeat(56)}` : '',
    failure: failed ? 'Two files could not be read because another program was using them.' : '',
    remediation: failed ? 'Close the program that was using the files and start another backup. Your earlier snapshots are unchanged.' : '',
    affectedPaths: failed ? ['C:\\Users\\you\\Documents\\Budget.xlsx', 'C:\\Users\\you\\Documents\\Notes.docx'] : [],
    events, hasLog: false,
  };
}
