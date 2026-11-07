// Backup alerts in the sample data (`npm run dev:demo`). `?alerts=overdue`, `?alerts=failing` or `?alerts=paused` puts the sample in
// that state, so the Protection concern, the schedule card's last start and the Settings switch can be seen without a backup
// installation. Read once at start, like restoreDemo's `?session`. The tray mark and the Windows notification belong to the desktop
// app and have no sample. Everything here is invented.
import type { DashboardState } from '../native-types';

const HOUR = 3_600_000;
const pad = (n: number) => String(n).padStart(2, '0');
const sentence = (date: Date) => date.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false });

/** The sample's answer to Settings > Backup alerts. Null when it took the choice, or why it refused it (as the host words it). */
export function setSampleAlerts(state: DashboardState, payload: Record<string, string | boolean> | undefined): string | null {
  const notify = String(payload?.notify ?? '');
  if (notify !== 'on' && notify !== 'off') return 'The requested alert setting is not valid.';
  if (state.alerts) state.alerts.notify = notify === 'on';
  return null;
}

export function applyAlertsScenario(state: DashboardState, now = Date.now()): void {
  const scenario = new URLSearchParams(window.location.search).get('alerts');
  if (!state.alerts || !scenario) return;
  // Today's 02:00 slot when it is more than two hours past, otherwise yesterday's.
  const slot = new Date(now);
  slot.setHours(2, 0, 0, 0);
  if (slot.getTime() > now - 2 * HOUR) slot.setDate(slot.getDate() - 1);
  const today = new Date(now).toDateString() === slot.toDateString();
  const when = `${today ? 'today' : 'yesterday'} at ${pad(slot.getHours())}:${pad(slot.getMinutes())}`;
  const overdue = () => {
    const verified = new Date(state.freshness.verifiedAt);
    state.freshness = {
      ...state.freshness, state: 'Overdue', title: 'Overdue',
      detail: `The backup due on ${sentence(slot)} did not complete. Your last good backup was ${sentence(verified)}. Choose Back up now to catch up.`,
    };
    state.status = { ...state.status, title: 'Backup overdue', detail: state.freshness.detail, badge: 'BACKUP OVERDUE' };
  };
  if (scenario === 'overdue') {
    overdue();
    state.alerts = {
      ...state.alerts, level: 'attention', reason: 'overdue', lastRun: { at: state.history[0].started, ok: true, code: 'code 0' },
      missedRun: { kind: 'pcOff', at: slot.toISOString(), text: `The PC was off, asleep or signed out ${when}, and Windows hasn’t run the missed backup yet.`, nextStep: '', code: '', tone: 'warning' },
    };
  } else if (scenario === 'failing') {
    const backups = state.history.filter(item => item.type === 'Backup');
    for (const run of backups.slice(0, 3)) {
      run.success = false; run.result = 'Failed'; run.snapshot = ''; run.storedBytes = 0; run.storedDisplay = '0 B';
    }
    const lastGood = backups.slice(3).find(run => run.success);
    if (lastGood) state.freshness = { ...state.freshness, verifiedAt: new Date(Date.parse(lastGood.started) + lastGood.durationSeconds * 1000).toISOString() };
    overdue();
    const latest = state.history[0];
    state.status = {
      ...state.status, key: 'failed', success: false, failure: true, title: 'Backup didn’t finish', badge: 'NEEDS ATTENTION', runId: latest.id,
      detail: 'The backup couldn’t read some of your files. See what happened for the details.',
    };
    state.alerts = {
      ...state.alerts, level: 'failing', reason: 'failing', failedRuns: 3, lastRun: { at: latest.started, ok: false, code: 'code 1' },
      missedRun: { kind: 'ranAndFailed', at: latest.started, text: `The backup that started ${when} didn’t finish.`, nextStep: 'Choose See what happened.', code: '', tone: 'danger' },
    };
  } else if (scenario === 'paused') {
    state.freshness = { ...state.freshness, state: 'Paused', title: 'Paused', detail: `Automatic backups are paused. Last verified ${sentence(new Date(state.freshness.verifiedAt))}.` };
    state.schedule = { ...state.schedule, summary: 'Paused — Daily at 02:00', nextRun: 'Paused', nextRunAt: '' };
    state.status = { ...state.status, title: 'Automatic backups paused', detail: state.freshness.detail, badge: 'PAUSED' };
    state.alerts = { ...state.alerts, level: 'attention', reason: 'paused' };
  }
}
