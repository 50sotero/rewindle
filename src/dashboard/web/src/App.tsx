import { Component, createContext, useCallback, useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ErrorInfo, type ReactNode } from 'react';
import { AnimatePresence, motion, MotionConfig } from 'motion/react';
import {
  ShieldCheck, History, Settings, RefreshCw, ArrowUpRight, ArrowRight,
  HardDrive, Clock3, LockKeyhole, Check, X, Play, Pause,
  Search, Sun, Moon, Monitor, CloudCheck, ArchiveRestore,
  Files, Gauge, Database, CircleAlert, CircleCheck, Activity, ListChecks, TriangleAlert, Info, OctagonAlert, Copy,
} from 'lucide-react';
import SidebarNav from '@/components/primitives/SidebarNav';
import TaskRows, { type TaskRow } from '@/components/primitives/TaskRows';
import FilterTable, { type TableRow, type FilterTableLabels, type FilterTableSelection, type FilterTableStatus } from '@/components/primitives/FilterTable';
import LoadingState from '@/components/primitives/LoadingState';
import ProtectedFolders, { type FolderView } from '@/components/primitives/ProtectedFolders';
import ProtectionHealth, { healthTime, phaseName } from '@/components/primitives/ProtectionHealth';
import FolderPickerModal from '@/components/primitives/FolderPickerModal';
import RestoreFlowModal from '@/components/primitives/RestoreFlowModal';
import InsightCards, { type InsightPage } from '@/components/primitives/InsightCards';
import RunDetailsModal from '@/components/primitives/RunDetailsModal';
import { Button } from '@/components/atoms/Button';
import { Shimmer } from '@/components/atoms/Shimmer';
import { noticeHoldProps, useDashboard, type NoticeHold } from './useDashboard';
import { PROTECTED_COMMANDS, usableLocale, type Availability, type CommandName, type DashboardPage, type DashboardState, type MotionPreference, type Notice, type RunState, type ThemePreference } from './native-types';
import { PROJECT_URL } from './project';

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
  const reload = <Button size="sm" variant={scope === 'app' ? 'primary' : 'secondary'} autoFocus={scope === 'app'} onClick={() => window.location.reload()}><RefreshCw size={13} aria-hidden="true" />Reload dashboard</Button>;
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
      <h2 id={titleId}>The {label} hit a problem</h2>
      <p>It stopped drawing, so it was cleared away. Close it and open it again. Nothing was changed, and a restore that is already running carries on by itself.</p>
      {note && <p className="crash-note" role="status">{note}</p>}
      <div className="crash-actions">{onClose && <Button size="sm" variant="primary" autoFocus onClick={onClose}>Close</Button>}{reload}{copyButton}</div>
      {technical}</section></div>;
  }
  if (scope === 'page') {
    return <section className="surface crash-card" role="alert" aria-labelledby={titleId}>
      <span className="crash-icon"><TriangleAlert size={22} aria-hidden="true" /></span>
      <h2 id={titleId}>This page hit a problem</h2>
      <p>The {label} stopped drawing. The rest of the app still works, so you can open another page. Your backups and settings are not affected.</p>
      <div className="crash-actions">{onRetry && <Button size="sm" variant="primary" onClick={onRetry}>Try again</Button>}{reload}{copyButton}</div>
      {technical}</section>;
  }
  return <div className="crash-screen" role="alert" aria-labelledby={titleId}>
    <span className="crash-icon"><TriangleAlert size={26} aria-hidden="true" /></span>
    <h1 id={titleId}>Rewindle hit a problem</h1>
    <p>This screen stopped drawing, so it was cleared. Your backups and settings are not affected, and scheduled backups keep running on their own. Reload the dashboard to carry on.</p>
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

// How the history table and the trend charts group a run: finished and verified, stopped on request, or not done.
const runStatus = (run: RunState): FilterTableStatus => run.success ? 'done' : /^(cancelled|canceled)$/i.test(run.result) ? 'progress' : 'todo';

const emptyHistoryView = (): HistoryView & ActivityDateFilter => ({ query: '', sort: 'newest', filter: 'all', from: '', to: '' });

const localDateKey = (value: string) => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
};

// A run's start the way the viewer's region writes it ("Fri, Oct 2, 2:00 AM" or "Fri 2 Oct, 02:00"), with the year added once
// the run is from an earlier year. The host sends one fixed day-month 24-hour pattern, so the page formats the ISO start
// itself. Formatters are cached: the host publishes about once a second and every retained run is formatted each time.
const whenFormats = new Map<string, Intl.DateTimeFormat>();
function runWhen(started: string, locale: string | undefined, fallback: string, weekday = true) {
  const date = new Date(started);
  if (Number.isNaN(date.getTime())) return fallback;
  const withYear = date.getFullYear() !== new Date().getFullYear();
  const key = `${locale ?? ''}|${withYear}|${weekday}`;
  let format = whenFormats.get(key);
  if (!format) {
    // A 12-hour clock reads "2:00 AM"; a 24-hour one keeps its leading zero ("02:00"), so the times line up down the table.
    const twelveHour = !!new Intl.DateTimeFormat(locale, { hour: 'numeric' }).resolvedOptions().hour12;
    format = new Intl.DateTimeFormat(locale, { weekday: weekday ? 'short' : undefined, day: 'numeric', month: 'short', year: withYear ? 'numeric' : undefined, hour: twelveHour ? 'numeric' : '2-digit', minute: '2-digit' });
    whenFormats.set(key, format);
  }
  return format.format(date);
}

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
function busyNote(state: DashboardState): string {
  if (state.demo) return 'You are viewing sample data. Backups and changes are turned off.';
  if (state.preview) return 'The animation preview is running. Real backups and changes are paused.';
  if (state.status.active) return 'A backup is running. Schedule, location and folder changes unlock when it finishes.';
  if (state.recovery.repairNeeded) return 'Backups are paused until the backup location is repaired.';
  return '';
}

// `hint` says what a figure counts, as a tooltip, for the ones whose meaning is not in their label. `bad` draws a figure that is a
// problem when it is not zero (errors) in the text-grade red; the label and the number still say it in words. `sub` is a line of
// words under the figure, for what it covers ("last 400 runs").
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
    <strong><CircleAlert size={14} className="inline mr-2" />Backup location needs attention</strong>
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
// "Check again" is the same refresh the toolbar has.
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
      <h2 id={titleId}>Engine not installed</h2>
      <p>Rewindle reports on a backup engine installed under Program Files. It did not find one on this computer, so there is nothing to show yet. Nothing was changed.</p>
      <p>Install or repair the engine (the Rewindle installer sets it up), then choose Check again. The README lists what Rewindle needs, under Requirements.</p>
      <dl className="setup-where">
        {setup.engine && <div><dt>Engine</dt><dd>{setup.engine}{setup.engineChosenBy === '--engine' ? ' (chosen with --engine)' : ''}</dd></div>}
        {searched.map((path, index) => <div key={path}><dt>{index === 0 ? 'Looked for' : ''}</dt><dd>{path}</dd></div>)}
        {setup.stateFolder && <div><dt>Reads status from</dt><dd>{setup.stateFolder}</dd></div>}
      </dl>
      <div className="setup-actions">
        <Button size="sm" variant="primary" onClick={() => send('refresh')}><RefreshCw size={13} aria-hidden="true" />Check again</Button>
        <Button size="sm" onClick={copy}><Copy size={13} aria-hidden="true" />{copied === 'done' ? 'Copied' : copied === 'failed' ? 'Could not copy' : 'Copy details'}</Button>
      </div>
      <p className="setup-report">{report}</p>
    </div>
  </section>;
}

type HeroTone = 'active' | 'danger' | 'warning' | 'success';

// One tone for the whole hero. The host overrides the title and badge text for an overdue or paused
// schedule, a repair, or a pending change review, but status.success still describes the last run,
// so the emblem, tag icon and step rows derive their look from everything the page already knows.
// A protected folder that cannot be found keeps the hero from being all green: the next backup cannot include it.
function heroTone(state: DashboardState): HeroTone {
  const s = state.status, freshness = state.freshness.state;
  if (s.active || state.recovery.repairBusy) return 'active';
  if (s.failure || state.recovery.repairNeeded || freshness === 'Overdue' || freshness === 'ClockAnomaly') return 'danger';
  if (!s.success || s.cancelled || freshness !== 'Healthy' || state.actions.reviewChanges?.visible || state.dataError || state.sources.some(source => !source.exists)) return 'warning';
  return 'success';
}

// The host draws its status badge in capitals for the native window ("NEEDS ATTENTION", "LIVE  •  BACKING UP"). The page says it as a
// sentence, like the chips beside it. Only text that is all capitals is changed, so a badge the host already wrote as a sentence
// ("Status unavailable") stays as it is, and "Off-site" keeps its hyphen and its capital.
function toSentence(badge: string): string {
  return badge.split(/\s*[•·]\s*/).map(part => {
    const text = part.trim();
    if (!text || text !== text.toUpperCase()) return text;
    const lower = text.toLowerCase().replace(/\boff-site\b/g, 'Off-site');
    return lower.charAt(0).toUpperCase() + lower.slice(1);
  }).filter(Boolean).join(' · ');
}

// What the status chip says. The host's plain "READY" badge is its fallback for a backup plan with nothing running and nothing wrong, and
// no verified run behind it. Beside "Last verified" that reads better as "Awaiting backup". The host picks the badge by precedence (a
// repair, a pause, an overdue backup each take it over), which the page cannot rebuild from the state key alone, so it follows the badge.
function statusBadgeLabel(status: DashboardState['status']): string {
  const label = toSentence(status.badge);
  return !status.success && label === 'Ready' ? 'Awaiting backup' : label;
}

// The storage line under the backup location. A drive that said it is not ready is a warning (its own icon, and a color that is readable
// as text), not a muted line: the backups cannot be written until it is back.
function VolumeLine({ repository }: { repository: DashboardState['repository'] }) {
  const missing = repository.volumeReady === false;
  return <div className={`muted-copy volume-line${missing ? ' is-unavailable' : ''}`}>{missing && <><TriangleAlert size={13} aria-hidden="true" /><span className="sr-only">Needs attention: </span></>}{repository.volume}</div>;
}

// `stale` is a page that has lost the host (see App's `connected`): what it shows is the last thing the host said, so it stops moving and
// is dimmed, and the banner above it says why.
function Protection({ state, send, folders, setFolders, stale }: { state: DashboardState; send: Send; folders: FolderView; setFolders: (value: FolderView) => void; stale: boolean }) {
  // Without the backup service every widget below would say "unavailable" or "0"; the one explanation takes their place.
  if (serviceMissing(state)) return <><Heading title="Protection" description="Rewindle is waiting for a backup service to report on." /><SetupNotice state={state} send={send} /></>;
  const s = state.status;
  const tone = heroTone(state);
  const locale = usableLocale(state.locale);
  // When the last verified backup finished. Not drawn where the time cannot be trusted (the status could not be read, or the clocks
  // disagree), the same rule the Local backup card below follows.
  const verifiedKnown = !state.dataError && state.freshness.state !== 'ClockAnomaly';
  const verifiedAt = healthTime(state.freshness.verifiedAt, locale);
  const missingFolders = state.sources.filter(source => !source.exists).length;
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
  const note = busyNote(state), quiet = !!note;
  // The host's title already says "Estimated time remaining" when the progress is an estimate, and "Stopping safely: Please wait" while
  // a cancel finishes, so the suffix is only for a plain "Time remaining" that has a time in it.
  const etaEstimated = s.estimated && s.key !== 'cancelling' && !/estimated/i.test(s.etaTitle || '') && /\d/.test(s.eta || '');
  // Which run the four figures describe, which the page never said: the one in progress, or the latest finished one with the
  // time it started. The host sends the figures as display text, so errors are "any digit but zero" rather than a parsed number.
  const metricsRun = state.history.find(run => run.id === s.runId)?.startedDisplay;
  const metricsContext = state.preview ? 'Previewed live run' : s.active ? 'Current run'
    : !s.runId || !(s.success || s.failure || s.cancelled) ? 'No run recorded yet' : s.success ? 'Latest verified run' : 'Latest recorded run';
  const hasErrors = /[1-9]/.test(s.errors || '');
  // One name per step, the same ones the page uses everywhere else: the restore test restores a small test file after every backup.
  const names = ['Back up files', 'Save snapshot', 'Check storage', 'Restore test'];
  const rows: TaskRow[] = names.map((label, i) => ({
    key: `backup-${i}`, label, step: i + 1,
    status: stepStatus(i),
    amount: s.success ? ['Files protected', 'Snapshot saved', 'Storage checked', 'Restore test passed'][i] : s.active && i === s.phaseIndex ? phaseName(s.phaseLabel) : '',
    details: [
      { label: ['Read your protected folders', 'Save an encrypted point in time', 'Check that the saved backup data is intact', 'Restore a small test file after every backup and verify it'][i], meta: '' },
      { label: i === 0 ? `${s.files} files · ${s.bytes}` : i === 1 ? state.repository.path : i === 2 ? 'Restic integrity check' : 'Independent restore verification', meta: '' },
    ],
  }));
  const folderCount = state.sources.length;
  return <>
    <Heading title="Protection" description={`${folderCount} protected ${folderCount === 1 ? 'folder' : 'folders'} · ${state.schedule.summary}`} note={note}>
      {s.active && <Action state={state} send={send} command="cancelBackup" icon={<X size={13} />} quiet={quiet} />}
      <Action state={state} send={send} command="backupNow" primary size="md" icon={<Play size={13} fill="currentColor" />} quiet={quiet} />
    </Heading>
    <Repairs state={state} send={send} />
    <section className={`surface surface-pad protection-hero ${s.active ? 'is-active' : ''} ${stale ? 'is-stale' : ''}`}>
      <div className="hero-grid">
        <div>
          <span className="eyebrow">Protection status</span>
          <div className="status-line">
            <motion.div key={s.key} initial={{ scale: .7, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} transition={{ type: 'spring', stiffness: 310, damping: 21 }}
              className={`status-emblem ${tone === 'success' ? '' : tone}`}>
              {tone === 'danger' ? <OctagonAlert size={22} /> : tone === 'active' ? <Activity size={23} /> : tone === 'success' ? <ShieldCheck size={24} /> : s.success ? <TriangleAlert size={22} /> : <Clock3 size={22} />}
            </motion.div>
            {/* A heading, so the page's main status is a stop in the outline under its title, with the sections below at the same
                level. Not a live region: useAnnouncements (in App) speaks the run reaching its next phase or ending, and it does
                so on every page, where this hero exists only on Protection. */}
            <h2 className="status-title">{(tone === 'danger' || tone === 'warning') && <span className="sr-only">Needs attention: </span>}{s.title}</h2>
          </div>
          <div className="status-detail">{s.detail}</div>
          {s.active ? <div className="progress-area">
            {/* No clock of its own: the loader counts from when it mounted, which is not when the run began (open the app 20 minutes in, or
                leave this page and come back, and it read 0s beside the host's real Elapsed). */}
            <div className="progress-copy"><LoadingState label={phaseName(s.phaseLabel) || 'Backing up'} live={false} showElapsed={false} /><strong>{Math.round(s.progress * 100)}%</strong></div>
            <div className="progress-rail" role="progressbar" aria-label={state.preview ? 'Preview backup progress' : 'Backup progress'} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(s.progress * 100)}><motion.div className="progress-bar" animate={{ width: `${Math.max(0, Math.min(100, s.progress * 100))}%` }} transition={{ duration: .65, ease: [.16, 1, .3, 1] }} /></div>
            <p className="muted-copy eta-line">{s.etaTitle || 'Time remaining'}: {s.eta || 'Calculating…'}{etaEstimated ? ' · estimated' : ''}</p>
            {/* Where the estimate comes from and when it expects to finish ("Likely around 14:35"): said on the page, not in a tooltip a keyboard or touch user never sees. */}
            {s.etaHint && <p className="muted-copy eta-hint">{s.etaHint}</p>}
          </div> : <div className="status-tags">
            {/* The first thing to know about protection is how recent it is. (The footer already says the backup is encrypted.) */}
            {verifiedKnown && <span className="quiet-tag">{verifiedAt ? <ShieldCheck size={11} aria-hidden="true" /> : <Clock3 size={11} aria-hidden="true" />}{verifiedAt ? <>Last verified <time dateTime={state.freshness.verifiedAt}>{verifiedAt}</time></> : 'No verified backup yet'}</span>}
            <span className="quiet-tag">{tone === 'success' ? <Check size={11} /> : <Clock3 size={11} />}{statusBadgeLabel(s)}</span>
            {missingFolders > 0 && <span className="quiet-tag is-warning"><TriangleAlert size={11} aria-hidden="true" />{missingFolders === 1 ? '1 folder cannot be found' : `${missingFolders} folders cannot be found`}</span>}
          </div>}
          <div className="info-action"><Action state={state} send={send} command="reviewChanges" icon={<ListChecks size={13} />} /></div>
        </div>
        <div><TaskRows rows={rows} className="backup-tasks" labels={{ completed: s.success ? 'Verified' : 'Done', failed: 'Failed', pending: ended ? 'Not run' : 'Pending' }} /></div>
      </div>
      <div className="stats-grid">
        <Stat label="Files" value={s.files} icon={<Files size={12} />} />
        <Stat label="Processed" value={s.bytes} icon={<Database size={12} />} hint="Data read from your protected folders during the run." />
        {/* "Run time", not "Last run": the figure is a length of time, which "Last run" reads as the moment the run happened. */}
        <Stat label={s.active ? 'Throughput' : 'Run time'} value={s.active ? s.speed : s.elapsed} icon={s.active ? <Gauge size={12} /> : <Clock3 size={12} />} hint={s.active ? undefined : 'How long the run took.'} />
        <Stat label={s.active ? 'Elapsed' : 'Errors'} value={s.active ? s.elapsed : s.errors} icon={s.active ? <Clock3 size={12} /> : <CircleAlert size={12} />} bad={!s.active && hasErrors} />
      </div>
      {!state.dataError && !s.unavailable && <p className="stats-caption">{metricsRun && !state.preview ? `${metricsContext} · ${metricsRun}` : metricsContext}</p>}
    </section>
    <div className="two-columns backup-destinations">
      <section className="surface surface-pad"><div className="info-heading"><Clock3 size={15} className="text-ink-3" />Next automatic backup</div>
        <div className="info-main">{state.schedule.nextRun || 'No upcoming run'}</div><div className="muted-copy">{state.schedule.summary}</div>
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
type RunChartData = { runs: RunState[]; selectedId: string | null; onSelect: (runId: string) => void; locale?: string };
const RunChartContext = createContext<RunChartData>({ runs: [], selectedId: null, onSelect: () => undefined });

// `floor` is the y of the baseline; the labels under it sit in the 28px below.
const CHART_HEIGHT = 176;
const PLOT = { left: 60, right: 18, top: 14, floor: CHART_HEIGHT - 28, inset: 9 };
const DURATION_STEPS = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400];
const decimalStep = (rough: number) => { const base = 10 ** Math.floor(Math.log10(rough)), f = rough / base; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * base; };
const axisLabel = (value: number, metric: ChartMetric, locale?: string) => metric === 'duration' ? duration(value) : bytes(value, locale);
const rawValue = (run: RunState, metric: ChartMetric) => metric === 'duration' ? run.durationSeconds : run.processedBytes;
const shownValue = (run: RunState, metric: ChartMetric) => metric === 'duration' ? run.durationDisplay : run.processedDisplay;

// A value axis padded enough that small changes stay visible, with a few round gridlines inside it. Bytes are
// scaled to one unit first, so the gridlines read 4.2, 4.4 and 4.6 GiB, not 4.5 billion bytes.
function chartScale(values: number[], metric: ChartMetric) {
  const peak = Math.max(...values, 1);
  let unit = 0;
  while (metric === 'processed' && unit < BYTE_UNITS.length - 1 && peak >= 1024 ** (unit + 1)) unit++;
  const divisor = 1024 ** unit, scaled = values.map(value => value / divisor);
  const low = Math.min(...scaled), high = Math.max(...scaled);
  if (high <= 0) return { min: 0, max: divisor, ticks: [0] };
  const pad = Math.max((high - low) * .12, high * .02);
  const min = Math.max(0, low - pad), max = high + pad, rough = (max - min) / 4;
  const step = metric === 'duration' ? DURATION_STEPS.find(candidate => candidate >= rough) ?? decimalStep(rough) : decimalStep(rough);
  const ticks: number[] = [];
  for (let n = Math.ceil(min / step); n * step <= max; n++) ticks.push(n * step * divisor);
  return { min: min * divisor, max: max * divisor, ticks };
}

function TrendChart({ runs, metric, selectedId, onSelect, locale }: { runs: RunState[]; metric: ChartMetric; selectedId: string | null; onSelect: (runId: string) => void; locale?: string }) {
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
    return { scale, start, span, px, py, dots: runs.map((run, i) => ({ run, x: px(times[i]), y: run.success ? py(rawValue(run, metric)) : floor, status: runStatus(run) })) };
  }, [runs, metric, width, last]);
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
  const verified = runs.filter(run => run.success), marked = runs.length - verified.length;
  const extreme = (better: (a: number, b: number) => boolean) => verified.reduce((best, run) => better(rawValue(run, metric), rawValue(best, metric)) ? run : best, verified[0]);
  const summary = (metric === 'duration'
    ? `Backup duration for the last ${verified.length} verified runs: latest ${verified[verified.length - 1].durationDisplay}, shortest ${shownValue(extreme((a, b) => a < b), metric)}, longest ${shownValue(extreme((a, b) => a > b), metric)}.`
    : `Data processed by the last ${verified.length} verified runs: latest ${verified[verified.length - 1].processedDisplay}, smallest ${shownValue(extreme((a, b) => a < b), metric)}, largest ${shownValue(extreme((a, b) => a > b), metric)}.`)
    + (marked ? ` ${marked} failed or cancelled ${marked === 1 ? 'run is' : 'runs are'} marked on the baseline and not counted.` : '');
  const title = metric === 'duration' ? 'Backup duration by run' : 'Data processed by run';
  const tip = active !== null && width > 0 ? dots[current] : null;
  return <div className="chart-area">
    <div ref={plotRef} className="run-chart" role="slider" tabIndex={0} aria-label={title} aria-describedby={summaryId}
      aria-valuemin={1} aria-valuemax={runs.length} aria-valuenow={current + 1} aria-valuetext={`${runs[current].startedDisplay}, ${runs[current].success ? `${shownValue(runs[current], metric)}, ` : ''}${runs[current].result}`}
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
          {dot.status === 'todo' ? <rect className="run-chart-dot is-failed" x={-4} y={-4} width={8} height={8} transform={`rotate(45) scale(${tip && i === current ? 1.3 : 1})`} />
            : <circle className={`run-chart-dot${dot.status === 'progress' ? ' is-canceled' : ''}`} r={tip && i === current ? 5 : 3.5} />}
        </g>)}
      </svg>}
      {tip && <div className="run-chart-tip" style={{ left: Math.max(Math.min(tip.x, width - 78), 78), top: tip.y >= 60 ? tip.y - 60 : tip.y + 14 }} aria-hidden="true">
        <strong>{tip.run.startedDisplay}</strong><span>{tip.run.success ? `${shownValue(tip.run, metric)} · ${tip.run.result}` : `${tip.run.result} · not counted`}</span>
      </div>}
    </div>
    <p id={summaryId} className="sr-only">{summary} Use the left and right arrow keys to move between runs and Enter to select one.</p>
    <div className="sr-only"><table><caption>{title}</caption>
      <thead><tr><th scope="col">Started</th><th scope="col">{metric === 'duration' ? 'Duration' : 'Processed'}</th><th scope="col">Result</th></tr></thead>
      <tbody>{runs.map(run => <tr key={run.id}><td>{run.startedDisplay}</td><td>{run.success ? shownValue(run, metric) : '—'}</td><td>{run.result}</td></tr>)}</tbody></table></div>
  </div>;
}

// How many verified runs each chart follows.
const CHART_RUNS = 30;

function RunChart({ metric }: { metric: ChartMetric }) {
  const { runs: all, selectedId, onSelect, locale } = useContext(RunChartContext);
  // The last 30 verified runs, oldest first, so the line reads left to right. A failed or cancelled run inside that span
  // stays on the chart as a marker, because it happened, but it is not a value: it feeds neither the line nor the figure above it.
  const { runs, verified, verifiedTotal } = useMemo(() => {
    const dated = all.filter(run => Number.isFinite(Date.parse(run.started))).sort((a, b) => Date.parse(a.started) - Date.parse(b.started));
    const done = dated.filter(run => run.success);
    const from = done.length > CHART_RUNS ? Date.parse(done[done.length - CHART_RUNS].started) : Number.NEGATIVE_INFINITY;
    return { runs: dated.filter(run => Date.parse(run.started) >= from), verified: done.slice(-CHART_RUNS), verifiedTotal: done.length };
  }, [all]);
  const latest = verified[verified.length - 1], newest = runs[runs.length - 1], marked = runs.length - verified.length;
  if (!latest || verified.length < 2) {
    const [heading, text] = !newest ? ['No completed backups yet', 'Run history and trends will appear after your first backup.']
      : latest ? ['Your first verified backup is recorded', `${latest.startedDisplay} · ${shownValue(latest, metric)}. A trend appears after the next verified backup.`]
      : ['No verified backup yet', `Latest run: ${newest.startedDisplay} · ${newest.result}. A trend appears once a backup is verified.`];
    return <div className="surface first-run-summary"><History size={22} /><div><strong>{heading}</strong><p>{text}</p></div></div>;
  }
  return <div className="surface chart-card">
    <div className="chart-heading"><div><span className="eyebrow">{metric === 'duration' ? 'Latest verified run duration' : 'Latest verified data processed'}</span><div className="chart-value">{shownValue(latest, metric)}</div></div><span className="quiet-tag">{verifiedTotal > CHART_RUNS ? `last ${CHART_RUNS} verified runs` : `${verified.length} verified runs`}</span></div>
    <TrendChart runs={runs} metric={metric} selectedId={selectedId} onSelect={onSelect} locale={locale} />
    {marked > 0 && <p className="chart-note">{marked} failed or cancelled {marked === 1 ? 'run is' : 'runs are'} marked on the baseline and left out of the trend.</p>}
  </div>;
}

// A chart that fails to draw replaces only its own card, and is drawn again when the run history next changes.
function GuardedChart({ metric }: { metric: ChartMetric }) {
  const { runs } = useContext(RunChartContext);
  return <ErrorBoundary scope="card" label="chart" resetKey={runs}><RunChart metric={metric} /></ErrorBoundary>;
}
const DurationChart = () => <GuardedChart metric="duration" />;
const ProcessedChart = () => <GuardedChart metric="processed" />;

const HISTORY_LABELS: FilterTableLabels = {
  columns: { task: 'When', date: 'Duration', status: 'Result', owner: 'Processed · files' },
  filters: { all: 'All runs', done: 'Completed', todo: 'Needs attention', progress: 'Cancelled' },
  openRow: 'Open details',
};

function ActivityPage({ state, send, view, setView, openRunDetails, openRestore, interactive }: { state: DashboardState; send: Send; view: HistoryView & ActivityDateFilter; setView: (value: HistoryView & ActivityDateFilter) => void; openRunDetails: (runId: string) => void; openRestore: () => void; interactive: boolean }) {
  const { query, sort, filter, from, to } = view;
  const locale = usableLocale(state.locale);
  // The search field keeps focus when it is cleared (the clear button goes away with the text, and focus would fall to the page).
  const searchRef = useRef<HTMLInputElement>(null);
  const historySignature = JSON.stringify(state.history);
  const history = useMemo(() => [...state.history].sort((a, b) => Date.parse(b.started) - Date.parse(a.started)), [historySignature]);
  const backupRuns = useMemo(() => history.filter(run => run.type === 'Backup'), [history]);
  const success = backupRuns.filter(run => run.success);
  const average = success.length ? success.reduce((sum, run) => sum + run.durationSeconds, 0) / success.length : 0;
  const selected = state.history.find(run => run.id === state.selectedRunId);
  const dateRangeInvalid = !!from && !!to && from > to;
  const needle = query.trim().toLowerCase();
  const matchesDate = (run: RunState) => {
    if (!from && !to) return true;
    const startedDate = localDateKey(run.started);
    return !!startedDate && (!from || startedDate >= from) && (!to || startedDate <= to);
  };
  // The local date (2025-10-02) is searchable too, because the table's own label leaves the year out for this year's runs.
  const matchesView = (run: RunState) => matchesDate(run) && [run.id, run.startedDisplay, localDateKey(run.started), run.result, run.snapshot, run.type].join(' ').toLowerCase().includes(needle);
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
    return filtered.map(run => ({ id: run.id, task: `${run.startedDisplay}${run.type !== 'Backup' ? ` · ${run.type}` : ''}`, date: run.durationDisplay, status: runStatus(run), statusLabel: run.result, owner: `${run.processedDisplay} · ${run.filesDisplay} files` }));
  }, [history, query, sort, from, to]);
  // Sorting is not a filter (it never hides a run), so only the search, the dates and the result chip count as filtering and are
  // cleared by "Clear filters"; the order stays as it was chosen.
  const filtering = !!query.trim() || !!from || !!to || filter !== 'all';
  const shown = rows.filter(row => filter === 'all' || row.status === filter).length;
  const clearFilters = useCallback(() => {
    setView({ ...view, query: '', from: '', to: '', filter: 'all' });
    searchRef.current?.focus();
  }, [setView, view]);
  // The table is large and the host publishes state every second, so everything it receives is kept stable
  // between publishes and it only re-renders when the runs, the filter or the selection change.
  const onFilterChange = useCallback((next: FilterTableSelection) => setView({ ...view, filter: next }), [setView, view]);
  const selectRow = useCallback((row: TableRow) => send('selectRun', { runId: row.id ?? '' }), [send]);
  const openRow = useCallback((row: TableRow) => openRunDetails(row.id ?? ''), [openRunDetails]);
  // Only drawn while there is history to filter (the first-run state below has its own), so this is always about filters that match nothing.
  const emptyContent = useMemo(() => <div className="empty-state"><Search size={22} aria-hidden="true" /><strong>{dateRangeInvalid ? 'Choose a valid date range' : 'No runs match these filters'}</strong><p>{dateRangeInvalid ? 'The start date must be on or before the end date.' : 'Try another search, adjust the dates, or show all results.'}</p><Button size="sm" onClick={clearFilters}>Clear filters</Button></div>, [dateRangeInvalid, clearFilters]);
  // What the tiles and the banner say about the window of runs the host keeps; the number is the host's own (see historyLimit).
  const limit = state.historyLimit;
  const windowNote = state.historyTruncated ? (limit ? `last ${limit.toLocaleString(locale)} runs` : 'newest runs only') : undefined;
  const capNote = limit
    ? `Showing the newest ${limit.toLocaleString(locale)} runs. Older runs have rolled off this list, but every backup is still saved in your backup location. Restore lists every backup you can recover from.`
    : 'The app keeps the newest 400 run records for fast loading. This does not remove backup snapshots.';
  const summary = filtering ? `Showing ${shown.toLocaleString(locale)} of ${history.length.toLocaleString(locale)} runs` : `${history.length.toLocaleString(locale)} ${history.length === 1 ? 'run' : 'runs'}`;
  const chart = useMemo<RunChartData>(() => ({ runs: backupRuns, selectedId: state.selectedRunId, onSelect: runId => send('selectRun', { runId }), locale }), [backupRuns, state.selectedRunId, send, locale]);
  // A trend needs two verified runs; failed and cancelled ones are only marked on it.
  const trend = success.length > 1, pill = selected ? 'Open selected run details' : 'Open newest run details';
  const pages: InsightPage[] = useMemo(() => [
    { key: 'duration', prose: trend ? 'How long your backups take. Point at a run to see it, or click one to select it.' : 'Compare backup duration as your run history grows.', Card: DurationChart, pill },
    { key: 'processed', prose: 'The amount of data processed by each backup run.', Card: ProcessedChart, pill },
  ], [trend, pill]);
  return <>
    <Heading title="Activity" description="Search your runs, inspect a snapshot, or review what needs attention." note={modeNote(state)}>
      <Action state={state} send={send} command="exportDiagnostics" icon={<ArrowUpRight size={13} />} quiet={!!modeNote(state)} />
    </Heading>
    <div className="activity-metrics">
      <div className="surface"><Stat label="Verified backups" value={backupRuns.length ? `${success.length} / ${backupRuns.length}` : 'No backups yet'} icon={<ShieldCheck size={13} />} sub={windowNote} /></div>
      <div className="surface"><Stat label="Average duration" value={success.length ? duration(average) : '—'} icon={<Clock3 size={13} />} sub={windowNote} /></div>
      <div className="surface"><Stat label="Latest stored" value={success.length ? success[0].storedDisplay : '—'} icon={<Database size={13} />} sub={windowNote} hint="New data the latest verified backup added to your backup location, after deduplication and compression." /></div>
    </div>
    <section>
      <div className="section-toolbar"><div><div className="history-heading"><h2 className="section-title">Run history</h2>{history.length > 0 && <span className="history-count" role="status">{summary}</span>}</div>
        {history.length > 0 && <p className="history-scope-note">History lists runs Rewindle has observed; runs that finish while it is closed may be missing.</p>}</div>
        {history.length > 0 && <div className="history-tools">
          <label className="search-field"><Search size={13} aria-hidden="true" /><input ref={searchRef} aria-label="Search backup history" placeholder="Date, result, or snapshot…" value={query} onChange={event => setView({ ...view, query: event.target.value })}
            onKeyDown={event => { if (event.key === 'Escape' && query) { event.preventDefault(); event.stopPropagation(); setView({ ...view, query: '' }); } }} />{query && <button aria-label="Clear history search" onClick={() => { setView({ ...view, query: '' }); searchRef.current?.focus(); }}><X size={13} /></button>}</label>
          <label className="date-filter"><span>From</span><input type="date" aria-label="Show runs from date" value={from} max={to || undefined} onChange={event => setView({ ...view, from: event.target.value })} /></label>
          <label className="date-filter"><span>To</span><input type="date" aria-label="Show runs through date" value={to} min={from || undefined} onChange={event => setView({ ...view, to: event.target.value })} /></label>
          <select className="sort-field" aria-label="Sort backup history" value={sort} onChange={event => setView({ ...view, sort: event.target.value })}><option value="newest">Newest first</option><option value="oldest">Oldest first</option><option value="duration">Longest first</option><option value="size">Largest first</option></select>
          {/* Always in the toolbar, hidden (so out of the tab order too) while there is nothing to clear: it appearing and going shifted the other fields. */}
          <Button size="xs" variant="quiet" style={{ visibility: filtering ? 'visible' : 'hidden' }} onClick={clearFilters}>Clear filters</Button>
        </div>}</div>
      {state.historyTruncated && <div className="history-cap-note" role="note"><Info size={13} aria-hidden="true" /><span>{capNote}</span><Button size="xs" variant="quiet" onClick={openRestore}>Open Restore</Button></div>}
      {history.length > 0 ? <>
        <FilterTable className="history-table" rows={rows} labels={HISTORY_LABELS}
          selectedRowId={state.selectedRunId} filter={filter} onFilterChange={onFilterChange} tableLabel="Backup run history"
          onRowClick={selectRow} onRowOpen={openRow} emptyContent={emptyContent} />
        <div className="selection-bar"><div><strong>{selected ? `${selected.type} · ${selected.startedDisplay}` : newest ? `Newest run · ${newest.startedDisplay}` : 'No run to open'}</strong><span>{selected ? `${selected.result} · Snapshot ${selected.snapshot || 'unavailable'}${selectedVisible ? '' : ' · Hidden by current filters'}` : newest ? `${newest.result} · Click a row to choose another run, or double-click one to open it.` : 'Adjust the search, dates or filters to see runs.'}</span></div><Button size="sm" variant="secondary" disabled={!canOpen} title={canOpen ? undefined : detailsAction?.help} onClick={() => target && openRunDetails(target.id)}><ArrowRight size={13} />Open details</Button></div>
      </> : <div className="surface empty-state history-empty"><History size={22} aria-hidden="true" /><strong>No backup history yet</strong><p>Your completed backup runs will appear here once you have made your first backup.</p>
        <Action state={state} send={send} command="backupNow" primary size="md" icon={<Play size={13} fill="currentColor" />} quiet={!!modeNote(state)} /></div>}
    </section>
    <RunChartContext.Provider value={chart}><div className="insights-wide"><InsightCards pages={pages} labels={{ title: 'Backup trends' }} actionDisabled={!canOpen} onAction={() => target && openRunDetails(target.id)} /></div></RunChartContext.Provider>
  </>;
}

function RestorePage({ state, send }: { state: DashboardState; send: Send }) {
  const steps: TaskRow[] = [
    { key: 'choose', label: 'Choose a backup', amount: '', step: 1, status: 'guide', details: [{ label: 'Browse your saved backups in Restore Center.', meta: '' }] },
    { key: 'find', label: 'Find your files', amount: '', step: 2, status: 'guide', details: [{ label: 'Explore the original folder structure and select what you need.', meta: '' }] },
    { key: 'destination', label: 'Choose an empty folder', amount: '', step: 3, status: 'guide', details: [{ label: 'Restore into a new or empty location. Your original files stay in place.', meta: '' }] },
    { key: 'verify', label: 'Restore and verify', amount: '', step: 4, status: 'guide', details: [{ label: 'Check the recovered files before using them.', meta: '' }] },
  ];
  const note = modeNote(state);
  if (serviceMissing(state)) return <><Heading title="Restore" description="Choose a saved backup and recover files to a separate folder." note={note} /><SetupNotice state={state} send={send} /></>;
  return <><Heading title="Restore" description="Choose a saved backup and recover files to a separate folder." note={note} />
    <Repairs state={state} send={send} />
    <div className="restore-layout"><section className="surface"><span className="eyebrow">Restore Center</span><div className={`status-emblem ${state.recovery.repairNeeded ? 'warning' : ''}`} style={{ marginTop: 22 }}><ArchiveRestore size={24} /></div>
      <h2>{state.recovery.title}</h2><p className="muted-copy">{state.recovery.detail}</p>
      <div className="actions" style={{ marginTop: 22 }}><Action state={state} send={send} command="openRestore" primary size="md" icon={<ArrowUpRight size={14} />} quiet={!!note} /><Action state={state} send={send} command="checkReadiness" quiet={!!note} /></div>
    </section><div><h2 className="section-title" style={{ marginBottom: 16 }}>How recovery works</h2><TaskRows rows={steps} className="restore-steps" variant="List" /></div></div>
    <div className="surface surface-pad"><div className="info-heading"><HardDrive size={15} />Backup location</div><div className="info-main">{state.repository.path}</div><p className="muted-copy">Browse a snapshot, select files, and review the destination before restoring. Recovered files are verified after the operation.</p></div>
  </>;
}

function SettingsPage({ state, send }: { state: DashboardState; send: Send }) {
  const themes: { name: ThemePreference; label: string; Icon: typeof Sun }[] = [{ name: 'System', label: 'System', Icon: Monitor }, { name: 'Midnight', label: 'Dark', Icon: Moon }, { name: 'Daylight', label: 'Light', Icon: Sun }];
  const motions: { name: MotionPreference; label: string }[] = [{ name: 'System', label: 'System' }, { name: 'Full', label: 'Full' }, { name: 'Reduced', label: 'Reduced' }];
  const motionDescription = state.motion === 'Full'
    ? 'Use animated transitions and feedback, even when Windows reduces animation. High contrast always reduces motion.'
    : state.motion === 'Reduced'
      ? 'Minimize movement while keeping progress and status updates visible.'
      : `System follows your Windows animation setting. It is currently using ${state.reducedMotion ? 'reduced' : 'full'} motion.`;
  const note = busyNote(state), quiet = !!note;
  return <><Heading title="Settings" description="Manage your backup plan and make the app comfortable to use." note={note} />
    <Repairs state={state} send={send} />
    {/* Every row has the same two slots, the words (`setting-copy`) and what they are controlled with (`setting-controls`), which sits at
        the bottom of its card, so the two pickers in a row of cards line up whatever the length of the text above them. */}
    <section className="settings-section"><h2 className="section-title">Appearance and motion</h2><div className="settings-grid">
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><Sun size={15} />Appearance</h3><p className="muted-copy">Follow your system, or choose a light or dark theme.</p>{state.highContrast && <p className="muted-copy">Windows High Contrast is on and sets the colors for now. Your choice is saved and applies when High Contrast is turned off.</p>}</div><div className="setting-controls"><div className="theme-picker" role="group" aria-label="Appearance">
        {themes.map(({ name, label, Icon }) => <button key={name} className="theme-choice" aria-pressed={state.theme === name} onClick={() => send('setTheme', { theme: name })}>
          {state.theme === name && <motion.div className="theme-highlight" layoutId="theme-thumb" transition={{ type: 'spring', stiffness: 440, damping: 34 }} />}<span><Icon size={13} />{label}</span></button>)}
      </div></div></section>
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><Activity size={15} />Motion</h3><p className="muted-copy">{motionDescription}</p></div><div className="setting-controls"><div className="motion-picker" role="group" aria-label="Motion preference">{motions.map(({ name, label }) => <button key={name} className="motion-choice" aria-pressed={state.motion === name} onClick={() => send('setMotion', { motion: name })}>{state.motion === name && <motion.div className="motion-highlight" layoutId="motion-thumb" transition={{ type: 'spring', stiffness: 440, damping: 34 }} />}<span>{label}</span></button>)}</div><Action state={state} send={send} command="togglePreview" icon={state.preview ? <Pause size={12} /> : <Play size={12} />}>{state.preview ? 'Stop preview' : 'Preview animations'}</Action></div></section>
    </div></section>
    {/* Without the backup service the plan, the schedule, the checks and the diagnostics have nothing to act on; the appearance
        settings above still work, and the one explanation stands where the rest would be. */}
    {serviceMissing(state) ? <SetupNotice state={state} send={send} /> : <>
    <section className="settings-section"><h2 className="section-title">Backup plan</h2><div className="settings-grid">
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><HardDrive size={15} />Backup location</h3><p className="muted-copy path-copy">{state.repository.path}</p><VolumeLine repository={state.repository} /></div><div className="setting-controls"><Action state={state} send={send} command="changeRepository" quiet={quiet} /></div></section>
      <section className="surface setting-row"><div className="setting-copy"><h3 className="info-heading"><Clock3 size={15} />Automatic backups</h3><p className="info-main">{state.schedule.summary}</p>
        {/* An unreadable schedule is a problem to explain, not a summary: the reason the host reports goes under Details. */}
        {state.schedule.error ? <div className="attention-note schedule-problem" role="alert">
          <strong><CircleAlert size={14} className="inline mr-2" />The schedule could not be read</strong>
          <p>Rewindle could not read the Windows backup schedule just now. Nothing was changed. Check again, or open Details to see why.</p>
          <details className="inline-details"><summary>Details</summary><p className="muted-copy">{state.schedule.error}</p></details>
          <Button size="sm" onClick={() => send('refresh')}><RefreshCw size={13} />Check again</Button>
        </div> : <><p className="muted-copy">Next: {state.schedule.nextRun}</p><details className="inline-details"><summary>Run conditions</summary><p className="muted-copy">{state.schedule.detail}</p></details></>}
        <ScheduleNotice notice={state.schedule.notice} className="schedule-notice-slot" /></div><div className="setting-controls"><Action state={state} send={send} command="editSchedule" quiet={quiet} /></div></section>
    </div><p className="muted-copy settings-note"><LockKeyhole size={12} aria-hidden="true" />Changing the location or schedule asks for Windows approval. Closing this window never stops a running backup.</p></section>
    <section className="settings-section"><h2 className="section-title">Verification & support</h2><ProtectionHealth state={state} send={send} quiet={quiet} heading={false} context="settings" /><div className="settings-grid">
      <section className="surface setting-row support-row"><div className="setting-copy"><h3 className="info-heading"><ListChecks size={15} />Diagnostics</h3><p className="muted-copy">Create a redacted support bundle to investigate a problem.</p>{state.setup?.engine && <p className="muted-copy">Engine: {state.setup.engine}{state.setup.engineVersion ? ` · version ${state.setup.engineVersion}` : ''}</p>}</div><div className="setting-controls"><Action state={state} send={send} command="exportDiagnostics" icon={<ArrowUpRight size={13} />} quiet={!!modeNote(state)} /></div></section>
    </div></section>
    </>}
    <AboutSection state={state} send={send} />
  </>;
}

// What a person or a bug report asks first: which Rewindle this is, which engine it reports on, and under what terms. The licenses
// button opens the folder of notices that ships beside the app; the host finds that folder itself, the page sends no path.
function AboutSection({ state, send }: { state: DashboardState; send: Send }) {
  // The sample data has no host, and so no version or engine to name.
  const setup = state.setup, unknown = state.demo ? 'Sample data' : 'Unknown';
  const engine = setup?.engineFound === false ? 'Not installed'
    : setup?.engine ? `${setup.engine}${setup.engineVersion ? ` · version ${setup.engineVersion}` : ''}` : unknown;
  return <section className="settings-section"><h2 className="section-title">About Rewindle</h2>
    <section className="surface setting-row about-row">
      <dl className="about-facts">
        <div><dt>Version</dt><dd>{setup?.appVersion || unknown}</dd></div>
        <div><dt>Engine</dt><dd>{engine}</dd></div>
        <div><dt>License</dt><dd>MIT License</dd></div>
        <div><dt>Backups</dt><dd>Powered by Restic</dd></div>
        <div><dt>Project</dt><dd className="path-copy">{PROJECT_URL}</dd></div>
      </dl>
      <div className="setting-controls"><Button size="sm" onClick={() => send('openLicensesFolder')}><ArrowUpRight size={13} aria-hidden="true" />Open licenses folder</Button></div>
    </section></section>;
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
    if (r.repairNeeded && !before.repair) { say(`Backup location needs attention. ${r.repairMessage} ${r.repairState}`.trim(), true); return; }
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
    const reason = (key: string) => offline ? 'The dashboard is waiting to reconnect to the desktop app. Refresh to try again.'
      : unreadable && !needsNoStatus.has(key) ? 'Backup status cannot be read right now. Retry once the message above clears.'
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
  if (!state) return <div className="connection-screen"><img src="./rewindle-icon.svg" alt="" width="48" height="48" /><LoadingState label="Opening Rewindle" variant="Orbit" /><p>{(window.rewindleNative ?? window.chrome?.webview) ? 'Loading your protected folders, backup history, and backup status.' : 'Open the desktop app to connect to your backup state.'}</p></div>;
  // The sidebar is narrow, so its dates leave out the weekday and the result keeps its room.
  const recents = [...state.history].sort((a, b) => Date.parse(b.started) - Date.parse(a.started)).slice(0, 8).map(run => ({ id: run.id, label: `${runWhen(run.started, usableLocale(state.locale), run.startedDisplay, false)} · ${run.result}` }));
  // This button flips between Light and Dark. From the System setting that replaces it, which Settings can restore, so the title says so.
  const themeAction = state.dark ? 'Use light theme' : 'Use dark theme';
  // Why protected controls may be off, so a dialog can say it in its own words: the link is down, the backup status cannot be read, or the animation preview is running.
  const availability: Availability = !connected ? 'offline' : state.dataError ? 'dataError' : state.preview ? 'preview' : 'ok';
  const failedClose = notice?.error ? notice.text : undefined;
  // A dialog that is open shows the notice itself, so the page's toast, which would sit unseen behind it and outlive it, stays away.
  const dialogOpen = !!state.sourcePicker?.open || !!state.restoreFlow?.open || (!!state.runDetails && dismissedRunDetailsId !== state.runDetails.id);
  return <MotionConfig reducedMotion={state.reducedMotion ? 'always' : 'never'}><div className="app-shell">
    <a className="skip-link" href="#main-content" onClick={event => { event.preventDefault(); pageRef.current?.focus(); }}>Skip to content</a>
    {/* Always present, empty until there is something to say: a live region speaks only what is put into it after it exists. */}
    <div className="sr-only" role="status" aria-live="polite" aria-atomic="true">{spoken.polite}</div>
    <div className="sr-only" role="alert" aria-live="assertive" aria-atomic="true">{spoken.assertive}</div>
    <SidebarNav className="app-sidebar" fill storageKey="rewindle.sidebar" activeNav={page} onNavigate={key => navigate(key as DashboardPage)} navItems={navItems}
      primaryActionLabel={null}
      recents={recents} recentLabel="Recent backups" recentSearchLabel="Search latest 8 backups"
      activeTitle={recents.find(run => run.id === state.selectedRunId)?.label ?? null}
      onPick={id => { setHistoryView(emptyHistoryView()); scrollPositions.current.Activity = 0; send('selectRun', { runId: id }); navigate('Activity'); }} onViewAll={() => { setHistoryView(emptyHistoryView()); scrollPositions.current.Activity = 0; navigate('Activity'); }} viewAllLabel="View all activity" footerLabel="Settings" footerShortcut="Control+4" footerActive={page === 'Settings'} footerIcon={<Settings size={14} />} onFooterClick={() => navigate('Settings')} />
    <div className="workspace"><header className="topbar"><div className="toolbar-actions">
      {(state.demo || state.preview) && <span className="demo-label">{state.demo ? 'Sample data' : 'Animation preview'}</span>}
      {/* Narrow, only the dot is drawn (see the 860px rule in app.css), so the tooltip says what it means and the words stay in the page for assistive technology. */}
      <span className="connection" title={`${connected ? 'App connected' : 'App reconnecting'}. Connection to the desktop app. Off-site verification is shown under Protection.`}><span className={`connection-dot ${connected ? '' : 'offline'}`} /><span className="connection-label">{connected ? 'App connected' : 'App reconnecting'}</span></span>
      {(state.demo || state.preview) && <Button size="sm" disabled={!state.actions.togglePreview?.enabled} title={state.actions.togglePreview?.help} onClick={() => send('togglePreview')}>{state.preview ? <X size={12} /> : <Play size={12} />}{state.preview ? 'Stop preview' : 'Play animation'}</Button>}
      <Button size="icon-sm" variant="quiet" aria-label="Refresh dashboard" title="Refresh dashboard (F5)" onClick={() => send('refresh')}><RefreshCw size={14} /></Button>
      <Button size="icon-sm" variant="quiet" aria-label={themeAction} title={state.theme === 'System' ? `${themeAction} (replaces System; Settings restores it)` : themeAction} onClick={() => send('setTheme', { theme: state.dark ? 'Daylight' : 'Midnight' })}>{state.dark ? <Sun size={15} /> : <Moon size={15} />}</Button>
    </div></header>
    {/* The status container is always present, so the warning that is put into it is announced; an alert is announced as it appears. */}
    <div role="status">{!connected && <div className="connection-warning"><CircleAlert size={14} /><span>Connection interrupted. Displayed status may be out of date.</span><Button size="xs" onClick={() => send('refresh')}>Refresh</Button></div>}</div>
    {state.dataError && <div className="connection-warning" role="alert"><CircleAlert size={14} /><span>Backup status could not be read. History shows the last available data. {state.dataError}</span><Button size="xs" onClick={() => send('refresh')}>Retry</Button></div>}
    {/* Named for the page, because a page change moves focus here (see onAnimationComplete): an unnamed landmark would be announced as
        just "main", and the title of the page that was opened would never be read. The skip link points here too. */}
    <div className="page-scroll" ref={scrollRef}><AnimatePresence mode="wait" initial={false}><motion.main id="main-content" tabIndex={-1} aria-label={page} ref={pageRef} className="page" key={page}
      initial={{ opacity: 0, y: state.reducedMotion ? 0 : 7 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, transition: { duration: state.reducedMotion ? 0 : .08 } }}
      onAnimationStart={target => { if (typeof target === 'object' && !Array.isArray(target) && target.opacity === 1 && focusPage.current) scrollRef.current?.scrollTo({ top: state.preview && page === 'Protection' ? 0 : scrollPositions.current[page] ?? 0 }); }}
      onAnimationComplete={target => { if (typeof target === 'object' && !Array.isArray(target) && target.opacity === 1 && focusPage.current) { pageRef.current?.focus({ preventScroll: true }); focusPage.current = false; } }}
      transition={{ duration: state.reducedMotion ? 0 : .22, ease: [.16, 1, .3, 1] }}>
      {/* A page that fails to draw is replaced by a notice, with the sidebar and the other pages still working, and is drawn again with the next state. */}
      <ErrorBoundary scope="page" label={`${page} page`} resetKey={state} onRetry={() => send('refresh')}>
        {page === 'Protection' ? <Protection state={state} send={send} folders={folderView} setFolders={setFolderView} stale={!connected} /> : page === 'Activity' ? <ActivityPage state={state} send={send} view={historyView} setView={setHistoryView} openRunDetails={openRunDetails} openRestore={() => navigate('Restore')} interactive={connected} /> : page === 'Restore' ? <RestorePage state={state} send={send} /> : <SettingsPage state={state} send={send} />}
      </ErrorBoundary>
      <footer className="app-footnote"><span><LockKeyhole size={10} />{state.preview ? 'Animation preview · no backup is running' : 'Restic · encrypted local backup'}</span><span title="Ctrl/Cmd+1–4 changes pages. / focuses search. Ctrl+= and Ctrl+- zoom, Ctrl+0 resets.">{state.status.active ? <Shimmer>{state.preview ? 'Preview running' : 'Backup is running'}</Shimmer> : state.updated}</span></footer>
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
      <RestoreFlowModal flow={state.restoreFlow ?? null} reducedMotion={state.reducedMotion} availability={availability} send={send} notice={notice} dismissNotice={dismissNotice} holdNotice={holdNotice} />
    </ErrorBoundary>
    <ErrorBoundary scope="dialog" label="run details window" resetKey={!!state.runDetails && dismissedRunDetailsId !== state.runDetails.id} onClose={closeRunDetails}>
      <RunDetailsModal details={state.runDetails ?? null} open={!!state.runDetails && dismissedRunDetailsId !== state.runDetails.id} reducedMotion={state.reducedMotion} send={send} notice={notice} dismissNotice={dismissNotice} holdNotice={holdNotice} onRequestClose={closeRunDetails} />
    </ErrorBoundary>
  </div></MotionConfig>;
}
