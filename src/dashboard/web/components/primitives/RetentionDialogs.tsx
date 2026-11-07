import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { Archive, CircleAlert, LockKeyhole, X } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import type { CommandName, RetentionState } from '@/src/native-types';
import {
  countError, filesCheckSentence, formatDay, formatMoment, groupByMonth, historySummary, monthLabel, parseCount, reasonsLabel, reasonTag, resultScreen,
  type CountKind,
} from '@/src/retention';
import { usePendingCommand } from '@/src/pendingCommands';

type Send = (command: CommandName, payload?: Record<string, string | boolean>, onResult?: (ok: boolean) => void) => void;

// A modal <dialog> that opens and closes with `open`, gives focus back to what had it, and treats Escape as Cancel.
function useModal(open: boolean, onCancel: () => void) {
  const dialog = useRef<HTMLDialogElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      element.showModal();
    } else if (!open && element.open) {
      element.close();
      if (returnFocus.current?.isConnected) returnFocus.current.focus({ preventScroll: true });
    }
  }, [open]);
  useEffect(() => () => { dialog.current?.close(); }, []);
  return {
    ref: dialog,
    onCancel: (event: React.SyntheticEvent) => { event.preventDefault(); onCancel(); },
  };
}

function DialogFrame({ titleId, title, lead, onClose, closeLabel, closeDisabled = false, children, footer }: {
  titleId: string; title: string; lead?: string; onClose: () => void; closeLabel: string; closeDisabled?: boolean; children?: ReactNode; footer: ReactNode;
}) {
  return <div className="old-backups-panel">
    <header className="old-backups-heading"><span className="old-backups-emblem"><Archive size={22} aria-hidden="true" /></span>
      <div><span className="eyebrow">Old backups</span><h2 id={titleId}>{title}</h2>{lead && <p>{lead}</p>}</div>
      <Button size="icon" variant="quiet" disabled={closeDisabled} onClick={onClose} aria-label={closeLabel}><X size={18} /></Button>
    </header>
    <div className="old-backups-body">{children}</div>
    <footer className="old-backups-footer">{footer}</footer>
  </div>;
}

const KINDS: { kind: CountKind; label: string; help: (n: string) => string; key: 'keepDaily' | 'keepWeekly' | 'keepMonthly' }[] = [
  { kind: 'daily', label: 'Days', key: 'keepDaily', help: n => `Keep the last backup of each of the last ${n || '…'} days that have a backup.` },
  { kind: 'weekly', label: 'Weeks', key: 'keepWeekly', help: n => `Keep the last backup of each of the last ${n || '…'} weeks that have a backup.` },
  { kind: 'monthly', label: 'Months', key: 'keepMonthly', help: n => `Keep the last backup of each of the last ${n || '…'} months that have a backup.` },
];

/** Turn on clean-up, or change how many backups it keeps. Nothing is removed here: the list opens afterwards for the person to check. */
export function RetentionCountsDialog({ open, retention, send, onClose, reducedMotion }: {
  open: boolean; retention: RetentionState; send: Send; onClose: () => void; reducedMotion: boolean;
}) {
  const titleId = useId();
  const pending = usePendingCommand();
  const modal = useModal(open, onClose);
  const [values, setValues] = useState({ daily: '', weekly: '', monthly: '' });
  useEffect(() => {
    if (open) setValues({ daily: String(retention.keepDaily), weekly: String(retention.keepWeekly), monthly: String(retention.keepMonthly) });
    // Only when it opens: a state that arrives while the person types does not overwrite what they typed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
  const parsed = {
    daily: parseCount('daily', values.daily, retention.limits),
    weekly: parseCount('weekly', values.weekly, retention.limits),
    monthly: parseCount('monthly', values.monthly, retention.limits),
  };
  const valid = parsed.daily !== null && parsed.weekly !== null && parsed.monthly !== null;
  const changing = retention.mode === 'on';
  const blocked = !retention.canConfigure.enabled;
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!valid || blocked || pending('retentionConfigure')) return;
    send('retentionConfigure', {
      enabled: '1', keepDaily: String(parsed.daily), keepWeekly: String(parsed.weekly), keepMonthly: String(parsed.monthly),
    }, ok => { if (ok) onClose(); });
  };
  return <dialog ref={modal.ref} className="old-backups-dialog app-dialog" aria-labelledby={titleId} onCancel={modal.onCancel} data-reduced-motion={reducedMotion || undefined}>
    {open && <form onSubmit={submit}><DialogFrame titleId={titleId} title={changing ? 'Change clean-up' : 'Clean up old backups'} onClose={onClose} closeLabel="Cancel"
      lead="Rewindle keeps the last backup of each day, week and month below and offers to remove the rest. Nothing is removed until you check the list and confirm it."
      footer={<><span><LockKeyhole size={14} aria-hidden="true" />Windows will ask for your permission.</span><div>
        <Button type="button" size="md" onClick={() => setValues({ daily: String(retention.recommended.daily), weekly: String(retention.recommended.weekly), monthly: String(retention.recommended.monthly) })}>Use recommended</Button>
        <Button type="button" size="md" onClick={onClose}>Cancel</Button>
        <Button type="submit" size="md" variant="primary" disabled={!valid || blocked || pending('retentionConfigure')}>Save and show the list</Button>
      </div></>}>
      <div className="old-backups-counts">
        {KINDS.map(({ kind, label, help }) => {
          const id = `${titleId}-${kind}`, invalid = parsed[kind] === null;
          return <div key={kind} className="old-backups-count">
            <label htmlFor={id}>{label}</label>
            <input id={id} inputMode="numeric" value={values[kind]} maxLength={3} aria-invalid={invalid || undefined} aria-describedby={`${id}-help`}
              onChange={event => setValues(current => ({ ...current, [kind]: event.target.value.replace(/[^0-9]/g, '') }))} />
            <span id={`${id}-help`} className={invalid ? 'old-backups-error' : 'muted-copy'}>{invalid ? countError(kind, retention.limits) : help(values[kind])}</span>
          </div>;
        })}
      </div>
      <p className="old-backups-summary" role="status">{valid ? historySummary(parsed.daily!, parsed.weekly!, parsed.monthly!) : ''}</p>
      <ul className="old-backups-notes">
        <li>Days, weeks and months count only when a backup was made, so nothing extra is removed while your PC is off.</li>
        <li>Backups made before your current backup plan, and backups from other computers, are never removed.</li>
        <li>Removing backups frees only the space of files that changed or were deleted since; anything that is also in a backup that stays can still be restored.</li>
      </ul>
      {blocked && <p className="old-backups-error" role="alert">{retention.canConfigure.help}</p>}
    </DialogFrame></form>}
  </dialog>;
}

/** Turning clean-up off: removes nothing, and keeps the counts for next time. */
export function RetentionTurnOffDialog({ open, send, onClose }: { open: boolean; send: Send; onClose: () => void }) {
  const titleId = useId();
  const pending = usePendingCommand();
  const modal = useModal(open, onClose);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (pending('retentionConfigure')) return;
    send('retentionConfigure', { enabled: '0' }, ok => { if (ok) onClose(); });
  };
  return <dialog ref={modal.ref} className="old-backups-dialog old-backups-small app-dialog" aria-labelledby={titleId} onCancel={modal.onCancel}>
    {open && <form onSubmit={submit}><DialogFrame titleId={titleId} title="Turn off clean-up?" onClose={onClose} closeLabel="Cancel"
      lead="Rewindle will keep every new backup from now on. Nothing is removed, and your settings are kept for next time."
      footer={<><span><LockKeyhole size={14} aria-hidden="true" />Windows will ask for your permission.</span><div>
        <Button type="button" size="md" onClick={onClose}>Cancel</Button>
        <Button type="submit" size="md" variant="primary" disabled={pending('retentionConfigure')}>Turn off</Button>
      </div></>} /></form>}
  </dialog>;
}

/**
 * The list of old backups the host captured: what goes, grouped by month, and what stays, with why. Remove sends the count the
 * person saw and their two confirmations; the host binds the removal to the exact list it captured, and refuses it if the list
 * on disk has changed since.
 */
export function RetentionReviewDialog({ retention, send, locale }: { retention: RetentionState; send: Send; locale?: string }) {
  const review = retention.review;
  const titleId = useId();
  const pending = usePendingCommand();
  const running = !!review?.running || (retention.operation.active && retention.operation.action === 'apply');
  const close = () => { if (!running) send('retentionCloseReview'); };
  const modal = useModal(!!review, close);
  const [listChecked, setListChecked] = useState(false);
  const [filesChecked, setFilesChecked] = useState(false);
  const captureKey = review?.captureKey ?? '';
  useEffect(() => { setListChecked(false); setFilesChecked(false); }, [captureKey]);
  if (!review) return <dialog ref={modal.ref} className="old-backups-dialog app-dialog" aria-labelledby={titleId} onCancel={modal.onCancel} />;

  const screen = resultScreen(review);
  const showList = !screen || review.result?.status === 'preview_changed' || review.result?.status === 'declined';
  const count = review.removeCount;
  const title = review.pruneOnly ? 'Finish freeing space?' : `Remove ${count.toLocaleString('en-US')} old ${count === 1 ? 'backup' : 'backups'}?`;
  const ready = listChecked && (!review.needsFilesConfirmed || filesChecked) && !review.changed && !running && !pending('retentionApply');
  const remove = (event: FormEvent) => {
    event.preventDefault();
    if (!ready) return;
    send('retentionApply', { removeCount: String(count), confirmList: true, confirmEarlierChanges: filesChecked });
  };
  const page = review.page;
  const newestKept = formatDay(review.newestKeptAt, locale);
  const groups = page.list === 'remove' ? groupByMonth(page.rows, locale) : [];
  const monthTotals = new Map(review.months.map(month => [month.month, month.count]));
  const turnPage = (list: 'remove' | 'keep', offset: number) => send('retentionReviewPage', { list, offset: String(offset) });

  return <dialog ref={modal.ref} className="old-backups-dialog old-backups-review app-dialog" aria-labelledby={titleId} onCancel={modal.onCancel}>
    <form onSubmit={remove}><DialogFrame titleId={titleId} title={screen && !showList ? screen.title : title} onClose={close} closeLabel="Close the list of old backups" closeDisabled={running}
      lead={screen && !showList ? undefined : review.pruneOnly
        ? 'The backups removed last time still take up space. Rewindle frees it and checks your remaining backups. Nothing else is removed.'
        : 'These backups are removed from your backup location. A file is only lost if it exists solely in these backups: anything that is also in a backup that stays can still be restored.'}
      footer={screen && !showList ? <><span /><div><Button type="button" size="md" variant="primary" onClick={close}>{review.result?.status === 'removed' || review.result?.status === 'nothing_to_remove' ? 'Done' : 'Close'}</Button></div></>
        : <><span><LockKeyhole size={14} aria-hidden="true" />Windows will ask for your permission. A backup that’s due while old backups are being removed is skipped; you can back up again as soon as it finishes.</span><div>
          <Button type="button" size="md" onClick={close} disabled={running}>Cancel</Button>
          <Button type="submit" size="md" variant="primary" className="old-backups-danger" disabled={!ready}>{running ? 'Removing…' : review.pruneOnly ? 'Free the space' : `Remove ${count.toLocaleString('en-US')} ${count === 1 ? 'backup' : 'backups'}`}</Button>
        </div></>}>
      <div role="status" aria-live="polite">
        {screen && <p className={`source-notice old-backups-result ${screen.tone}`}>{!showList && <strong>{screen.title}. </strong>}{screen.text}</p>}
        {review.changed && <div className="old-backups-changed"><CircleAlert size={14} aria-hidden="true" /><span>This list was updated. Nothing was removed.</span>
          <Button type="button" size="sm" onClick={() => send('retentionOpenReview')}>Show the new list</Button></div>}
        {running && <p className="muted-copy">Removing old backups… This window updates when it finishes.</p>}
      </div>
      {showList && <>
        {!review.pruneOnly && <p className="old-backups-overview">{count.toLocaleString('en-US')} to remove · {review.keepCount.toLocaleString('en-US')} stay{newestKept ? ` · your newest backup, from ${newestKept}, stays` : ''}</p>}
        {review.needsFilesConfirmed && <section className="old-backups-check" aria-label="Check your files first">
          <h3>Check your files first</h3>
          <p>{filesCheckSentence(review.earlierChanges, review.earlierChangesUnknown, 'list', locale)}</p>
          <label className="old-backups-tick"><input type="checkbox" checked={filesChecked} disabled={running} onChange={event => setFilesChecked(event.target.checked)} />I’ve checked my files and they look right.</label>
        </section>}
        {!review.pruneOnly && <div className="old-backups-tabs" role="group" aria-label="Which list to show">
          <Button type="button" size="sm" variant={page.list === 'remove' ? 'primary' : 'secondary'} aria-pressed={page.list === 'remove'} onClick={() => turnPage('remove', 0)}>To remove ({count.toLocaleString('en-US')})</Button>
          <Button type="button" size="sm" variant={page.list === 'keep' ? 'primary' : 'secondary'} aria-pressed={page.list === 'keep'} onClick={() => turnPage('keep', 0)}>Staying ({review.keepCount.toLocaleString('en-US')})</Button>
        </div>}
        {page.list === 'remove' ? <div className="old-backups-list">
          {groups.map(group => <details key={group.key} open={groups.length <= 3}>
            <summary>{group.label} · {(monthTotals.get(group.key) ?? group.items.length).toLocaleString('en-US')} {(monthTotals.get(group.key) ?? group.items.length) === 1 ? 'backup' : 'backups'}</summary>
            <ul>{group.items.map(row => <li key={row.key}>{formatMoment(row.when, locale)}{row.files != null ? ` · ${row.files.toLocaleString('en-US')} files` : ''}</li>)}</ul>
          </details>)}
          {review.months.length > groups.length && <p className="muted-copy">Months on this list: {review.months.map(month => `${monthLabel(month.month, locale)} (${month.count})`).join(', ')}.</p>}
        </div> : <ul className="old-backups-list old-backups-staying">
          {page.rows.map(row => <li key={row.key} aria-label={`${formatMoment(row.when, locale)}. ${reasonsLabel(row.reasons)}.`}>
            <span aria-hidden="true">{formatMoment(row.when, locale)}{row.files != null ? ` · ${row.files.toLocaleString('en-US')} files` : ''}</span>
            <span className="old-backups-tags" aria-hidden="true">{row.reasons.map(reason => reasonTag(reason)).filter(Boolean).map(tag => <span key={tag}>{tag}</span>)}</span>
          </li>)}
        </ul>}
        {page.total > page.size && <div className="old-backups-pager">
          <span className="muted-copy">Showing {(page.offset + 1).toLocaleString('en-US')}–{Math.min(page.total, page.offset + page.size).toLocaleString('en-US')} of {page.total.toLocaleString('en-US')}</span>
          <Button type="button" size="sm" disabled={page.offset === 0} onClick={() => turnPage(page.list, Math.max(0, page.offset - page.size))}>Previous</Button>
          <Button type="button" size="sm" disabled={page.offset + page.size >= page.total} onClick={() => turnPage(page.list, page.offset + page.size)}>Show more</Button>
        </div>}
        <label className="old-backups-tick old-backups-confirm"><input type="checkbox" checked={listChecked} disabled={running || review.changed} onChange={event => setListChecked(event.target.checked)} />
          {review.pruneOnly ? 'I’ve read this. Free the space now.' : `I’ve looked at this list. Remove these ${count.toLocaleString('en-US')} ${count === 1 ? 'backup' : 'backups'}.`}</label>
      </>}
    </DialogFrame></form>
  </dialog>;
}
