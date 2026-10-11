import { useId, useState } from 'react';
import { motion } from 'motion/react';
import { ArchiveRestore, ArrowUpRight, Check, ChevronDown, Clock3, Cloud, HardDrive, LoaderCircle, OctagonAlert, Play, RefreshCw, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { usableLocale, type CommandName, type DashboardState } from '@/src/native-types';
import { formatClock, formatWhen, formatWhenAgo } from '@/src/when';
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
  /** Draws the action as a quiet button: nothing is wrong, and the button is only there for someone who wants it. */
  subdued?: boolean;
  /** Drawn as one quiet line instead of a card: an off-site copy that is not set up is optional, so it asks for nothing (no time, no
   *  next step, no evidence, no button) and does not take a card's room for ever. */
  compact?: boolean;
};

/** A time the way the cards print it ("Oct 2, 2:05 AM", with the year once it is another year's; see when.ts), or '' when the text is not a date. */
export function healthTime(value: string | undefined, locale?: string): string {
  return formatWhen(value, locale, '', { weekday: false });
}

/** The same moment with its age in words ("yesterday at 2:03 AM", "3 days ago (Wed, Oct 8, 2:03 AM)"), or '' when the text is not a date. */
export function healthAge(value: string | undefined, locale?: string): string {
  return formatWhenAgo(value, locale, '');
}

// The host's label for the restore-test step (Telemetry.cs: GetPhase and InferFailurePhase). Phase
// index 3 is shared with the backup data sample and a generic verification failure, so the label
// is what tells a failed or running restore test apart from those. The page only matches it: wherever
// it is shown, it says "Restore test" (see phaseName), the one name this step has on every screen.
const RECOVERY_TEST_PHASE = 'Recovery test';

/** A host phase label the way the page says it. The host's "Recovery test" is the restore test everywhere else on the page, and its "Repository", "Snapshot" and "Data sample" are checks of the saved backup. */
export function phaseName(label: string): string {
  return label === RECOVERY_TEST_PHASE ? 'Restore test' : label === 'Repository' ? 'Backup check' : label === 'Snapshot' ? 'Saving the backup' : label === 'Data sample' ? 'Backup data check' : label;
}

// The first line of what the host reported, cut to what a card can hold. The whole text stays in the details under it.
const REASON_LIMIT = 160;
function briefReason(text: string | undefined): string {
  const line = (text ?? '').split(/\r?\n/).map(part => part.trim()).find(Boolean) ?? '';
  return line.length > REASON_LIMIT ? `${line.slice(0, REASON_LIMIT - 1).trimEnd()}…` : line;
}

type ItemAction = NonNullable<HealthItem['action']>;

// On Protection the hero already says what the host says for these states (the host puts the same sentence in both places), so the
// card there names the cause in a few words instead of repeating it. Settings has no hero and keeps the host's sentence, which carries
// the dates. A schedule that cannot be read has its own wording below: the hero's concern line and this card each say a different half.
const FRESHNESS_CAUSE: Partial<Record<DashboardState['freshness']['state'], string>> = {
  Overdue: 'Anything you changed since your last good backup isn’t saved yet.',
  Paused: 'Nothing will back up on its own until you turn the schedule back on.',
  NoVerifiedBackup: 'Your files are not protected until the first backup finishes.',
  ClockAnomaly: 'Rewindle can’t tell how old your last backup is.',
  Unavailable: 'Your backups may still be running on time. Rewindle just can’t confirm it.',
};

// What the card calls the schedule's state. The host's "Healthy" and "Overdue" are one word each; beside "Local backup" these read as sentences.
const FRESHNESS_TITLE: Partial<Record<DashboardState['freshness']['state'], string>> = { Healthy: 'On schedule', Overdue: 'Backup overdue' };

export function protectionHealthItems(state: DashboardState, context: HealthContext = 'protection'): HealthItem[] {
  const freshness = state.freshness;
  const cloud = state.offsite;
  const s = state.status;
  // Protection has the hero (with its own button for a failed run) and Back up now above the cards; Settings has neither.
  const here = context === 'protection';
  // The provider is named only when the host's evidence names one ("Google Drive" for a direct My Drive proof); otherwise the page
  // says "off-site" and nothing more, because most backups have no off-site copy and one that does may be anywhere.
  const provider = (cloud.provider ?? '').trim();
  // The status could not be read: the page lost the host's answer (dataError), or the host could read no status file (status.unavailable,
  // which is not a failed run, so the failure wording below must not be used for it).
  const unavailable = !!state.dataError || !!s.unavailable;
  const hasTest = !!freshness.verifiedAt && freshness.state !== 'ClockAnomaly' && !unavailable;
  // The newest run's restore test outranks an older pass, which stays visible as "Last passed".
  const restoreFailed = !unavailable && s.failure && s.phaseLabel === RECOVERY_TEST_PHASE;
  const restoreRunning = !unavailable && s.active && s.phaseLabel === RECOVERY_TEST_PHASE;
  // Behind schedule is as red here as in the hero. A backup the person stopped, with the backups still on time, asks for nothing, and an
  // old restore test is not a second problem: the next backup runs it again.
  const behind = freshness.state === 'Overdue' || freshness.state === 'ClockAnomaly';
  const calmStop = s.cancelled && !s.failure && freshness.state === 'Healthy';
  const restoreTone: Tone = restoreFailed ? 'danger' : restoreRunning ? 'active'
    : hasTest ? (freshness.state === 'Healthy' ? 'success' : 'neutral')
    : unavailable || freshness.state === 'ClockAnomaly' ? 'warning' : 'neutral';
  const localTone: Tone = unavailable ? 'warning' : s.active ? 'active'
    : s.failure || behind ? 'danger' : calmStop ? 'neutral' : s.cancelled ? 'warning' : freshness.state === 'Healthy' ? 'success' : 'warning';
  // An off-site copy waiting for its next check is neutral: Rewindle does the check by itself, so nothing is asked of the person.
  const cloudWaiting = cloud.kind === 'Stale';
  const cloudTone: Tone = unavailable ? 'warning' : cloud.kind === 'RestoreVerified' || cloud.kind === 'ProviderConfirmed' ? 'success'
    : cloud.kind === 'Failed' ? 'danger' : cloud.kind === 'InProgress' ? 'active'
    : cloud.kind === 'NotConfigured' || cloudWaiting ? 'neutral' : 'warning';
  const cloudTitles: Record<DashboardState['offsite']['kind'], string> = {
    NotConfigured: 'Not set up (optional)', StatusUnavailable: 'Can’t be confirmed yet', Stale: 'Waiting for the next check', Failed: 'The last check failed',
    InProgress: 'Being checked', LocalVerifiedProviderPending: provider ? `Waiting for ${provider} to confirm` : 'Waiting for confirmation',
    ProviderConfirmed: provider ? `Confirmed by ${provider}` : 'Off-site copy confirmed', RestoreVerified: provider ? `Verified in ${provider}` : 'Off-site copy verified',
  };
  // The description under the title is worded per kind, so for an off-site copy that failed or cannot be confirmed the cause the host
  // reports would only be inside the closed disclosure. It is brought up as one line and the disclosure opens with it. A status that
  // could not be read has no current cause to report.
  const cloudProblem = !unavailable && (cloudTone === 'danger' || cloudTone === 'warning');
  // A backup with no off-site copy is not a problem and asks for nothing: it is one quiet line, not a card (see `compact`). It names no
  // provider, because nothing says there is one.
  const cloudOptional = !unavailable && cloud.kind === 'NotConfigured';
  const cloudDetails: Record<DashboardState['offsite']['kind'], string> = {
    NotConfigured: 'No off-site copy is set up. That is optional: your backup on this computer works without one.',
    StatusUnavailable: 'Rewindle could not confirm the off-site copy just now. Your backup on this computer is not affected.',
    Stale: `Your latest backup hasn’t been checked in ${provider || 'the off-site copy'} yet. The next check will cover it, so there is nothing to do.`,
    Failed: 'The last check of the off-site copy did not succeed. What was reported is below.',
    InProgress: provider ? `The copy in ${provider} is being checked. The result appears here when it finishes.` : 'The off-site copy is being checked. The result appears here when it finishes.',
    LocalVerifiedProviderPending: `The backup passed the checks on this computer. Confirmation from ${provider || 'the off-site provider'} is still pending.`,
    ProviderConfirmed: `${provider || 'The off-site provider'} confirmed the copy. A test restore from it has not been done yet.`,
    RestoreVerified: provider ? `${provider} holds a complete copy of your backups, and a test restore from ${provider} worked.` : 'The off-site location holds a complete copy of your backups, and a test restore from it worked.',
  };
  // What the local card offers follows what is wrong, and its next step says the same thing in words (so both are decided in this order).
  // On Protection a run in progress is shown by the hero, a failed run has its button there, and a backup that is due is made with the Back up
  // now at the top of the page, so the card does not repeat those buttons; Settings has none of them, so there the card carries them. A
  // schedule that cannot be read is looked at in Settings.
  const needsBackup = freshness.state === 'Overdue' || freshness.state === 'NoVerifiedBackup';
  const viewActivity: ItemAction | undefined = here ? undefined : { command: 'navigate', label: 'View activity', payload: { page: 'Activity' } };
  const heroOffersRun = here && !!s.runId;
  const localAction: ItemAction | undefined = unavailable ? { command: 'refresh', label: 'Try again' }
    : s.active ? viewActivity
    : freshness.state === 'Paused' ? { command: 'editSchedule', label: 'Review schedule' }
    : freshness.state === 'ClockAnomaly' ? { command: 'refresh', label: 'Try again' }
    : s.failure ? (heroOffersRun ? undefined : { command: 'navigate', label: 'See what happened', payload: { page: 'Activity' } })
    : needsBackup ? (here ? undefined : { command: 'backupNow', label: 'Back up now' })
    : s.cancelled ? viewActivity
    : freshness.state === 'Unavailable' ? (here ? { command: 'navigate', label: 'Open Settings', payload: { page: 'Settings' } } : { command: 'refresh', label: 'Try again' })
    : viewActivity;
  const checkReadiness: ItemAction = { command: 'checkReadiness', label: state.actions.checkReadiness?.label || 'Check recovery readiness' };
  return [
    {
      key: 'local', label: 'Local backup', tone: localTone,
      title: unavailable ? 'Status unavailable' : s.active ? 'Backup in progress' : s.failure ? 'Latest backup did not finish' : s.cancelled ? 'Latest backup was stopped' : FRESHNESS_TITLE[freshness.state] || freshness.title || 'Not verified yet',
      // A status file that could not be read has its own sentence from the host (which file, and why); a page that lost the host has none.
      detail: unavailable ? (!state.dataError && s.detail) || 'Rewindle could not read the backup status just now. It tries again on its own.'
        : s.active ? (here ? 'A backup is running now. Progress is shown above.' : s.detail)
        : s.failure ? (here ? 'This run is not counted as a backup.' : s.detail)
        : s.cancelled ? (calmStop ? 'You stopped the latest backup before it finished. Your earlier backups are not affected.' : here ? 'The latest backup was stopped before it finished.' : s.detail)
        : freshness.state === 'Healthy' ? 'Nothing needs your attention.'
        : (here && FRESHNESS_CAUSE[freshness.state]) || freshness.detail,
      // The hero already says when the last verified backup finished.
      timestamp: unavailable || here ? '' : freshness.verifiedAt, timestampLabel: 'Last verified',
      nextStep: unavailable ? ''
        : s.active ? ''
        : freshness.state === 'Paused' ? 'Choose Review schedule to turn automatic backups back on.'
        : freshness.state === 'ClockAnomaly' ? 'Set the date and time in Windows Settings, then choose Try again.'
        : s.failure ? (heroOffersRun ? '' : 'Open the latest run in Activity to see what happened.')
        : needsBackup ? (here ? 'Choose Back up now at the top of this page.' : 'Choose Back up now below.')
        : s.cancelled ? (calmStop ? '' : here ? 'Choose Back up now at the top of this page to run it again.' : 'Start a backup from Protection to run it again.')
        : freshness.state === 'Unavailable' ? (here ? 'Open Settings to check the schedule under Automatic backups.' : 'Check the schedule under Automatic backups, above.')
        : '',
      action: localAction,
      primary: context === 'settings' && localAction?.command === 'backupNow',
    },
    {
      key: 'cloud', label: 'Off-site copy', tone: cloudTone,
      title: unavailable ? 'Status unavailable' : cloudTitles[cloud.kind] || 'Can’t be confirmed yet',
      detail: unavailable ? 'Rewindle could not read the off-site status just now.' : cloudDetails[cloud.kind] || 'There is no current check result.',
      timestamp: unavailable || cloudOptional ? '' : cloud.checkedAt,
      timestampLabel: cloudTone === 'success' ? 'Last verified' : 'Last checked',
      // Rewindle checks the off-site copy by itself (nothing on this page starts that check), so there is no button and nothing to wait for.
      nextStep: cloud.kind === 'Failed' ? `Make sure ${provider || 'the off-site location'} is available. Rewindle checks again automatically.`
        : cloud.kind === 'StatusUnavailable' ? 'Rewindle checks again automatically. The details below say what it found.' : '',
      reason: cloudProblem ? briefReason(cloud.detail) : '',
      evidence: cloudOptional ? undefined : [cloud.title, cloud.detail, cloud.evidence].filter(Boolean).join('\n\n'),
      openEvidence: cloudProblem,
      compact: cloudOptional,
    },
    {
      key: 'restore', label: 'Restore test', tone: restoreTone,
      title: restoreFailed ? 'Latest restore test failed' : restoreRunning ? 'Restore test running'
        : hasTest ? (restoreTone === 'success' ? 'Restore test passed' : freshness.state === 'Unavailable' ? 'Passed earlier' : 'Passed earlier, not re-tested')
        : restoreTone === 'neutral' ? 'Not tested yet' : 'Restore test not confirmed',
      detail: restoreFailed ? `The newest backup could not restore its test file.${hasTest ? ' An earlier restore test did pass.' : ' No earlier restore test passed.'}`
        : restoreRunning ? 'The current backup is restoring its test file to confirm that recovery works.'
        : hasTest ? (restoreTone === 'success' ? 'The latest verified backup restored its test file successfully.'
          : freshness.state === 'Paused' ? 'Automatic backups are paused, so the restore test has not run since this earlier pass.'
          : freshness.state === 'Unavailable' ? 'The backup schedule could not be read, so this test cannot be judged current.'
          : 'This test is older than the schedule expects. The next verified backup runs it again.')
        : restoreTone === 'neutral' ? 'No verified backup has run a restore test yet. The first one restores a small test file.'
        : 'There is no restore test result that can be trusted right now.',
      // The hero already says when the last verified backup finished; this is the time of the same backup's restore test.
      timestamp: hasTest && !here ? freshness.verifiedAt : '', timestampLabel: 'Last passed',
      nextStep: restoreFailed ? `Choose ${checkReadiness.label} to find out why, then choose Back up now to try again.`
        : restoreTone === 'warning' ? `${checkReadiness.label} opens a separate window that tests that your backup can be unlocked and restored.` : '',
      evidence: 'After every backup, Rewindle restores a small test file and checks it. That shows recovery works; it does not mean every backed-up file has been restored.',
      action: checkReadiness,
      subdued: restoreTone === 'success' || restoreTone === 'neutral',
    },
  ];
}

// `quiet` is for a page that already says why its controls are paused (see busyNote in App.tsx): the reason
// stays linked for assistive technology and shows as a tooltip, but takes no room, so these cards do not
// grow when a backup starts.
function HealthAction({ item, state, send, quiet, locale }: { item: HealthItem; state: DashboardState; send: Send; quiet: boolean; locale?: string }) {
  const id = useId();
  // Try again asks the host to read its status files again, and the host answers with nothing to show unless a file changed, so a
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
    if (refreshes) setReread(previous => ({ at: formatClock(new Date().toISOString(), locale), count: (previous?.count ?? 0) + 1 }));
  };
  return <div className="health-action" title={quiet && reason ? reason : undefined}><Button size="xs" variant={item.primary ? 'primary' : item.subdued ? 'quiet' : 'secondary'} disabled={!!reason} aria-describedby={reason ? id : undefined}
    onClick={press}>{starts && <Icon size={11} fill="currentColor" aria-hidden="true" />}{action.label}{!starts && <Icon size={12} aria-hidden="true" />}</Button>
    {reason && <p id={id} className={quiet ? 'sr-only' : 'action-disabled-reason'}>{reason}</p>}
    {/* Always present, so a note that appears after a press is announced. */}
    {refreshes && <div role="status">{reread && <p key={reread.count} className="action-disabled-reason health-reread">Status read again at {reread.at}.</p>}</div>}</div>;
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
      const when = healthAge(item.timestamp, locale);
      return <motion.article key={item.key} className={`health-card surface health-${item.tone}`}
        initial={{ opacity: 0, y: state.reducedMotion ? 0 : 5 }} animate={{ opacity: 1, y: 0 }}
        transition={{ duration: state.reducedMotion ? 0 : .24, delay: state.reducedMotion ? 0 : index * .035 }}>
        <div className="health-card-label"><Icon size={15} aria-hidden="true" />{item.label}</div>
        <div className="health-card-status"><StatusIcon size={15} aria-hidden="true" /><h3>{(item.tone === 'warning' || item.tone === 'danger') && <span className="sr-only">Needs attention: </span>}{item.title}</h3></div>
        <p className="health-description">{item.detail}</p>
        {item.reason && <p className="health-reason"><span className="sr-only">Reported: </span>{item.reason}</p>}
        {when && <p className="health-time">{item.timestampLabel} <time dateTime={item.timestamp}>{when}</time></p>}
        {item.nextStep && <p className="health-next-step">{item.nextStep}</p>}
        {/* `open` is only the state the card is drawn in: React leaves the element alone until the prop changes, so a person who closes it keeps it closed. */}
        {item.evidence && <details className="health-evidence" open={item.openEvidence}><summary>{item.key === 'cloud' ? 'Details' : 'What this test covers'}<ChevronDown size={12} aria-hidden="true" /></summary><p>{item.evidence}</p></details>}
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
