// A stand-in for the desktop app's Restore flow, for the sample data (`npm run dev:demo`). Every backup, folder and file here is
// invented, and nothing is read or written: it only moves the page through the same steps and states the real flow publishes, with
// the host's own words, so every screen of Restore can be looked at without a backup installation.
//
// A few folder names make the sample show the screens that are hard to reach for real. In the "folder to restore into" field:
//   "decline" ends the restore as if Windows permission was declined, "partial" as a restore that stopped part-way, "fail" as one
//   that failed, "small" as a drive with too little room for everything, "OneDrive" as a folder Rewindle cannot restore into,
//   "full" as a folder that already has files in it, and a path in Documents, Pictures, Desktop, Music or Projects as a folder that
//   is itself backed up. The page's URL decides how Windows asks: `?session=once` is one prompt for the whole restore; without it,
//   every folder opened is its own prompt, as on the earlier edition of the backup service.
import type { DashboardState, RestoreEntry, RestoreFlowState, RestoreSnapshot } from '../native-types';
import { createSampleRuns, formatBytes } from './demoState';

type Payload = Record<string, string | boolean> | undefined;

const USER = '/C/Users/you';
const GIB = 1024 ** 3;
const FREE_BYTES = 412 * GIB;
const PROMPT_MS = 1600;
const READ_MS = 500;
const RESTORE_MS = 5200;

const folder = (parent: string, name: string): RestoreEntry => ({ name, path: `${parent === '/' ? '' : parent}/${name}`, type: 'dir', size: 0, sizeDisplay: 'Folder' });
const file = (parent: string, name: string, size: number): RestoreEntry => ({ name, path: `${parent}/${name}`, type: 'file', size, sizeDisplay: formatBytes(size) });

// What each folder of the sample backup holds. A folder that is not listed is empty.
const TREE: Record<string, RestoreEntry[]> = {
  '/': [folder('/', 'C')],
  '/C': [folder('/C', 'Users')],
  '/C/Users': [folder('/C/Users', 'you')],
  [USER]: ['Desktop', 'Documents', 'Music', 'Pictures', 'Projects'].map(name => folder(USER, name)),
  [`${USER}/Desktop`]: [file(`${USER}/Desktop`, 'Shopping list.txt', 1_300)],
  [`${USER}/Documents`]: [folder(`${USER}/Documents`, 'Letters'), folder(`${USER}/Documents`, 'Taxes'), file(`${USER}/Documents`, 'Budget 2026.xlsx', 48_200), file(`${USER}/Documents`, 'Notes.txt', 2_100), file(`${USER}/Documents`, 'Resume.docx', 96_400)],
  [`${USER}/Documents/Letters`]: [file(`${USER}/Documents/Letters`, 'Insurance claim.pdf', 520_000), file(`${USER}/Documents/Letters`, 'Landlord.docx', 41_000)],
  [`${USER}/Documents/Taxes`]: [file(`${USER}/Documents/Taxes`, '2025 return.pdf', 1_240_000), file(`${USER}/Documents/Taxes`, 'Receipts.zip', 18_700_000), file(`${USER}/Documents/Taxes`, 'W-2.pdf', 310_000)],
  [`${USER}/Music`]: [file(`${USER}/Music`, 'Playlist.m3u', 4_800)],
  [`${USER}/Pictures`]: [folder(`${USER}/Pictures`, 'Holiday 2026'), file(`${USER}/Pictures`, 'Cat.jpg', 3_400_000)],
  [`${USER}/Pictures/Holiday 2026`]: [file(`${USER}/Pictures/Holiday 2026`, 'Beach.jpg', 4_100_000), file(`${USER}/Pictures/Holiday 2026`, 'Hotel.jpg', 3_700_000)],
  [`${USER}/Projects`]: [folder(`${USER}/Projects`, 'garden-planner'), file(`${USER}/Projects`, 'todo.md', 900)],
  [`${USER}/Projects/garden-planner`]: [file(`${USER}/Projects/garden-planner`, 'README.md', 2_600), file(`${USER}/Projects/garden-planner`, 'plan.json', 14_300)],
};

const BACKED_UP = ['documents', 'pictures', 'desktop', 'music', 'projects'];
const plural = (count: number, one: string, many: string) => `${count.toLocaleString()} ${count === 1 ? one : many}`;

function sampleSnapshots(now: number): RestoreSnapshot[] {
  const sources = 'C:\\Users\\you\\Desktop, C:\\Users\\you\\Documents, C:\\Users\\you\\Music, C:\\Users\\you\\Pictures, C:\\Users\\you\\Projects';
  return createSampleRuns(now).filter(run => run.success && run.snapshot).slice(0, 14).map((run, index, all): RestoreSnapshot => ({
    id: `${run.snapshot}${'0'.repeat(56)}`, shortId: run.snapshot, when: run.started, whenDisplay: run.startedDisplay, hostname: 'YOUR-PC', configGeneration: '1',
    fileCount: run.files, fileCountDisplay: run.files.toLocaleString(), byteCount: run.processedBytes, sizeDisplay: run.processedDisplay,
    sourceSummary: sources, bindingState: index === all.length - 1 ? 'legacy_unbound' : 'plan', isLegacyUnbound: index === all.length - 1,
  }));
}

export interface RestoreDemo {
  /** The commands the Restore flow answers; the bridge hands them over. Returns why one was refused, or null. */
  handles(command: string): boolean;
  handle(command: string, payload: Payload): string | null;
}

export function createRestoreDemo(getState: () => DashboardState, notify: () => void): RestoreDemo {
  const eachStep = !new URLSearchParams(window.location.search).get('session');
  let flow: RestoreFlowState | null = null;
  let generation = 0;
  const cache = new Set<string>();
  let promptsGiven = 0;

  const later = (ms: number, step: () => void) => {
    const mine = generation;
    window.setTimeout(() => { if (flow && mine === generation) { step(); notify(); } }, ms);
  };
  const say = (title: string, detail: string) => { if (flow) flow.message = { title, detail }; };
  const chosen = () => flow?.snapshots.find(snapshot => snapshot.id === flow?.selectedSnapshotId) ?? null;
  const approvalNotice = () => eachStep
    ? 'Windows asks for your permission each time Rewindle opens your backup. Looking at it does not change anything.'
    : promptsGiven > 0 ? 'The earlier permission has ended, so Windows will ask for your permission again to let Rewindle read and restore from your backup.'
      : 'Windows will ask once for your permission to let Rewindle read and restore from your backup.';
  // A protected step: Windows asks first (every step on the earlier edition, once for the whole flow otherwise), then the step runs.
  const protectedStep = (ms: number, done: () => void, begin: () => void) => {
    if (!flow) return;
    begin();
    const asks = eachStep || promptsGiven === 0;
    flow.busy = true;
    flow.status = 'loading';
    flow.approval = { waiting: asks, session: !eachStep, notice: approvalNotice() };
    if (asks) say('Waiting for Windows permission…', approvalNotice());
    later(asks ? PROMPT_MS : 0, () => {
      if (!flow) return;
      if (asks) promptsGiven += 1;
      flow.approval = { waiting: false, session: !eachStep, notice: approvalNotice() };
      later(ms, () => { if (!flow) return; flow.busy = false; done(); });
    });
  };

  const validate = () => {
    if (!flow) return;
    const snapshot = chosen();
    const errors: string[] = [];
    if (!snapshot) errors.push('Choose a backup before continuing.');
    if (!flow.wholeSnapshotSelected && flow.selectedPaths.length === 0) errors.push('Choose files or folders, or choose everything in the backup.');
    if (flow.wholeSnapshotSelected && flow.selectedPaths.length) errors.push('Choose either some items or everything in the backup, not both.');
    if (flow.destination.checking || !flow.destination.valid) errors.push(flow.destination.status || 'Choose a new or empty folder to restore into.');
    const warnings: string[] = [];
    if (snapshot?.isLegacyUnbound) warnings.push('This backup was made before your current backup settings. Confirm that you want to restore from it.');
    const free = /small/i.test(flow.destination.path) ? GIB : FREE_BYTES;
    let spaceWarning = '';
    if (snapshot && flow.wholeSnapshotSelected && flow.destination.valid && snapshot.byteCount + snapshot.byteCount / 20 > free) {
      spaceWarning = `Everything in this backup is about ${snapshot.sizeDisplay}, but only ${formatBytes(free)} is free on D:. The restore may stop part-way. Choose a drive with more room if you can.`;
      warnings.push(spaceWarning);
    }
    flow.destination.freeDisplay = flow.destination.valid ? formatBytes(free) : '';
    flow.destination.drive = flow.destination.valid ? 'D:' : '';
    flow.validation = {
      ready: errors.length === 0 && !flow.destination.checking, errors, warnings, spaceWarning,
      scopeLabel: flow.wholeSnapshotSelected ? 'Everything in this backup' : plural(flow.selectedPaths.length, 'item', 'items'),
    };
  };

  const listFolder = (path: string) => {
    if (!flow) return;
    const entries = TREE[path] ?? [];
    flow.tree = { path, entries, total: entries.length, truncated: false, loading: false, error: '', errorPath: '', loaded: true };
    flow.step = 'files';
    flow.status = 'ready';
    const where = path === '/' ? 'the top level of your backup' : path.replace(/^\/([A-Za-z])(?=\/|$)/, '$1:').replace(/\//g, '\\');
    say('Choose files', `${plural(entries.length, 'item', 'items')} in ${where}.`);
  };

  const checkFolder = (path: string) => {
    if (!flow) return;
    const target = path.trim();
    flow.destination = { path: target, valid: false, checking: true, status: 'Checking that this folder is empty and safe to use…', error: '' };
    flow.busy = false;
    say('Checking folder', 'Restore only writes to a new or empty folder.');
    validate();
    later(READ_MS + 200, () => {
      if (!flow) return;
      let error = '';
      if (!/^[A-Za-z]:\\/.test(target)) error = 'Use an absolute local path, such as C:\\Restores\\2026-09-14.';
      else if (/onedrive/i.test(target)) error = 'This folder is inside OneDrive or is a shortcut or link, which Rewindle cannot restore into. Choose a folder that is not synced to OneDrive, for example a new folder on a local drive.';
      else if (/^[A-Za-z]:\\?$/.test(target)) error = 'This is a drive root, which usually holds hidden system folders that Explorer does not show. Choose or create a folder on this drive instead, for example D:\\Rewindle restore.';
      else if (BACKED_UP.some(name => target.toLowerCase().startsWith(`c:\\users\\you\\${name}`))) error = 'That folder is part of what Rewindle backs up or where its backups are kept. Choose a different folder, for example a new folder on another drive.';
      else if (/full/i.test(target)) error = 'That folder already has files in it. Choose a new or empty folder; Rewindle never overwrites files.';
      flow.destination = {
        path: target, valid: !error, checking: false, error,
        status: error || (/exists/i.test(target) ? 'Ready · this existing folder is empty and will hold the restored files.' : 'Ready · this new folder will be created for the restored files.'),
      };
      validate();
      say(error ? 'Choose another folder' : 'Folder ready', 'Nothing is restored until the last step.');
    });
  };

  const finish = () => {
    if (!flow) return;
    const target = flow.destination.path;
    flow.busy = false;
    flow.approval = { waiting: false, session: !eachStep, notice: approvalNotice() };
    flow.progress = { stage: 'complete', message: '', percent: 100, awaitingApproval: false };
    const outcome = /decline/i.test(target) ? 'cancelled' : /partial/i.test(target) ? 'partial' : /fail/i.test(target) ? 'error' : 'success';
    if (outcome === 'cancelled') {
      flow.step = 'error'; flow.status = 'failed';
      flow.result = { ...flow.result, status: 'cancelled', target: '', verified: false, error: 'Nothing was restored. Rewindle needs that permission to read your backup.', title: 'Windows permission was not given', message: 'Nothing was restored. Rewindle needs that permission to read your backup.', retryable: true, retryLabel: 'Try again' };
      say('Windows permission was not given', 'Nothing was restored. Rewindle needs that permission to read your backup.');
    } else if (outcome === 'error') {
      flow.step = 'error'; flow.status = 'failed';
      flow.result = { ...flow.result, status: 'error', target: '', verified: false, error: 'Rewindle could not confirm the result of this step, so it was not used. Your files and backups were not changed. Try again.', title: 'Restore did not finish', message: 'Rewindle could not confirm the result of this step, so it was not used. Your files and backups were not changed. Try again.', retryable: true, retryLabel: 'Try again' };
      say('Restore did not finish', flow.result.message || '');
    } else if (outcome === 'partial') {
      flow.step = 'partial'; flow.status = 'partial';
      flow.result = { ...flow.result, status: 'partial', target, verified: false, error: 'The drive stopped answering before every file was copied.', title: 'Restore incomplete', message: 'The drive stopped answering before every file was copied.', retryable: true, retryLabel: 'Try again' };
      say('Restore incomplete', 'The drive stopped answering before every file was copied. Some files were copied to the folder you chose; your current files were not changed.');
    } else {
      flow.step = 'success'; flow.status = 'succeeded';
      flow.result = { ...flow.result, status: 'success', target, verified: true, error: '', title: 'Restore complete and verified', message: '', retryable: false, retryLabel: 'Try again' };
      say('Restore complete and verified', `Your files are in ${target}.`);
    }
  };

  const open = () => {
    generation += 1;
    cache.clear();
    promptsGiven = 0;
    const snapshots = sampleSnapshots(Date.now());
    flow = {
      open: true, busy: true, step: 'backup', status: 'loading', canCancel: false, startBlocked: '',
      message: { title: 'Choose a backup', detail: 'Opening your list of backups…' },
      snapshots: [], selectedSnapshotId: '', limits: { maxPaths: 64 },
      tree: { path: '/', entries: [], total: 0, truncated: false, loading: false, error: '', errorPath: '', loaded: false },
      selectedPaths: [], wholeSnapshotSelected: false,
      destination: { path: '', valid: false, checking: false, status: 'Choose a new or empty folder.', error: '' },
      validation: { ready: false, errors: [], warnings: [], spaceWarning: '', scopeLabel: 'Nothing chosen yet' },
      progress: { stage: '', message: '', percent: 0, awaitingApproval: false },
      result: { status: null, target: '', verified: false, error: null, snapshotId: '' },
      approval: { waiting: false, session: !eachStep, notice: approvalNotice() },
    };
    getState().restoreFlow = flow;
    protectedStep(READ_MS, () => {
      if (!flow) return;
      flow.snapshots = snapshots;
      flow.status = 'ready';
      say('Choose a backup', `${snapshots.length} backups are available.`);
    }, () => say('Loading your backups', 'Looking at your backups does not change them.'));
  };

  const handle = (command: string, payload: Payload): string | null => {
    if (command === 'openRestore' || command === 'restoreFlowOpen') {
      open();
      return null;
    }
    if (!flow) return 'Open Restore first.';
    const busyReason = flow.busy || flow.destination.checking ? 'Restore is still working. Wait for it to finish.' : null;
    switch (command) {
      case 'restoreFlowNavigate': {
        if (busyReason) return busyReason;
        const step = String(payload?.step ?? '');
        const id = String(payload?.snapshotId ?? '');
        if (id && id !== flow.selectedSnapshotId) {
          if (!flow.snapshots.some(snapshot => snapshot.id === id)) return 'Choose one of the backups in the list.';
          flow.selectedSnapshotId = id;
          flow.selectedPaths = []; flow.wholeSnapshotSelected = false;
          flow.tree = { path: '/', entries: [], total: 0, truncated: false, loading: false, error: '', errorPath: '', loaded: false };
        }
        if (step === 'backup') { flow.step = 'backup'; flow.status = 'ready'; say('Choose a backup', 'Choose a backup to continue.'); }
        else if (step === 'files') {
          if (!chosen()) return 'Choose a backup before choosing files.';
          flow.step = 'files'; flow.status = 'ready';
          say('Choose files', 'Nothing is restored until the last step.');
        } else if (step === 'destination') {
          if (!flow.wholeSnapshotSelected && flow.selectedPaths.length === 0) return 'Choose files or folders first, or choose everything in the backup.';
          flow.step = 'destination'; flow.status = 'ready';
          say('Choose a folder', 'Nothing is restored until the last step.');
        } else return 'The requested restore step is invalid.';
        validate();
        return null;
      }
      case 'restoreFlowBrowseFiles': {
        if (busyReason) return busyReason;
        const path = String(payload?.path ?? '') || '/';
        const previous = flow.tree;
        if (cache.has(path)) { listFolder(path); return null; }
        protectedStep(READ_MS, () => {
          if (!flow) return;
          cache.add(path);
          listFolder(path);
        }, () => {
          if (!flow) return;
          flow.step = 'files';
          flow.tree = { ...previous, path, loading: true, error: '', errorPath: '' };
          say('Opening folder', 'Opening your backup.');
        });
        flow.tree = { ...previous, path, loading: true, error: '', errorPath: '' };
        return null;
      }
      case 'restoreFlowSelectPaths': {
        if (busyReason) return busyReason;
        const paths = String(payload?.paths ?? '').split('\n').map(item => item.trim()).filter(Boolean);
        const whole = payload?.wholeSnapshot === true || payload?.wholeSnapshot === 'true';
        if (!whole && paths.length > 64) return 'Select at most 64 items for one restore. Tick a parent folder to include more.';
        flow.selectedPaths = whole ? [] : paths;
        flow.wholeSnapshotSelected = whole;
        flow.step = 'files'; flow.status = 'ready';
        say(whole ? 'Everything selected' : 'Selection updated', whole ? 'Everything in this backup will be restored.' : `${plural(paths.length, 'item', 'items')} selected.`);
        validate();
        return null;
      }
      case 'restoreFlowBrowseDestination':
        if (busyReason) return busyReason;
        checkFolder('D:\\Restored files');
        return null;
      case 'restoreFlowValidateDestination': {
        if (busyReason) return busyReason;
        const path = String(payload?.path ?? '').trim();
        if (!path) return 'Choose a new or empty folder to restore into.';
        checkFolder(path);
        return null;
      }
      case 'restoreFlowReview':
        if (busyReason) return busyReason;
        validate();
        if (!flow.validation.ready) return flow.validation.errors[0] || 'Review your choices before starting.';
        flow.step = 'review'; flow.status = 'ready';
        say('Review restore', 'Check your choices, then press Restore now.');
        return null;
      case 'restoreFlowStart': {
        if (busyReason) return busyReason;
        if (flow.step !== 'review') return 'Review your choices before starting.';
        if (chosen()?.isLegacyUnbound && payload?.legacyConfirmed !== true && payload?.legacyConfirmed !== 'true') return 'Confirm that you want to restore from this older backup first.';
        flow.step = 'progress'; flow.status = 'running'; flow.busy = true;
        flow.result = { status: null, target: '', verified: false, error: null, snapshotId: flow.selectedSnapshotId };
        const asks = eachStep || promptsGiven === 0;
        flow.progress = { stage: 'preflight', message: asks ? 'Waiting for your permission on the Windows prompt before anything is written.' : 'Starting the restore.', percent: 0, awaitingApproval: asks };
        flow.approval = { waiting: asks, session: !eachStep, notice: approvalNotice() };
        say('Starting restore', 'Files are only added to the folder you chose. Nothing is overwritten.');
        later(asks ? PROMPT_MS : 300, () => {
          if (!flow) return;
          if (asks) promptsGiven += 1;
          flow.approval = { waiting: false, session: !eachStep, notice: approvalNotice() };
          if (/decline/i.test(flow.destination.path)) { finish(); return; }
          flow.progress = { stage: 'restoring', message: 'Copying your files into the folder you chose, then checking each one.', percent: 0, awaitingApproval: false };
          say('Restoring', 'Copying your files into the folder you chose, then checking each one.');
          later(RESTORE_MS, finish);
        });
        return null;
      }
      case 'restoreFlowCancel':
        return flow.step === 'progress' ? 'The restore is running and cannot be stopped safely. Keep this window open until it finishes.' : busyReason ?? 'There is nothing to cancel.';
      case 'restoreFlowRetry': {
        if (busyReason) return busyReason;
        const status = flow.result.status;
        flow.result = { status: null, target: '', verified: false, error: null, snapshotId: flow.selectedSnapshotId };
        if (!flow.snapshots.length) { open(); return null; }
        if (status === 'cancelled') { flow.step = 'review'; flow.status = 'ready'; say('Review restore', 'Check your choices, then press Restore now.'); return null; }
        flow.destination = { ...flow.destination, valid: false, checking: false, error: '', status: flow.destination.path ? 'Choose a different empty folder, or check this one again.' : 'Choose a new or empty folder.' };
        flow.step = 'destination'; flow.status = 'ready';
        say('Choose a folder again', flow.destination.status);
        validate();
        return null;
      }
      case 'restoreFlowClose':
        if (flow.busy) return 'Wait for this step to finish before closing Restore.';
        generation += 1;
        flow = null;
        getState().restoreFlow = null;
        return null;
      case 'restoreFlowOpenDestination':
      case 'restoreFlowCopyDestination':
        return 'This is sample data, so no real folder exists to open or copy.';
      default:
        return 'The requested restore-flow command is not allowed.';
    }
  };

  return {
    handles: command => command === 'openRestore' || command.startsWith('restoreFlow'),
    handle,
  };
}
