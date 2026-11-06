import type { CommandName, DashboardState, RetentionReviewRow, RetentionState } from '../native-types';

// Settings > Old backups with invented backups, for the sample bridge (mockBridge.ts). It only changes the in-memory sample:
// clean-up is shown on, with a list of old backups to look at, and Remove pretends to remove them. Nothing here reaches a backup.

type Payload = Record<string, string | boolean> | undefined;
const PAGE = 100;

function sampleRows(now: number): { remove: RetentionReviewRow[]; keep: RetentionReviewRow[] } {
  const day = 86_400_000;
  const remove: RetentionReviewRow[] = [];
  const keep: RetentionReviewRow[] = [];
  for (let index = 0; index < 160; index++) {
    const when = new Date(now - (index + 1) * day);
    when.setHours(2, 0, 0, 0);
    const row = { key: `sample${String(index).padStart(6, '0')}`, when: when.toISOString(), files: 12000 + index * 7, reasons: [] as string[] };
    if (index < 14) keep.push({ ...row, reasons: index === 0 ? ['latest', 'day', 'week', 'month'] : ['day'] });
    else if (index % 7 === 0 && index < 56) keep.push({ ...row, reasons: ['week'] });
    else if (index % 30 === 0) keep.push({ ...row, reasons: ['month'] });
    else remove.push(row);
  }
  return { remove, keep };
}

export function createSampleRetention(now = Date.now()): RetentionState {
  const rows = sampleRows(now);
  return {
    mode: 'on', unsupportedReason: '', keepDaily: 14, keepWeekly: 8, keepMonthly: 24,
    limits: { daily: [7, 90], weekly: [4, 104], monthly: [6, 120] }, recommended: { daily: 14, weekly: 8, monthly: 24 },
    resetByReinstall: false, problem: '',
    preview: {
      status: 'ready', blocked: '', errorCode: '', checkedAt: new Date(now - 3_600_000).toISOString(),
      removeCount: rows.remove.length, keepCount: rows.keep.length,
      oldestRemoveAt: rows.remove[rows.remove.length - 1].when, newestRemoveAt: rows.remove[0].when,
      earlierChangeAt: '', earlierChangesUnknown: false, futureDatedAt: '', prunePending: false,
    },
    lastRun: { finishedAt: new Date(now - 32 * 86_400_000).toISOString(), outcome: 'removed', removedCount: 9, confirmedCount: 9, freedDisplay: '3.4 GiB' },
    operation: { active: false, action: '', stage: '', count: 0, percent: null },
    notice: null,
    canConfigure: { enabled: true, help: '' }, canTurnOff: { enabled: true, help: '' },
    canReview: { enabled: true, help: '' }, canCheckNow: { enabled: true, help: '' },
    review: null,
  };
}

const COMMANDS: ReadonlySet<CommandName> = new Set<CommandName>([
  'retentionConfigure', 'retentionCheckNow', 'retentionOpenReview', 'retentionReviewPage', 'retentionApply', 'retentionCloseReview',
]);

export function createRetentionDemo(getState: () => DashboardState, publish: () => void) {
  let rows = sampleRows(Date.now());
  const retention = () => {
    const state = getState();
    if (!state.retention) state.retention = createSampleRetention();
    return state.retention;
  };
  const showPage = (list: 'remove' | 'keep', offset: number) => {
    const state = retention();
    if (!state.review) return;
    const source = list === 'remove' ? rows.remove : rows.keep;
    state.review.page = { list, offset, total: source.length, size: PAGE, rows: source.slice(offset, offset + PAGE) };
  };
  return {
    handles: (command: CommandName) => COMMANDS.has(command),
    handle(command: CommandName, payload: Payload): string | null {
      const state = retention();
      switch (command) {
        case 'retentionOpenReview': {
          if (state.preview?.status !== 'ready' || state.preview.removeCount === 0) return 'Nothing to remove right now.';
          const months = new Map<string, number>();
          for (const row of rows.remove) months.set(row.when.slice(0, 7), (months.get(row.when.slice(0, 7)) ?? 0) + 1);
          state.review = {
            removeCount: rows.remove.length, keepCount: rows.keep.length, newestKeptAt: rows.keep[0].when,
            earlierChanges: [], earlierChangesUnknown: false, needsFilesConfirmed: true, pruneOnly: false, changed: false, running: false,
            captureKey: `sample-${rows.remove.length}`, months: [...months.entries()].map(([month, count]) => ({ month, count })),
            page: { list: 'remove', offset: 0, total: 0, size: PAGE, rows: [] }, result: null,
          };
          showPage('remove', 0);
          return null;
        }
        case 'retentionReviewPage': {
          const list = payload?.list === 'keep' ? 'keep' : 'remove';
          showPage(list, Math.max(0, Number(payload?.offset ?? 0) || 0));
          return null;
        }
        case 'retentionApply': {
          if (!state.review) return 'Open the list of old backups first.';
          const removed = rows.remove.length;
          state.review.result = { status: 'removed', removedCount: removed, confirmedCount: removed, freedDisplay: '12.6 GiB', reason: '' };
          state.lastRun = { finishedAt: new Date().toISOString(), outcome: 'removed', removedCount: removed, confirmedCount: removed, freedDisplay: '12.6 GiB' };
          rows = { remove: [], keep: rows.keep };
          if (state.preview) { state.preview.removeCount = 0; state.preview.oldestRemoveAt = ''; state.preview.newestRemoveAt = ''; }
          publish();
          return null;
        }
        case 'retentionCloseReview':
          state.review = null;
          return null;
        case 'retentionCheckNow':
          state.notice = { text: 'Sample data: nothing was checked.', tone: 'info' };
          return null;
        default:
          return 'Sample data is read-only.';
      }
    },
  };
}
