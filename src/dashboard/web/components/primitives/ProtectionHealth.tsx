import { useId, useState } from 'react';
import { motion } from 'motion/react';
import { ArchiveRestore, ArrowUpRight, Check, ChevronDown, Clock3, Cloud, HardDrive, LoaderCircle, OctagonAlert, Play, RefreshCw, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { usableLocale, type CommandName, type DashboardState } from '@/src/native-types';
import './protection-health.css';

type Send = (command: CommandName, payload?: Record<string, string | boolean>) => void;
type Tone = 'success' | 'warning' | 'danger' | 'active' | 'neutral';
/** Where the cards are drawn: Protection has the hero and its Back up now above them, Settings has neither. */
export type HealthContext = 'protection' | 'settings';
type HealthItem = {
  key: 'local' | 'cloud' | 'restore'; label: string; title: string; tone: Tone;
  detail: string; timestamp: string; timestampLabel: string; nextStep: string;
  /** One line of what the host itself reported, shown under the description; the full text stays in `evidence`. */
  reason?: string;
  evidence?: string;
  /** Opens the evidence disclosure when the card is drawn, for a card whose evidence is the explanation of a problem. */
  openEvidence?: boolean;
  action?: { command: CommandName; label: string; payload?: Record<string, string | boolean> };
  /** Draws the action as the page's main button. Only where nothing else on the page is: Protection already has one at the top. */
  primary?: boolean;
  /** Drawn as one quiet line instead of a card: an off-site copy that is not set up is optional, so it asks for nothing (no time, no
   *  next step, no evidence, no button) and does not take a card's room for ever. */
  compact?: boolean;
};

/** A time the way the cards print it ("Oct 2, 02:00 AM", with the year once it is another year's), or '' when the text is not a date. */
export function healthTime(value: string | undefined, locale?: string): string {
  const date = value ? new Date(value) : null;
  if (!date || Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(locale, { day: 'numeric', month: 'short', year: date.getFullYear() !== new Date().getFullYear() ? 'numeric' : undefined, hour: '2-digit', minute: '2-digit' });
}

// The host's label for the restore-test step (Telemetry.cs: GetPhase and InferFailurePhase). Phase
// index 3 is shared with the repository data sample and a generic verification failure, so the label
// is what tells a failed or running restore test apart from those. The page only matches it: wherever
// it is shown, it says "Restore test" (see phaseName), the one name this step has on every screen.
const RECOVERY_TEST_PHASE = 'Recovery test';

/** A host phase label the way the page says it. The host's "Recovery test" and "Repository" are the restore test and the storage check everywhere else on the page. */
export function phaseName(label: string): string {
  return label === RECOVERY_TEST_PHASE ? 'Restore test' : label === 'Repository' ? 'Storage check' : label;
}

// The first line of what the host reported, cut to what a card can hold. The whole text stays in the details under it.
const REASON_LIMIT = 160;
function briefReason(text: string | undefined): string {
  const line = (text ?? '').split(/\r?\n/).map(part => part.trim()).find(Boolean) ?? '';
  return line.length > REASON_LIMIT ? `${line.slice(0, REASON_LIMIT - 1).trimEnd()}…` : line;
}

type ItemAction = NonNullable<HealthItem['action']>;

// On Protection the hero already says what the host says for these four states, word for word (the host puts the same sentence in both
// places), so the card there names the cause instead of repeating it. Settings has no hero and keeps the host's sentence, which carries
// the dates. A state that is not here (a schedule that cannot be read) is not repeated by the hero, so its card keeps the host's sentence.
const FRESHNESS_CAUSE: Partial<Record<DashboardState['freshness']['state'], string>> = {
  Overdue: 'The last verified backup is older than the schedule expects.',
  Paused: 'Automatic backups are paused.',
  NoVerifiedBackup: 'No completed, verified backup has been recorded yet.',
  ClockAnomaly: 'The computer’s clock looks wrong, so the age of the last backup cannot be judged.',
};

export function protectionHealthItems(state: DashboardState, context: HealthContext = 'protection'): HealthItem[] {
  const freshness = state.freshness;
  const cloud = state.offsite;
  // The provider is named only when the host's evidence names one ("Google Drive" for a direct My Drive proof); otherwise the page
  // says "off-site" and nothing more, because most backups have no off-site copy and one that does may be anywhere.
  const provider = (cloud.provider ?? '').trim();
  // The status could not be read: the page lost the host's answer (dataError), or the host could read no status file (status.unavailable,
  // which is not a failed run, so the failure wording below must not be used for it).
  const unavailable = !!state.dataError || !!state.status.unavailable;
  const hasTest = !!freshness.verifiedAt && freshness.state !== 'ClockAnomaly' && !unavailable;
  // The newest run's restore test outranks an older pass, which stays visible as "Last passed".
  const restoreFailed = !unavailable && state.status.failure && state.status.phaseLabel === RECOVERY_TEST_PHASE;
  const restoreRunning = !unavailable && state.status.active && state.status.phaseLabel === RECOVERY_TEST_PHASE;
  const restoreTone: Tone = restoreFailed ? 'danger' : restoreRunning ? 'active'
    : hasTest ? (freshness.state === 'Healthy' ? 'success' : 'warning')
    : unavailable || freshness.state === 'ClockAnomaly' ? 'warning' : 'neutral';
  const localTone: Tone = unavailable ? 'warning' : state.status.active ? 'active'
    : state.status.failure ? 'danger' : state.status.cancelled ? 'warning' : freshness.state === 'Healthy' ? 'success' : 'warning';
  const cloudTone: Tone = unavailable ? 'warning' : cloud.kind === 'RestoreVerified' || cloud.kind === 'ProviderConfirmed' ? 'success'
    : cloud.kind === 'Failed' ? 'danger' : cloud.kind === 'InProgress' ? 'active'
    : cloud.kind === 'NotConfigured' ? 'neutral' : 'warning';
  const cloudTitles: Record<DashboardState['offsite']['kind'], string> = {
    NotConfigured: 'Not set up (optional)', StatusUnavailable: 'Needs verification', Failed: 'Verification failed',
    InProgress: 'Verification in progress', LocalVerifiedProviderPending: provider ? `Waiting for ${provider} to confirm` : 'Waiting for confirmation',
    ProviderConfirmed: provider ? `Confirmed by ${provider}` : 'Off-site copy confirmed', RestoreVerified: provider ? `Verified in ${provider}` : 'Off-site copy verified',
  };
  // The description under the title is worded per kind, so for an off-site copy that failed or cannot be confirmed the cause the host
  // reports ("Direct cloud proof is stale", what a failed check said) would only be inside the closed disclosure. It is brought
  // up as one line and the disclosure opens with it. A status that could not be read has no current cause to report.
  const cloudProblem = !unavailable && (cloudTone === 'danger' || cloudTone === 'warning');
  // A backup with no off-site copy is not a problem and asks for nothing: it is one quiet line, not a card (see `compact`). It names no
  // provider, because nothing says there is one.
  const cloudOptional = !unavailable && cloud.kind === 'NotConfigured';
  const cloudDetails: Record<DashboardState['offsite']['kind'], string> = {
    NotConfigured: 'No off-site copy is set up. That is optional: your local backup works without one.',
    StatusUnavailable: 'Current off-site protection could not be confirmed. Your local backup is assessed separately.',
    Failed: 'The most recent off-site verification did not succeed. Review the recorded issue below.',
    InProgress: provider ? `The copy in ${provider} is being checked. A verified result will appear when it finishes.` : 'The off-site copy is being checked. A verified result will appear when it finishes.',
    LocalVerifiedProviderPending: `The backup passed local checks. Confirmation from ${provider || 'the off-site provider'} is still pending.`,
    ProviderConfirmed: `${provider || 'The off-site provider'} confirmed the copy. An independent restore from it has not been verified yet.`,
    RestoreVerified: provider ? `The ${provider} inventory matches the backup location, and an independent restore from ${provider} passed.` : 'The off-site inventory matches the backup location, and an independent restore from it passed.',
  };
  // What the local card offers follows what is wrong, and its next step says the same thing in words (so both are decided in this order).
  // A run in progress is watched in Activity, a failed run is read there, and a backup that is due is made with Back up now: on Protection
  // that button is also at the top of the page, so the card's is a second way to the same action and stays an ordinary button; Settings has
  // none of its own, so there it is the main one. A schedule that cannot be read is looked at in Settings.
  const needsBackup = freshness.state === 'Overdue' || freshness.state === 'NoVerifiedBackup';
  const viewActivity: ItemAction = { command: 'navigate', label: 'View activity', payload: { page: 'Activity' } };
  const localAction: ItemAction = unavailable ? { command: 'refresh', label: 'Refresh status' }
    : state.status.active ? viewActivity
    : freshness.state === 'Paused' ? { command: 'editSchedule', label: 'Review schedule' }
    : freshness.state === 'ClockAnomaly' ? { command: 'refresh', label: 'Refresh status' }
    : state.status.failure ? { command: 'navigate', label: 'Review the failed run', payload: { page: 'Activity' } }
    : needsBackup ? { command: 'backupNow', label: 'Back up now' }
    : state.status.cancelled ? viewActivity
    : freshness.state === 'Unavailable' ? (context === 'protection' ? { command: 'navigate', label: 'Open Settings', payload: { page: 'Settings' } } : { command: 'refresh', label: 'Refresh status' })
    : viewActivity;
  return [
    {
      key: 'local', label: 'Local backup', tone: localTone,
      title: unavailable ? 'Status unavailable' : state.status.active ? 'Backup in progress' : state.status.failure ? 'Latest run needs attention' : state.status.cancelled ? 'Latest run was cancelled' : freshness.title || 'Not verified yet',
      // A status file that could not be read has its own sentence from the host (which file, and why); a page that lost the host has none.
      detail: unavailable ? (!state.dataError && state.status.detail) || 'Refresh the dashboard to read the current backup state.' : state.status.active || state.status.failure || state.status.cancelled ? state.status.detail
        : freshness.state === 'Healthy' ? 'Your verified backup is up to date with the automatic schedule.'
        : (context === 'protection' && FRESHNESS_CAUSE[freshness.state]) || freshness.detail,
      timestamp: unavailable ? '' : freshness.verifiedAt, timestampLabel: 'Last verified',
      nextStep: unavailable ? 'Refresh before starting another operation.' : state.status.active ? 'Leave the app open or return later to see the result.'
        : freshness.state === 'Paused' ? 'Review the schedule to resume automatic backups.'
        : freshness.state === 'ClockAnomaly' ? 'Check the computer’s date and time, then refresh.'
        : state.status.failure ? 'Open the latest run for its recorded issue and next step.'
        : needsBackup ? (context === 'protection' ? 'Use Back up now at the top of this page to create a fresh backup.' : 'Use Back up now below to create a fresh backup.')
        : state.status.cancelled ? (context === 'protection' ? 'Review the cancelled run in Activity, or use Back up now at the top of this page.' : 'Review the cancelled run in Activity, or start a fresh backup from Protection.')
        : freshness.state === 'Unavailable' ? (context === 'protection' ? 'Open Settings to check the schedule under Automatic backups.' : 'Check the schedule under Automatic backups, above.')
        : 'Your next automatic run is shown in the backup schedule.',
      action: localAction,
      primary: context === 'settings' && localAction.command === 'backupNow',
    },
    {
      key: 'cloud', label: 'Off-site copy', tone: cloudTone,
      title: unavailable ? 'Status unavailable' : cloudTitles[cloud.kind] || 'Needs verification',
      detail: unavailable ? 'Current off-site status could not be read.' : cloudDetails[cloud.kind] || 'No current verification result is available.',
      timestamp: unavailable || cloudOptional ? '' : cloud.checkedAt,
      timestampLabel: cloudTone === 'success' ? 'Last verified' : 'Last checked',
      nextStep: cloudOptional ? ''
        : cloudTone === 'success' ? 'Off-site verification is separate from the local backup schedule.'
        : cloud.kind === 'InProgress' ? 'Wait for verification to finish, then refresh the status.'
        : `Check that ${provider || 'the off-site location'} is available and review the verification details below.`,
      reason: cloudProblem ? briefReason(cloud.detail) : '',
      evidence: cloudOptional ? undefined : [cloud.title, cloud.detail, cloud.evidence].filter(Boolean).join('\n\n'),
      openEvidence: cloudProblem,
      action: cloudOptional ? undefined : { command: 'refresh', label: 'Refresh status' },
      compact: cloudOptional,
    },
    {
      key: 'restore', label: 'Restore test', tone: restoreTone,
      title: restoreFailed ? 'Latest restore test failed' : restoreRunning ? 'Restore test running'
        : hasTest ? (restoreTone === 'success' ? 'Restore test passed' : freshness.state === 'Unavailable' ? 'Passed earlier' : 'Passed earlier, not re-tested')
        : restoreTone === 'neutral' ? 'Not tested yet' : 'Restore test not confirmed',
      detail: restoreFailed ? `The newest run could not restore its test file. ${hasTest ? 'The last passing test is shown below.' : 'No earlier passing test is recorded.'}`
        : restoreRunning ? 'The current backup is restoring its test file to confirm that recovery works.'
        : hasTest ? (restoreTone === 'success' ? 'The latest verified backup restored its test file successfully.'
          : freshness.state === 'Paused' ? 'Automatic backups are paused, so recovery has not been tested since this earlier pass.'
          : freshness.state === 'Unavailable' ? 'The backup schedule could not be verified, so this test cannot be judged current.'
          : 'This test is older than the backup schedule expects. The next verified backup runs the restore test again.')
        : restoreTone === 'neutral' ? 'No verified backup has run a restore test yet. The first one restores a small test file.'
        : 'A completed, verified restore test with a reliable timestamp is not available.',
      timestamp: hasTest ? freshness.verifiedAt : '', timestampLabel: 'Last passed',
      nextStep: restoreFailed ? 'Open the latest run in Activity for its recorded issue, then start a fresh backup from Protection.'
        : restoreRunning ? 'Leave the app open or return later to see the result.'
        : 'Check recovery readiness for an independent assessment of backup access and recovery requirements.',
      evidence: 'After every backup, Rewindle restores a small test file and checks it. That shows recovery works; it does not mean every backed-up file has been restored.',
      action: { command: 'checkReadiness', label: 'Check recovery readiness' },
    },
  ];
}

// `quiet` is for a page that already says why its controls are paused (see busyNote in App.tsx): the reason
// stays linked for assistive technology and shows as a tooltip, but takes no room, so these cards do not
// grow when a backup starts.
function HealthAction({ item, state, send, quiet, locale }: { item: HealthItem; state: DashboardState; send: Send; quiet: boolean; locale?: string }) {
  const id = useId();
  // Refresh asks the host to read its status files again, and the host answers with nothing to show unless a file changed, so a
  // press that changed nothing looked as if it had done nothing. The card says when it last asked; the count restarts the note, so a
  // second press within the same minute is still seen (and heard).
  const [reread, setReread] = useState<{ at: string; count: number } | null>(null);
  if (!item.action) return null;
  const action = item.action;
  const stateAction = state.actions[action.command];
  const refreshes = action.command === 'refresh';
  const nativeAction = action.command !== 'navigate' && !refreshes;
  if (nativeAction && stateAction?.visible === false) return null;
  const reason = nativeAction && !stateAction?.enabled ? stateAction?.help || 'This action is currently unavailable.' : '';
  // Starting a backup leads with the same play mark as Back up now at the top of Protection; the others end in an arrow that says they go elsewhere.
  const starts = action.command === 'backupNow';
  const Icon = refreshes ? RefreshCw : starts ? Play : ArrowUpRight;
  const press = () => {
    send(action.command, action.payload);
    if (refreshes) setReread(previous => ({ at: new Date().toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' }), count: (previous?.count ?? 0) + 1 }));
  };
  return <div className="health-action" title={quiet && reason ? reason : undefined}><Button size="xs" variant={item.primary ? 'primary' : 'secondary'} disabled={!!reason} aria-describedby={reason ? id : undefined}
    onClick={press}>{starts && <Icon size={11} fill="currentColor" aria-hidden="true" />}{action.label}{!starts && <Icon size={12} aria-hidden="true" />}</Button>
    {reason && <p id={id} className={quiet ? 'sr-only' : 'action-disabled-reason'}>{reason}</p>}
    {/* Always present, so a note that appears after a press is announced. A cloud check is not started from here, and the note says so. */}
    {refreshes && <div role="status">{reread && <p key={reread.count} className="action-disabled-reason health-reread">Status re-read at {reread.at}.{item.key === 'cloud' ? ' Off-site checks run on their own schedule.' : ''}</p>}</div>}</div>;
}

// `heading` adds the page outline's missing level: the cards are <h3>, so on a page whose last heading is the
// <h1> (Protection) they would skip one. Where a section title already sits above the cards (Settings), the
// caller turns it off and the region keeps its plain label. `context` says which page the cards are on, so their wording and the
// local card's action fit it (see protectionHealthItems).
export default function ProtectionHealth({ state, send, quiet = false, heading = true, context = 'protection' }: { state: DashboardState; send: Send; quiet?: boolean; heading?: boolean; context?: HealthContext }) {
  const headingId = useId();
  const icons = { local: HardDrive, cloud: Cloud, restore: ArchiveRestore };
  // The host's regional format, so these times read like the run times and figures elsewhere on the page.
  const locale = usableLocale(state.locale);
  const items = protectionHealthItems(state, context);
  const cards = items.filter(item => !item.compact), rows = items.filter(item => item.compact);
  return <section className={`protection-health${cards.length === 2 ? ' is-two' : ''}`} aria-label={heading ? undefined : 'Protection checks'} aria-labelledby={heading ? headingId : undefined}>
    {heading && <h2 id={headingId} className="sr-only">Protection checks</h2>}
    {cards.map((item, index) => {
      const Icon = icons[item.key];
      // Each state has its own shape as well as its own color: a triangle needs attention, an octagon is a problem.
      const StatusIcon = item.tone === 'success' ? Check : item.tone === 'active' ? LoaderCircle : item.tone === 'neutral' ? Clock3 : item.tone === 'warning' ? TriangleAlert : OctagonAlert;
      const when = healthTime(item.timestamp, locale);
      return <motion.article key={item.key} className={`health-card surface health-${item.tone}`}
        initial={{ opacity: 0, y: state.reducedMotion ? 0 : 5 }} animate={{ opacity: 1, y: 0 }}
        transition={{ duration: state.reducedMotion ? 0 : .24, delay: state.reducedMotion ? 0 : index * .035 }}>
        <div className="health-card-label"><Icon size={15} aria-hidden="true" />{item.label}</div>
        <div className="health-card-status"><StatusIcon size={15} aria-hidden="true" /><h3>{(item.tone === 'warning' || item.tone === 'danger') && <span className="sr-only">Needs attention: </span>}{item.title}</h3></div>
        <p className="health-description">{item.detail}</p>
        {item.reason && <p className="health-reason"><span className="sr-only">Reported: </span>{item.reason}</p>}
        <p className="health-time">{when
          ? <>{item.timestampLabel} <time dateTime={item.timestamp}>{when}</time></>
          : 'No verified time available'}</p>
        {item.nextStep && <p className="health-next-step">{item.nextStep}</p>}
        {/* `open` is only the state the card is drawn in: React leaves the element alone until the prop changes, so a person who closes it keeps it closed. */}
        {item.evidence && <details className="health-evidence" open={item.openEvidence}><summary>{item.key === 'cloud' ? 'Verification details' : 'What this test covers'}<ChevronDown size={12} aria-hidden="true" /></summary><p>{item.evidence}</p></details>}
        <HealthAction item={item} state={state} send={send} quiet={quiet} locale={locale} />
      </motion.article>;
    })}
    {/* One line for what is optional and not set up: it says so and asks for nothing. */}
    {rows.map(item => {
      const Icon = icons[item.key];
      return <p key={item.key} className={`health-row health-${item.tone}`}><Icon size={14} aria-hidden="true" />
        <span className="health-row-label">{item.label}</span><span aria-hidden="true">·</span><span>{item.title}</span></p>;
    })}
  </section>;
}
