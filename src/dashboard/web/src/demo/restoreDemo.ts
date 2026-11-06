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
// Find a file is offered only with `?session=once`, as the real host offers it only with a restore session. "Budget" finds a few
// versions and a file that is gone from the newer backups; a text with "older" in it stops after the newest backups (Look further
// back), "broad" and "slow" end as a name too common and a backup too large, and "fail" as a search that did not finish.
import type { BackupRangeState, DashboardState, RestoreEntry, RestoreFileSearch, RestoreFlowState, RestoreSearchResult, RestoreSnapshot } from '../native-types';
import { checkSearchText } from '../fileSearch';
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
// A file the older backups have and the newer ones do not (for "Not in your backups after …").
const DELETED: RestoreEntry = file(`${USER}/Documents`, 'Budget 2025.xlsx', 44_900);
const SEARCH_MS = 1800;
const SEARCH_PAGE = 6;
const emptySearch = (total: number): RestoreFileSearch => ({
  text: '', status: 'idle', outcome: '', message: '', error: '', listChanged: false, nothingSearched: false, searched: 0, total,
  searchedOldest: '', searchedOldestDisplay: '', canContinue: false, overflow: false, blocked: '', results: [], resultsTotal: 0,
});
const plural = (count: number, one: string, many: string) => `${count.toLocaleString()} ${count === 1 ? one : many}`;

function sampleSnapshots(now: number): RestoreSnapshot[] {
  const sources = 'C:\\Users\\you\\Desktop, C:\\Users\\you\\Documents, C:\\Users\\you\\Music, C:\\Users\\you\\Pictures, C:\\Users\\you\\Projects';
  return createSampleRuns(now).filter(run => run.success && run.snapshot).slice(0, 14).map((run, index, all): RestoreSnapshot => ({
    id: `${run.snapshot}${'0'.repeat(56)}`, shortId: run.snapshot, when: run.started, whenDisplay: run.startedDisplay, hostname: 'YOUR-PC', configGeneration: '1',
    fileCount: run.files, fileCountDisplay: run.files.toLocaleString(), byteCount: run.processedBytes, sizeDisplay: run.processedDisplay,
    sourceSummary: sources, bindingState: index === all.length - 1 ? 'legacy_unbound' : 'plan', isLegacyUnbound: index === all.length - 1,
  }));
}

/**
 * How far back the sample's backups go, from the same backups the Restore dialog lists, so the page and the dialog agree. Counted
 * by the backup service when the newest one finished, unless `asOfDaysEarlier` makes it a Restore-list count from that many days
 * before (which the page then dates: "· as of …").
 */
export function sampleBackupRange(now: number, asOfDaysEarlier = 0): BackupRangeState {
  const snapshots = sampleSnapshots(now);
  const times = snapshots.map(snapshot => Date.parse(snapshot.when));
  const newestRun = createSampleRuns(now).find(run => run.success && run.type === 'Backup');
  const counted = newestRun ? Date.parse(newestRun.started) + newestRun.durationSeconds * 1000 : Math.max(...times);
  return {
    count: snapshots.length, oldestAt: new Date(Math.min(...times)).toISOString(),
    countedAt: new Date(counted - asOfDaysEarlier * 86_400_000).toISOString(), source: asOfDaysEarlier > 0 ? 'restore' : 'backup',
  };
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
      search: eachStep ? undefined : emptySearch(0),
    };
    getState().restoreFlow = flow;
    protectedStep(READ_MS, () => {
      if (!flow) return;
      flow.snapshots = snapshots;
      flow.status = 'ready';
      if (flow.search) flow.search = emptySearch(snapshots.length);
      say('Choose a backup', `${snapshots.length} backups are available.`);
    }, () => say('Loading your backups', 'Looking at your backups does not change them.'));
  };

  // Find a file: what the sample backups hold under a name, the newest first. `from` is how many backups earlier pages looked through.
  const newestFirst = () => [...(flow?.snapshots ?? [])].sort((a, b) => Date.parse(b.when) - Date.parse(a.when));
  const runSearch = (text: string, from: number) => {
    if (!flow?.search) return;
    const search = flow.search;
    const all = newestFirst();
    const needle = text.toLowerCase();
    const looked = /older/i.test(text) && from === 0 ? all.slice(0, SEARCH_PAGE) : all.slice(from);
    flow.busy = false;
    flow.status = 'ready';
    if (/fail/i.test(text)) {
      Object.assign(search, { status: 'failed', outcome: '', message: '', error: 'Rewindle could not search your backups this time. Nothing was changed. Try again; if it keeps happening, choose Save problem report in Settings.' });
      say('Search did not finish', search.error);
      return;
    }
    if (/slow|broad/i.test(text)) {
      Object.assign(search, {
        status: 'done', outcome: /slow/i.test(text) ? 'tooSlow' : 'tooBroad', canContinue: false, nothingSearched: false,
        message: /slow/i.test(text)
          ? 'One of your backups is too large to search in the time allowed. Choose a backup by date, then open its folders to find your file.'
          : `So many files are in folders whose names contain “${text}” that Rewindle stopped looking. Type more of the file’s name, for example Budget 2026.xlsx.`,
      });
      say('Search finished', search.message);
      return;
    }
    const entries = [...Object.values(TREE).flat(), DELETED].filter(entry => entry.name.toLowerCase().includes(needle));
    const searched = from + looked.length;
    const newest = all[0], oldest = looked[looked.length - 1] ?? newest;
    const found: RestoreSearchResult[] = entries.map(entry => {
      const gone = entry === DELETED;
      const holders = gone ? all.slice(Math.min(all.length - 1, 4)) : all.slice(0, searched);
      const latest = holders[0] ?? newest;
      const first = holders[holders.length - 1] ?? latest;
      const versions = [{
        snapshotId: latest.id, when: latest.when, whenDisplay: latest.whenDisplay, firstWhen: first.when, firstWhenDisplay: first.whenDisplay,
        modified: entry.type === 'dir' ? '' : new Date(Date.parse(latest.when) - 86_400_000 * 3).toISOString(), modifiedDisplay: '',
        size: entry.size, sizeDisplay: entry.type === 'dir' ? '' : entry.sizeDisplay, backups: holders.length, isLegacyUnbound: latest.isLegacyUnbound,
      }];
      // An older version of the budget, in the older backups.
      if (entry.name === 'Budget 2026.xlsx' && holders.length > 3) {
        const older = holders.slice(Math.ceil(holders.length / 2));
        versions[0] = { ...versions[0], backups: holders.length - older.length, firstWhen: older[0].when, firstWhenDisplay: older[0].whenDisplay };
        versions.push({ ...versions[0], snapshotId: older[0].id, when: older[0].when, whenDisplay: older[0].whenDisplay, firstWhen: older[older.length - 1].when,
          firstWhenDisplay: older[older.length - 1].whenDisplay, modified: new Date(Date.parse(older[0].when) - 86_400_000 * 5).toISOString(), size: 41_300,
          sizeDisplay: formatBytes(41_300), backups: older.length, isLegacyUnbound: older[0].isLegacyUnbound });
      }
      const where = entry.path.slice(0, entry.path.lastIndexOf('/')).replace(/^\/([A-Za-z])(?=\/|$)/, '$1:').replace(/\//g, '\\');
      return { key: `${entry.type}|${entry.path}`, path: entry.path, name: entry.name, type: entry.type, folderDisplay: where, lastSeen: latest.when,
        lastSeenDisplay: latest.whenDisplay, missingFromNewer: gone, hasMoreVersions: false, versions };
    });
    const more = searched < all.length;
    Object.assign(search, {
      status: 'done', outcome: more ? 'more' : 'complete', canContinue: more, nothingSearched: false, searched, total: all.length,
      searchedOldest: oldest?.when ?? '', searchedOldestDisplay: oldest?.whenDisplay ?? '', results: found, resultsTotal: found.length,
      message: more
        ? `Looked through the ${searched} newest of your ${all.length} backups, back to ${oldest?.whenDisplay}. Choose Look further back to search older ones.`
        : found.length ? `Looked through all ${all.length} backups.` : `No file or folder with “${text}” in its name is in any of your ${all.length} backups. Check the spelling, or type a shorter part of the name.`,
    });
    say('Search finished', search.message);
  };
  const startSearch = (text: string, from: number) => {
    if (!flow?.search) return;
    flow.busy = true;
    flow.status = 'searching';
    Object.assign(flow.search, { text, status: 'searching', error: '', listChanged: false });
    say('Searching your backups', `Looking for “${text}”, newest backup first. This only reads your backups.`);
    later(SEARCH_MS, () => runSearch(text, from));
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
      case 'restoreFlowFindFiles': {
        if (busyReason) return busyReason;
        if (!flow.search) return 'Searching all your backups at once is not available with the backup service on this PC. Choose a backup by date, then open its folders to find your file.';
        if (!flow.snapshots.length) return 'There are no backups to search yet.';
        const checked = checkSearchText(String(payload?.text ?? ''));
        if (checked.error) return checked.message;
        flow.search = { ...emptySearch(flow.snapshots.length), text: checked.normalized };
        startSearch(checked.normalized, 0);
        return null;
      }
      case 'restoreFlowFindMore':
        if (busyReason) return busyReason;
        if (!flow.search?.canContinue) return 'There are no older backups left to search.';
        startSearch(flow.search.text, flow.search.searched);
        return null;
      case 'restoreFlowFindClear':
        if (busyReason) return busyReason;
        if (flow.search) flow.search = emptySearch(flow.snapshots.length);
        say('Choose a backup', 'Choose a backup to continue.');
        return null;
      case 'restoreFlowPickFound': {
        if (busyReason) return busyReason;
        const id = String(payload?.snapshotId ?? ''), path = String(payload?.path ?? '');
        const result = flow.search?.results.find(item => item.path === path && item.versions.some(version => version.snapshotId === id));
        if (!result) return 'That version is no longer in the search results. Search again.';
        const snapshot = flow.snapshots.find(item => item.id === id);
        if (!snapshot) return 'That backup is no longer in your list. Choose Reload backups, then search again.';
        if (id !== flow.selectedSnapshotId) {
          flow.selectedSnapshotId = id;
          flow.tree = { path: '/', entries: [], total: 0, truncated: false, loading: false, error: '', errorPath: '', loaded: false };
        }
        flow.selectedPaths = [path];
        flow.wholeSnapshotSelected = false;
        flow.step = 'destination'; flow.status = 'ready';
        say('Choose a folder', `“${result.name}” from the backup of ${snapshot.whenDisplay} is selected. Nothing is restored until the last step.`);
        validate();
        return null;
      }
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
