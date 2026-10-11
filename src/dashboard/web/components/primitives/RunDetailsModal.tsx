import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import {
  AlertTriangle,
  Check,
  CircleCheck,
  Clipboard,
  ClipboardCheck,
  ChevronDown,
  Copy,
  FileText,
  FolderOpen,
  Hash,
  Info,
  Search,
  X,
} from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { ValuePill, type ValuePillTone } from '@/components/atoms/ValuePill';
import type { CommandName, Notice, RunDetailsState } from '@/src/native-types';
import { noticeHoldProps, type NoticeHold } from '@/src/useDashboard';
import { isUnchanged, knownOutcome, resultLabel, runNoun, typeLabel, type Resolver } from '@/src/runProblems';

type Send = (command: CommandName, payload?: Record<string, string | boolean>) => void;

type RunDetailsModalProps = {
  details: RunDetailsState | null;
  open: boolean;
  /** The later run that put this one right, when it did not succeed and a later one did (see runProblems). */
  resolvedBy?: Resolver;
  reducedMotion: boolean;
  send: Send;
  notice: Notice | null;
  dismissNotice: () => void;
  /** Keeps the notice up while the pointer or keyboard focus is on it (see useDashboard). */
  holdNotice?: NoticeHold;
  onRequestClose: () => void;
};

type ModalPhase = 'closed' | 'opening' | 'open' | 'closing';

const focusableSelector = [
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'a[href]',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

// `resolved`: a later backup put this run right, so it is a record and not something to act on.
function statusDetails(details: RunDetailsState, resolved: boolean) {
  const noun = runNoun(details.type), subject = `${noun.charAt(0).toUpperCase()}${noun.slice(1)}`, isBackup = noun === 'backup';
  const normalizedResult = details.result.trim();
  // Stopped on request: nothing went wrong, so it is told apart from a run that failed.
  const cancelled = /^(cancelled|canceled)$/i.test(normalizedResult);
  const unchanged = details.success && isBackup && isUnchanged(normalizedResult);
  const verified = details.success && isBackup && (unchanged || /^verified$/i.test(normalizedResult));
  // Orange is for a run that may need a look; a failed one is red. A stopped or an already-resolved run is neither.
  const warning = details.success || /warn|unknown|incomplete|review|source errors|cancellation failed/i.test(normalizedResult);
  const tone: ValuePillTone = verified ? 'green' : resolved || cancelled ? 'neutral' : details.success ? 'accent' : warning ? 'orange' : 'red';
  const status = normalizedResult || (details.success ? 'Completed' : 'Needs attention');
  // The host's short result, said as a sentence about the run ("Backup failed", "Check found files it could not read").
  const outcome = knownOutcome(status);
  const title = details.success
    ? unchanged ? 'Nothing new to back up' : verified ? 'Backup verified' : !isBackup && /^clean baseline$/i.test(status) ? 'Check passed' : `${subject} completed`
    : outcome ? `${subject} ${outcome}` : `${subject}: ${resultLabel(status)}`;
  // The headline already names the result for a verified or an unsuccessful run, so the eyebrow's "type / result"
  // would only repeat it. For other successes the eyebrow is where the result shows.
  const titleStatesResult = verified || !details.success;
  return { tone, status, title, warning, verified, unchanged, cancelled, isBackup, noun, titleStatesResult };
}

function DetailStat({ label, value, icon, hint }: { label: string; value: string; icon: React.ReactNode; hint?: string }) {
  return <div className="run-detail-stat" title={hint}>
    <span className="run-detail-stat-label">{icon}{label}</span>
    <strong>{value || '—'}</strong>
  </div>;
}

// `why` is the tooltip while the button is off, so it never just sits there greyed out with no reason.
function DetailIconButton({ label, children, onClick, disabled = false, why }: {
  label: string; children: React.ReactNode; onClick: () => void; disabled?: boolean; why?: string;
}) {
  return <Button size="sm" variant="secondary" className="run-detail-action" aria-label={label} title={disabled && why ? why : label} onClick={onClick} disabled={disabled}>
    {children}<span>{label}</span>
  </Button>;
}

export default function RunDetailsModal({
  details,
  open,
  resolvedBy,
  reducedMotion,
  send,
  notice,
  dismissNotice,
  holdNotice,
  onRequestClose,
}: RunDetailsModalProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const eventsRef = useRef<HTMLDivElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const closeTimerRef = useRef<number | null>(null);
  // Whether the press that is now ending started on the backdrop, and when the dialog opened (see the click handler).
  const pressedBackdropRef = useRef(false);
  const openedAtRef = useRef(0);
  const onRequestCloseRef = useRef(onRequestClose);
  const [activeDetails, setActiveDetails] = useState<RunDetailsState | null>(details);
  const [phase, setPhase] = useState<ModalPhase>('closed');
  const [query, setQuery] = useState('');
  // The log of a run that worked is a wall of lines nobody needs; it opens on request. A failed run shows it at once.
  const [showEvents, setShowEvents] = useState(false);

  onRequestCloseRef.current = onRequestClose;

  useEffect(() => {
    if (details && details.id !== activeDetails?.id) {
      setActiveDetails(details);
      setQuery('');
      setShowEvents(false);
    } else if (details && activeDetails && details.id === activeDetails.id && details !== activeDetails) {
      // The native host keeps a single immutable details payload open. Keep this
      // update tolerant of a reconnect without resetting the user's filter.
      setActiveDetails(details);
    }
  }, [details, activeDetails]);

  const finishClose = useCallback(() => {
    const dialog = dialogRef.current;
    if (closeTimerRef.current !== null) {
      window.clearTimeout(closeTimerRef.current);
      closeTimerRef.current = null;
    }
    if (dialog?.open) dialog.close();
    setPhase('closed');
    setActiveDetails(null);
    setQuery('');
    setShowEvents(false);
    const returnFocus = returnFocusRef.current;
    returnFocusRef.current = null;
    if (returnFocus && document.contains(returnFocus)) returnFocus.focus({ preventScroll: true });
  }, []);

  const close = useCallback((notifyNative: boolean) => {
    const dialog = dialogRef.current;
    if (!dialog?.open || phase === 'closing') return;
    if (notifyNative) onRequestCloseRef.current();
    setPhase('closing');
    const delay = reducedMotion ? 0 : 190;
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    closeTimerRef.current = window.setTimeout(finishClose, delay);
  }, [finishClose, phase, reducedMotion]);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && activeDetails) {
      if (closeTimerRef.current !== null) {
        window.clearTimeout(closeTimerRef.current);
        closeTimerRef.current = null;
      }
      if (!dialog.open) {
        returnFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
        openedAtRef.current = Date.now();
        try { dialog.showModal(); } catch { /* A concurrent StrictMode effect may already have opened it. */ }
        setPhase('opening');
        window.requestAnimationFrame(() => panelRef.current?.querySelector<HTMLElement>('[data-autofocus]')?.focus());
      } else if (phase === 'closing' || phase === 'closed') {
        setPhase('open');
      }
    } else if (!open && dialog.open && phase !== 'closing') {
      close(false);
    }
  }, [activeDetails, close, open, phase]);

  useEffect(() => () => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    if (dialogRef.current?.open) dialogRef.current.close();
  }, []);

  // Each line keeps its place in the recorded list, so its number does not change as the filter does.
  const numberedEvents = useMemo(() => (activeDetails?.events ?? []).map((text, index) => ({ n: index + 1, text })), [activeDetails?.events]);
  const filteredEvents = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    if (!normalizedQuery) return numberedEvents;
    return numberedEvents.filter(event => event.text.toLowerCase().includes(normalizedQuery));
  }, [numberedEvents, query]);

  useEffect(() => {
    // Keep chronological events, initially showing the newest outcome at the end.
    const frame = window.requestAnimationFrame(() => {
      if (eventsRef.current) eventsRef.current.scrollTop = query ? 0 : eventsRef.current.scrollHeight;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [activeDetails?.id, phase === 'closed', query, showEvents]);

  // Only for the run it was worked out for: the dialog keeps the details it shows while it closes.
  const resolver = activeDetails && !activeDetails.success && details?.id === activeDetails.id ? resolvedBy : undefined;
  const result = activeDetails ? statusDetails(activeDetails, !!resolver) : null;
  const hasDetail = !!activeDetails && (!!activeDetails.failure.trim() || !!activeDetails.remediation.trim() || activeDetails.affectedPaths.length > 0);
  const hasIssue = !!activeDetails && (!activeDetails.success || hasDetail);
  // What the run recorded that a support person asks for; the run's id and snapshot are listed under it, not in the headline.
  const technical = activeDetails ? [
    ['Phase', activeDetails.phase],
    ['Failure code', activeDetails.failureCode],
    ['Exit code', activeDetails.exitCode],
  ].filter(([, value]) => value.trim()) : [];
  const snapshotId = activeDetails && !['-', '—', ''].includes(activeDetails.snapshotId.trim()) ? activeDetails.snapshotId.trim() : '';
  const eventsOpen = !!activeDetails && (!activeDetails.success || showEvents || !!query || activeDetails.events.length === 0);
  const tryAgain = 'Choose Back up now to try again; if it fails again, use Save problem report in Settings.';
  // A zero on a run that did not finish is "nothing counted", not "nothing there".
  const counted = (value: string) => activeDetails && !activeDetails.success && /^0(\s?B)?$/.test(value.trim()) ? '' : value;

  const copy = (command: CommandName, extra?: Record<string, string | boolean>) => {
    if (!activeDetails) return;
    send(command, { runId: activeDetails.id, ...extra });
  };

  // The notice itself (a copy that worked, a log that could not be opened). New for each one, so the same words said twice are drawn
  // and announced again; it waits while the pointer or focus is on it.
  const noticeView = (item: Notice) => <motion.div key={item.id} className={`run-detail-notice ${item.error ? 'error' : ''}`}
    initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 5 }} {...noticeHoldProps(holdNotice)}>
    <span>{item.text}</span><Button size="icon-sm" variant="quiet" aria-label="Dismiss notification" onClick={dismissNotice}><X size={13} /></Button>
  </motion.div>;

  const onKeyDown = (event: React.KeyboardEvent<HTMLDialogElement>) => {
    if (event.key === 'Escape' && query) {
      event.preventDefault();
      event.stopPropagation();
      setQuery('');
      return;
    }
    if (event.key.toLowerCase() === 'f' && (event.ctrlKey || event.metaKey) && !event.altKey) {
      event.preventDefault();
      dialogRef.current?.querySelector<HTMLInputElement>('.run-detail-filter input')?.focus();
      return;
    }
    if (event.key !== 'Tab') return;
    const dialog = dialogRef.current;
    if (!dialog) return;
    const elements = Array.from(dialog.querySelectorAll<HTMLElement>(focusableSelector)).filter(element => element.offsetParent !== null);
    if (elements.length === 0) return;
    const first = elements[0];
    const last = elements[elements.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  // app-dialog and is-closing give it the same scrim, fading in and out with the panel, as the other two dialogs (see app.css).
  return <dialog
    ref={dialogRef}
    className={`run-details-dialog app-dialog${phase === 'closing' ? ' is-closing' : ''}`}
    aria-labelledby="run-details-title"
    aria-describedby="run-details-subtitle"
    onCancel={event => { event.preventDefault(); close(true); }}
    onKeyDown={onKeyDown}
    onPointerDown={event => { pressedBackdropRef.current = event.target === event.currentTarget; }}
    onClick={event => {
      // The panel fills the dialog, so only the backdrop reaches the dialog itself. Dragging a text selection out of
      // the panel and releasing over the backdrop also clicks the dialog, so a click closes it only when the press
      // began on the backdrop too. The moments right after opening ignore the backdrop as well, so the tail of the
      // double-click that opened the dialog cannot dismiss it.
      const pressedBackdrop = pressedBackdropRef.current;
      pressedBackdropRef.current = false;
      if (pressedBackdrop && event.target === event.currentTarget && Date.now() - openedAtRef.current > 300) close(true);
    }}
    onClose={() => { if (phase !== 'closed') finishClose(); }}
  >
    <AnimatePresence initial={false} mode="wait">
      {/* Mounted as soon as the dialog is asked to open, so its title and subtitle already exist when showModal runs: a dialog
          that opens empty has no name for a screen reader to speak, and focus lands on the bare dialog first. */}
      {activeDetails && (phase !== 'closed' || open) && result && <motion.div
        key={activeDetails.id}
        ref={panelRef}
        className="run-details-panel"
        initial={{ opacity: 0, y: reducedMotion ? 0 : 12, scale: reducedMotion ? 1 : .985 }}
        animate={{ opacity: phase === 'closing' ? 0 : 1, y: phase === 'closing' && !reducedMotion ? 8 : 0, scale: 1 }}
        exit={{ opacity: 0, y: reducedMotion ? 0 : 8 }}
        transition={{ duration: reducedMotion ? 0 : .18, ease: [.16, 1, .3, 1] }}
      >
        <header className="run-detail-header">
          <div className="run-detail-heading">
            <div className={`run-detail-status-icon ${result.tone}`} aria-hidden="true">
              {result.tone === 'green' ? <Check size={18} /> : resolver ? <CircleCheck size={18} /> : result.cancelled || result.warning ? <Info size={18} /> : <AlertTriangle size={18} />}
            </div>
            <div>
              <div className="run-detail-eyebrow">{resolver
                ? <><span>Run details</span><span aria-hidden="true">/</span><span className="run-detail-eyebrow-status">Resolved</span></>
                : result.titleStatesResult
                  ? <span>Run details</span>
                  : <><span>{typeLabel(activeDetails.type)}</span><span aria-hidden="true">/</span><span className="run-detail-eyebrow-status">{resultLabel(result.status)}</span></>}</div>
              <h2 id="run-details-title">{result.title}</h2>
              <p id="run-details-subtitle" className="run-detail-subtitle"><span>{activeDetails.startedDisplay || 'Date unavailable'}</span><span aria-hidden="true">·</span><span>{activeDetails.durationDisplay || 'Duration unavailable'}</span></p>
            </div>
          </div>
          <Button size="icon" variant="quiet" data-autofocus aria-label="Close run details" title="Close run details (Escape)" onClick={() => close(true)}><X size={17} /></Button>
        </header>

        <div className="run-detail-scroll">
          <div className="run-detail-summary">
            <section className="run-detail-stats" aria-label="Run summary">
              <DetailStat label="Files" value={counted(activeDetails.filesDisplay)} icon={<FileText size={13} />} />
              <DetailStat label="Size covered" value={counted(activeDetails.processedDisplay)} icon={<Clipboard size={13} />} hint="Everything this run looked through, new and unchanged files alike." />
              <DetailStat label="New data saved" value={!result.isBackup ? 'Nothing saved' : result.unchanged ? 'Nothing new' : counted(activeDetails.storedDisplay)} icon={<FolderOpen size={13} />} hint="Added to your backup location by this run, after removing duplicates and compressing." />
            </section>

            {hasIssue && <section className={`run-detail-issue ${resolver ? 'resolved' : result.cancelled ? 'stopped' : result.warning ? 'warning' : 'error'}`} aria-label={resolver ? 'What happened in this run' : result.cancelled ? 'Why this run stopped' : 'Run attention details'}>
              {/* A run a later one put right, or one that was stopped on request, asks for nothing: it says so first. The next step of a
                  resolved run is advice for the next time. */}
              <div className="run-detail-issue-title">{resolver ? <CircleCheck size={15} /> : result.cancelled ? <Info size={15} /> : <AlertTriangle size={15} />}<strong>{resolver ? `Resolved by a later ${runNoun(resolver.type)}` : result.cancelled ? 'Stopped before it finished' : result.warning ? 'Run needs attention' : 'Run failed'}</strong></div>
              {resolver && <p>The {runNoun(resolver.type)} {resolver.finished ? 'that finished on' : 'on'} {resolver.startedDisplay} succeeded, so nothing needs doing about this run.{hasDetail ? ' What went wrong is kept below for reference.' : ''}</p>}
              {!resolver && result.cancelled && <p>This {result.noun} was stopped on request. Nothing is wrong, and your earlier backups are not affected.</p>}
              {activeDetails.failure.trim() && <p><strong>What went wrong</strong>{activeDetails.failure}</p>}
              {activeDetails.remediation.trim() && <p><strong>{resolver ? 'If it happens again' : 'Next step'}</strong>{activeDetails.remediation}</p>}
              {activeDetails.affectedPaths.length > 0 && <div className="run-detail-paths"><strong>Affected paths</strong><ul>{activeDetails.affectedPaths.map(path => <li key={path}><code>{path}</code></li>)}</ul></div>}
              {/* A run that failed always says what to do next, even when the log kept nothing about why. */}
              {!resolver && !result.cancelled && !activeDetails.success && !activeDetails.remediation.trim() && (hasDetail ? <p><strong>Next step</strong>{tryAgain}</p> : <p>No reason was recorded for this run. {tryAgain}</p>)}
            </section>}

            <details className="run-detail-technical">
              <summary><span><Hash size={14} />Technical details</span><span className="run-detail-summary-hint">{technical.length + 1 + (snapshotId ? 1 : 0)} recorded<ChevronDown size={13} /></span></summary>
              {technical.length > 0 && <div className="run-detail-technical-grid">{technical.map(([label, value]) => <div key={label}><span>{label}</span><code>{value}</code></div>)}</div>}
              <div className="run-detail-technical-rows">
                <div><span>Run ID</span><code>{activeDetails.id}</code></div>
                {/* The snapshot is the backup's name inside the backup location; a support person asks for it, so it is one click to copy. */}
                {snapshotId && <div><span>Snapshot</span><code title={snapshotId}>{snapshotId.slice(0, 8)}</code><Button size="xs" variant="secondary" onClick={() => copy('copyRunSnapshot')}><Copy size={12} />Copy ID</Button></div>}
              </div>
            </details>
          </div>

          <section className={`run-detail-events surface${eventsOpen ? '' : ' is-collapsed'}`} aria-labelledby="run-detail-events-heading">
            <div className="run-detail-events-heading"><div><h3 id="run-detail-events-heading">Event timeline</h3><p>{activeDetails.eventsTruncated ? `Showing the last ${activeDetails.events.length} events of this run's log` : `${activeDetails.events.length} recorded ${activeDetails.events.length === 1 ? 'event' : 'events'}`}</p>{activeDetails.logNote && <p className="run-detail-events-note"><AlertTriangle size={12} />{activeDetails.logNote}</p>}</div>
              {eventsOpen ? <span className="run-detail-event-count"><ValuePill>{filteredEvents.length} shown</ValuePill></span>
                : <Button size="sm" variant="secondary" aria-expanded={false} onClick={() => setShowEvents(true)}>Show log events</Button>}</div>
            {eventsOpen && <>
              <div className="run-detail-filter-row"><label className="run-detail-filter"><Search size={14} /><span className="sr-only">Filter events</span><input value={query} maxLength={4096} onChange={event => setQuery(event.target.value)} placeholder="Filter events" aria-label="Filter events" /><kbd>Ctrl F</kbd></label>{query && <Button size="xs" variant="quiet" onClick={() => setQuery('')}>Clear filter</Button>}</div>
              <div ref={eventsRef} className="run-detail-event-list" tabIndex={0} role="log" aria-label="Log events" aria-live="off">
                {filteredEvents.length > 0 ? filteredEvents.map(event => <div className="run-detail-event" key={event.n}><span aria-hidden="true">{String(event.n).padStart(3, '0')}</span><code>{event.text}</code></div>) : <div className="run-detail-event-empty"><Search size={18} /><strong>{activeDetails.events.length ? 'No matching events' : activeDetails.hasLog ? 'No events recorded' : 'No log was kept for this run'}</strong><p>{activeDetails.events.length ? 'Try a different filter or clear the current search.' : activeDetails.hasLog ? activeDetails.logNote || 'This log has no events to show.' : 'Rewindle did not keep a readable log for this run.'}</p>{query && <Button size="xs" onClick={() => setQuery('')}>Clear filter</Button>}</div>}
              </div>
            </>}
          </section>
        </div>

        <footer className="run-detail-footer">
          <div className="run-detail-footer-actions">
            <DetailIconButton label="Open log location" disabled={!activeDetails.hasLog} why="No log was kept for this run" onClick={() => copy('openRunLogLocation')}><FolderOpen size={14} /></DetailIconButton>
            <DetailIconButton label="Copy summary" onClick={() => copy('copyRunSummary')}><ClipboardCheck size={14} /></DetailIconButton>
            <DetailIconButton label="Copy events" disabled={filteredEvents.length === 0} why="There are no events to copy" onClick={() => copy('copyRunEvents', { query })}><Copy size={14} /></DetailIconButton>
          </div>
          <Button size="md" variant="primary" onClick={() => close(true)}>Close</Button>
        </footer>
        {/* Both regions are in the panel from the moment the dialog opens and are empty until there is something to say: a live region
            that is created together with its text is often not announced. Only the notice inside comes and goes. */}
        <div role="status" aria-live="polite" aria-atomic="true"><AnimatePresence mode="wait">{notice && !notice.error && noticeView(notice)}</AnimatePresence></div>
        <div role="alert"><AnimatePresence mode="wait">{notice?.error && noticeView(notice)}</AnimatePresence></div>
      </motion.div>}
    </AnimatePresence>
  </dialog>;
}
