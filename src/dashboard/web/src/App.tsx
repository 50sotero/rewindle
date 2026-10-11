import { Component, createContext, useCallback, useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ErrorInfo, type ReactNode } from 'react';
import { AnimatePresence, motion, MotionConfig } from 'motion/react';
import {
  ShieldCheck, History, Settings, RefreshCw, ArrowUpRight, ArrowRight,
  HardDrive, Clock3, LockKeyhole, Check, X, Play, Pause,
  Search, Sun, Moon, Monitor, CloudCheck, ArchiveRestore,
  Files, Gauge, Database, CircleAlert, CircleCheck, Activity, ListChecks, TriangleAlert, Info, OctagonAlert, Copy,
  Type as TextSize, Keyboard,
} from 'lucide-react';
import SidebarNav from '@/components/primitives/SidebarNav';
import TaskRows, { type TaskRow } from '@/components/primitives/TaskRows';
import FilterTable, { type TableRow, type FilterTableLabels, type FilterTableSelection, type FilterTableStatus } from '@/components/primitives/FilterTable';
import LoadingState from '@/components/primitives/LoadingState';
import ProtectedFolders, { type FolderView } from '@/components/primitives/ProtectedFolders';
import ProtectionHealth, { phaseName } from '@/components/primitives/ProtectionHealth';
import FolderPickerModal from '@/components/primitives/FolderPickerModal';
import RestoreFlowModal from '@/components/primitives/RestoreFlowModal';
import RunDetailsModal from '@/components/primitives/RunDetailsModal';
import { Button } from '@/components/atoms/Button';
import { Shimmer } from '@/components/atoms/Shimmer';
import { noticeHoldProps, useDashboard, type NoticeHold } from './useDashboard';
import { PROTECTED_COMMANDS, usableLocale, type Availability, type CommandName, type DashboardPage, type DashboardState, type MotionPreference, type Notice, type RunState, type ThemePreference } from './native-types';
import { PROJECT_URL } from './project';
import {
  attentionText, isCancelled, isProblem, isUnchanged, lastSuccessfulBackup, lastVerified, resolvedByText, resolvedRuns, resultHint, resultLabel,
  typeLabel, unresolvedRuns, usualSeconds, type Verified,
} from './runProblems';
import { formatClock, formatWhen, formatWhenAgo } from './when';
import { driveOf, heroConcern, heroTone } from './protectionTone';

type Send = (command: CommandName, payload?: Record<string, string | boolean>) => void;

// A component that throws while it renders would otherwise take the whole page with it and leave an empty window with nothing to
// click, and the host would go on sending state to a page that is gone. The boundaries below keep the damage as small as where it
// happened (a chart card, one page, one dialog, and last of all the app), say what the person can do about it, and draw the real
// content again as soon as the next state renders cleanly.
type CrashScope = 'app' | 'page' | 'card' | 'dialog';

// What can be copied for a bug report: the message and the first lines of the stack. It is never sent anywhere, and it holds no backup data.
const crashDetails = (error: Error, componentStack: string) => [
  'Rewindle web interface error',
  `${error.name}: ${error.message}`,
  ...(error.stack ?? '').split('\n').slice(1, 6).map(line => line.trim()),
  ...(componentStack ? ['Component stack:', ...componentStack.split('\n').filter(Boolean).slice(0, 6).map(line => line.trim())] : []),
].join('\n');

async function copyText(text: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(text); return true; } catch { /* the clipboard API can be refused; the older route below may not be */ }
  try {
    const field = document.createElement('textarea');
    field.value = text; field.setAttribute('readonly', ''); field.style.position = 'fixed'; field.style.opacity = '0';
    document.body.appendChild(field); field.select();
    const copied = document.execCommand('copy');
    field.remove();
    return copied;
  } catch { return false; }
}

function CrashNotice({ scope, label, error, componentStack, note, onRetry, onClose }: {
  scope: CrashScope; label: string; error: Error; componentStack: string; note?: string; onRetry?: () => void; onClose?: () => void;
}) {
  const titleId = useId();
  const [copied, setCopied] = useState<'idle' | 'done' | 'failed'>('idle');
  const details = useMemo(() => crashDetails(error, componentStack), [error, componentStack]);
  const copy = async () => { setCopied(await copyText(details) ? 'done' : 'failed'); window.setTimeout(() => setCopied('idle'), 2500); };
  const copyButton = <Button size="sm" onClick={copy}><Copy size={13} aria-hidden="true" />{copied === 'done' ? 'Copied' : copied === 'failed' ? 'Could not copy' : 'Copy details'}</Button>;
  const reload = <Button size="sm" variant={scope === 'app' ? 'primary' : 'secondary'} autoFocus={scope === 'app'} onClick={() => window.location.reload()}><RefreshCw size={13} aria-hidden="true" />Reload Rewindle</Button>;
  const technical = <details className="crash-details"><summary>Technical details</summary><pre>{details}</pre></details>;
  if (scope === 'card') {
    return <div className="surface crash-card is-compact" role="alert"><TriangleAlert size={18} aria-hidden="true" />
      <div><strong>This {label} can't be shown right now</strong><p>The rest of the page still works. It comes back on its own with the next update.</p></div>
      {onRetry && <Button size="sm" onClick={onRetry}>Try again</Button>}</div>;
  }
  if (scope === 'dialog') {
    return <div className="crash-overlay"><section className="surface crash-card" role="alertdialog" aria-modal="true" aria-labelledby={titleId}
      onKeyDown={event => { if (event.key === 'Escape' && onClose) { event.preventDefault(); onClose(); } }}>
      <span className="crash-icon"><TriangleAlert size={22} aria-hidden="true" /></span>
      <h2 id={titleId}>The {label} couldn't be shown</h2>
      <p>This window couldn't be shown. Close it and open it again. Nothing was changed, and a restore that is already running carries on by itself.</p>
      {note && <p className="crash-note" role="status">{note}</p>}
      <div className="crash-actions">{onClose && <Button size="sm" variant="primary" autoFocus onClick={onClose}>Close</Button>}{reload}{copyButton}</div>
      {technical}</section></div>;
  }
  if (scope === 'page') {
    return <section className="surface crash-card" role="alert" aria-labelledby={titleId}>
      <span className="crash-icon"><TriangleAlert size={22} aria-hidden="true" /></span>
      <h2 id={titleId}>This page couldn't be shown</h2>
      <p>The rest of Rewindle still works, so you can open another page. Your backups and settings are not affected.</p>
      <div className="crash-actions">{onRetry && <Button size="sm" variant="primary" onClick={onRetry}>Try again</Button>}{reload}{copyButton}</div>
      {technical}</section>;
  }
  return <div className="crash-screen" role="alert" aria-labelledby={titleId}>
    <span className="crash-icon"><TriangleAlert size={26} aria-hidden="true" /></span>
    <h1 id={titleId}>Something went wrong</h1>
    <p>Rewindle couldn't show this window. Your backups and settings are not affected, and scheduled backups keep running. Reload to carry on.</p>
    <div className="crash-actions">{reload}{copyButton}</div>
    {technical}
  </div>;
}

export class ErrorBoundary extends Component<{
  scope: CrashScope;
  /** What broke, as the notice names it ("restore window", "Activity page"). */
  label: string;
  /** The children are drawn again when this changes (a new state, another page, the dialog closing). */
  resetKey?: unknown;
  /** Asks the host for a fresh state; offered as Try again. */
  onRetry?: () => void;
  /** Closes a dialog on the host's side; offered as Close. */
  onClose?: () => void;
  /** Why that did not work, when the host said. */
  note?: string;
  children?: ReactNode;
}, { error: Error | null; componentStack: string }> {
  state = { error: null as Error | null, componentStack: '' };
  private lastLogged = '';
  static getDerivedStateFromError(error: unknown) {
    return { error: error instanceof Error ? error : new Error(String(error)) };
  }
  componentDidCatch(error: unknown, info: ErrorInfo) {
    // A failure that comes back with every state is logged once, not once a second.
    const signature = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    if (signature !== this.lastLogged) console.error(`[Rewindle] The ${this.props.label} stopped drawing.`, error, info.componentStack);
    this.lastLogged = signature;
    this.setState({ componentStack: info.componentStack ?? '' });
  }
  componentDidUpdate(previous: { resetKey?: unknown }) {
    if (this.state.error && !Object.is(previous.resetKey, this.props.resetKey)) this.setState({ error: null, componentStack: '' });
  }
  render() {
    const { error, componentStack } = this.state;
    if (!error) return this.props.children;
    const { scope, label, note, onRetry, onClose } = this.props;
    return <CrashNotice scope={scope} label={label} error={error} componentStack={componentStack} note={note} onClose={onClose}
      onRetry={onRetry ? () => { this.setState({ error: null, componentStack: '' }); onRetry(); } : undefined} />;
  }
}

/** The whole app in one boundary, for main.tsx: the last resort when nothing smaller caught the failure. */
export function AppErrorBoundary({ children }: { children?: ReactNode }) {
  return <ErrorBoundary scope="app" label="dashboard">{children}</ErrorBoundary>;
}
// Ctrl+1 to Ctrl+4 open the pages in this order (Settings is the fourth, in the sidebar's footer); the key handler in App does it.
const navItems = [
  { key: 'Protection', label: 'Protection', icon: <ShieldCheck size={18} />, shortcut: 'Control+1' },
  { key: 'Activity', label: 'Activity', icon: <History size={18} />, shortcut: 'Control+2' },
  { key: 'Restore', label: 'Restore', icon: <ArchiveRestore size={18} />, shortcut: 'Control+3' },
];
// These two mirror TelemetryFormat.FormatBytes and FormatDuration in the host (Telemetry.cs), so a figure the page
// formats itself reads like the strings the host sends: whole numbers for bytes, then 2, 1 or 0 decimals as the
// value grows, and days once a duration passes 24 hours.
const BYTE_UNITS = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
const bytes = (n: number, locale?: string) => {
  if (!Number.isFinite(n) || n < 0) return '—';
  let value = n, unit = 0;
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) { value /= 1024; unit++; }
  const digits = unit === 0 ? 0 : value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toLocaleString(locale, { minimumFractionDigits: digits, maximumFractionDigits: digits })} ${BYTE_UNITS[unit]}`;
};
const duration = (n: number) => {
  const seconds = Math.max(0, Math.floor(n)), minutes = String(Math.floor(seconds % 3600 / 60)).padStart(2, '0');
  return seconds >= 86400 ? `${Math.floor(seconds / 86400)}d ${Math.floor(seconds % 86400 / 3600)}h`
    : seconds >= 3600 ? `${Math.floor(seconds / 3600)}h ${minutes}m`
    : seconds >= 60 ? `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s` : `${seconds}s`;
};
type HistoryView = { query: string; sort: string; filter: FilterTableSelection };
type ActivityDateFilter = { from: string; to: string };

// How the history table and the trend charts group a run: finished and verified, stopped on request, or a problem (see runProblems).
const runStatus = (run: RunState): FilterTableStatus => run.success ? 'done' : isCancelled(run) ? 'progress' : 'todo';

const emptyHistoryView = (): HistoryView & ActivityDateFilter => ({ query: '', sort: 'newest', filter: 'all', from: '', to: '' });

const localDateKey = (value: string) => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
};

// A run's start the way the viewer's region writes it (see when.ts). The host sends one fixed day-month 24-hour pattern, so the
// page formats the ISO start itself.
const runWhen = (started: string, locale: string | undefined, fallback: string, weekday = true) => formatWhen(started, locale, fallback, { weekday });

// Formats every run time from its ISO start in one place, so the table, the sidebar, the charts and the run details agree.
function withRunDates(state: DashboardState): DashboardState {
  const locale = usableLocale(state.locale), details = state.runDetails;
  return {
    ...state,
    history: state.history.map(run => ({ ...run, startedDisplay: runWhen(run.started, locale, run.startedDisplay) })),
    runDetails: details ? { ...details, startedDisplay: details.started ? runWhen(details.started, locale, details.startedDisplay) : details.startedDisplay } : details,
  };
}

// A disabled action explains itself in place. `quiet` is for a page that already says why once (see
// busyNote): the reason stays linked for assistive technology and shows as a tooltip, but takes no
// room, so the page does not shift when a backup starts or ends. A disabled button receives no
// pointer events, so the tooltip sits on the wrapper.
function Action({ state, send, command, children, icon, primary = false, payload, size = 'sm', quiet = false }: {
  state: DashboardState; send: Send; command: CommandName; children?: React.ReactNode;
  icon?: React.ReactNode; primary?: boolean; payload?: Record<string, string | boolean>; size?: 'sm' | 'md' | 'xs'; quiet?: boolean;
}) {
  const action = state.actions[command];
  const helpId = useId();
  if (action?.visible === false) return null;
  const disabledReason = !action?.enabled ? action?.help || 'This action is currently unavailable.' : '';
  return <span className="context-action" title={quiet && disabledReason ? disabledReason : undefined}><Button size={size} variant={primary ? 'primary' : 'secondary'} disabled={!action?.enabled}
    aria-describedby={disabledReason ? helpId : undefined} title={action?.help}
    onClick={() => send(command, payload)}>{icon}{children ?? action?.label ?? command}</Button>
    {disabledReason && <span className={quiet ? 'sr-only' : 'action-disabled-reason'} id={helpId}>{disabledReason}</span>}</span>;
}

// Sample data and the animation preview turn off every page's actions; a running backup or a repair only
// the pages that hold schedule, location and folder controls.
const modeNote = (state: DashboardState) => state.demo || state.preview ? busyNote(state) : '';

// Why the schedule, location and folder controls are paused, said once for the whole page.
function busyNote(state: DashboardState, offline = false): string {
  if (state.demo) return 'You are viewing sample data. Backups and changes are turned off.';
  if (state.preview) return 'The animation preview is running. Real backups and changes are paused.';
  // The page lost the host and every control is off. The banner at the top says so; this says it once for the controls, so they do not each repeat it.
  if (offline) return 'Waiting to reconnect to Rewindle. Backup controls are paused. Scheduled backups are not affected.';
  if (state.status.active) return 'A backup is running. Schedule, location and folder changes unlock when it finishes.';
  if (state.recovery.repairNeeded) return 'Backups are paused until the backup location is repaired.';
  return '';
}

// `hint` says what a figure counts, as a tooltip, for the ones whose meaning is not in their label (it does not reach a keyboard or touch
// user, so Protection names its figures plainly and leaves it out). `bad` draws a figure that is a problem when it is not zero (errors) in
// the text-grade red; the label and the number still say it in words. `sub` is a line of words under the figure, for what it covers ("last 400 runs").
function Stat({ label, value, icon, hint, bad = false, sub }: { label: string; value: string; icon?: React.ReactNode; hint?: string; bad?: boolean; sub?: string }) {
  return <div title={hint} className={bad ? 'stat-bad' : undefined}><span className="stat-label">{icon}{label}</span><div style={{ overflow: 'hidden' }}>
    <motion.span className="stat-number" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      transition={{ duration: .28, ease: [.16, 1, .3, 1] }}>{value || '—'}</motion.span>
  </div>{sub && <span className="stat-sub">{sub}</span>}</div>;
}

// The status container is always present so a note that appears later is announced.
function Heading({ title, description, note = '', children }: { title: string; description: string; note?: string; children?: React.ReactNode }) {
  return <div className="section-head"><div><h1 className="page-title">{title}</h1><p className="page-description">{description}</p>
    <div role="status">{note && <p className="busy-note"><Info size={13} aria-hidden="true" />{note}</p>}</div></div>{children && <div className="actions">{children}</div>}</div>;
}

const scheduleNoticeIcons = { info: Info, success: CircleCheck, warning: TriangleAlert, error: CircleAlert };

// What became of the latest schedule change (waiting for Windows approval, saved and verified, cancelled, not confirmed). Its
// container is always present, so a notice that appears later is announced; the host lets it lapse after a short while.
function ScheduleNotice({ notice, className = '' }: { notice?: DashboardState['schedule']['notice']; className?: string }) {
  const Icon = notice ? scheduleNoticeIcons[notice.tone] ?? Info : Info;
  return <div role="status" className={className}>{notice && <p className={`source-notice schedule-notice ${notice.tone}`}><Icon size={14} aria-hidden="true" />{notice.text}</p>}</div>;
}

function Repairs({ state, send }: { state: DashboardState; send: Send }) {
  if (!state.recovery.repairNeeded) return null;
  const percent = state.recovery.repairPercent;
  // The host publishes one sentence as both the state line and the action's help; print it once.
  const repeated = !!state.actions.repairRepository?.help && state.actions.repairRepository.help === state.recovery.repairState;
  return <motion.div className="attention-note" initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}>
    <strong><CircleAlert size={14} className="inline mr-2" />Backups are paused: moving the backup location didn’t finish</strong>
    <p>{state.recovery.repairMessage}<br />{state.recovery.repairState}</p>
    {state.recovery.repairBusy ? <>
      <LoadingState label="Repairing backup location" variant="Orbit" live={false} />
      {percent != null && <div className="progress-rail repair-progress" role="progressbar" aria-label="Backup location repair progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(percent)}>
        <div className="progress-bar" style={{ width: `${Math.max(0, Math.min(100, percent))}%` }} /></div>}
    </> : <Action state={state} send={send} command="repairRepository" quiet={repeated} />}
  </motion.div>;
}

// True once the host is sure the backup service this dashboard reports on is not installed on this computer. A host that does not say (and
// the sample data) is taken to have found it.
const serviceMissing = (state: DashboardState) => state.setup?.engineFound === false;

// What a computer without the backup service sees in place of the pages that need it: one explanation, where Rewindle looked, what to do,
// and a line to paste into a bug report, instead of an "unavailable" in every widget. It only reads: nothing here changes anything, and
// "Try again" is the same refresh the toolbar has.
function SetupNotice({ state, send }: { state: DashboardState; send: Send }) {
  const titleId = useId();
  const [copied, setCopied] = useState<'idle' | 'done' | 'failed'>('idle');
  const setup = state.setup;
  if (!setup) return null;
  const report = [`Rewindle ${setup.appVersion || '(unknown version)'}`, setup.engine ? `${setup.engine}${setup.engineVersion ? ` ${setup.engineVersion}` : ''}` : '', setup.os, setup.webView2 ? `WebView2 ${setup.webView2}` : ''].filter(Boolean).join(' · ');
  const searched = setup.searchedConfigs && setup.searchedConfigs.length > 0 ? setup.searchedConfigs : [setup.expectedConfig || 'The installed backup configuration'];
  const copy = async () => { setCopied(await copyText(report) ? 'done' : 'failed'); window.setTimeout(() => setCopied('idle'), 2500); };
  return <section className="surface setup-notice" aria-labelledby={titleId}>
    <span className="setup-icon"><HardDrive size={22} aria-hidden="true" /></span>
    <div className="setup-copy">
      <h2 id={titleId}>Rewindle's backup service isn't installed</h2>
      <p>Rewindle shows the state of its backup service, which Rewindle Setup installs under Program Files. It wasn't found on this computer, so there is nothing to show yet. Nothing was changed.</p>
      <p>Install or repair the backup service (Rewindle Setup does both), then choose Try again. The README lists what Rewindle needs, under Requirements.</p>
      <dl className="setup-where">
        {setup.engine && <div><dt>Backup service</dt><dd>{setup.engine}{setup.engineChosenBy === '--engine' ? ' (chosen with --engine)' : ''}</dd></div>}
        {searched.map((path, index) => <div key={path}><dt>{index === 0 ? 'Looked for' : ''}</dt><dd>{path}</dd></div>)}
        {setup.stateFolder && <div><dt>Reads status from</dt><dd>{setup.stateFolder}</dd></div>}
      </dl>
      <div className="setup-actions">
        <Button size="sm" variant="primary" onClick={() => send('refresh')}><RefreshCw size={13} aria-hidden="true" />Try again</Button>
        <Button size="sm" onClick={copy}><Copy size={13} aria-hidden="true" />{copied === 'done' ? 'Copied' : copied === 'failed' ? 'Could not copy' : 'Copy details'}</Button>
      </div>
      <p className="setup-report">{report}</p>
    </div>
  </section>;
}

// The storage line under the backup location. A drive that said it is not ready is a warning (its own icon, and a color that is readable
// as text), not a muted line: the backups cannot be written until it is back. The host's own words for it ("D:\ • Volume unavailable")
// say nothing to do, so the page names the drive and keeps the host's words as a tooltip.
function VolumeLine({ repository }: { repository: DashboardState['repository'] }) {
  const missing = repository.volumeReady === false, drive = driveOf(repository.path);
  return <div className={`muted-copy volume-line${missing ? ' is-unavailable' : ''}`} title={missing ? repository.volume : undefined}>{missing && <><TriangleAlert size={13} aria-hidden="true" /><span className="sr-only">Needs attention: </span></>}{missing ? `The backup drive${drive ? ` (${drive})` : ''} isn’t connected` : repository.volume}</div>;
}

// `stale` is a page that has lost the host (see App's `connected`): what it shows is the last thing the host said, so it stops moving and
// is dimmed, and the banner above it says why.
function Protection({ state, send, folders, setFolders, stale, openRunDetails }: { state: DashboardState; send: Send; folders: FolderView; setFolders: (value: FolderView) => void; stale: boolean; openRunDetails: (runId: string) => void }) {
  // Without the backup service every widget below would say "unavailable" or "0"; the one explanation takes their place.
  if (serviceMissing(state)) return <><Heading title="Protection" description="Rewindle is waiting for a backup service to report on." /><SetupNotice state={state} send={send} /></>;
  const s = state.status;
  const tone = heroTone(state), concern = heroConcern(state);
  const locale = usableLocale(state.locale);
  // When the last verified backup finished, with its age in words ("yesterday at 2:03 AM"): how recent it is is the first thing to know.
  // Not drawn where the time cannot be trusted (the status could not be read, or the clocks disagree), the same rule the Local backup card follows.
  const verifiedKnown = !state.dataError && state.freshness.state !== 'ClockAnomaly';
  const verifiedAt = formatWhenAgo(state.freshness.verifiedAt, locale);
  // The host puts the same sentence in the hero and in the repair note above it; say it once.
  const repairDuplicate = state.recovery.repairNeeded && !!state.recovery.repairMessage && s.detail === state.recovery.repairMessage;
  // The last run passed but something else needs attention (overdue, paused, a change review): its steps
  // are shown as that run's results, not as proof that the backup is current.
  const lastRunOnly = s.success && tone !== 'success';
  // A run that ended early shows how far it got: earlier steps finished, the step it stopped on failed
  // or was cancelled, and later steps never ran. With no run to describe (first start, unreadable
  // status) the rows are a plain numbered guide instead of four claims of "Pending".
  const ended = s.failure || s.cancelled;
  const stepStatus = (i: number): TaskRow['status'] => s.success ? (lastRunOnly ? 'lastRun' : 'done')
    : s.active ? (i < s.phaseIndex ? 'done' : i === s.phaseIndex ? 'running' : 'pending')
    : ended && s.phaseIndex >= 0 ? (i < s.phaseIndex ? 'done' : i === s.phaseIndex ? (s.failure ? 'failed' : 'cancelled') : 'pending')
    : 'guide';
  const note = busyNote(state, stale), quiet = !!note;
  // The host's title already says "Estimated time remaining" when the progress is an estimate, and "Stopping safely: Please wait" while
  // a cancel finishes, so the suffix is only for a plain "Time remaining" that has a time in it.
  const etaEstimated = s.estimated && s.key !== 'cancelling' && !/estimated/i.test(s.etaTitle || '') && /\d/.test(s.eta || '');
  // Which run the four figures describe, which the page never said: the one in progress, or the latest finished one with the
  // time it started. The host sends the figures as display text, so errors are "any digit but zero" rather than a parsed number.
  const metricsRun = state.history.find(run => run.id === s.runId)?.startedDisplay;
  const metricsContext = state.preview ? 'Previewed live run' : s.active ? 'Current run'
    : !s.runId || !(s.success || s.failure || s.cancelled) ? 'No run recorded yet' : s.success ? 'Latest verified run' : 'Latest recorded run';
  const hasErrors = /[1-9]/.test(s.errors || '');
  // One name per step, the same ones the page uses everywhere else: the restore test restores a small test file after every backup. A row says
  // its state once (its mark and pill), so it has no second line of its own; what it does is one line in its details.
  const names = ['Back up files', 'Save the backup', 'Check the backup', 'Restore test'];
  const explanations = ['Reads your protected folders and copies what changed.', 'Saves an encrypted copy of your files as one backup.', 'Checks that the saved backup data is intact.', 'Restores a small test file after every backup and compares it with the original.'];
  const rows: TaskRow[] = names.map((label, i) => ({
    key: `backup-${i}`, label, step: i + 1,
    status: stepStatus(i),
    amount: '',
    details: [{ label: explanations[i], meta: '' }],
  }));
  // Which of the four steps a running backup is on. The title above already names the phase in the host's words, so the loader counts instead of repeating it.
  const stepNumber = Math.min(Math.max(s.phaseIndex, 0), 3) + 1;
  const reviewLabel = state.actions.reviewChanges?.label === 'Review changes' ? 'Confirm these changes' : undefined;
  const showTags = verifiedKnown || (stale && !!state.updated);
  const folderCount = state.sources.length;
  return <>
    <Heading title="Protection" description={`${folderCount} protected ${folderCount === 1 ? 'folder' : 'folders'} · ${state.schedule.summary}`} note={note}>
      {s.active && <Action state={state} send={send} command="cancelBackup" icon={<X size={13} />} quiet={quiet} />}
      <Action state={state} send={send} command="backupNow" primary size="md" icon={<Play size={13} fill="currentColor" />} quiet={quiet} />
    </Heading>
    {/* A backup that was asked for and did not start: the host's explanation used to be a tooltip on a button that was already back to normal. */}
    <div className="live-slot" role="status">{s.backupNote && !s.active && <p className="source-notice warning"><TriangleAlert size={14} aria-hidden="true" />{s.backupNote}</p>}</div>
    <Repairs state={state} send={send} />
    <section className={`surface surface-pad protection-hero ${s.active ? 'is-active' : ''} ${stale ? 'is-stale' : ''}`}>
      <div className="hero-grid">
        <div>
          <span className="eyebrow">Protection status</span>
          <div className="status-line">
            <motion.div key={s.key} initial={{ scale: .7, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} transition={{ type: 'spring', stiffness: 310, damping: 21 }}
              className={`status-emblem ${tone === 'success' ? '' : tone}`}>
              {tone === 'danger' ? <OctagonAlert size={22} /> : tone === 'active' ? <Activity size={23} /> : tone === 'success' ? <ShieldCheck size={24} /> : tone === 'neutral' ? <Info size={22} /> : s.success ? <TriangleAlert size={22} /> : <Clock3 size={22} />}
            </motion.div>
            {/* A heading, so the page's main status is a stop in the outline under its title, with the sections below at the same
                level. Not a live region: useAnnouncements (in App) speaks the run reaching its next phase or ending, and it does
                so on every page, where this hero exists only on Protection. */}
            <h2 className="status-title">{(tone === 'danger' || tone === 'warning') && <span className="sr-only">Needs attention: </span>}{s.title}</h2>
          </div>
          {s.detail && !repairDuplicate && <div className="status-detail">{s.detail}</div>}
          {/* What the colour above is about, when the host's title does not say it (see heroConcern). The container is always present, so a
              drive that is unplugged while the page is open is announced. */}
          <div role="status">{concern && <p className={`hero-concern ${concern.tone}`}>{concern.tone === 'danger' ? <OctagonAlert size={14} aria-hidden="true" /> : <TriangleAlert size={14} aria-hidden="true" />}<span>{concern.text}</span></p>}</div>
          {s.active ? <div className="progress-area">
            {/* No clock of its own: the loader counts from when it mounted, which is not when the run began (open the app 20 minutes in, or
                leave this page and come back, and it read 0s beside the host's real Elapsed). */}
            <div className="progress-copy"><LoadingState label={s.key === 'cancelling' ? 'Please wait' : `Step ${stepNumber} of 4`} live={false} showElapsed={false} /><strong>{Math.round(s.progress * 100)}%</strong></div>
            <div className="progress-rail" role="progressbar" aria-label={state.preview ? 'Preview backup progress' : 'Backup progress'} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(s.progress * 100)}><motion.div className="progress-bar" animate={{ width: `${Math.max(0, Math.min(100, s.progress * 100))}%` }} transition={{ duration: .65, ease: [.16, 1, .3, 1] }} /></div>
            <p className="muted-copy eta-line">{s.etaTitle || 'Time remaining'}: {s.eta || 'Calculating…'}{etaEstimated ? ' · estimated' : ''}</p>
            {/* Where the estimate comes from and when it expects to finish ("Likely around 14:35"): said on the page, not in a tooltip a keyboard or touch user never sees. */}
            {s.etaHint && <p className="muted-copy eta-hint">{s.etaHint}</p>}
          </div> : showTags && <div className="status-tags">
            {verifiedKnown && <span className="quiet-tag">{verifiedAt ? <ShieldCheck size={11} aria-hidden="true" /> : <Clock3 size={11} aria-hidden="true" />}{verifiedAt ? <>Last verified <time dateTime={state.freshness.verifiedAt}>{verifiedAt}</time></> : 'No verified backup yet'}</span>}
            {/* A page that lost the host shows the last thing it was told; this says when that was. */}
            {stale && state.updated && <span className="quiet-tag"><Clock3 size={11} aria-hidden="true" />{state.updated}</span>}
          </div>}
          <div className="info-action">
            {s.failure && !s.active && s.runId && <Button size="sm" disabled={!state.actions.viewRunDetails?.enabled} title={state.actions.viewRunDetails?.help || undefined} onClick={() => openRunDetails(s.runId)}><ListChecks size={13} aria-hidden="true" />See what happened</Button>}
            <Action state={state} send={send} command="reviewChanges" icon={<ListChecks size={13} />}>{reviewLabel}</Action>
          </div>
        </div>
        <div><TaskRows rows={rows} className="backup-tasks" labels={{ completed: s.success ? 'Verified' : 'Done', failed: 'Failed', pending: ended ? 'Not run' : 'Pending' }} /></div>
      </div>
      <div className="stats-grid">
        <Stat label="Files" value={s.files} icon={<Files size={12} />} />
        <Stat label="Data read" value={s.bytes} icon={<Database size={12} />} />
        {/* "Run time", not "Last run": the figure is a length of time, which "Last run" reads as the moment the run happened. */}
        <Stat label={s.active ? 'Throughput' : 'Run time'} value={s.active ? s.speed : s.elapsed} icon={s.active ? <Gauge size={12} /> : <Clock3 size={12} />} />
        {/* A status that could not be read has no count of errors: its "0" would say there were none. */}
        <Stat label={s.active ? 'Elapsed' : 'Errors'} value={s.active ? s.elapsed : s.unavailable ? '—' : s.errors} icon={s.active ? <Clock3 size={12} /> : <CircleAlert size={12} />} bad={!s.active && hasErrors} />
      </div>
      {!state.dataError && !s.unavailable && <p className="stats-caption">{metricsRun && !state.preview ? `${metricsContext} · ${metricsRun}` : metricsContext}</p>}
    </section>
    <div className="two-columns backup-destinations">
      <section className="surface surface-pad"><div className="info-heading"><Clock3 size={15} className="text-ink-3" />Next automatic backup</div>
        {/* A schedule Windows would not show is a problem with a way out, not a card that says "Unavailable" (Settings has the same). */}
        {state.schedule.error ? <div className="schedule-problem">
          <p className="muted-copy">Rewindle can’t read the Windows backup schedule just now. Nothing was changed.</p>
          <div className="actions"><Button size="xs" onClick={() => send('refresh')}><RefreshCw size={12} aria-hidden="true" />Try again</Button></div>
          <details className="inline-details"><summary>Technical details</summary><p className="muted-copy">{state.schedule.error}</p></details>
        </div> : <>
          <div className="info-main">{state.schedule.nextRunAt ? formatWhen(state.schedule.nextRunAt, locale, state.schedule.nextRun) : state.schedule.nextRun || 'No upcoming run'}</div><div className="muted-copy">{state.schedule.summary}</div>
        </>}
        <ScheduleNotice notice={state.schedule.notice} className="schedule-notice-slot" />
        <div className="info-action"><Action state={state} send={send} command="editSchedule" icon={<ArrowUpRight size={12} />} quiet={quiet} /></div></section>
      <section className="surface surface-pad"><div className="info-heading"><HardDrive size={15} className="text-ink-3" />Backup location</div>
        <div className="info-main">{state.repository.path || 'Location unavailable'}</div><VolumeLine repository={state.repository} />
        <div className="info-action"><Action state={state} send={send} command="changeRepository" icon={<ArrowUpRight size={12} />} quiet={quiet} /></div></section>
    </div>
    <ProtectionHealth state={state} send={send} quiet={quiet} />
    <ProtectedFolders state={state} send={send} view={folders} setView={setFolders} lockReason={note} />
  </>;
}

// Trend charts. Two small SVG charts of the run history: one marker per run that happened, and the nearest real
// run is named when you point at the chart or move along it with the arrow keys. They never interpolate a run
// that did not occur, and only a run that finished and verified is a value on the line: a failed or cancelled run
// stopped early, so it is marked on the baseline instead. Every color is a token, so they follow the theme and
// Windows High Contrast.
type ChartMetric = 'duration' | 'processed';
// `resolvedIds`: the runs that did not finish and a later backup put right; they are marked quietly, not in the color of something to act on.
type RunChartData = { runs: RunState[]; selectedId: string | null; onSelect: (runId: string) => void; locale?: string; resolvedIds: ReadonlySet<string> };
const RunChartContext = createContext<RunChartData>({ runs: [], selectedId: null, onSelect: () => undefined, resolvedIds: new Set() });

// `floor` is the y of the baseline; the labels under it sit in the 28px below.
const CHART_HEIGHT = 176;
const PLOT = { left: 60, right: 18, top: 14, floor: CHART_HEIGHT - 28, inset: 9 };
const DURATION_STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400];
const decimalStep = (rough: number) => { const base = 10 ** Math.floor(Math.log10(rough)), f = rough / base; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * base; };
const axisLabel = (value: number, metric: ChartMetric, locale?: string) => metric === 'duration' ? duration(value) : bytes(value, locale);
const rawValue = (run: RunState, metric: ChartMetric) => metric === 'duration' ? run.durationSeconds : run.processedBytes;
const shownValue = (run: RunState, metric: ChartMetric) => metric === 'duration' ? run.durationDisplay : run.processedDisplay;

// A value axis with a few round gridlines inside it. Bytes are scaled to one unit first, so the gridlines read 4.2, 4.4 and 4.6 GiB,
// not 4.5 billion bytes. When the values stay within half of the peak the axis starts at zero: starting it near the lowest value
// would draw a 1% change in size as a cliff, and a person reading it would worry about nothing. The tooltip has the exact figures.
function chartScale(values: number[], metric: ChartMetric) {
  const peak = Math.max(...values, 1);
  let unit = 0;
  while (metric === 'processed' && unit < BYTE_UNITS.length - 1 && peak >= 1024 ** (unit + 1)) unit++;
  const divisor = 1024 ** unit, scaled = values.map(value => value / divisor);
  const low = Math.min(...scaled), high = Math.max(...scaled);
  if (high <= 0) return { min: 0, max: divisor, ticks: [0] };
  const pad = Math.max((high - low) * .12, high * .02);
  const min = (high - low) / high < .5 ? 0 : Math.max(0, low - pad), max = high + pad, rough = (max - min) / 4;
  const step = metric === 'duration' ? DURATION_STEPS.find(candidate => candidate >= rough) ?? decimalStep(rough) : decimalStep(rough);
  const ticks: number[] = [];
  for (let n = Math.ceil(min / step); n * step <= max; n++) ticks.push(n * step * divisor);
  return { min: min * divisor, max: max * divisor, ticks };
}

// What sits on the baseline, said once for the note under the chart and (without the symbols) for the spoken summary: runs that did not
// finish (a filled diamond while any is still open, a hollow one once a later backup put each right) and runs stopped on request.
function markerNote(runs: RunState[], resolvedIds: ReadonlySet<string>, symbols = true): string {
  const failed = runs.filter(isProblem), open = failed.filter(run => !resolvedIds.has(run.id)).length, stopped = runs.filter(isCancelled).length;
  const parts: string[] = [];
  if (failed.length) {
    const fixed = failed.length - open;
    parts.push(`${symbols ? `${open ? '◆' : '◇'} ` : ''}${failed.length} ${failed.length === 1 ? 'run' : 'runs'} that did not finish${open === 0 ? `, ${failed.length === 1 ? 'put' : 'each put'} right by a later backup` : fixed > 0 ? ` (${fixed} put right by a later backup)` : ''}`);
  }
  if (stopped) parts.push(`${symbols ? '○ ' : ''}${stopped} cancelled`);
  return parts.length ? `On the baseline, left out of the trend: ${parts.join('; ')}.` : '';
}

function TrendChart({ runs, metric, selectedId, onSelect, locale, resolvedIds }: { runs: RunState[]; metric: ChartMetric; selectedId: string | null; onSelect: (runId: string) => void; locale?: string; resolvedIds: ReadonlySet<string> }) {
  const plotRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [active, setActive] = useState<number | null>(null);
  const uid = useId().replace(/[^a-zA-Z0-9_-]/g, ''), gradientId = `run-chart-fill-${uid}`, summaryId = `run-chart-summary-${uid}`;
  useLayoutEffect(() => {
    const element = plotRef.current;
    if (!element) return;
    const measure = () => setWidth(Math.floor(element.getBoundingClientRect().width));
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const { left, right, top, floor, inset } = PLOT, last = runs.length - 1;
  // The scale and the line come from verified runs only. A failed or cancelled run sits on the baseline at its own time.
  const model = useMemo(() => {
    const times = runs.map(run => Date.parse(run.started)), scale = chartScale(runs.filter(run => run.success).map(run => rawValue(run, metric)), metric);
    const start = times[0], span = Math.max(1, times[last] - start), inner = Math.max(1, width - left - right - 2 * inset), range = scale.max - scale.min || 1;
    const px = (time: number) => left + inset + (time - start) / span * inner;
    const py = (value: number) => top + (1 - (value - scale.min) / range) * (floor - top);
    return { scale, start, span, px, py, dots: runs.map((run, i) => ({ run, x: px(times[i]), y: run.success ? py(rawValue(run, metric)) : floor, status: runStatus(run), resolved: resolvedIds.has(run.id) })) };
  }, [runs, metric, width, last, resolvedIds]);
  const { scale, dots } = model;
  const plotted = dots.filter(dot => dot.run.success);
  const selectedIndex = runs.findIndex(run => run.id === selectedId);
  const resting = selectedIndex >= 0 ? selectedIndex : last, current = Math.min(last, active ?? resting);

  const shortSpan = model.span < 2 * 86_400_000;
  const dateFormat = useMemo(() => new Intl.DateTimeFormat(locale, shortSpan ? { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' } : { day: 'numeric', month: 'short' }), [shortSpan, locale]);
  const labelCount = width >= 760 ? 6 : width >= 520 ? 5 : width >= 360 ? 3 : 2;
  const xTicks = Array.from({ length: labelCount }, (_, i) => model.start + model.span * i / (labelCount - 1))
    .map(time => ({ x: model.px(time), text: dateFormat.format(time) }))
    .filter((tick, i, all) => i === 0 || tick.text !== all[i - 1].text);
  const yTicks = scale.ticks.map(tick => ({ y: model.py(tick), text: axisLabel(tick, metric, locale) })).filter(tick => tick.y >= top - 1 && tick.y <= floor + 1);
  const linePath = plotted.map((dot, i) => `${i ? 'L' : 'M'}${dot.x.toFixed(1)} ${dot.y.toFixed(1)}`).join(' ');
  const areaPath = plotted.length ? `${linePath} L${plotted[plotted.length - 1].x.toFixed(1)} ${floor} L${plotted[0].x.toFixed(1)} ${floor} Z` : '';

  const nearest = (clientX: number) => {
    const box = plotRef.current?.getBoundingClientRect();
    if (!box) return null;
    const x = clientX - box.left;
    return dots.reduce((best, dot, i) => Math.abs(dot.x - x) < Math.abs(dots[best].x - x) ? i : best, 0);
  };
  const choose = (index: number) => { setActive(index); onSelect(runs[index].id); };
  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    const move = (index: number) => { event.preventDefault(); setActive(Math.max(0, Math.min(last, index))); };
    switch (event.key) {
      case 'ArrowLeft': case 'ArrowDown': move(current - 1); break;
      case 'ArrowRight': case 'ArrowUp': move(current + 1); break;
      case 'Home': move(0); break;
      case 'End': move(last); break;
      case 'Enter': case ' ': event.preventDefault(); if (!event.repeat) choose(current); break;
    }
  };

  // The figures spoken for the chart count verified runs only; the others are named so a listener knows they exist.
  const verified = runs.filter(run => run.success);
  const extreme = (better: (a: number, b: number) => boolean) => verified.reduce((best, run) => better(rawValue(run, metric), rawValue(best, metric)) ? run : best, verified[0]);
  const summary = (metric === 'duration'
    ? `Backup time for the last ${verified.length} successful backups: latest ${verified[verified.length - 1].durationDisplay}, shortest ${shownValue(extreme((a, b) => a < b), metric)}, longest ${shownValue(extreme((a, b) => a > b), metric)}.`
    : `Data covered by the last ${verified.length} successful backups: latest ${verified[verified.length - 1].processedDisplay}, smallest ${shownValue(extreme((a, b) => a < b), metric)}, largest ${shownValue(extreme((a, b) => a > b), metric)}.`)
    + (markerNote(runs, resolvedIds, false) ? ` ${markerNote(runs, resolvedIds, false)}` : '');
  const title = metric === 'duration' ? 'How long each backup took' : 'How much data each backup covered';
  const tip = active !== null && width > 0 ? dots[current] : null;
  return <div className="chart-area">
    <div ref={plotRef} className="run-chart" role="slider" tabIndex={0} aria-label={title} aria-describedby={summaryId}
      aria-valuemin={1} aria-valuemax={runs.length} aria-valuenow={current + 1} aria-valuetext={`${runs[current].startedDisplay}, ${runs[current].success ? `${shownValue(runs[current], metric)}, ` : ''}${resultLabel(runs[current].result)}${resolvedIds.has(runs[current].id) ? ', put right by a later backup' : ''}`}
      onPointerDown={event => { const index = nearest(event.clientX); if (index !== null) setActive(index); }}
      onPointerMove={event => { const index = nearest(event.clientX); if (index !== null) setActive(index); }}
      onPointerLeave={event => setActive(event.currentTarget.matches(':focus-visible') ? resting : null)}
      onFocus={event => { if (event.currentTarget.matches(':focus-visible')) setActive(previous => previous ?? resting); }} onBlur={() => setActive(null)} onKeyDown={onKeyDown}
      onClick={event => { const index = nearest(event.clientX); if (index !== null) choose(index); }}>
      {width > 0 && <svg width={width} height={CHART_HEIGHT} aria-hidden="true">
        <defs><linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" style={{ stopColor: 'var(--accent)', stopOpacity: .22 }} /><stop offset="1" style={{ stopColor: 'var(--accent)', stopOpacity: 0 }} />
        </linearGradient></defs>
        {yTicks.map(tick => <g key={tick.y.toFixed(1)}>
          <line className="run-chart-grid" x1={left} x2={width - right} y1={tick.y} y2={tick.y} />
          <text className="run-chart-label" x={left - 8} y={tick.y} dy="0.34em" textAnchor="end">{tick.text}</text>
        </g>)}
        <line className="run-chart-axis" x1={left} x2={width - right} y1={floor} y2={floor} />
        {xTicks.map((tick, i) => <text key={i} className="run-chart-label" x={tick.x} y={CHART_HEIGHT - 8} textAnchor={tick.x <= left + inset + 1 ? 'start' : tick.x >= width - right - inset - 1 ? 'end' : 'middle'}>{tick.text}</text>)}
        {areaPath && <path d={areaPath} fill={`url(#${gradientId})`} />}
        <path className="run-chart-line" d={linePath} />
        {tip && <line className="run-chart-cursor" x1={tip.x} x2={tip.x} y1={top} y2={floor} />}
        {dots.map((dot, i) => <g key={dot.run.id} transform={`translate(${dot.x.toFixed(1)} ${dot.y.toFixed(1)})`}>
          {i === selectedIndex && <circle className="run-chart-selected" r={8} />}
          {dot.status === 'todo' ? <rect className={`run-chart-dot ${dot.resolved ? 'is-resolved' : 'is-failed'}`} x={-4} y={-4} width={8} height={8} transform={`rotate(45) scale(${tip && i === current ? 1.3 : 1})`} />
            : <circle className={`run-chart-dot${dot.status === 'progress' ? ' is-canceled' : ''}`} r={tip && i === current ? 5 : 3.5} />}
        </g>)}
      </svg>}
      {tip && <div className="run-chart-tip" style={{ left: Math.max(Math.min(tip.x, width - 78), 78), top: tip.y >= 60 ? tip.y - 60 : tip.y + 14 }} aria-hidden="true">
        <strong>{tip.run.startedDisplay}</strong><span>{tip.run.success ? `${shownValue(tip.run, metric)} · ${resultLabel(tip.run.result)}` : `${resultLabel(tip.run.result)}${tip.resolved ? ' · put right by a later backup' : ''} · not in the trend`}</span>
      </div>}
    </div>
    <p id={summaryId} className="sr-only">{summary} Use the left and right arrow keys to move between runs and Enter to select one.</p>
    <div className="sr-only"><table><caption>{title}</caption>
      <thead><tr><th scope="col">Started</th><th scope="col">{metric === 'duration' ? 'Duration' : 'Size covered'}</th><th scope="col">Result</th></tr></thead>
      <tbody>{runs.map(run => <tr key={run.id}><td>{run.startedDisplay}</td><td>{run.success ? shownValue(run, metric) : '—'}</td><td>{resultLabel(run.result)}</td></tr>)}</tbody></table></div>
  </div>;
}

// How many successful backups each chart follows.
const CHART_RUNS = 30;

function RunChart({ metric }: { metric: ChartMetric }) {
  const { runs: all, selectedId, onSelect, locale, resolvedIds } = useContext(RunChartContext);
  // The last 30 verified runs, oldest first, so the line reads left to right. A failed or cancelled run inside that span
  // stays on the chart as a marker, because it happened, but it is not a value: it feeds neither the line nor the figure above it.
  const { runs, verified, verifiedTotal } = useMemo(() => {
    const dated = all.filter(run => Number.isFinite(Date.parse(run.started))).sort((a, b) => Date.parse(a.started) - Date.parse(b.started));
    const done = dated.filter(run => run.success);
    const from = done.length > CHART_RUNS ? Date.parse(done[done.length - CHART_RUNS].started) : Number.NEGATIVE_INFINITY;
    return { runs: dated.filter(run => Date.parse(run.started) >= from), verified: done.slice(-CHART_RUNS), verifiedTotal: done.length };
  }, [all]);
  const latest = verified[verified.length - 1], newest = runs[runs.length - 1];
  if (!latest || verified.length < 2) {
    const [heading, text] = !newest ? ['No backups yet', 'Run history and trends will appear after your first backup.']
      : latest ? ['Your first successful backup is recorded', `${latest.startedDisplay} · ${shownValue(latest, metric)}. A trend appears after the next successful backup.`]
      : ['No successful backup yet', `Latest run: ${newest.startedDisplay} · ${resultLabel(newest.result)}. A trend appears once a backup succeeds.`];
    return <div className="surface first-run-summary"><History size={22} /><div><strong>{heading}</strong><p>{text}</p></div></div>;
  }
  // One sentence on what the line says, so the chart is not left to be read: the usual time, or whether the size is moving.
  const first = verified[0];
  const change = latest.processedBytes - first.processedBytes;
  const takeaway = metric === 'duration' ? `Latest backup · usually about ${duration(usualSeconds(verified))}`
    : Math.abs(change) < Math.max(1, first.processedBytes) * .01 ? `Latest backup · steady over these ${verified.length} backups`
    : `Latest backup · ${change > 0 ? 'up' : 'down'} ${bytes(Math.abs(change), locale)} since ${first.startedDisplay}`;
  const note = markerNote(runs, resolvedIds);
  return <div className="surface chart-card">
    <div className="chart-heading"><div><span className="eyebrow">{metric === 'duration' ? 'How long backups take' : 'How much data backups cover'}</span><div className="chart-value">{shownValue(latest, metric)}</div><p className="chart-takeaway">{takeaway}</p></div><span className="quiet-tag">{verifiedTotal > CHART_RUNS ? `last ${CHART_RUNS} successful backups` : `${verified.length} successful backups`}</span></div>
    <TrendChart runs={runs} metric={metric} selectedId={selectedId} onSelect={onSelect} locale={locale} resolvedIds={resolvedIds} />
    {note && <p className="chart-note">{note}</p>}
  </div>;
}

// A chart that fails to draw replaces only its own card, and is drawn again when the run history next changes.
function GuardedChart({ metric }: { metric: ChartMetric }) {
  const { runs } = useContext(RunChartContext);
  return <ErrorBoundary scope="card" label="chart" resetKey={runs}><RunChart metric={metric} /></ErrorBoundary>;
}
const DurationChart = () => <GuardedChart metric="duration" />;
const ProcessedChart = () => <GuardedChart metric="processed" />;

const HISTORY_COLUMNS = { task: 'When', date: 'Time taken', status: 'Result', owner: 'Files · size' };

// The host's last verified backup, in the form runProblems settles older problems with (see lastVerified).
const verifiedBackup = (state: DashboardState): Verified | undefined =>
  lastVerified(state.freshness, formatWhen(state.freshness.verifiedAt, usableLocale(state.locale)));

// "dayKey(6)" is the local date six days ago, as a date field writes it.
const dayKey = (daysBack: number) => { const day = new Date(); day.setDate(day.getDate() - daysBack); return localDateKey(day.toISOString()); };
// The ranges the date menu offers, as the number of days they reach back (today counts as the first).
const DATE_RANGES: [days: string, label: string][] = [['7', 'Last 7 days'], ['30', 'Last 30 days'], ['365', 'Last year']];

type ActivityProps = { state: DashboardState; send: Send; view: HistoryView & ActivityDateFilter; setView: (value: HistoryView & ActivityDateFilter) => void; openRunDetails: (runId: string) => void; openRestore: () => void; interactive: boolean };

// Without the backup service there is no history to list and nothing to start: the one explanation takes the page's place.
function ActivityPage(props: ActivityProps) {
  if (serviceMissing(props.state)) return <><Heading title="Activity" description="Rewindle is waiting for a backup service to report on." /><SetupNotice state={props.state} send={props.send} /></>;
  return <ActivityHistory {...props} />;
}

function ActivityHistory({ state, send, view, setView, openRunDetails, openRestore, interactive }: ActivityProps) {
  const { query, sort, filter, from, to } = view;
  const locale = usableLocale(state.locale);
  // The search field keeps focus when it is cleared (the clear button goes away with the text, and focus would fall to the page).
  const searchRef = useRef<HTMLInputElement>(null);
  // "Pick dates…" shows the two date fields; a range typed or kept from before shows them too (see rangeValue).
  const [pickDates, setPickDates] = useState(false);
  const historySignature = JSON.stringify(state.history);
  const history = useMemo(() => [...state.history].sort((a, b) => Date.parse(b.started) - Date.parse(a.started)), [historySignature]);
  const backupRuns = useMemo(() => history.filter(run => run.type === 'Backup'), [history]);
  const success = backupRuns.filter(run => run.success);
  // A failed or incomplete run that a later success put right is shown as resolved; only what nothing has put right asks for anything.
  // The host's own last verified backup counts as that success too, because the list only holds runs this app saw.
  const verified = useMemo(() => verifiedBackup(state), [state.freshness.state, state.freshness.verifiedAt, locale]);
  const resolved = useMemo(() => resolvedRuns(history, verified), [history, verified]);
  const unresolved = useMemo(() => unresolvedRuns(history, resolved), [history, resolved]);
  const attention = attentionText(unresolved, lastSuccessfulBackup(history, verified));
  const problems = useMemo(() => history.filter(isProblem).length, [history]);
  const failedBackups = backupRuns.filter(isProblem).length;
  const usual = usualSeconds(success);
  const latestBackup = success[0];
  const selected = state.history.find(run => run.id === state.selectedRunId);
  const selectedResolver = selected && resolved.get(selected.id);
  const dateRangeInvalid = !!from && !!to && from > to;
  const needle = query.trim().toLowerCase();
  const matchesDate = (run: RunState) => {
    if (!from && !to) return true;
    const startedDate = localDateKey(run.started);
    return !!startedDate && (!from || startedDate >= from) && (!to || startedDate <= to);
  };
  // The local date (2025-10-02) is searchable too, because the table's own label leaves the year out for this year's runs. The host's raw
  // result and the snapshot stay searchable though the page says them differently.
  const matchesView = (run: RunState) => matchesDate(run) && [run.id, run.startedDisplay, localDateKey(run.started), run.result, resultLabel(run.result), run.snapshot, run.type, typeLabel(run.type)].join(' ').toLowerCase().includes(needle);
  const inChip = (run: RunState) => filter === 'all' || filter === runStatus(run);
  const selectedVisible = !!selected && matchesView(selected) && inChip(selected);
  // With nothing selected, "Open details" falls back to the newest run the table shows, so the first visit has no
  // dead button. The host only enables its action once a run is selected, but it takes a run id and selects that run itself.
  const newest = selected ? undefined : history.find(run => matchesView(run) && inChip(run));
  const target = selected ?? newest;
  const detailsAction = state.actions.viewRunDetails;
  const canOpen = !!target && !!detailsAction && (selected ? detailsAction.enabled : interactive);
  const rows: TableRow[] = useMemo(() => {
    const filtered = history.filter(matchesView);
    filtered.sort((a, b) => sort === 'duration' ? b.durationSeconds - a.durationSeconds : sort === 'size' ? b.processedBytes - a.processedBytes : sort === 'oldest' ? Date.parse(a.started) - Date.parse(b.started) : Date.parse(b.started) - Date.parse(a.started));
    return filtered.map(run => {
      const by = resolved.get(run.id);
      // A run that did not finish has no figures worth showing when it counted nothing: a dash says so, "0 B · 0 files" reads as an empty backup.
      return { id: run.id, task: `${run.startedDisplay}${run.type !== 'Backup' ? ` · ${typeLabel(run.type)}` : ''}`, date: run.durationDisplay, status: runStatus(run), statusLabel: resultLabel(run.result), statusTitle: resultHint(run.result),
        owner: run.success || run.files > 0 || run.processedBytes > 0 ? `${run.filesDisplay} files · ${run.processedDisplay}` : '—',
        ...(by ? { quiet: true, statusNote: 'Resolved', statusHint: `${resolvedByText(by)}, so this run needs nothing from you.` } : {}) };
    });
  }, [history, resolved, query, sort, from, to]);
  // "Problems" only while something is still open; once a later backup put every one right they are a record, and the chip says so.
  const labels = useMemo<FilterTableLabels>(() => ({
    columns: HISTORY_COLUMNS,
    filters: { all: 'All runs', done: 'Successful', todo: unresolved.length ? 'Problems' : 'Resolved', progress: 'Cancelled' },
    openRow: 'Open details', filtersName: 'Show runs by result',
  }), [unresolved.length]);
  // Sorting is not a filter (it never hides a run), so only the search, the dates and the result chip count as filtering and are
  // cleared by "Show all runs"; the order stays as it was chosen.
  const filtering = !!query.trim() || !!from || !!to || filter !== 'all';
  const shown = rows.filter(row => filter === 'all' || row.status === filter).length;
  const clearFilters = useCallback(() => {
    setView({ ...view, query: '', from: '', to: '', filter: 'all' });
    setPickDates(false);
    searchRef.current?.focus();
  }, [setView, view]);
  // The table is large and the host publishes state every second, so everything it receives is kept stable
  // between publishes and it only re-renders when the runs, the filter or the selection change.
  const onFilterChange = useCallback((next: FilterTableSelection) => setView({ ...view, filter: next }), [setView, view]);
  const selectRow = useCallback((row: TableRow) => send('selectRun', { runId: row.id ?? '' }), [send]);
  const openRow = useCallback((row: TableRow) => openRunDetails(row.id ?? ''), [openRunDetails]);
  // Only drawn while there is history to filter (the first-run state below has its own), so this is always about filters that match nothing.
  const emptyContent = useMemo(() => {
    const [title, text] = dateRangeInvalid ? ['Choose a valid date range', 'The start date must be on or before the end date.']
      : filter === 'todo' ? ['No problems found', 'None of the runs shown failed or was incomplete.']
      : filter === 'progress' ? ['No cancelled runs', 'None of the runs shown was cancelled.']
      : filter === 'done' ? ['No successful runs', 'None of the runs shown succeeded.']
      : ['No runs match these filters', 'Try another search, adjust the dates, or show all runs.'];
    return <div className="empty-state"><Search size={22} aria-hidden="true" /><strong>{title}</strong><p>{text}</p><Button size="sm" onClick={clearFilters}>Show all runs</Button></div>;
  }, [dateRangeInvalid, filter, clearFilters]);
  // What the banner says about the window of runs the host keeps; the number is the host's own (see historyLimit).
  const limit = state.historyLimit;
  const capNote = limit
    ? `Showing the newest ${limit.toLocaleString(locale)} runs. Older runs have rolled off this list, but every backup is still saved in your backup location. Restore lists every backup you can recover from.`
    : 'The app keeps the newest 400 run records for fast loading. This does not remove backup snapshots.';
  const summary = filtering ? `Showing ${shown.toLocaleString(locale)} of ${history.length.toLocaleString(locale)} runs` : `${history.length.toLocaleString(locale)} ${history.length === 1 ? 'run' : 'runs'}`;
  const resolvedIds = useMemo<ReadonlySet<string>>(() => new Set(resolved.keys()), [resolved]);
  const chart = useMemo<RunChartData>(() => ({ runs: backupRuns, selectedId: state.selectedRunId, onSelect: runId => send('selectRun', { runId }), locale, resolvedIds }), [backupRuns, state.selectedRunId, send, locale, resolvedIds]);
  // A trend needs two successful backups; failed and cancelled ones are only marked on it.
  const trend = success.length > 1;
  // The date menu shows a range it knows, or "Pick dates…" with the two fields; dates left over from before show as picked.
  const rangeValue = !from && !to ? 'any' : !to ? DATE_RANGES.find(([days]) => from === dayKey(Number(days) - 1))?.[0] ?? 'custom' : 'custom';
  const showDates = pickDates || rangeValue === 'custom';
  const onRangeChange = (value: string) => {
    setPickDates(value === 'custom');
    if (value !== 'custom') setView({ ...view, from: value === 'any' ? '' : dayKey(Number(value) - 1), to: '' });
  };
  // What the first tile adds to its number, so "79" is not left to read as a score out of something: what, if anything, is still open.
  const successSub = unresolved.length ? `${unresolved.length} ${unresolved.length === 1 ? 'needs' : 'need'} a look`
    : failedBackups ? `${failedBackups} did not finish; ${failedBackups === 1 ? 'a later backup put it' : 'later backups put them'} right`
    : success.length ? 'None have failed' : undefined;
  if (history.length === 0) {
    return <>
      <Heading title="Activity" description="See every backup Rewindle has made, and what happened when one did not finish." note={modeNote(state)} />
      <div className="surface empty-state history-empty"><History size={22} aria-hidden="true" /><strong>No backups yet</strong><p>Your backups will be listed here once the first one has run. You can start one now.</p>
        <Action state={state} send={send} command="backupNow" primary size="md" icon={<Play size={13} fill="currentColor" />} quiet={!!modeNote(state)} /></div>
    </>;
  }
  return <>
    <Heading title="Activity" description="See every backup Rewindle has made, and what happened when one did not finish." note={modeNote(state)} />
    <div className="activity-metrics">
      <div className="surface"><Stat label="Successful backups" value={backupRuns.length ? String(success.length) : 'No backups yet'} icon={<ShieldCheck size={13} />} sub={successSub} /></div>
      <div className="surface"><Stat label="Usual backup time" value={usual ? duration(usual) : '—'} icon={<Clock3 size={13} />} sub={latestBackup ? `Last one: ${latestBackup.durationDisplay}` : undefined} /></div>
      <div className="surface"><Stat label="New data in last backup" value={latestBackup ? (isUnchanged(latestBackup.result) ? 'Nothing new' : latestBackup.storedDisplay) : '—'} icon={<Database size={13} />}
        sub={latestBackup ? (isUnchanged(latestBackup.result) ? 'Your files matched the previous backup' : 'Added to your backup location') : undefined} /></div>
    </div>
    <section>
      <div className="section-toolbar"><div><div className="history-heading"><h2 className="section-title">Run history</h2><span className="history-count" role="status">{summary}</span></div>
        <p className="history-scope-note">Click a run to select it. Double-click it, or press Enter, to see its details. Runs that finish while Rewindle is closed can be missing from this list.</p></div>
        <div className="history-tools">
          <label className="search-field"><Search size={13} aria-hidden="true" /><input ref={searchRef} aria-label="Search backup history" placeholder="Search by date or result…" value={query} onChange={event => setView({ ...view, query: event.target.value })}
            onKeyDown={event => { if (event.key === 'Escape' && query) { event.preventDefault(); event.stopPropagation(); setView({ ...view, query: '' }); } }} />{query && <button aria-label="Clear history search" onClick={() => { setView({ ...view, query: '' }); searchRef.current?.focus(); }}><X size={13} /></button>}</label>
          <select className="sort-field" aria-label="Show runs from" value={showDates ? 'custom' : rangeValue} onChange={event => onRangeChange(event.target.value)}>
            <option value="any">Any time</option>{DATE_RANGES.map(([days, label]) => <option key={days} value={days}>{label}</option>)}<option value="custom">Pick dates…</option></select>
          {showDates && <>
            <label className="date-filter"><span>From</span><input type="date" aria-label="Show runs from date" value={from} max={to || undefined} onChange={event => setView({ ...view, from: event.target.value })} /></label>
            <label className="date-filter"><span>To</span><input type="date" aria-label="Show runs through date" value={to} min={from || undefined} onChange={event => setView({ ...view, to: event.target.value })} /></label></>}
          <select className="sort-field" aria-label="Sort backup history" value={sort} onChange={event => setView({ ...view, sort: event.target.value })}><option value="newest">Newest first</option><option value="oldest">Oldest first</option><option value="duration">Longest first</option><option value="size">Largest first</option></select>
          {/* Always in the toolbar, hidden (so out of the tab order too) while there is nothing to clear: it appearing and going shifted the other fields. */}
          <Button size="xs" variant="quiet" style={{ visibility: filtering ? 'visible' : 'hidden' }} onClick={clearFilters}>Clear filters</Button>
        </div></div>
      {state.historyTruncated && <div className="history-cap-note" role="note"><Info size={13} aria-hidden="true" /><span>{capNote}</span><Button size="xs" variant="quiet" onClick={openRestore}>Open Restore</Button></div>}
      {/* What the history asks for: nothing while every problem was put right by a later backup, which is said once the problems are
          the ones shown; otherwise the runs since the last successful backup, with a way to try again and the way to the newest one's details. */}
      {attention ? <div className="history-cap-note is-warning" role="note"><TriangleAlert size={13} aria-hidden="true" /><span>{attention} Try Back up now. If it fails again, open its details to see why.</span>
        <Action state={state} send={send} command="backupNow" primary size="xs" icon={<Play size={12} fill="currentColor" />} quiet />
        <Button size="xs" variant="secondary" disabled={!interactive || !detailsAction} title={interactive ? detailsAction?.help : undefined} onClick={() => openRunDetails(unresolved[0].id)}><ArrowRight size={12} />Open details</Button></div>
        : filter === 'todo' && problems > 0 && <div className="history-cap-note is-resolved" role="note"><CircleCheck size={13} aria-hidden="true" /><span>Nothing needs doing. A later backup succeeded after each of these runs, so they stay here only as a record of what happened.</span></div>}
      <FilterTable className="history-table" rows={rows} labels={labels}
        selectedRowId={state.selectedRunId} filter={filter} onFilterChange={onFilterChange} tableLabel="Backup run history"
        onRowClick={selectRow} onRowOpen={openRow} emptyContent={emptyContent} />
      <div className="selection-bar"><div><strong>{selected ? `${typeLabel(selected.type)} · ${selected.startedDisplay}` : newest ? `Newest run · ${newest.startedDisplay}` : 'No run to open'}</strong><span>{selected ? `${resultLabel(selected.result)}${selectedResolver ? ` · ${resolvedByText(selectedResolver)}` : ''}${selectedVisible ? '' : ' · Hidden by current filters'}` : newest ? resultLabel(newest.result) : 'Adjust the search, dates or filters to see runs.'}</span></div><Button size="sm" variant="secondary" disabled={!canOpen} title={canOpen ? undefined : detailsAction?.help} onClick={() => target && openRunDetails(target.id)}><ArrowRight size={13} />Open details</Button></div>
    </section>
    {/* Both charts side by side, with no pager to hide half of them. Fewer than two successful backups draws one card that says why. */}
    <RunChartContext.Provider value={chart}><section className="trends-section"><h2 className="section-title">Backup trends</h2>
      {trend ? <div className="two-columns"><DurationChart /><ProcessedChart /></div> : <DurationChart />}</section></RunChartContext.Provider>
  </>;
}

function RestorePage({ state: shown, send }: { state: DashboardState; send: Send }) {
  const note = modeNote(shown);
  // The sample data walks the whole flow on invented backups (demo/restoreDemo.ts), so this page's button is the one the sample leaves on.
  const state: DashboardState = shown.demo && shown.actions.openRestore
    ? { ...shown, actions: { ...shown.actions, openRestore: { ...shown.actions.openRestore, enabled: true, help: 'Choose a backup and restore files into a separate folder. Windows will ask for your permission.' } } }
    : shown;
  const description = 'Get back files you deleted, lost or changed. Rewindle copies them from a backup into a new folder; your current files are never touched.';
  if (serviceMissing(state)) return <><Heading title="Restore" description={description} note={note} /><SetupNotice state={state} send={send} /></>;
  const { recovery } = state;
  const ready = !!state.actions.openRestore?.enabled;
  // What the page offers while restoring is not available. A host that does not say is taken to need a fresh read (an unavailable
  // restore with nothing running and no repair to make); the repair banner above has its own button, and the sample note says why itself.
  const next = recovery.next ?? (ready || recovery.repairNeeded || note ? '' : 'refresh');
  // Waiting is not a problem (it unlocks by itself) and a sample or preview is paused on purpose, so only the rest is drawn as one.
  const tone = ready || note ? '' : next === 'wait' ? 'active' : 'warning';
  // The backup to look at first: the newest one that saved something. The dialog marks it "Newest" in its list.
  const newest = ready ? state.history.filter(run => run.success && run.snapshot).reduce<RunState | null>((best, run) => !best || Date.parse(run.started) > Date.parse(best.started) ? run : best, null) : null;
  // The earlier edition (and an older engine) asks Windows for every protected step; a newer one asks once. Only the earlier one is certain from here.
  const permission = state.setup?.engineProfile === 'legacy'
    ? 'On this computer Windows asks for your permission each time Rewindle opens your backup: once to list your backups, once for each folder you open, and once to restore. Choose Yes each time.'
    : 'Windows asks for your permission (a shield prompt) before Rewindle reads your backup. Choose Yes.';
  return <><Heading title="Restore" description={description} note={note} />
    <Repairs state={state} send={send} />
    <div className="restore-layout"><section className="surface"><div className={`status-emblem ${tone}`}><ArchiveRestore size={24} aria-hidden="true" /></div>
      <h2>{recovery.title}</h2><p className="muted-copy">{recovery.repairNeeded ? 'Restore opens once the repair above is finished.' : recovery.detail}</p>
      {newest && <p className="muted-copy">Newest backup to restore from: <strong>{newest.startedDisplay}</strong>.</p>}
      <div className="actions" style={{ marginTop: 22 }}><Action state={state} send={send} command="openRestore" primary size="md" icon={<ArrowUpRight size={14} />} quiet />
        {next === 'refresh' && <Button size="md" variant="secondary" onClick={() => send('refresh')}><RefreshCw size={14} aria-hidden="true" />Try again</Button>}</div>
      {ready && <p className="muted-copy restore-permission">{permission}</p>}
      <div className="restore-readiness"><Action state={state} send={send} command="checkReadiness" quiet />
        <p>Makes sure your backups can be opened and restored. It opens in its own window, only reads, and changes nothing.</p></div>
    </section><div><h2 className="section-title" style={{ marginBottom: 16 }}>How restoring works</h2><ol className="restore-howto">
      <li><strong>Choose a backup</strong><span>Pick the newest one from before the files were lost.</span></li>
      <li><strong>Choose files</strong><span>Open folders and tick what you need, or restore everything.</span></li>
      <li><strong>Choose a folder</strong><span>A new or empty folder. Your current files are never replaced.</span></li>
      <li><strong>Review and restore</strong><span>Rewindle copies your files and checks each one.</span></li>
    </ol></div></div>
  </>;
}

// The three themes in the order the Settings picker lists them and the toolbar button steps through them (System, Light, Dark, and
// round again), so the button never replaces "follow Windows" without a way back.
const THEME_STEPS: { name: ThemePreference; label: string; Icon: typeof Sun }[] = [
  { name: 'System', label: 'System', Icon: Monitor }, { name: 'Daylight', label: 'Light', Icon: Sun }, { name: 'Midnight', label: 'Dark', Icon: Moon }];
const MOTION_STEPS: { name: MotionPreference; label: string }[] = [{ name: 'System', label: 'Follow Windows' }, { name: 'Full', label: 'Always on' }, { name: 'Reduced', label: 'Reduced' }];
const ISSUES_URL = `${PROJECT_URL}/issues`;

// Copies a link: the page cannot open one (the host refuses every navigation away from the app), so the person pastes it into a
// browser. The button says it worked, and a screen reader is told too.
function CopyLinkButton({ text, label = 'Copy link' }: { text: string; label?: string }) {
  const [copied, setCopied] = useState<'idle' | 'done' | 'failed'>('idle');
  const copy = async () => { setCopied(await copyText(text) ? 'done' : 'failed'); window.setTimeout(() => setCopied('idle'), 2500); };
  return <><Button size="sm" onClick={copy}><Copy size={13} aria-hidden="true" />{copied === 'done' ? 'Copied' : copied === 'failed' ? 'Could not copy' : label}</Button>
    <span className="sr-only" role="status">{copied === 'done' ? 'Link copied' : copied === 'failed' ? 'The link could not be copied' : ''}</span></>;
}

function SettingsPage({ state, send, stale = false }: { state: DashboardState; send: Send; stale?: boolean }) {
  const motionDescription = state.motion === 'Full'
    ? 'Animated transitions and feedback are always on, even when Windows reduces animation. High contrast always reduces motion.'
    : state.motion === 'Reduced'
      ? 'Movement is kept to a minimum, while progress and status updates stay visible.'
      : `Follows your Windows animation setting, which is currently ${state.reducedMotion ? 'reduced' : 'on'}.`;
  const note = busyNote(state, stale), quiet = !!note, missing = serviceMissing(state);
  return <><Heading title="Settings" description="Where your backups go, when they run, and how Rewindle looks." note={note} />
    <Repairs state={state} send={send} />
    {/* Without the backup service the plan, the schedule and the problem report have nothing to act on; the appearance settings below
        still work, and the one explanation stands where the rest would be. Every row has the same two slots, the words
        (`setting-copy`) and what they are controlled with (`setting-controls`), which sits at the bottom of its card, so the two
        pickers in a row of cards line up whatever the length of the text above them. */}
    {missing ? <SetupNotice state={state} send={send} /> :
    <section className="settings-section"><h2 className="section-title">Backup plan</h2><div className="settings-grid">
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><HardDrive size={15} />Backup location</h3><p className="muted-copy path-copy">{state.repository.path}</p><VolumeLine repository={state.repository} /></div><div className="setting-controls"><Action state={state} send={send} command="changeRepository" quiet={quiet} /></div></section>
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><Clock3 size={15} />Automatic backups</h3><p className="info-main">{state.schedule.summary}</p>
        {/* An unreadable schedule is a problem to explain, not a summary: the reason the host reports goes under Details. */}
        {state.schedule.error ? <div className="attention-note schedule-problem" role="alert">
          <strong><CircleAlert size={14} className="inline mr-2" />The schedule could not be read</strong>
          <p>Rewindle could not read the Windows backup schedule just now. Nothing was changed. Try again, or open Details to see why.</p>
          <details className="inline-details"><summary>Details</summary><p className="muted-copy">{state.schedule.error}</p></details>
          <Button size="sm" onClick={() => send('refresh')}><RefreshCw size={13} />Try again</Button>
        </div> : <><p className="muted-copy">Next: {formatWhen(state.schedule.nextRunAt, usableLocale(state.locale), state.schedule.nextRun)}</p><details className="inline-details"><summary>Run conditions</summary><p className="muted-copy">{state.schedule.detail}</p></details></>}
        <ScheduleNotice notice={state.schedule.notice} className="schedule-notice-slot" /></div><div className="setting-controls"><Action state={state} send={send} command="editSchedule" quiet={quiet} /></div></section>
    </div><div className="settings-notes">
      <p className="muted-copy settings-note"><LockKeyhole size={12} aria-hidden="true" />Windows asks for your permission before the location or schedule changes.</p>
      {/* Closing the window sends it to the tray (the host says so once, in a balloon, and never again). */}
      <p className="muted-copy settings-note"><Info size={12} aria-hidden="true" />Closing this window never stops a running backup. Rewindle keeps running in the notification area, where it shows your backup status, and scheduled backups run either way. To quit Rewindle, right-click its tray icon and choose Exit Rewindle.</p>
    </div></section>}
    {/* The backup health cards (local backup, restore test, off-site copy) are on Protection, where the person looks for them; they were
        also here, which said everything twice. */}
    <section className="settings-section"><h2 className="section-title">Appearance</h2><div className="settings-grid">
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><Sun size={15} />Theme</h3><p className="muted-copy">Follow your system, or choose a light or dark theme.</p>{state.highContrast && <p className="muted-copy">Windows High Contrast is on and sets the colors for now. Your choice is saved and applies when High Contrast is turned off.</p>}</div><div className="setting-controls"><div className="theme-picker" role="group" aria-label="Theme">
        {THEME_STEPS.map(({ name, label, Icon }) => <button key={name} className="theme-choice" aria-pressed={state.theme === name} onClick={() => send('setTheme', { theme: name })}>
          {state.theme === name && <motion.div className="theme-highlight" layoutId="theme-thumb" transition={{ type: 'spring', stiffness: 440, damping: 34 }} />}<span><Icon size={13} />{label}</span></button>)}
      </div></div></section>
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><Activity size={15} />Animations</h3><p className="muted-copy">{motionDescription}</p></div><div className="setting-controls"><div className="motion-picker" role="group" aria-label="Animations">{MOTION_STEPS.map(({ name, label }) => <button key={name} className="motion-choice" aria-pressed={state.motion === name} onClick={() => send('setMotion', { motion: name })}>{state.motion === name && <motion.div className="motion-highlight" layoutId="motion-thumb" transition={{ type: 'spring', stiffness: 440, damping: 34 }} />}<span>{label}</span></button>)}</div>
        {/* The preview fakes a running backup and pauses the real controls, so it is for the sample data (screenshots, trying the interface), not for someone looking after their backups. */}
        {state.demo && <Action state={state} send={send} command="togglePreview" icon={state.preview ? <Pause size={12} /> : <Play size={12} />}>{state.preview ? 'Stop preview' : 'Preview animations'}</Action>}</div></section>
      {/* The host answers each press with the size it reached ("Text size 125%") and keeps it for the next launch. */}
      <section className="surface setting-row wide-row"><div className="setting-copy"><h3 className="info-heading"><TextSize size={15} />Text size</h3><p className="muted-copy">Make everything larger or smaller. Rewindle keeps your choice the next time it opens.</p></div><div className="setting-controls">
        <Button size="sm" onClick={() => send('setZoom', { zoom: 'out' })}>Smaller</Button><Button size="sm" onClick={() => send('setZoom', { zoom: 'reset' })}>Normal size</Button><Button size="sm" onClick={() => send('setZoom', { zoom: 'in' })}>Larger</Button></div></section>
    </div></section>
    <section className="settings-section"><h2 className="section-title">Help and about</h2><div className="settings-grid">
      {!missing && <section className="surface setting-row wide-row"><div className="setting-copy"><h3 className="info-heading"><ListChecks size={15} />Problem report</h3>
        <p className="muted-copy">Save a report to send when you need help. It lists what Rewindle saw, with personal file names and account details removed.</p>
        <p className="muted-copy">To get help, attach it to a new issue at <span className="path-copy">{ISSUES_URL.replace(/^https?:\/\//, '')}</span>.</p></div>
        <div className="setting-controls"><Action state={state} send={send} command="exportDiagnostics" icon={<ArrowUpRight size={13} />} quiet={!!modeNote(state)}>Save problem report</Action><CopyLinkButton text={ISSUES_URL} /></div></section>}
      <AboutSection state={state} send={send} />
    </div></section>
  </>;
}

// What the keyboard does, said where a person looks for help (these used to be a tooltip on the footer's clock). The page handles the
// first four itself and the desktop app handles zoom; Escape is each window's and each search field's own.
const SHORTCUTS: { keys: React.ReactNode; does: string }[] = [
  { keys: <><kbd>Ctrl+1</kbd> to <kbd>Ctrl+4</kbd></>, does: 'Open Protection, Activity, Restore or Settings' },
  { keys: <kbd>/</kbd>, does: 'Search the page (Activity, and Protection when it has a search box)' },
  { keys: <kbd>F5</kbd>, does: 'Refresh' },
  { keys: <><kbd>Ctrl+=</kbd> and <kbd>Ctrl+-</kbd></>, does: 'Make text larger or smaller' },
  { keys: <kbd>Ctrl+0</kbd>, does: 'Return text to normal size' },
  { keys: <kbd>Esc</kbd>, does: 'Close a window, or clear a search' },
];

// What a person or a bug report asks first: which Rewindle this is, which backup service it reports on, and under what terms. The
// licenses button opens the folder of notices that ships beside the app; the host finds that folder itself, the page sends no path.
function AboutSection({ state, send }: { state: DashboardState; send: Send }) {
  // The sample data has no host, and so no version or backup service to name.
  const setup = state.setup, unknown = state.demo ? 'Sample data' : 'Unknown';
  const service = setup?.engineFound === false ? 'Not installed'
    : setup?.engine ? `${setup.engine}${setup.engineVersion ? ` · version ${setup.engineVersion}` : ''}` : unknown;
  return <section className="surface setting-row about-row">
    <h3 className="info-heading about-heading">About Rewindle</h3>
    <dl className="about-facts">
      <div><dt>Version</dt><dd>{setup?.appVersion || unknown}</dd></div>
      <div><dt>Backup service</dt><dd>{service}</dd></div>
      <div><dt>License</dt><dd>MIT License</dd></div>
      <div><dt>Built on</dt><dd>Restic, open-source encrypted backup</dd></div>
      <div><dt>Source code</dt><dd className="path-copy">{PROJECT_URL}</dd></div>
    </dl>
    <div className="setting-controls"><Button size="sm" onClick={() => send('openLicensesFolder')}><ArrowUpRight size={13} aria-hidden="true" />Open licenses folder</Button><CopyLinkButton text={PROJECT_URL} label="Copy project link" /></div>
    <details className="inline-details shortcuts"><summary><Keyboard size={13} aria-hidden="true" />Keyboard shortcuts</summary>
      <dl className="shortcut-list">{SHORTCUTS.map((shortcut, index) => <div key={index}><dt>{shortcut.keys}</dt><dd>{shortcut.does}</dd></div>)}</dl></details>
  </section>;
}

// A notice outside a dialog, drawn in the page's corner. It is only the part that comes and goes: the live region around it is always
// in the page (see App), so a screen reader already knows the region when this is put into it. A notice that is hovered or focused
// waits (see useDashboard), Escape dismisses one that has focus, and focus goes back to where it was.
function Toast({ notice, dismiss, hold }: { notice: Notice; dismiss: () => void; hold: NoticeHold }) {
  const previousFocus = useRef<HTMLElement | null>(null);
  const close = () => {
    const previous = previousFocus.current;
    dismiss();
    if (previous?.isConnected) previous.focus({ preventScroll: true });
  };
  return <motion.div className={`toast ${notice.error ? 'error' : ''}`} initial={{ opacity: 0, y: 16, scale: .98 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, y: 8 }}
    {...noticeHoldProps(hold)}
    onFocusCapture={event => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) previousFocus.current = event.relatedTarget instanceof HTMLElement ? event.relatedTarget : null; }}
    onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); close(); } }}>
    <span>{notice.text}</span><Button size="icon-sm" variant="quiet" aria-label="Dismiss notification" onClick={close}><X size={14} /></Button>
  </motion.div>;
}

// What a screen reader is told as a backup starts, moves on and ends, whichever page is showing. The host republishes the whole
// state about once a second, so this listens only to what changes when something happened: the state key and title, the phase,
// each quarter of the progress, and the repair notice. The elapsed time, speed and estimate are left out, or it would speak every
// second. The first state after the page loads or the connection returns, and the animation preview, say nothing: what they show
// is not news. A failed run and a repair that becomes necessary interrupt; everything else waits its turn.
type Spoken = { polite: string; assertive: string };
type SpokenSnapshot = { key: string; title: string; phase: number; quarter: number; repair: boolean; repairState: string; error: boolean; unreadable?: boolean };
const NOTHING_SPOKEN: Spoken = { polite: '', assertive: '' };

function useAnnouncements(state: DashboardState | null, connected: boolean): Spoken {
  const [spoken, setSpoken] = useState<Spoken>(NOTHING_SPOKEN);
  const seen = useRef<SpokenSnapshot | null>(null);
  const status = state?.status, recovery = state?.recovery;
  const quarter = status ? Math.floor(status.progress * 4) : 0;
  useEffect(() => {
    if (!state || !connected || state.preview) { seen.current = null; return; }
    const s = state.status, r = state.recovery;
    const before = seen.current;
    // The other region is emptied too, so the same sentence can be spoken again later.
    const say = (text: string, urgent: boolean) => setSpoken(urgent ? { polite: '', assertive: text } : { polite: text, assertive: '' });
    if (s.unavailable) {
      // A status the host could read no file for is said once, as it begins, and is not a state the run left or entered: the state before
      // it stays what the next readable one is compared with, so a run that was already announced is not announced again after a gap in
      // its file (a real change still is). With nothing before it there is nothing to compare with afterwards either.
      if (before && !before.unreadable && !state.dataError) say([s.title, s.detail].filter(Boolean).join('. '), false);
      seen.current = before ? { ...before, unreadable: true } : null;
      return;
    }
    seen.current = { key: s.key, title: s.title, phase: s.phaseIndex, quarter, repair: r.repairNeeded, repairState: r.repairState, error: !!state.dataError };
    // Nothing to compare with yet, or the host was still reading the backup state (its key is "unknown" until it has). A status that
    // cannot be read is already said by the page's own alert; once it can be read again, that change is spoken like any other.
    if (!before || (before.key === 'unknown' && !before.error) || state.dataError) return;
    if (r.repairNeeded && !before.repair) { say(`Backups are paused: moving the backup location didn’t finish. ${r.repairMessage} ${r.repairState}`.trim(), true); return; }
    if (s.key !== before.key || s.title !== before.title) { say(s.active ? s.title : [s.title, s.detail].filter(Boolean).join('. '), s.failure); return; }
    if (r.repairNeeded && r.repairState && r.repairState !== before.repairState) { say(r.repairState, false); return; }
    if (s.active && (s.phaseIndex !== before.phase || quarter !== before.quarter)) say(`${phaseName(s.phaseLabel) || 'Backing up'}, ${Math.round(s.progress * 100)} percent`, false);
  }, [connected, state?.preview, status?.key, status?.title, status?.unavailable, status?.phaseIndex, quarter, recovery?.repairNeeded, recovery?.repairState]);
  // A sentence left in the region would be found again by someone reading the page with a screen reader's cursor.
  useEffect(() => {
    if (!spoken.polite && !spoken.assertive) return;
    const timer = window.setTimeout(() => setSpoken(NOTHING_SPOKEN), 12000);
    return () => window.clearTimeout(timer);
  }, [spoken]);
  return spoken;
}

// The loader on the first screen, before the host has sent anything. Without a clock (it would count seconds nobody asked for), and if the
// host stays silent for a while it says so and offers to ask again, so the first screen is never a spinner with no way out.
function OpeningLoader({ send }: { send: Send }) {
  const [slow, setSlow] = useState(false);
  useEffect(() => { const timer = window.setTimeout(() => setSlow(true), 10000); return () => window.clearTimeout(timer); }, []);
  const hosted = !!(window.rewindleNative ?? window.chrome?.webview);
  return <><LoadingState label="Opening Rewindle" variant="Orbit" showElapsed={false} />
    <div role="status">{slow && hosted && <p>Taking longer than usual. <Button size="sm" onClick={() => send('ready')}>Try again</Button></p>}</div></>;
}

export default function App() {
  const { state: rawState, connected, send, notice, dismissNotice, holdNotice } = useDashboard();
  const state = useMemo(() => {
    if (!rawState) return null;
    const offline = !connected, unreadable = !!rawState.dataError;
    // The sample-data bridge only answers these actions. Everything else stays off even if a fixture drifts.
    const sampleActions = new Set(['togglePreview', 'viewRunDetails']);
    // These two work from what is already on disk, so backup status that cannot be read does not turn them off (a lost
    // connection still does). The host decides whether either is available.
    const needsNoStatus = new Set(['exportDiagnostics', 'viewRunDetails']);
    const dated = withRunDates(rawState);
    if (!offline && !unreadable && !rawState.preview && !rawState.demo) return dated;
    const locked = (key: string) => offline || (unreadable && !needsNoStatus.has(key))
      || (rawState.demo ? !sampleActions.has(key) : rawState.preview && PROTECTED_COMMANDS.has(key as CommandName));
    const reason = (key: string) => offline ? 'Rewindle has stopped updating, so this is turned off for now. Try again in a moment.'
      : unreadable && !needsNoStatus.has(key) ? 'Backup status cannot be read right now. Try again once the message above clears.'
      : rawState.demo ? 'Sample data is read-only.' : 'Stop the animation preview before using this action.';
    return { ...dated, sources: dated.sources.map(source => ({ ...source, canRemove: false })), actions: Object.fromEntries(Object.entries(dated.actions).map(([key, value]) => [key, value && locked(key) ? { ...value, enabled: false, help: reason(key) } : value])) };
  }, [rawState, connected]);
  const spoken = useAnnouncements(state, connected);
  const [page, setPage] = useState<DashboardPage>('Protection');
  const [historyView, setHistoryView] = useState<HistoryView & ActivityDateFilter>(emptyHistoryView());
  const [folderView, setFolderView] = useState<FolderView>({ query: '', unavailable: false });
  const [dismissedRunDetailsId, setDismissedRunDetailsId] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const pageRef = useRef<HTMLElement>(null);
  const previousPage = useRef<DashboardPage>('Protection');
  const scrollPositions = useRef<Partial<Record<DashboardPage, number>>>({});
  const focusPage = useRef(false);
  const appliedTheme = useRef<string | null>(null);
  // The refresh button spins for a moment when pressed: the host answers a refresh with nothing to show but the next state, so without
  // it the button looks dead. Where animation is off, the words "Refreshing" are said to a screen reader instead (see the toolbar).
  const [refreshing, setRefreshing] = useState(false);
  const refreshTimer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(refreshTimer.current), []);
  // Layout effect: apply theme, contrast and motion before the first frame of new state is painted. <html> starts with no theme
  // class (the first frame follows prefers-color-scheme, which the host sets to the theme it resolved), and both classes are set
  // here, so a fixed Light or Dark choice never depends on the operating system's own setting.
  useLayoutEffect(() => {
    if (!state) return;
    const root = document.documentElement;
    const theme = `${state.dark}:${state.highContrast}`;
    if (appliedTheme.current !== null && appliedTheme.current !== theme) {
      // A theme change swaps every token at once. Controls that transition their colors (buttons, rows) would fade while
      // surfaces snap, so transitions are held off (.theme-switching, in beautifului.css) until the frame that paints the
      // new theme is out. The class comes off two animation frames later: dropping it in the very next frame would let that
      // frame's style change transition after all.
      root.classList.add('theme-switching');
      requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('theme-switching')));
    }
    appliedTheme.current = theme;
    root.classList.toggle('dark', state.dark);
    root.classList.toggle('light', !state.dark);
    root.style.colorScheme = state.dark ? 'dark' : 'light';
    root.dataset.highContrast = String(state.highContrast);
    root.dataset.reducedMotion = String(state.reducedMotion);
    root.dataset.motion = state.motion.toLowerCase();
  }, [state?.dark, state?.highContrast, state?.motion, state?.reducedMotion]);
  // The page chosen here that the host has not confirmed yet. The host answers every navigation with a state, so after two quick
  // choices the answer to the first would otherwise flip the page back to it before the second arrives.
  const pendingPage = useRef<{ page: DashboardPage; at: number } | null>(null);
  useEffect(() => {
    const hostPage = state?.page;
    if (!hostPage) return;
    const pending = pendingPage.current;
    if (pending) {
      // What the host reports may still be an earlier choice. Once it agrees, or has taken too long (it refused, or it is busy),
      // it is the authority again, which is also how a page the host opens by itself (from the tray, say) is followed.
      if (hostPage !== pending.page && Date.now() - pending.at < 500) return;
      pendingPage.current = null;
    }
    setPage(hostPage);
  }, [state]);
  useEffect(() => {
    if (previousPage.current !== page) {
      scrollPositions.current[previousPage.current] = scrollRef.current?.scrollTop ?? 0;
      previousPage.current = page;
      focusPage.current = true;
    }
  }, [page]);
  const navigate = (next: DashboardPage) => { pendingPage.current = { page: next, at: Date.now() }; setPage(next); send('navigate', { page: next }); };
  const runDetailsId = state?.runDetails?.id ?? null;
  useEffect(() => {
    setDismissedRunDetailsId(previous => previous && previous === runDetailsId ? previous : null);
  }, [runDetailsId]);
  const openRunDetails = useCallback((runId: string) => {
    if (!runId) return;
    setDismissedRunDetailsId(null);
    // The dialog shows the current notice, and an error never times out, so an earlier one (a declined Windows prompt,
    // say) would otherwise appear inside it. A failure to open this run still arrives afterwards and is shown.
    dismissNotice();
    send('viewRunDetails', { runId });
  }, [dismissNotice, send]);
  const closeRunDetails = useCallback(() => {
    const id = state?.runDetails?.id;
    if (!id) return;
    setDismissedRunDetailsId(id);
    // What the dialog said (a copy that did not work, a log that would not open) was said to the person looking at it. Left in place it
    // would show again on the page the moment the dialog is gone; a failure of the close itself still arrives afterwards.
    dismissNotice();
    send('closeRunDetails', { runId: id });
  }, [dismissNotice, send, state?.runDetails?.id]);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      // The desktop host turns the browser's own reload off, so F5 refreshes the dashboard data instead.
      // Held down, it repeats; one refresh is enough.
      if (event.key === 'F5' && !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey && window.chrome?.webview) {
        event.preventDefault();
        if (!event.repeat) send('refresh');
        return;
      }
      // Zoom, for larger text. The desktop host turns the browser's own zoom keys off with the rest of its shortcuts, so Ctrl+= and
      // Ctrl+- (and Ctrl+0 for the normal size) ask the host to zoom, which keeps it within the sizes the layout was made for. It
      // works in a dialog and while typing, like the browser's own. Ctrl+mouse wheel needs no help, and outside the desktop app
      // the browser zooms by itself, so nothing is intercepted there.
      if ((event.ctrlKey || event.metaKey) && !event.altKey && window.chrome?.webview) {
        const zoom = event.key === '=' || event.key === '+' ? 'in' : event.key === '-' || event.key === '_' ? 'out' : event.key === '0' ? 'reset' : null;
        if (zoom) {
          event.preventDefault();
          if (!event.repeat) send('setZoom', { zoom });
          return;
        }
      }
      if (state?.sourcePicker?.open || state?.restoreFlow?.open || (state?.runDetails && dismissedRunDetailsId !== state.runDetails.id)) return;
      const target = event.target;
      if (target instanceof HTMLElement && (target.matches('input, textarea, select') || target.isContentEditable)) return;
      if ((event.ctrlKey || event.metaKey) && !event.altKey && ['1', '2', '3', '4'].includes(event.key)) {
        event.preventDefault(); navigate((['Protection', 'Activity', 'Restore', 'Settings'] as DashboardPage[])[Number(event.key) - 1]);
      } else if (event.key === '/' && (page === 'Activity' || page === 'Protection')) {
        // Protection only has a search field once it lists enough folders to need one, so without a field the key is left alone.
        const search = pageRef.current?.querySelector<HTMLInputElement>('.search-field input');
        if (search) { event.preventDefault(); search.focus(); }
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [dismissedRunDetailsId, page, send, state?.restoreFlow?.open, state?.runDetails, state?.sourcePicker?.open]);
  if (!state) return <div className="connection-screen"><img src="./rewindle-icon.svg" alt="" width="48" height="48" /><OpeningLoader send={send} /><p>{(window.rewindleNative ?? window.chrome?.webview) ? 'Loading your protected folders, backup history, and backup status.' : 'Open the desktop app to connect to your backup state.'}</p></div>;
  // The toolbar button steps System, Light, Dark and round again, so it never replaces "follow Windows" with no way back; its title says
  // where the theme is and where one press takes it.
  const themeIndex = Math.max(0, THEME_STEPS.findIndex(step => step.name === state.theme)), themeNow = THEME_STEPS[themeIndex], themeNext = THEME_STEPS[(themeIndex + 1) % THEME_STEPS.length];
  const themeTitle = `Theme: ${themeNow.label}. Switch to ${themeNext.label}.`;
  const refresh = () => { send('refresh'); setRefreshing(true); window.clearTimeout(refreshTimer.current); refreshTimer.current = window.setTimeout(() => setRefreshing(false), 800); };
  // When the figures were read, in the viewer's own clock ("Updated 14:03" or "Updated 2:03 PM"); the host's words while it retries.
  const updatedClock = formatClock(state.updatedAt, usableLocale(state.locale)), updatedText = updatedClock ? `Updated ${updatedClock}` : state.updated;
  // Why protected controls may be off, so a dialog can say it in its own words: the link is down, the backup status cannot be read, or the animation preview is running.
  const availability: Availability = !connected ? 'offline' : state.dataError ? 'dataError' : state.preview ? 'preview' : 'ok';
  const failedClose = notice?.error ? notice.text : undefined;
  // A dialog that is open shows the notice itself, so the page's toast, which would sit unseen behind it and outlive it, stays away.
  const dialogOpen = !!state.sourcePicker?.open || !!state.restoreFlow?.open || (!!state.runDetails && dismissedRunDetailsId !== state.runDetails.id);
  // The later run that put the open run right, if one did, so its details do not ask for something nothing needs.
  const detailsResolvedBy = state.runDetails && !state.runDetails.success ? resolvedRuns(state.history, verifiedBackup(state)).get(state.runDetails.id) : undefined;
  return <MotionConfig reducedMotion={state.reducedMotion ? 'always' : 'never'}><div className="app-shell">
    <a className="skip-link" href="#main-content" onClick={event => { event.preventDefault(); pageRef.current?.focus(); }}>Skip to content</a>
    {/* Always present, empty until there is something to say: a live region speaks only what is put into it after it exists. */}
    <div className="sr-only" role="status" aria-live="polite" aria-atomic="true">{spoken.polite}</div>
    <div className="sr-only" role="alert" aria-live="assertive" aria-atomic="true">{spoken.assertive}</div>
    <SidebarNav className="app-sidebar" fill storageKey="rewindle.sidebar" activeNav={page} onNavigate={key => navigate(key as DashboardPage)} navItems={navItems}
      primaryActionLabel={null}
      footerLabel="Settings" footerShortcut="Control+4" footerActive={page === 'Settings'} footerIcon={<Settings size={18} />} onFooterClick={() => navigate('Settings')} />
    <div className="workspace"><header className="topbar"><div className="toolbar-actions">
      {(state.demo || state.preview) && <span className="demo-label">{state.demo ? 'Sample data' : 'Animation preview'}</span>}
      {/* No "connected" light: the window is the app, so a light that is always on says nothing. When the page stops getting updates, the
          banner below says so and the Protection hero dims. */}
      {(state.demo || state.preview) && <Button size="sm" disabled={!state.actions.togglePreview?.enabled} title={state.actions.togglePreview?.help} onClick={() => send('togglePreview')}>{state.preview ? <X size={12} /> : <Play size={12} />}{state.preview ? 'Stop preview' : 'Play animation'}</Button>}
      <Button size="icon-sm" variant="quiet" aria-label="Refresh" title="Refresh (F5)" onClick={refresh}><RefreshCw size={14} className={refreshing ? 'refresh-spin' : undefined} /></Button>
      <span className="sr-only" role="status">{refreshing ? 'Refreshing' : ''}</span>
      <Button size="icon-sm" variant="quiet" aria-label={themeTitle} title={themeTitle} onClick={() => send('setTheme', { theme: themeNext.name })}><themeNow.Icon size={15} /></Button>
    </div></header>
    {/* The status container is always present, so the warning that is put into it is announced; an alert is announced as it appears. */}
    <div role="status">{!connected && <div className="connection-warning"><CircleAlert size={14} /><span>Rewindle has stopped updating, so what you see may be out of date.</span><Button size="xs" onClick={refresh}>Try again</Button></div>}</div>
    {/* What the host reported is its own wording, often a system message, so it waits under Details instead of running into the sentence. */}
    {state.dataError && <div className="connection-warning" role="alert"><CircleAlert size={14} /><div><span>Rewindle couldn't read the backup status just now, so this page may be out of date.</span>
      <details className="inline-details"><summary>Details</summary><p className="muted-copy">{state.dataError}</p></details></div><Button size="xs" onClick={refresh}>Try again</Button></div>}
    {/* Named for the page, because a page change moves focus here (see onAnimationComplete): an unnamed landmark would be announced as
        just "main", and the title of the page that was opened would never be read. The skip link points here too. */}
    <div className="page-scroll" ref={scrollRef}><AnimatePresence mode="wait" initial={false}><motion.main id="main-content" tabIndex={-1} aria-label={page} ref={pageRef} className="page" key={page}
      initial={{ opacity: 0, y: state.reducedMotion ? 0 : 7 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, transition: { duration: state.reducedMotion ? 0 : .08 } }}
      onAnimationStart={target => { if (typeof target === 'object' && !Array.isArray(target) && target.opacity === 1 && focusPage.current) scrollRef.current?.scrollTo({ top: state.preview && page === 'Protection' ? 0 : scrollPositions.current[page] ?? 0 }); }}
      onAnimationComplete={target => { if (typeof target === 'object' && !Array.isArray(target) && target.opacity === 1 && focusPage.current) { pageRef.current?.focus({ preventScroll: true }); focusPage.current = false; } }}
      transition={{ duration: state.reducedMotion ? 0 : .22, ease: [.16, 1, .3, 1] }}>
      {/* A page that fails to draw is replaced by a notice, with the sidebar and the other pages still working, and is drawn again with the next state. */}
      <ErrorBoundary scope="page" label={`${page} page`} resetKey={state} onRetry={() => send('refresh')}>
        {page === 'Protection' ? <Protection state={state} send={send} folders={folderView} setFolders={setFolderView} stale={!connected} openRunDetails={openRunDetails} /> : page === 'Activity' ? <ActivityPage state={state} send={send} view={historyView} setView={setHistoryView} openRunDetails={openRunDetails} openRestore={() => navigate('Restore')} interactive={connected} /> : page === 'Restore' ? <RestorePage state={state} send={send} /> : <SettingsPage state={state} send={send} stale={!connected} />}
      </ErrorBoundary>
      <footer className="app-footnote"><span><LockKeyhole size={10} />{state.preview ? 'Animation preview · no backup is running' : 'Your backups are encrypted'}</span><span>{state.status.active ? <Shimmer>{state.preview ? 'Preview running' : 'Backup is running'}</Shimmer> : updatedText}</span></footer>
    </motion.main></AnimatePresence></div></div>
    {/* The two regions are in the page from the start and empty until there is something to say, so a screen reader already knows them
        when a notice is put in: a live region that is created together with its text is often not announced. Only the toast inside
        comes and goes, and an error has the alert region, which is announced at once and is never timed out. */}
    <div className="toast-region" role="status" aria-live="polite" aria-atomic="true"><AnimatePresence mode="wait">{notice && !notice.error && !dialogOpen && <Toast key={notice.id} notice={notice} dismiss={dismissNotice} hold={holdNotice} />}</AnimatePresence></div>
    <div className="toast-region" role="alert"><AnimatePresence mode="wait">{notice?.error && !dialogOpen && <Toast key={notice.id} notice={notice} dismiss={dismissNotice} hold={holdNotice} />}</AnimatePresence></div>
    {/* A dialog that fails to draw is replaced by a notice that can close it on the host's side, so the host is not left holding a flow nobody can see. */}
    <ErrorBoundary scope="dialog" label="folder chooser" resetKey={!!state.sourcePicker?.open} onClose={() => send('closeSourcePicker')} note={failedClose}>
      <FolderPickerModal picker={state.sourcePicker ?? null} send={send} reducedMotion={state.reducedMotion} availability={availability} notice={notice} dismissNotice={dismissNotice} />
    </ErrorBoundary>
    <ErrorBoundary scope="dialog" label="restore window" resetKey={!!state.restoreFlow?.open} onClose={() => send('restoreFlowClose')} note={failedClose}>
      <RestoreFlowModal flow={state.restoreFlow ?? null} reducedMotion={state.reducedMotion} availability={availability} send={send} notice={notice} dismissNotice={dismissNotice} holdNotice={holdNotice} locale={usableLocale(state.locale)} sources={state.sources} />
    </ErrorBoundary>
    <ErrorBoundary scope="dialog" label="run details window" resetKey={!!state.runDetails && dismissedRunDetailsId !== state.runDetails.id} onClose={closeRunDetails}>
      <RunDetailsModal details={state.runDetails ?? null} open={!!state.runDetails && dismissedRunDetailsId !== state.runDetails.id} resolvedBy={detailsResolvedBy} reducedMotion={state.reducedMotion} send={send} notice={notice} dismissNotice={dismissNotice} holdNotice={holdNotice} onRequestClose={closeRunDetails} />
    </ErrorBoundary>
  </div></MotionConfig>;
}
