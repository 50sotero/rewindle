import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import {
  ArchiveRestore,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  CalendarDays,
  Check,
  CheckCircle2,
  ChevronRight,
  CircleAlert,
  Copy,
  File,
  Folder,
  FolderOpen,
  HardDrive,
  Info,
  LoaderCircle,
  LockKeyhole,
  RotateCcw,
  Search,
  ShieldCheck,
  X,
} from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { ValuePill, type ValuePillTone } from '@/components/atoms/ValuePill';
import LoadingState from '@/components/primitives/LoadingState';
import type {
  Availability,
  CommandName,
  Notice,
  RestoreEntry,
  RestoreFlowState,
  RestoreSnapshot,
} from '@/src/native-types';
import { noticeHoldProps, type NoticeHold } from '@/src/useDashboard';

// `onResult` hears how the host answered a command: false when it refused it, or when the page could not send it.
type Send = (command: CommandName, payload?: Record<string, string | boolean>, onResult?: (ok: boolean) => void) => void;
type RestoreStep = 'backup' | 'files' | 'destination' | 'review' | 'progress' | 'success' | 'partial' | 'error';

const focusableSelector = [
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'a[href]',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

const stepItems: { key: RestoreStep; label: string; shortLabel: string }[] = [
  { key: 'backup', label: 'Choose backup', shortLabel: 'Backup' },
  { key: 'files', label: 'Choose files', shortLabel: 'Files' },
  { key: 'destination', label: 'Choose destination', shortLabel: 'Destination' },
  { key: 'review', label: 'Review and restore', shortLabel: 'Review' },
];

// The host refuses a restore of more paths than it allows (ParseRestoreFlowPaths in DashboardWindow.RestoreFlow.cs) and says how many
// in `limits`. The list stops offering more once that is reached, so the host's refusal is never the first the person hears of it.
// The host stays the authority; this is only the number to use for a host that does not say.
const DEFAULT_MAX_RESTORE_PATHS = 64;
const capHint = (max: number) => `You can pick up to ${max} items. Select a parent folder to include more.`;
// A folder lists this many rows, and each "Show more" adds as many, so a folder of thousands of files does not draw them all at once.
const ROW_CHUNK = 200;
// What the footer says about the step. The main button points at it, so a button that waits says why.
const HINT_ID = 'restore-flow-hint';
// What the steps say when protected controls are off, by the reason they are off.
const UNAVAILABLE_HINT: Record<Exclude<Availability, 'ok'>, string> = {
  offline: 'Reconnect to the desktop app to continue.',
  dataError: 'Backup status cannot be read right now. Continue once it can be.',
  preview: 'Stop the animation preview first to continue.',
};
const UNAVAILABLE_WARNING: Record<Exclude<Availability, 'ok'>, string> = {
  offline: 'Reconnect to the desktop app before choosing a backup.',
  dataError: 'Backup status cannot be read right now, so a backup cannot be chosen. Try again once it can be read.',
  preview: 'Stop the animation preview first. A restore cannot start while it runs.',
};

const snapshotWhen = (snapshot: RestoreSnapshot) => snapshot.whenDisplay || snapshot.when || 'Date unavailable';
const snapshotSource = (snapshot: RestoreSnapshot) => snapshot.sourceSummary || snapshot.hostname || 'Protected folders';
// The host sends the count on its own ("12,345", in its regional format), so the unit is always added here.
const snapshotFiles = (snapshot: RestoreSnapshot) => `${snapshot.fileCountDisplay || snapshot.fileCount.toLocaleString()} ${snapshot.fileCount === 1 ? 'file' : 'files'}`;
const snapshotSize = (snapshot: RestoreSnapshot) => snapshot.sizeDisplay || formatBytes(snapshot.byteCount);
const formatBytes = (value: number) => value >= 1073741824 ? `${(value / 1073741824).toFixed(2)} GiB` : value >= 1048576 ? `${(value / 1048576).toFixed(1)} MiB` : value >= 1024 ? `${(value / 1024).toFixed(1)} KiB` : `${value} B`;
const pathName = (entry: RestoreEntry) => entry.name || entry.path;
const isDirectory = (entry: RestoreEntry) => entry.type === 'dir';
const selectedList = (value: string[] | undefined) => value ?? [];
const destinationPath = (value: RestoreFlowState['destination'] | undefined) => value?.path || '';
// The host's "Ready · this new folder will be used…" sits under a "Ready for restore" heading, so the line says the rest.
const afterReady = (text: string) => { const rest = text.replace(/^Ready\s*\u00b7\s*/i, ''); return rest.charAt(0).toUpperCase() + rest.slice(1); };

// The manager's stage tokens in words, matching the names the desktop app gives them (FriendlyRestoreFlowStage in the host).
const STAGE_LABELS: Record<string, string> = {
  preflight: 'Validating restore safety',
  reading: 'Reading protected snapshot data',
  restoring: 'Restoring and verifying',
  complete: 'Protected restore complete',
};

// Seconds since the restore began. The protected step can run for a long time without a percentage to show, so a
// running clock is what tells the viewer the window has not stalled.
function useElapsedSeconds(active: boolean) {
  const [seconds, setSeconds] = useState(0);
  useEffect(() => {
    setSeconds(0);
    if (!active) return;
    const started = Date.now();
    const timer = window.setInterval(() => setSeconds(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => window.clearInterval(timer);
  }, [active]);
  return seconds;
}
const formatElapsed = (total: number) => {
  const hours = Math.floor(total / 3600), minutes = Math.floor(total % 3600 / 60), seconds = String(total % 60).padStart(2, '0');
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${seconds}` : `${minutes}:${seconds}`;
};

function stepFrom(flow: RestoreFlowState): RestoreStep {
  const raw = String(flow.step || '').toLowerCase();
  if (raw === 'backup') return 'backup';
  if (raw === 'files') return 'files';
  if (raw === 'destination') return 'destination';
  if (raw === 'review') return 'review';
  if (raw === 'progress') return 'progress';
  if (raw === 'success') return 'success';
  if (raw === 'partial') return 'partial';
  if (raw === 'error') return 'error';
  if (flow.status === 'succeeded') return 'success';
  if (flow.status === 'partial') return 'partial';
  if (flow.status === 'failed') return 'error';
  return 'backup';
}

function statusTone(status: string | undefined): ValuePillTone {
  if (status === 'succeeded' || status === 'success') return 'green';
  if (status === 'partial' || status === 'cancelled') return 'orange';
  if (status === 'failed' || status === 'error') return 'red';
  return 'accent';
}

function SnapshotCard({ snapshot, selected, disabled, onSelect, reducedMotion }: {
  snapshot: RestoreSnapshot; selected: boolean; disabled: boolean; onSelect: () => void; reducedMotion: boolean;
}) {
  return <motion.button type="button" className={`restore-snapshot-card ${selected ? 'is-selected' : ''}`} aria-pressed={selected} disabled={disabled} onClick={onSelect}
    initial={{ opacity: 0, y: reducedMotion ? 0 : 7 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: reducedMotion ? 0 : .18 }}>
    <span className="restore-snapshot-icon"><ArchiveRestore size={17} /></span>
    <span className="restore-snapshot-main"><strong title={snapshotWhen(snapshot)}>{snapshotWhen(snapshot)}</strong><span title={snapshotSource(snapshot)}>{snapshotSource(snapshot)}</span><small>{snapshotFiles(snapshot)} · {snapshotSize(snapshot)}{snapshot.shortId && <> · <code>{snapshot.shortId}</code></>}</small></span>
    <span className="restore-snapshot-meta">{snapshot.bindingState && !snapshot.isLegacyUnbound && <ValuePill tone="accent">Plan matched</ValuePill>}{snapshot.isLegacyUnbound && <ValuePill tone="orange">Legacy</ValuePill>}{selected ? <CheckCircle2 size={17} /> : <ChevronRight size={16} />}</span>
  </motion.button>;
}

export default function RestoreFlowModal({ flow, reducedMotion, availability, send, notice, dismissNotice, holdNotice }: {
  flow: RestoreFlowState | null;
  reducedMotion: boolean;
  availability: Availability;
  send: Send;
  notice: Notice | null;
  dismissNotice: () => void;
  /** Keeps the notice up while the pointer or keyboard focus is on it (see useDashboard). */
  holdNotice?: NoticeHold;
}) {
  const connected = availability === 'ok';
  const dialogRef = useRef<HTMLDialogElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  // The scrolling body, which a new step starts again from the top of; and the folder list, which is where focus goes back to after a read.
  const bodyRef = useRef<HTMLDivElement>(null);
  const treeRef = useRef<HTMLDivElement>(null);
  const stepHeadingRef = useRef<HTMLHeadingElement>(null);
  const previousStepRef = useRef<RestoreStep | null>(null);
  // Whether a folder read, or a check of the destination, was under way at the last render, so the render that ends it can be told apart.
  const treeWasLoadingRef = useRef(false);
  const destinationWasCheckingRef = useRef(false);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const closeTimerRef = useRef<number | null>(null);
  const [visible, setVisible] = useState<RestoreFlowState | null>(flow);
  const [closing, setClosing] = useState(false);
  const [snapshotQuery, setSnapshotQuery] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [fileQuery, setFileQuery] = useState('');
  const [draftSnapshotId, setDraftSnapshotId] = useState(flow?.selectedSnapshotId || '');
  const [draftPaths, setDraftPaths] = useState<string[]>(selectedList(flow?.selectedPaths));
  const [draftWhole, setDraftWhole] = useState(!!flow?.wholeSnapshotSelected);
  const [destinationDraft, setDestinationDraft] = useState(destinationPath(flow?.destination));
  const [validatedDestinationPath, setValidatedDestinationPath] = useState(destinationPath(flow?.destination));
  const destinationDraftDirtyRef = useRef(false);
  const destinationPickerPendingRef = useRef(false);
  const destinationSyncRef = useRef<{ destination: RestoreFlowState['destination']; open: boolean } | null>(null);
  // Bumped when the host has answered the folder picker, whether a folder was chosen or the picker was cancelled.
  const [browseAnswered, setBrowseAnswered] = useState(0);
  // The newest state from the host, for answers that arrive after the render that sent the command.
  const flowRef = useRef(flow);
  const selectionRoundRef = useRef(0);
  const [legacyConfirmed, setLegacyConfirmed] = useState(false);
  // A check that found the destination ready asks for focus to go to Review restore, which opens a moment later (see below).
  const [focusReview, setFocusReview] = useState(false);

  const current = flow ?? visible;
  const activeStep = current ? stepFrom(current) : 'backup';
  const selectedSnapshot = current?.snapshots.find(snapshot => snapshot.id === draftSnapshotId) ?? null;
  const selectedId = draftSnapshotId;
  const paths = draftPaths;
  const wholeSnapshot = draftWhole;
  const validation = current?.validation;
  const destinationState = current?.destination;
  const destinationValid = !!destinationDraft.trim() && destinationDraft.trim() === validatedDestinationPath && !!destinationState?.valid && !!validation?.ready;
  const destinationChecking = !!destinationState?.checking;
  const status = current?.status || 'idle';
  const progress = current?.progress;
  const result = current?.result;
  const treeLoading = !!current?.tree?.loading;
  // Choosing a backup reads none of its folders: until the person asks to browse it the host has no listing (an older host does
  // not say, and has always read the root).
  const treeLoaded = current?.tree?.loaded !== false;
  // Windows is showing its approval prompt for the step that is loading. The host words it: once for a restore session, or for
  // each step when the installed engine has none.
  const approvalWaiting = !!current?.approval?.waiting;
  const approvalNotice = current?.approval?.notice || '';
  // What the host says it is doing decides this. The status word "loading" alone does not: a read that ended without the host saying
  // so would leave it behind, and the dialog could then neither be closed nor left. A restore that is running (or being cancelled) is
  // busy for as long as its status says so.
  const busy = !!current?.busy || status === 'running' || status === 'canceling' || destinationChecking || treeLoading;
  // "Loading" with nothing under way is a flow that got stuck. After a moment the dialog says so and offers Try again; Close works throughout.
  const stuck = status === 'loading' && !current?.busy && !destinationChecking && !treeLoading;
  const [stalled, setStalled] = useState(false);
  const restoring = activeStep === 'progress';
  const canCancel = !!current?.canCancel && restoring;
  const maxPaths = current?.limits?.maxPaths ?? DEFAULT_MAX_RESTORE_PATHS;
  const selectionAccepted = !!flow && flow.selectedSnapshotId === selectedId && flow.selectedPaths.join('\n') === paths.join('\n') && flow.wholeSnapshotSelected === wholeSnapshot;
  const elapsedSeconds = useElapsedSeconds(restoring);
  const treeId = useId();
  const treePath = current?.tree?.path || '';
  const [rowLimit, setRowLimit] = useState(ROW_CHUNK);

  useEffect(() => { flowRef.current = flow; });

  useEffect(() => {
    if (!stuck) { setStalled(false); return; }
    const timer = window.setTimeout(() => setStalled(true), 3000);
    return () => window.clearTimeout(timer);
  }, [stuck]);

  // A filter typed in one folder, or for one backup, must not keep hiding rows in the next.
  useEffect(() => { setFileQuery(''); }, [treePath, selectedId]);
  // Another folder, or another filter, starts again with the first rows.
  useEffect(() => { setRowLimit(ROW_CHUNK); }, [treePath, selectedId, fileQuery]);

  useEffect(() => {
    if (previousStepRef.current === null) {
      previousStepRef.current = activeStep;
      return;
    }
    if (previousStepRef.current === activeStep) return;
    previousStepRef.current = activeStep;
    // Focus is moved without scrolling, so a step opens at its top as well, not wherever the one before it was scrolled to.
    if (bodyRef.current) bodyRef.current.scrollTop = 0;
    const frame = window.requestAnimationFrame(() => stepHeadingRef.current?.focus({ preventScroll: true }));
    return () => window.cancelAnimationFrame(frame);
  }, [activeStep]);

  // A folder read and a destination check disable the controls they were started from (and a read replaces the rows), which drops focus
  // to the page. When one ends, focus goes back to where the next thing is to be done, but only if it was lost: it is never taken from
  // a control the person has moved to. "Lost" is nothing focused, the dialog itself, or a control that is gone or disabled.
  const focusLost = () => {
    const active = document.activeElement;
    return !active || active === document.body || active === dialogRef.current || !active.isConnected || (active as HTMLButtonElement).disabled === true;
  };
  useEffect(() => {
    const wasLoading = treeWasLoadingRef.current;
    treeWasLoadingRef.current = treeLoading;
    if (!wasLoading || treeLoading || activeStep !== 'files' || !focusLost()) return;
    // A folder that could not be opened has its own Try again. Otherwise the list's first row, when that is a folder to open, so the next
    // step down can be taken from the keyboard; a list that starts with a file (a label, which cannot take focus) takes focus itself,
    // and Tab goes on into its first row.
    const tree = treeRef.current;
    const firstName = tree?.querySelector('.restore-tree-row .restore-entry-name');
    const target = panelRef.current?.querySelector<HTMLElement>('.restore-tree-error button:not(:disabled)')
      ?? (firstName instanceof HTMLButtonElement && !firstName.disabled ? firstName : tree);
    target?.focus({ preventScroll: true });
  }, [activeStep, treeLoading]);
  useEffect(() => {
    const wasChecking = destinationWasCheckingRef.current;
    destinationWasCheckingRef.current = destinationChecking;
    if (destinationChecking) { setFocusReview(false); return; }
    if (!wasChecking || activeStep !== 'destination' || !focusLost()) return;
    // A folder that failed its check goes back to the field to be fixed. One that passed goes on to Review restore, which only opens once
    // the page has taken the verdict in (the next effect), so the button is asked for then.
    if (destinationState?.valid && validation?.ready) setFocusReview(true);
    else panelRef.current?.querySelector<HTMLElement>('#restore-destination-path')?.focus({ preventScroll: true });
  }, [activeStep, destinationChecking]);
  useEffect(() => {
    if (!focusReview || !destinationValid || busy) return;
    setFocusReview(false);
    if (focusLost()) panelRef.current?.querySelector<HTMLElement>('[data-review-restore]')?.focus({ preventScroll: true });
  }, [focusReview, destinationValid, busy]);

  useEffect(() => {
    if (!flow) {
      destinationDraftDirtyRef.current = false;
      destinationPickerPendingRef.current = false;
      destinationSyncRef.current = null;
      return;
    }
    setVisible(flow);
    setClosing(false);
    setDraftSnapshotId(flow.selectedSnapshotId);
    setDraftPaths(selectedList(flow.selectedPaths));
    setDraftWhole(flow.wholeSnapshotSelected);
    const authoritativeDestination = destinationPath(flow.destination);
    const destinationWasPicked = destinationPickerPendingRef.current && authoritativeDestination !== destinationPath(destinationSyncRef.current?.destination);
    const destinationCheckFinished = destinationSyncRef.current?.destination.checking && !flow.destination.checking;
    const destinationMatchesDraft = authoritativeDestination === destinationDraft.trim();
    // `destination.status` is the host's sentence for the person (not a code), so a finished check shows as a verdict or an error.
    const destinationValidationSettled = flow.validation.ready && flow.destination.valid || !!flow.destination.error || flow.validation.errors.length > 0;
    const destinationSettled = destinationWasPicked || destinationCheckFinished || (destinationMatchesDraft && !flow.destination.checking && destinationValidationSettled);
    if (!destinationDraftDirtyRef.current || destinationSettled) {
      setDestinationDraft(authoritativeDestination);
      destinationDraftDirtyRef.current = false;
    }
    if (!destinationDraftDirtyRef.current || destinationSettled) {
      setValidatedDestinationPath(flow.validation.ready && flow.destination.valid ? authoritativeDestination : '');
    }
    if (destinationWasPicked || destinationSettled) destinationPickerPendingRef.current = false;
    destinationSyncRef.current = { destination: flow.destination, open: flow.open };
  }, [flow?.open, flow?.selectedSnapshotId, flow?.selectedPaths?.join('\n'), flow?.wholeSnapshotSelected, flow?.destination.path, flow?.destination.valid, flow?.destination.checking, flow?.destination.status, flow?.validation.ready, flow?.validation.errors.join('|')]);

  // The picker has answered. A folder it chose reached the sync effect above first (the host publishes it before it answers), and
  // a picker that was cancelled published nothing, so either way a later publish is no longer "the folder that was picked".
  useEffect(() => { destinationPickerPendingRef.current = false; }, [browseAnswered]);

  const finishClose = useCallback(() => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    closeTimerRef.current = null;
    if (dialogRef.current?.open) dialogRef.current.close();
    setClosing(false);
    setVisible(null);
    const returnFocus = returnFocusRef.current;
    returnFocusRef.current = null;
    if (returnFocus && document.contains(returnFocus)) returnFocus.focus({ preventScroll: true });
  }, []);

  const close = useCallback(() => {
    if (restoring || busy) return;
    // A refused command leaves its reason in the notice, which would otherwise outlive the dialog and show again in the next one.
    dismissNotice();
    if (!dialogRef.current?.open) { send('restoreFlowClose'); return; }
    setClosing(true);
    closeTimerRef.current = window.setTimeout(finishClose, reducedMotion ? 0 : 190);
    send('restoreFlowClose', undefined, ok => {
      if (ok) return;
      // The host keeps the flow open (it will not close while it is working), so the dialog stays: take the close back, and
      // show the dialog again if its closing animation had already hidden it.
      if (closeTimerRef.current !== null) { window.clearTimeout(closeTimerRef.current); closeTimerRef.current = null; }
      setClosing(false);
      if (flowRef.current?.open) setVisible(flowRef.current);
    });
  }, [busy, dismissNotice, finishClose, reducedMotion, restoring, send]);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (flow?.open && visible) {
      // A close in progress waits for the host to say the flow is gone, so the render it just caused must not cancel its timer;
      // only a flow that comes back (opened again while the dialog was still closing) does.
      if (!closing && closeTimerRef.current !== null) { window.clearTimeout(closeTimerRef.current); closeTimerRef.current = null; }
      if (!dialog.open) {
        returnFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
        dismissNotice();
        try { dialog.showModal(); } catch { /* StrictMode can run the effect twice. */ }
        window.requestAnimationFrame(() => panelRef.current?.querySelector<HTMLElement>('[data-autofocus]')?.focus());
      }
    } else if (!flow?.open && dialog.open && !closing) {
      setClosing(true);
      closeTimerRef.current = window.setTimeout(finishClose, reducedMotion ? 0 : 190);
    }
  }, [closing, dismissNotice, finishClose, flow?.open, reducedMotion, visible]);

  useEffect(() => () => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    if (dialogRef.current?.open) dialogRef.current.close();
  }, []);

  const filteredSnapshots = useMemo(() => {
    if (!current) return [];
    const query = snapshotQuery.trim().toLowerCase();
    const from = dateFrom ? new Date(`${dateFrom}T00:00:00`).getTime() : Number.NEGATIVE_INFINITY;
    const to = dateTo ? new Date(`${dateTo}T23:59:59.999`).getTime() : Number.POSITIVE_INFINITY;
    return current.snapshots.filter(snapshot => {
      const haystack = [snapshot.id, snapshot.shortId, snapshotWhen(snapshot), snapshotSource(snapshot), snapshot.hostname].filter(Boolean).join(' ').toLowerCase();
      const time = Date.parse(snapshot.when);
      const dateFilterActive = !!dateFrom || !!dateTo;
      const dateMatches = dateFilterActive && Number.isNaN(time) ? false : (!dateFilterActive || (time >= from && time <= to));
      return (!query || haystack.includes(query)) && dateMatches;
    });
  }, [current, dateFrom, dateTo, snapshotQuery]);

  const entries = current?.tree?.entries ?? [];
  // How many entries the folder holds. The host sends the listing only on Choose files, and cuts a very large one short, so this is
  // also how the page knows the host still has a listing (going back to it must not read the backup again) and when it is not all here.
  const listedTotal = current?.tree?.total ?? entries.length;
  const visibleEntries = useMemo(() => {
    const query = fileQuery.trim().toLowerCase();
    if (!query) return entries;
    return entries.filter(entry => `${entry.name || ''} ${entry.path}`.toLowerCase().includes(query));
  }, [entries, fileQuery]);
  const shownEntries = useMemo(() => visibleEntries.slice(0, rowLimit), [visibleEntries, rowLimit]);

  const sendSelection = useCallback((nextPaths: string[], nextWhole: boolean) => {
    if (!selectedId || !connected || busy) return;
    // The list stops offering one item more than the host allows, so this only holds a request the host would refuse.
    if (!nextWhole && nextPaths.length > maxPaths) return;
    const round = ++selectionRoundRef.current;
    dismissNotice();
    setDraftPaths(nextPaths);
    setDraftWhole(nextWhole);
    send('restoreFlowSelectPaths', { snapshotId: selectedId, paths: nextPaths.join('\n'), wholeSnapshot: nextWhole }, ok => {
      // A selection the host refuses is never published, so the drafts would go on showing what it did not accept. A newer
      // selection that is still on its way will settle them itself.
      if (ok || round !== selectionRoundRef.current) return;
      const accepted = flowRef.current;
      if (!accepted) return;
      setDraftPaths(selectedList(accepted.selectedPaths));
      setDraftWhole(accepted.wholeSnapshotSelected);
    });
  }, [busy, connected, dismissNotice, maxPaths, selectedId, send]);

  // A move to another step or folder starts afresh: the reason a refused command gave belongs to the step it was refused on.
  const move = (command: CommandName, payload?: Record<string, string | boolean>) => { dismissNotice(); send(command, payload); };

  // On to the files of the backup already chosen. Choosing a backup reads none of its folders: the host goes to Choose files with
  // the listing and the scope it already holds for this backup, or with none, and the root is read only when the person chooses
  // Browse files. So going on (or back and on again) never reads the backup, and "Everything in this snapshot" never needs a read.
  const openFiles = () => {
    if (!selectedId || !connected || busy) return;
    dismissNotice();
    send('restoreFlowNavigate', { step: 'files', snapshotId: selectedId });
  };

  const selectSnapshot = (snapshot: RestoreSnapshot) => {
    if (busy || !connected) return;
    // The backup that is already chosen keeps what was picked from it (the host keeps it too); only another backup starts over.
    if (snapshot.id === selectedId) { openFiles(); return; }
    dismissNotice();
    setDraftPaths([]);
    setDraftWhole(false);
    setDraftSnapshotId(snapshot.id);
    setLegacyConfirmed(false);
    send('restoreFlowNavigate', { step: 'files', snapshotId: snapshot.id });
  };

  const browseFiles = (parentPath: string) => {
    if (!selectedId || !connected || busy) return;
    move('restoreFlowBrowseFiles', { snapshotId: selectedId, path: parentPath });
  };

  const goDestination = () => {
    if (!selectedId || (!wholeSnapshot && paths.length === 0) || !selectionAccepted || !connected || busy) return;
    move('restoreFlowNavigate', { step: 'destination' });
  };

  const validateDestination = () => {
    if (!destinationDraft.trim() || !connected || busy) return;
    dismissNotice();
    setValidatedDestinationPath('');
    send('restoreFlowValidateDestination', { path: destinationDraft.trim() });
  };

  const browseDestination = () => {
    if (!connected || busy) return;
    destinationPickerPendingRef.current = true;
    // The check that follows a chosen folder clears the validated path when its state arrives. A cancelled picker changes nothing,
    // so a folder that was already checked stays checked.
    send('restoreFlowBrowseDestination', undefined, () => setBrowseAnswered(round => round + 1));
  };

  const goReview = () => {
    if (!selectedId || (!wholeSnapshot && paths.length === 0) || !selectionAccepted || !destinationValid || !connected || busy) return;
    move('restoreFlowReview');
  };

  const startRestore = () => {
    if (!selectedId || (!wholeSnapshot && paths.length === 0) || !selectionAccepted || !destinationValid || (selectedSnapshot?.isLegacyUnbound && !legacyConfirmed) || !connected || busy) return;
    dismissNotice();
    send('restoreFlowStart', { legacyConfirmed });
  };

  // Escape in a filter field first clears what was typed, as it does in the run details; with the field empty it closes the flow like
  // anywhere else. Left to the dialog, the key closed the flow and dropped the backup, files and destination chosen so far. The
  // preventDefault also keeps the dialog's own cancel event (onCancel) from closing it.
  const clearOnEscape = (value: string, clear: () => void) => (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key !== 'Escape' || !value) return;
    event.preventDefault();
    event.stopPropagation();
    clear();
  };

  const onKeyDown = (event: React.KeyboardEvent<HTMLDialogElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close();
      return;
    }
    if (event.key !== 'Tab') return;
    const dialog = dialogRef.current;
    if (!dialog) return;
    const focusable = Array.from(dialog.querySelectorAll<HTMLElement>(focusableSelector)).filter(element => element.offsetParent !== null);
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  };

  if (!current) return <dialog ref={dialogRef} className="restore-flow-dialog app-dialog" />;
  const currentPath = treePath;
  const treeError = current.tree?.error || '';
  const resultStep = !restoring && ['success', 'partial', 'error'].includes(activeStep);
  const resultStatus = result?.status || (activeStep === 'success' ? 'success' : activeStep === 'partial' ? 'partial' : activeStep === 'error' ? 'error' : '');
  // The dialog keeps one steady name, which is what a screen reader reads on opening it. What the host says about each action (its title
  // and its detail: "Restore scope updated", "12 entries loaded from /Documents") is not the dialog's name, so it no longer stands in for
  // it: the detail stays in view under the name, and the whole message is spoken once, politely, by the status region below. The result
  // screen says what happened in its own body, and takes focus, so the header and the region leave it alone; so do the progress screen
  // and the destination step, which have a live region of their own for what they report.
  const title = 'Restore your files';
  const detail = resultStep ? '' : current.message.detail || 'Choose a verified point in time, select exactly what to recover, and review the destination before anything is written.';
  const spoken = resultStep || restoring || activeStep === 'destination' ? '' : [current.message.title, current.message.detail].filter(Boolean).join('. ');
  const resultTone = statusTone(resultStatus);
  // Files to look at: a verified restore, or a partial one that leaves what it restored in the destination. Open and Copy carry no
  // path: the host acts on the folder the manager reported, and only after a restore has ended (the host checks that again).
  const resultFolder = (resultStatus === 'success' || resultStatus === 'partial') && result?.target ? result.target : '';
  // These two only look at, or copy the name of, a folder the host already knows, so they work whenever the host answers.
  const hostReachable = availability !== 'offline';
  const canContinueFiles = selectionAccepted && (wholeSnapshot || paths.length > 0);
  const startBlocked = current.startBlocked || '';
  // Room on the destination's drive, read when it was checked, and the host's warning when a whole snapshot is larger than it (the
  // restore is never blocked for it: the host cannot know what the drive will hold by the time the files are written).
  const freeText = destinationState?.freeDisplay ? `${destinationState.freeDisplay} free${destinationState.drive ? ` (${destinationState.drive})` : ''}` : '';
  const spaceWarning = validation?.spaceWarning || '';
  const wholeSize = wholeSnapshot && selectedSnapshot && selectedSnapshot.byteCount > 0 ? snapshotSize(selectedSnapshot) : '';
  const legacyPending = !!selectedSnapshot?.isLegacyUnbound && !legacyConfirmed;
  const canStart = canContinueFiles && destinationValid && !legacyPending && !busy && !startBlocked;
  const atCap = !wholeSnapshot && paths.length >= maxPaths;
  const capText = capHint(maxPaths);
  // The host cuts a very large folder short; the page says so, so a shorter list is never taken for the whole folder.
  const listingCut = !!current.tree?.truncated;
  const hiddenRows = visibleEntries.length - shownEntries.length;
  // "Loading" with nothing under way (see `stalled`) is not shown as a spinner that never ends.
  const loadingBackups = current.status === 'loading' && !stalled;

  // What the destination check has said about the folder in the field. A verdict is about the path that was checked: once the
  // field holds another one, the earlier verdict (and any error with it) is not about this path, and a first visit has none.
  const draftPath = destinationDraft.trim();
  const checkedDraft = !!draftPath && draftPath === destinationPath(destinationState);
  const destinationFailure = checkedDraft && !destinationValid && !destinationChecking ? destinationState?.error || '' : '';
  // Problems with the scope rather than the folder. While the folder is not valid its own status is among the host's errors too,
  // so it is left out here: it is shown above, once there is a check to report it for.
  const scopeProblems = !destinationValid && !destinationChecking ? (validation?.errors ?? []).filter(message => message !== destinationState?.status) : [];
  const destinationProblems = [destinationFailure, ...scopeProblems].filter(Boolean);
  const destinationTone: 'ready' | 'error' | 'idle' = destinationValid ? 'ready' : destinationProblems.length ? 'error' : 'idle';
  // Without a verdict to report, the host's own line says what to do (for example after Try again), else the page does.
  const destinationGuidance = checkedDraft && !destinationState?.valid && !destinationState?.error && destinationState?.status
    ? destinationState.status
    : draftPath ? 'Choose Check location to verify this folder before anything is restored.' : 'Enter a folder or choose Browse. Rewindle verifies it before anything is restored.';

  // Where the protected step stands. The manager reports no real percentage while it waits for Windows approval or
  // restores (the desktop window shows that as an unknown amount too), so those show a moving bar and a clock, not "0%".
  const awaitingApproval = !!progress?.awaitingApproval || (restoring && approvalWaiting);
  const stageToken = String(progress?.stage || '').toLowerCase();
  const stageLabel = awaitingApproval ? 'Waiting for Windows approval' : STAGE_LABELS[stageToken] || 'Recovering files';
  const progressPercent = Math.max(0, Math.min(100, Math.round(typeof progress?.percent === 'number' ? progress.percent : 0)));
  const indeterminate = awaitingApproval || stageToken === 'restoring' || progressPercent <= 5;
  const progressMessage = progress?.message || 'Rewindle is restoring the selected scope and verifying the result.';

  // What the result screen says. The host words a restore that ran; for anything else its own headline is used, and the page
  // supplies one if there is none. The protected manager reports no file counts, so none are shown: the facts under the message are the
  // snapshot and the verification, and the latter only for a restore that ran.
  const resultTitle = resultStatus === 'success' ? 'Restore complete and verified' : resultStatus === 'partial' ? 'Restore incomplete' : result?.title || current.message.title || (resultStatus === 'cancelled' ? 'Windows approval cancelled' : 'Restore needs attention');
  const resultMessage = result?.message || result?.error || (resultStatus === 'success' ? 'The selected files were restored and verified at the destination.' : resultStatus === 'partial' ? 'Some files were restored. Review the skipped items before trying again.' : resultStatus === 'cancelled' ? 'The restore request was cancelled before completion. You can try it again.' : 'Rewindle could not complete the restore.');
  const showVerification = resultStatus === 'success' || resultStatus === 'partial';

  // The steps follow the flow. A finished restore ticks all four; one that stopped marks the step it stopped on (Review, or Backup
  // when no backup was chosen yet) and leaves the others to the Try again button.
  const stoppedStep: RestoreStep = selectedSnapshot ? 'review' : 'backup';
  const railStep: RestoreStep = activeStep === 'progress' ? 'review' : activeStep === 'partial' || activeStep === 'error' ? stoppedStep : activeStep;
  const finished = activeStep === 'success';
  const railIndex = finished ? stepItems.length : stepItems.findIndex(step => step.key === railStep);
  // Beyond the steps already passed, a step is open once the choices made so far allow it (the host checks every move again).
  const reachable: Partial<Record<RestoreStep, boolean>> = { backup: true, files: !!selectedId, destination: canContinueFiles, review: canContinueFiles && destinationValid };

  // The footer's line. It names what the step waits for, and the main button points at it, so a disabled button says why.
  const [hint, hintExplains] = ((): [string, boolean] => {
    if (restoring) return [canCancel ? 'Restore can be cancelled safely.' : 'Restore is running; the window will unlock when it finishes.', false];
    if (activeStep === 'success') return [resultFolder ? 'Files restored and verified. Open the folder to see them.' : 'Files restored and verified.', false];
    if (activeStep === 'partial') return ['Review skipped files before retrying.', false];
    if (activeStep === 'error') return ['Nothing else will run until you try again.', false];
    if (availability !== 'ok') return [UNAVAILABLE_HINT[availability], true];
    if (activeStep === 'destination' && destinationChecking) return ['Checking the destination…', true];
    if (busy && approvalWaiting) return ['Waiting for Windows approval…', true];
    if (busy) return ['Waiting for the repository step to finish.', true];
    if (activeStep === 'backup') return selectedId ? ['Choose files to go on with the selected backup, or pick another.', false] : ['Choose a backup to continue.', true];
    if (activeStep === 'files') {
      if (!selectionAccepted && (wholeSnapshot || paths.length > 0)) return ['Waiting for the selection to be confirmed…', true];
      if (!canContinueFiles && !treeLoaded) return ['Choose Everything in this snapshot, or Browse files to pick folders and files.', true];
      if (!canContinueFiles) return ['Select at least one file or folder, or choose Everything in this snapshot.', true];
      return [atCap ? capText : 'Next, choose where the files are restored.', false];
    }
    if (activeStep === 'destination') {
      if (!draftPath) return ['Enter a folder, or choose Browse…', true];
      if (!destinationValid) return ['Choose Check location to continue.', true];
      return ['The destination is ready. Review the restore next.', false];
    }
    if (startBlocked) return ['Restore unlocks when the running operation finishes.', true];
    if (legacyPending) return ['Confirm the older backup above to continue.', true];
    return ['Nothing starts until you press Restore now.', false];
  })();

  // The location as clickable folders. Past four, the middle collapses so the folder you are in is never the part that is cut off.
  const segments = currentPath.split('/').filter(Boolean);
  const atRoot = segments.length === 0;
  const crumbs = segments.map((name, index) => ({ name, path: `/${segments.slice(0, index + 1).join('/')}` }));
  const trail: ({ name: string; path: string } | null)[] = crumbs.length > 4 ? [crumbs[0], null, ...crumbs.slice(-2)] : crumbs;
  const parentPath = segments.length > 1 ? `/${segments.slice(0, -1).join('/')}` : '';
  const browseLocked = busy || !connected;

  // The notice itself (a refused command, a copied path). New for each one, so the same words said twice are drawn and announced
  // again; it waits while the pointer or focus is on it.
  const noticeView = (item: Notice) => <motion.div key={item.id} className={`restore-flow-notice ${item.error ? 'is-error' : ''}`}
    initial={{ opacity: 0, y: reducedMotion ? 0 : 7 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: reducedMotion ? 0 : 4 }} {...noticeHoldProps(holdNotice)}>
    {item.error ? <CircleAlert size={15} /> : <Info size={15} />}<span>{item.text}</span><Button size="icon-sm" variant="quiet" aria-label="Dismiss restore notice" onClick={dismissNotice}><X size={13} /></Button>
  </motion.div>;

  return <dialog ref={dialogRef} className={`restore-flow-dialog app-dialog ${closing ? 'is-closing' : ''}`} aria-labelledby="restore-flow-title" aria-describedby={detail ? 'restore-flow-description' : undefined}
    onCancel={event => { event.preventDefault(); close(); }} onKeyDown={onKeyDown} onClose={() => { if (!flow?.open) finishClose(); }}>
    <AnimatePresence initial={false} mode="wait">
      {visible && <motion.div ref={panelRef} className="restore-flow-panel" initial={{ opacity: 0, y: reducedMotion ? 0 : 16, scale: reducedMotion ? 1 : .98 }} animate={{ opacity: closing ? 0 : 1, y: closing && !reducedMotion ? 9 : 0, scale: 1 }} transition={{ duration: reducedMotion ? 0 : .2, ease: [.16, 1, .3, 1] }}>
        <header className="restore-flow-header">
          <div className="restore-flow-heading"><span className="restore-flow-emblem"><ArchiveRestore size={22} /></span><div><span className="eyebrow">Restore Center</span><h2 id="restore-flow-title">{title}</h2>{detail && <p id="restore-flow-description" title={detail}>{detail}</p>}</div></div>
          <Button size="icon" variant="quiet" data-autofocus aria-label={restoring || busy ? 'Restore flow is busy' : 'Close restore'} title={restoring || busy ? 'Wait for the current restore step to finish' : 'Close restore (Escape)'} disabled={restoring || busy} onClick={close}><X size={17} /></Button>
        </header>
        {/* In the panel from the moment the dialog opens, so a screen reader already knows the region when its text changes. */}
        <div className="sr-only" role="status" aria-live="polite" aria-atomic="true">{spoken}</div>

        <nav className="restore-flow-steps" aria-label="Restore progress">
          {stepItems.map((item, index) => {
            const done = index < railIndex;
            const active = !finished && item.key === railStep;
            const warning = active && (activeStep === 'partial' || activeStep === 'error');
            // A result is final: its steps only show where things ended, and Try again is the way back.
            const clickable = !resultStep && !busy && connected && (done || active || !!reachable[item.key]);
            return <button key={item.key} type="button" className={`${active ? 'is-active' : ''} ${done ? 'is-done' : ''} ${warning ? 'is-warning' : ''}`} aria-current={active ? 'step' : undefined} disabled={!clickable}
              onClick={() => { if (active) return; if (item.key === 'backup') move('restoreFlowNavigate', { step: 'backup' }); else if (item.key === 'files') openFiles(); else if (item.key === 'destination') goDestination(); else if (item.key === 'review') goReview(); }}>
              <span>{warning ? <CircleAlert size={13} /> : done ? <Check size={13} /> : index + 1}</span><strong>{item.label}</strong><small>{item.shortLabel}</small>
            </button>;
          })}
        </nav>

        {/* On the first step nothing has been chosen to recap ("Not selected" three times), and on a short window the room is better spent on the step. */}
        {activeStep !== 'backup' && <section className="restore-flow-persistent-summary" aria-label="Restore summary">
          <div className="restore-summary-item"><span className="restore-summary-icon"><ArchiveRestore size={14} /></span><span><small>Backup</small><strong title={selectedSnapshot ? snapshotWhen(selectedSnapshot) : undefined}>{selectedSnapshot ? snapshotWhen(selectedSnapshot) : 'Not selected'}</strong><em title={selectedSnapshot ? snapshotSource(selectedSnapshot) : undefined}>{selectedSnapshot ? `${snapshotSource(selectedSnapshot)} · ${selectedSnapshot.shortId || selectedSnapshot.id}` : 'Choose a saved point in time.'}</em></span></div>
          <details className="restore-summary-item restore-summary-scope">
            <summary><span className="restore-summary-icon"><CheckCircle2 size={14} /></span><span><small>Scope</small><strong>{wholeSnapshot ? 'Whole snapshot' : paths.length ? `${paths.length} selected ${paths.length === 1 ? 'path' : 'paths'}` : 'Not selected'}</strong><em>{!selectionAccepted && (paths.length || wholeSnapshot) ? 'Waiting for selection confirmation…' : wholeSnapshot ? 'All protected paths.' : paths.length ? 'Expand to review or remove paths.' : 'Choose files or explicitly choose everything.'}</em></span><ChevronRight size={14} className="restore-summary-chevron" /></summary>
            {!wholeSnapshot && paths.length > 0 && <ul>{paths.map(path => <li key={path}><code title={path}>{path}</code><Button size="icon-sm" variant="quiet" disabled={busy || !connected} aria-label={`Remove ${path} from restore scope`} title={`Remove ${path}`} onClick={() => sendSelection(paths.filter(selectedPath => selectedPath !== path), false)}><X size={12} /></Button></li>)}</ul>}
          </details>
          <div className="restore-summary-item"><span className="restore-summary-icon"><FolderOpen size={14} /></span><span><small>Destination</small><strong title={destinationDraft || undefined}>{destinationDraft || 'Not selected'}</strong><em>{destinationValid ? 'Checked and ready.' : destinationDraft ? 'Needs validation.' : 'Choose where recovered files will go.'}</em></span></div>
        </section>}

        <div className="restore-flow-body" ref={bodyRef}>
          {activeStep === 'backup' && <section className="restore-flow-step" aria-labelledby="restore-backup-heading">
            <div className="restore-flow-section-heading"><div><span className="eyebrow">Step 1 of 4</span><h3 ref={stepHeadingRef} tabIndex={-1} id="restore-backup-heading">Choose a backup</h3><p>Search the saved points in time by date, snapshot ID, or source.</p></div><ValuePill tone="accent">{filteredSnapshots.length} shown</ValuePill></div>
            <div className="restore-snapshot-filters"><label className="restore-flow-search"><Search size={14} /><span className="sr-only">Search backups</span><input value={snapshotQuery} onChange={event => setSnapshotQuery(event.target.value)} onKeyDown={clearOnEscape(snapshotQuery, () => setSnapshotQuery(''))} placeholder="Search ID, source, or computer…" /></label><label className="restore-date-field"><CalendarDays size={13} /><span className="sr-only">From date</span><input type="date" value={dateFrom} onChange={event => setDateFrom(event.target.value)} onKeyDown={clearOnEscape(dateFrom, () => setDateFrom(''))} aria-label="From date" /></label><span className="restore-date-separator">to</span><label className="restore-date-field"><CalendarDays size={13} /><span className="sr-only">To date</span><input type="date" value={dateTo} onChange={event => setDateTo(event.target.value)} onKeyDown={clearOnEscape(dateTo, () => setDateTo(''))} aria-label="To date" /></label>{(snapshotQuery || dateFrom || dateTo) && <Button size="xs" variant="quiet" onClick={() => { setSnapshotQuery(''); setDateFrom(''); setDateTo(''); }}>Clear</Button>}</div>
            <div className="restore-snapshot-list" role="list" aria-label="Available backups">
              {loadingBackups && <div className="restore-flow-empty"><LoadingState label={approvalWaiting ? 'Waiting for Windows approval…' : 'Loading saved backups'} variant="Orbit" live={false} />{approvalWaiting && <p className="restore-progress-hint"><Info size={13} />{approvalNotice || 'Approve the Windows prompt to continue.'} If you do not see it, check the taskbar.</p>}</div>}
              {!loadingBackups && filteredSnapshots.map(snapshot => <div key={snapshot.id} role="listitem"><SnapshotCard snapshot={snapshot} selected={snapshot.id === selectedId} disabled={busy || !connected} onSelect={() => selectSnapshot(snapshot)} reducedMotion={reducedMotion} /></div>)}
              {!loadingBackups && filteredSnapshots.length === 0 && <div className="restore-flow-empty"><Search size={20} /><strong>{dateFrom && dateTo && dateFrom > dateTo ? 'Choose a valid date range' : current.snapshots.length ? 'No backups match those filters' : 'No saved backups available'}</strong><p>{dateFrom && dateTo && dateFrom > dateTo ? 'The start date must be on or before the end date.' : current.snapshots.length ? 'Try a different ID, source, or date range.' : 'Refresh the dashboard and try again when the repository is available.'}</p>{(snapshotQuery || dateFrom || dateTo) && <Button size="sm" onClick={() => { setSnapshotQuery(''); setDateFrom(''); setDateTo(''); }}>Clear filters</Button>}</div>}
            </div>
            {availability !== 'ok' && <div className="restore-flow-inline-warning" role="alert"><CircleAlert size={15} />{UNAVAILABLE_WARNING[availability]}</div>}
          </section>}

          {activeStep === 'files' && <section className="restore-flow-step" aria-labelledby="restore-files-heading">
            <div className="restore-flow-section-heading"><div><span className="eyebrow">Step 2 of 4</span><h3 ref={stepHeadingRef} tabIndex={-1} id="restore-files-heading">Choose files</h3><p>Select individual files or folders. Choosing the whole snapshot is always explicit.</p></div><ValuePill tone={canContinueFiles ? 'green' : 'neutral'}>{wholeSnapshot ? 'Whole snapshot' : `${paths.length} / ${maxPaths} selected`}</ValuePill></div>
            <label className={`restore-whole-snapshot ${wholeSnapshot ? 'is-selected' : ''}`}><input type="checkbox" checked={wholeSnapshot} onChange={event => sendSelection([], event.target.checked)} disabled={!connected || busy} /><span><strong>Everything in this snapshot</strong><small>Restore all protected paths from {selectedSnapshot ? snapshotWhen(selectedSnapshot) : 'the selected backup'}.</small></span><ArchiveRestore size={17} /></label>
            {treeLoaded && <div className="restore-tree-toolbar"><nav className="restore-tree-breadcrumb" aria-label="Snapshot location">
              <Button type="button" size="icon-sm" variant="quiet" className="restore-tree-up" aria-label="Up one level" title="Up one level" disabled={atRoot || browseLocked} onClick={() => browseFiles(parentPath)}><ArrowUp size={14} /></Button>
              <ol className="restore-tree-crumbs">
                <li>{atRoot ? <span className="restore-crumb is-current" aria-current="page"><HardDrive size={13} /><span>Snapshot root</span></span> : <button type="button" className="restore-crumb" disabled={browseLocked} onClick={() => browseFiles('')}><HardDrive size={13} /><span>Snapshot root</span></button>}</li>
                {trail.map((crumb, index) => crumb === null
                  ? <li key="gap" aria-hidden="true"><ChevronRight size={12} /><span className="restore-crumb-gap" title={crumbs.slice(1, -2).map(item => item.name).join(' / ')}>…</span></li>
                  : <li key={crumb.path}><ChevronRight size={12} aria-hidden="true" />{index === trail.length - 1
                    ? <span className="restore-crumb is-current" aria-current="page" title={crumb.path}><span>{crumb.name}</span></span>
                    : <button type="button" className="restore-crumb" title={crumb.path} disabled={browseLocked} onClick={() => browseFiles(crumb.path)}><span>{crumb.name}</span></button>}</li>)}
              </ol></nav><label className="restore-flow-search"><Search size={13} /><span className="sr-only">Search files</span><input value={fileQuery} onChange={event => setFileQuery(event.target.value)} onKeyDown={clearOnEscape(fileQuery, () => setFileQuery(''))} placeholder="Filter this folder…" /></label></div>}
            {treeError && !current.tree?.loading && <div className="restore-tree-error" role="alert"><CircleAlert size={15} /><span><strong>That folder could not be opened.</strong> {treeError}</span><Button size="xs" disabled={busy || !connected} onClick={() => browseFiles(current.tree?.errorPath || currentPath)}><RotateCcw size={12} />Try again</Button></div>}
            {atCap && <div className="restore-flow-inline-warning is-above" role="status"><Info size={15} />{capText}</div>}
            {listingCut && treeLoaded && !current.tree?.loading && <div className="restore-flow-inline-warning is-above" role="status"><Info size={15} />This folder holds {listedTotal.toLocaleString()} items and the first {entries.length.toLocaleString()} are listed, folders first. Open a subfolder to narrow it down, or select this folder from the level above to restore everything in it.</div>}
            <div className="restore-tree" role="list" aria-label="Snapshot files" ref={treeRef} tabIndex={-1}>
              {current.tree?.loading && <div className="restore-flow-empty"><LoadingState label={approvalWaiting ? 'Waiting for Windows approval…' : 'Reading snapshot contents'} variant="Orbit" live={false} />{approvalWaiting && <p className="restore-progress-hint"><Info size={13} />{approvalNotice || 'Approve the Windows prompt to continue.'} If you do not see it, check the taskbar.</p>}</div>}
              {/* Nothing of this backup has been read: restoring all of it needs no folder, and the root is read only on request. */}
              {!current.tree?.loading && !treeLoaded && !treeError && <div className="restore-flow-empty restore-tree-browse"><FolderOpen size={20} /><strong>Browse this backup</strong><p>Restore everything above, or open its folders to choose files.</p><Button size="sm" disabled={browseLocked} onClick={() => browseFiles('')}><FolderOpen size={14} />Browse files</Button></div>}
              {!current.tree?.loading && treeLoaded && shownEntries.map((entry, index) => { const selected = !wholeSnapshot && paths.includes(entry.path), directory = isDirectory(entry), capped = atCap && !selected, locked = wholeSnapshot || busy || !connected, inert = locked || capped, checkId = `${treeId}-${index}`; return <div key={entry.path} className={`restore-tree-row ${selected ? 'is-selected' : ''}`} role="listitem">
                <label className="restore-entry-check" title={capped ? capText : undefined}><input id={checkId} type="checkbox" aria-label={`Select ${pathName(entry)}`} checked={selected} disabled={inert} onChange={() => sendSelection(selected ? paths.filter(path => path !== entry.path) : [...paths, entry.path], false)} /></label>
                {directory
                  ? <button type="button" className="restore-entry-name" title={entry.path} disabled={busy || !connected} onClick={() => browseFiles(entry.path)}><Folder size={16} /><span>{pathName(entry)}</span><ChevronRight size={14} /></button>
                  : <label htmlFor={checkId} className={`restore-entry-name${inert ? ' is-inert' : ''}`} title={entry.path}><File size={16} /><span>{pathName(entry)}</span></label>}
                <span className="restore-entry-size">{entry.sizeDisplay || (directory ? 'Folder' : formatBytes(entry.size))}</span>
              </div>; })}
              {!current.tree?.loading && treeLoaded && hiddenRows > 0 && <div role="listitem" className="restore-tree-more"><Button size="sm" onClick={() => setRowLimit(limit => limit + ROW_CHUNK)}>Show more<span> · {hiddenRows.toLocaleString()} not shown</span></Button></div>}
              {!current.tree?.loading && treeLoaded && visibleEntries.length === 0 && !treeError && <div className="restore-flow-empty"><FolderOpen size={20} /><strong>{entries.length ? 'No matching files' : 'This folder is empty'}</strong><p>{entries.length ? 'Try another filename or clear the filter.' : 'Choose another folder in the snapshot.'}</p></div>}
              {!current.tree?.loading && visibleEntries.length === 0 && !!treeError && <div className="restore-flow-empty"><FolderOpen size={20} /><strong>{entries.length ? 'No matching files' : 'Nothing to show yet'}</strong><p>{entries.length ? 'Try another filename or clear the filter.' : 'Try opening the folder again, or go back and choose another backup.'}</p></div>}
            </div>
          </section>}

          {activeStep === 'destination' && <section className="restore-flow-step" aria-labelledby="restore-destination-heading">
            <div className="restore-flow-section-heading"><div><span className="eyebrow">Step 3 of 4</span><h3 ref={stepHeadingRef} tabIndex={-1} id="restore-destination-heading">Choose a destination</h3><p>Restore into a separate location so the originals remain untouched.</p></div><HardDrive size={20} className="restore-flow-muted-icon" /></div>
            <form className="restore-destination-card" noValidate onSubmit={event => { event.preventDefault(); validateDestination(); }}>
              <label htmlFor="restore-destination-path">Restore location</label>
              <div className="restore-destination-entry"><FolderOpen size={17} /><input id="restore-destination-path" value={destinationDraft} maxLength={4096} onChange={event => { destinationPickerPendingRef.current = false; destinationDraftDirtyRef.current = true; setDestinationDraft(event.target.value); setValidatedDestinationPath(''); }} placeholder={'C:\\Users\\you\\Restored files'} disabled={busy || !connected} spellCheck={false} autoComplete="off" aria-describedby="restore-destination-help restore-destination-result" aria-invalid={destinationFailure ? true : undefined} /><Button size="sm" type="button" onClick={browseDestination} disabled={busy || !connected}><FolderOpen size={14} />Browse…</Button></div>
              <div className="restore-destination-actions"><span id="restore-destination-help">Use a new or empty folder for the safest recovery. Press Enter to check it.</span><Button size="sm" type="submit" disabled={!draftPath || busy || !connected}>{destinationChecking ? <LoaderCircle size={14} className="restore-spin" /> : <Check size={14} />}Check location</Button></div>
            </form>
            <AnimatePresence mode="wait" initial={false}><motion.div id="restore-destination-result" key={`${destinationTone}|${destinationChecking}|${destinationProblems.join('|')}|${destinationValid ? destinationState?.status : destinationGuidance}`} className={`restore-validation ${destinationTone === 'ready' ? 'is-ready' : destinationTone === 'error' ? 'is-error' : ''}`} role={destinationTone === 'error' ? 'alert' : 'status'} initial={{ opacity: 0, y: reducedMotion ? 0 : 5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} transition={{ duration: reducedMotion ? 0 : .14 }}>
              {destinationChecking ? <LoadingState label="Checking destination" variant="Orbit" /> : <>
                {destinationTone === 'ready' ? <CheckCircle2 size={18} /> : destinationTone === 'error' ? <CircleAlert size={18} /> : <Info size={18} />}
                <div>
                  <strong>{destinationTone === 'ready' ? 'Ready for restore' : destinationTone === 'error' ? (destinationFailure ? 'Choose another destination' : 'Check the restore scope') : 'Check the destination to continue'}</strong>
                  {destinationTone === 'ready' ? <><p>{afterReady(destinationState?.status || '') || 'The destination is available and the selected scope is ready to review.'}</p>{validation?.scopeLabel && <p>Scope: {validation.scopeLabel}.</p>}{freeText && <p>{freeText}.</p>}</>
                    : destinationTone === 'error' ? destinationProblems.map(problem => <p key={problem}>{problem}</p>) : <p>{destinationGuidance}</p>}
                  {validation?.warnings.map(warning => <p className="restore-validation-warning" key={warning}>{warning}</p>)}
                </div></>}
            </motion.div></AnimatePresence>
          </section>}

          {activeStep === 'review' && <section className="restore-flow-step" aria-labelledby="restore-review-heading">
            <div className="restore-flow-section-heading"><div><span className="eyebrow">Step 4 of 4</span><h3 ref={stepHeadingRef} tabIndex={-1} id="restore-review-heading">Review and restore</h3><p>Confirm the immutable snapshot, exact scope, and destination before starting.</p></div><ValuePill tone="accent">Ready to review</ValuePill></div>
            <div className="restore-review-grid"><div className="restore-review-card"><span className="restore-review-label"><ArchiveRestore size={13} />Backup</span><strong title={selectedSnapshot ? snapshotWhen(selectedSnapshot) : undefined}>{selectedSnapshot ? snapshotWhen(selectedSnapshot) : 'No backup selected'}</strong><span>{selectedSnapshot ? `${snapshotSource(selectedSnapshot)} · ${selectedSnapshot.shortId || selectedSnapshot.id}` : 'Choose a saved point in time.'}</span></div><div className="restore-review-card"><span className="restore-review-label"><CheckCircle2 size={13} />Scope</span><strong>{wholeSnapshot ? 'Whole snapshot' : `${paths.length} selected ${paths.length === 1 ? 'path' : 'paths'}`}</strong>{wholeSnapshot ? <span>All protected paths in this snapshot{wholeSize ? ` · about ${wholeSize}` : ''}.</span> : <ul className="restore-review-paths" aria-label="Paths that will be restored">{paths.map(path => <li key={path}><code title={path}>{path}</code></li>)}</ul>}</div><div className="restore-review-card"><span className="restore-review-label"><FolderOpen size={13} />Destination</span><strong className="restore-review-path">{destinationDraft || 'No destination selected'}</strong><span>{destinationValid ? `Destination checked and ready${freeText ? ` · ${freeText}` : ''}.` : 'Destination still needs validation.'}</span></div></div>
            {selectedSnapshot?.isLegacyUnbound && <label className="restore-legacy-confirmation"><input type="checkbox" checked={legacyConfirmed} onChange={event => setLegacyConfirmed(event.target.checked)} disabled={busy || !connected} /><span><strong>This backup is from an older configuration.</strong><small>Confirm that you want to restore from this unbound snapshot even though its folder mapping may have changed.</small></span></label>}
            {startBlocked && <div className="restore-flow-inline-warning" role="status"><Info size={15} />{startBlocked}</div>}
            {spaceWarning && <div className="restore-flow-inline-warning" role="status"><CircleAlert size={15} />{spaceWarning}</div>}
            <div className="restore-review-safety"><LockKeyhole size={15} /><span>Restore writes only to the destination above. Your protected folders and existing snapshots are not changed.</span></div>
          </section>}

          {restoring && <section className="restore-flow-progress"><span className="restore-progress-emblem"><LoaderCircle size={25} className="restore-spin" /></span><div><span className="eyebrow">Restore in progress</span><h3 ref={stepHeadingRef} tabIndex={-1}>{stageLabel}</h3><p>{progressMessage}</p>
            {awaitingApproval && <p className="restore-progress-hint"><Info size={13} />Approve the Windows prompt to continue. If you do not see it, check the taskbar.</p>}
            <div className="restore-progress-rail" role="progressbar" aria-label="Restore progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={indeterminate ? undefined : progressPercent}><motion.div className="progress-bar" animate={{ width: indeterminate ? '100%' : `${progressPercent}%`, opacity: indeterminate ? .5 : 1 }} transition={{ duration: reducedMotion ? 0 : .4 }} /></div>
            <span className="restore-progress-percent">{indeterminate ? 'Working…' : `${progressPercent}%`}<span aria-hidden="true"> · {formatElapsed(elapsedSeconds)} elapsed</span></span>
            {/* One sentence that changes only when the step or its wording does, so the ticking clock and the bar are not announced. */}
            <span className="sr-only" role="status">{stageLabel}. {progressMessage}</span>
            {!canCancel && <p className="restore-progress-lock"><LockKeyhole size={13} />This protected restore must finish before the window can close.</p>}</div></section>}

          {/* One channel: the heading takes focus when the result arrives and carries the message as its description, so the section is not also a live region (that would read the result twice). */}
          {resultStep && <section className={`restore-flow-result is-${resultTone}`}><span className="restore-result-emblem">{resultTone === 'green' ? <CheckCircle2 size={28} /> : <CircleAlert size={28} />}</span><span className="eyebrow">Restore result</span><h3 ref={stepHeadingRef} tabIndex={-1} aria-describedby="restore-result-message">{resultTitle}</h3><p id="restore-result-message">{resultMessage}</p>{resultStatus === 'partial' && <p>Partial files remain in the alternate destination; live files were not changed.</p>}
            {(selectedSnapshot || showVerification) && <div className="restore-result-stats">{selectedSnapshot && <span><ArchiveRestore size={13} />Snapshot <code>{selectedSnapshot.shortId || selectedSnapshot.id.slice(0, 8)}</code></span>}{showVerification && <span className={result?.verified ? 'is-verified' : 'is-unverified'}>{result?.verified ? <ShieldCheck size={13} /> : <CircleAlert size={13} />}{result?.verified ? 'Verified' : 'Not verified'}</span>}</div>}
            {resultFolder && <div className="restore-result-folder"><span>{resultStatus === 'partial' ? 'Partly restored to' : 'Restored to'}</span><code className="restore-result-path">{resultFolder}</code></div>}</section>}
        </div>

        {/* A flow that says it is loading while nothing is under way would otherwise sit here for good. Close stays available, and Try again asks the host to start the step again. */}
        {stalled && <div className="restore-flow-notice is-error" role="alert"><CircleAlert size={15} /><span><strong>Something went wrong.</strong> Rewindle stopped waiting for the repository, and nothing was changed. Try again, or close Restore and open it again.</span><Button size="xs" disabled={!connected} onClick={() => move('restoreFlowRetry')}><RotateCcw size={12} />Try again</Button></div>}
        {/* Outside the scrolling body, so a refused command is never left below the fold. Both regions are in the panel from the moment the
            dialog opens and are empty until there is something to say: a live region that is created together with its text is often
            not announced. Only the notice inside comes and goes. */}
        <div className="restore-flow-notice-region" role="status" aria-live="polite" aria-atomic="true"><AnimatePresence mode="wait">{notice && !notice.error && noticeView(notice)}</AnimatePresence></div>
        <div className="restore-flow-notice-region" role="alert"><AnimatePresence mode="wait">{notice?.error && noticeView(notice)}</AnimatePresence></div>

        <footer className="restore-flow-footer"><span className="restore-flow-footnote" id={HINT_ID}>{hintExplains ? <Info size={13} /> : <LockKeyhole size={13} />}{hint}</span><div className="restore-flow-actions">
          {!['backup', 'success', 'partial', 'error'].includes(activeStep) && !restoring && !busy && <Button size="md" variant="secondary" disabled={!connected} onClick={() => { if (activeStep === 'files') move('restoreFlowNavigate', { step: 'backup' }); else if (activeStep === 'destination') move('restoreFlowNavigate', { step: 'files' }); else if (activeStep === 'review') move('restoreFlowNavigate', { step: 'destination' }); }}><ArrowLeft size={14} />Back</Button>}
          {!restoring && activeStep === 'backup' && <Button size="md" variant="secondary" disabled={busy} onClick={close}>Cancel</Button>}
          {!restoring && activeStep === 'backup' && <Button size="md" variant="primary" aria-describedby={HINT_ID} disabled={!selectedId || !connected || busy} onClick={openFiles}>Choose files <ArrowRight size={14} /></Button>}
          {!restoring && activeStep === 'files' && <Button size="md" variant="primary" aria-describedby={HINT_ID} disabled={!canContinueFiles || !connected || busy} onClick={goDestination}>Choose destination <ArrowRight size={14} /></Button>}
          {!restoring && activeStep === 'destination' && <Button size="md" variant="primary" aria-describedby={HINT_ID} data-review-restore disabled={!destinationValid || !canContinueFiles || !connected || busy} onClick={goReview}>Review restore <ArrowRight size={14} /></Button>}
          {!restoring && activeStep === 'review' && <Button size="md" variant="primary" aria-describedby={HINT_ID} disabled={!canStart || !connected || busy} onClick={startRestore}><ArchiveRestore size={15} />Restore now</Button>}
          {restoring && canCancel && <Button size="md" variant="secondary" disabled={status === 'canceling' || !connected} onClick={() => send('restoreFlowCancel')}><X size={14} />{status === 'canceling' ? 'Cancelling…' : 'Cancel restore'}</Button>}
          {/* On a restore that worked, opening the folder is the next thing anyone does, so it is the main button and Close steps back. After a
              partial one, Try again stays the main button and the folder is offered beside it. */}
          {!restoring && ['success', 'partial', 'error'].includes(activeStep) && <>
            {resultFolder && <Button size="md" variant="quiet" disabled={!hostReachable || busy} onClick={() => move('restoreFlowCopyDestination')}><Copy size={14} />Copy path</Button>}
            <Button size="md" variant="secondary" disabled={busy} onClick={close}>Close</Button>
            {resultFolder && <Button size="md" variant={resultStatus === 'success' ? 'primary' : 'secondary'} disabled={!hostReachable || busy} onClick={() => move('restoreFlowOpenDestination')}><FolderOpen size={14} />{resultStatus === 'partial' ? 'Open partial folder' : 'Open restored folder'}</Button>}
            {(result?.retryable || resultStatus === 'partial' || resultStatus === 'error' || resultStatus === 'cancelled') && <Button size="md" variant="primary" disabled={!connected || busy} onClick={() => move('restoreFlowRetry')}><RotateCcw size={14} />{result?.retryLabel || 'Try again'}</Button>}</>}
        </div></footer>
      </motion.div>}
    </AnimatePresence>
  </dialog>;
}
