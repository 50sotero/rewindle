import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import {
  AlertTriangle,
  Check,
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

type Send = (command: CommandName, payload?: Record<string, string | boolean>) => void;

type RunDetailsModalProps = {
  details: RunDetailsState | null;
  open: boolean;
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

// The host's short result, said as a sentence about the run ("Backup failed", "Dry run found source errors").
const OUTCOMES: Record<string, string> = {
  failed: 'failed', canceled: 'cancelled', cancelled: 'cancelled', incomplete: 'was incomplete',
  'source errors': 'found source errors', 'cancellation failed': 'could not be cancelled', 'needs attention': 'needs attention',
};

function statusDetails(details: RunDetailsState) {
  const subject = details.type.trim() || 'Run';
  const normalizedType = details.type.trim().toLowerCase();
  const normalizedResult = details.result.trim();
  const verified = details.success && normalizedType === 'backup' && /^verified$/i.test(normalizedResult);
  const warning = details.success || /cancel|warn|dry\s*run|unknown|incomplete|review/i.test(`${details.type} ${details.result}`);
  const tone: ValuePillTone = verified ? 'green' : details.success ? 'accent' : warning ? 'orange' : 'red';
  const status = normalizedResult || (details.success ? 'Completed' : 'Needs attention');
  const outcome = OUTCOMES[status.toLowerCase()];
  const title = details.success
    ? verified ? 'Backup verified' : `${subject} completed`
    : outcome ? `${subject} ${outcome}` : `${subject}: ${status}`;
  // The headline already names the result for a verified or an unsuccessful run, so the eyebrow's "type / result"
  // would only repeat it. For other successes ("Unchanged", "Clean baseline") the eyebrow is where the result shows.
  const titleStatesResult = verified || !details.success;
  return { tone, status, title, warning, verified, titleStatesResult };
}

function DetailStat({ label, value, icon, hint }: { label: string; value: string; icon: React.ReactNode; hint?: string }) {
  return <div className="run-detail-stat" title={hint}>
    <span className="run-detail-stat-label">{icon}{label}</span>
    <strong>{value || '—'}</strong>
  </div>;
}

function DetailIconButton({ label, children, onClick, disabled = false }: {
  label: string; children: React.ReactNode; onClick: () => void; disabled?: boolean;
}) {
  return <Button size="sm" variant="secondary" className="run-detail-action" aria-label={label} title={label} onClick={onClick} disabled={disabled}>
    {children}<span>{label}</span>
  </Button>;
}

export default function RunDetailsModal({
  details,
  open,
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

  onRequestCloseRef.current = onRequestClose;

  useEffect(() => {
    if (details && details.id !== activeDetails?.id) {
      setActiveDetails(details);
      setQuery('');
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
  }, [activeDetails?.id, phase === 'closed', query]);

  const hasIssue = !!activeDetails && (!activeDetails.success || !!activeDetails.failure.trim() || !!activeDetails.remediation.trim() || activeDetails.affectedPaths.length > 0);
  const technical = activeDetails ? [
    ['Phase', activeDetails.phase],
    ['Failure code', activeDetails.failureCode],
    ['Exit code', activeDetails.exitCode],
  ].filter(([, value]) => value.trim()) : [];
  const result = activeDetails ? statusDetails(activeDetails) : null;

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
              {result.tone === 'green' ? <Check size={18} /> : result.warning ? <Info size={18} /> : <AlertTriangle size={18} />}
            </div>
            <div>
              <div className="run-detail-eyebrow">{result.titleStatesResult
                ? <span>Run details</span>
                : <><span>{activeDetails.type || 'Run'}</span><span aria-hidden="true">/</span><span className="run-detail-eyebrow-status">{result.status}</span></>}</div>
              <h2 id="run-details-title">{result.title}</h2>
              <p id="run-details-subtitle" className="run-detail-subtitle"><span>{activeDetails.startedDisplay || 'Date unavailable'}</span><span aria-hidden="true">·</span><span>{activeDetails.durationDisplay || 'Duration unavailable'}</span></p>
              <code className="run-detail-id">{activeDetails.id}</code>
            </div>
          </div>
          <Button size="icon" variant="quiet" data-autofocus aria-label="Close run details" title="Close run details (Escape)" onClick={() => close(true)}><X size={17} /></Button>
        </header>

        <div className="run-detail-scroll">
          <div className="run-detail-summary">
            <section className="run-detail-stats" aria-label="Run summary">
              <DetailStat label="Files" value={activeDetails.filesDisplay} icon={<FileText size={13} />} />
              <DetailStat label="Processed" value={activeDetails.processedDisplay} icon={<Clipboard size={13} />} hint="Data read from your protected folders during this run." />
              <DetailStat label="Stored" value={activeDetails.storedDisplay} icon={<FolderOpen size={13} />} hint="New data this run added to the repository, after deduplication and compression." />
            </section>

            {activeDetails.snapshotId.trim() && !['-', '—'].includes(activeDetails.snapshotId.trim()) && <section className="run-detail-snapshot surface" aria-labelledby="run-detail-snapshot-heading">
              <div className="run-detail-section-heading"><div><h3 id="run-detail-snapshot-heading">{result.verified ? 'Verified snapshot' : 'Recorded snapshot'}</h3></div></div>
              <div className="run-detail-snapshot-row"><code>{activeDetails.snapshotId}</code><Button size="xs" variant="secondary" onClick={() => copy('copyRunSnapshot')}><Copy size={12} />Copy ID</Button></div>
            </section>}

            {hasIssue && <section className={`run-detail-issue ${result.warning ? 'warning' : 'error'}`} aria-label="Run attention details">
              <div className="run-detail-issue-title"><AlertTriangle size={15} /><strong>{result.warning ? 'Run needs attention' : 'Run failed'}</strong></div>
              {activeDetails.failure.trim() && <p><strong>Failure</strong>{activeDetails.failure}</p>}
              {activeDetails.remediation.trim() && <p><strong>Next step</strong>{activeDetails.remediation}</p>}
              {activeDetails.affectedPaths.length > 0 && <div className="run-detail-paths"><strong>Affected paths</strong><ul>{activeDetails.affectedPaths.map(path => <li key={path}><code>{path}</code></li>)}</ul></div>}
              {!activeDetails.failure.trim() && !activeDetails.remediation.trim() && activeDetails.affectedPaths.length === 0 && <p>No additional issue detail was recorded for this run.</p>}
            </section>}

            <details className="run-detail-technical">
              <summary><span><Hash size={14} />Technical details</span><span className="run-detail-summary-hint">{technical.length ? `${technical.length} recorded` : 'No detail recorded'}<ChevronDown size={13} /></span></summary>
              {technical.length > 0 ? <div className="run-detail-technical-grid">{technical.map(([label, value]) => <div key={label}><span>{label}</span><code>{value}</code></div>)}</div> : <p>No phase, failure code, or exit code was recorded for this run.</p>}
            </details>
          </div>

          <section className="run-detail-events surface" aria-labelledby="run-detail-events-heading">
            <div className="run-detail-events-heading"><div><h3 id="run-detail-events-heading">Event timeline</h3><p>{activeDetails.eventsTruncated ? `Showing the last ${activeDetails.events.length} events of this run's log` : `${activeDetails.events.length} recorded ${activeDetails.events.length === 1 ? 'event' : 'events'}`}</p>{activeDetails.logNote && <p className="run-detail-events-note"><AlertTriangle size={12} />{activeDetails.logNote}</p>}</div><span className="run-detail-event-count"><ValuePill tone={result.tone}>{filteredEvents.length} shown</ValuePill></span></div>
            <div className="run-detail-filter-row"><label className="run-detail-filter"><Search size={14} /><span className="sr-only">Filter events</span><input value={query} maxLength={4096} onChange={event => setQuery(event.target.value)} placeholder="Filter events" aria-label="Filter events" /><kbd>Ctrl F</kbd></label>{query && <Button size="xs" variant="quiet" onClick={() => setQuery('')}>Clear filter</Button>}</div>
            <div ref={eventsRef} className="run-detail-event-list" tabIndex={0} role="log" aria-label="Protected log events" aria-live="off">
              {filteredEvents.length > 0 ? filteredEvents.map(event => <div className="run-detail-event" key={event.n}><span aria-hidden="true">{String(event.n).padStart(3, '0')}</span><code>{event.text}</code></div>) : <div className="run-detail-event-empty"><Search size={18} /><strong>{activeDetails.events.length ? 'No matching events' : activeDetails.hasLog ? 'No events recorded' : 'No protected log is available'}</strong><p>{activeDetails.events.length ? 'Try a different filter or clear the current search.' : activeDetails.hasLog ? activeDetails.logNote || 'This log has no structured events to display.' : 'This run does not have a readable event log.'}</p>{query && <Button size="xs" onClick={() => setQuery('')}>Clear filter</Button>}</div>}
            </div>
          </section>
        </div>

        <footer className="run-detail-footer">
          <div className="run-detail-footer-actions">
            <DetailIconButton label="Open log location" disabled={!activeDetails.hasLog} onClick={() => copy('openRunLogLocation')}><FolderOpen size={14} /></DetailIconButton>
            <DetailIconButton label="Copy summary" onClick={() => copy('copyRunSummary')}><ClipboardCheck size={14} /></DetailIconButton>
            <DetailIconButton label="Copy visible events" disabled={filteredEvents.length === 0} onClick={() => copy('copyRunEvents', { query })}><Copy size={14} /></DetailIconButton>
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
