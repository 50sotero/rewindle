import { useEffect, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { ArrowRight, Check, CircleAlert, Folder, FolderOpen, FolderPlus, Image, Laptop, LockKeyhole, Music2, Video, X } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import LoadingState from '@/components/primitives/LoadingState';
import type { Availability, CommandName, Notice, SourcePickerState } from '@/src/native-types';

type Send = (command: CommandName, payload?: Record<string, string | boolean>) => void;
const shortcutIcon = (name: string) => /picture/i.test(name) ? Image : /music/i.test(name) ? Music2 : /video/i.test(name) ? Video : /desktop/i.test(name) ? Laptop : Folder;
// What the review says while protected controls are off, by the reason they are off.
const UNAVAILABLE: Record<Exclude<Availability, 'ok'>, { title: string; text: string }> = {
  offline: { title: 'Connection interrupted', text: 'Reconnect to the desktop app before changing protected folders.' },
  dataError: { title: 'Backup status unavailable', text: 'Backup status cannot be read right now, so protected folders cannot be changed. Try again once it can be read.' },
  preview: { title: 'Animation preview is running', text: 'Stop the animation preview first. Protected folders cannot be changed while it runs.' },
};

export default function FolderPickerModal({ picker, send, reducedMotion, availability, notice, dismissNotice }: {
  picker: SourcePickerState | null; send: Send; reducedMotion: boolean; availability: Availability;
  notice: Notice | null; dismissNotice: () => void;
}) {
  const connected = availability === 'ok';
  const unavailable = availability === 'ok' ? null : UNAVAILABLE[availability];
  const dialog = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const [draft, setDraft] = useState('');
  const [closing, setClosing] = useState(false);
  const [visible, setVisible] = useState<SourcePickerState | null>(null);
  const previousStatus = useRef(picker?.status);
  const current = picker?.open ? picker : visible;
  const busy = current?.status === 'busy';
  const checking = current?.status === 'checking';
  const success = current?.status === 'succeeded';
  const ready = !!picker?.open && !closing && current?.status === 'ready' && draft.trim() === current.path && connected;
  const changed = draft.trim() !== (current?.path ?? '');
  const failed = current?.status === 'invalid' || current?.status === 'failed';

  useEffect(() => {
    if (picker?.open) {
      setVisible(picker);
      setClosing(false);
      if (!dialog.current?.open) {
        returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
        setDraft(picker.path);
        dismissNotice();
        dialog.current?.showModal();
        input.current?.focus({ preventScroll: true });
      }
    } else if (dialog.current?.open) {
      setClosing(true);
      const timer = window.setTimeout(() => {
        dialog.current?.close();
        setVisible(null);
        if (returnFocus.current?.isConnected) returnFocus.current.focus({ preventScroll: true });
      }, reducedMotion ? 0 : 160);
      return () => window.clearTimeout(timer);
    }
  }, [picker, reducedMotion, dismissNotice]);

  useEffect(() => { if (picker?.open && picker.status !== 'checking') setDraft(picker.path); }, [picker?.path, picker?.open, picker?.status]);
  useEffect(() => {
    if (previousStatus.current === 'succeeded' && picker?.status === 'idle') input.current?.focus({ preventScroll: true });
    if (previousStatus.current === 'checking' && picker?.open && picker.status !== 'checking' && picker.status !== 'busy') input.current?.focus({ preventScroll: true });
    previousStatus.current = picker?.status;
  }, [picker?.status]);
  useEffect(() => () => { dialog.current?.close(); }, []);
  // The button that was pressed (Add folder) was disabled while the request ran and then became "Add another folder", which would
  // start another protected request, so focus goes to Done: the way out, and where the person was headed.
  useEffect(() => {
    if (success) dialog.current?.querySelector<HTMLElement>('[data-done]')?.focus({ preventScroll: true });
  }, [success]);

  const close = () => {
    if (busy) return;
    // A refused command leaves its reason in the notice, which would otherwise outlive the dialog and show again on the page behind it.
    // A refusal of the close itself arrives afterwards, and is shown.
    dismissNotice();
    send('closeSourcePicker');
  };
  const check = (path: string) => {
    dismissNotice();
    setDraft(path.trim());
    send('validateSourcePath', { path: path.trim() });
  };

  return <dialog ref={dialog} className={`folder-picker-dialog app-dialog ${closing ? 'is-closing' : ''}`} aria-labelledby="folder-picker-title" aria-describedby="folder-picker-description"
    onCancel={event => { event.preventDefault(); close(); }}>
    {current && <motion.div className="folder-picker-panel" initial={{ opacity: 0, y: reducedMotion ? 0 : 16, scale: reducedMotion ? 1 : .975 }}
      animate={{ opacity: closing ? 0 : 1, y: closing && !reducedMotion ? 10 : 0, scale: closing && !reducedMotion ? .985 : 1 }} transition={{ duration: reducedMotion ? 0 : .2, ease: [.16, 1, .3, 1] }}>
      <header className="folder-picker-heading"><span className="folder-picker-emblem"><FolderPlus size={23} /></span>
        <div><span className="eyebrow">Your backup scope</span><h2 id="folder-picker-title">Add a protected folder</h2><p id="folder-picker-description">Choose a location. Its files and subfolders will be included in future backups.</p></div>
        <Button size="icon" variant="quiet" disabled={busy} onClick={close} aria-label="Close folder chooser"><X size={18} /></Button>
      </header>
      {/* In the panel from the moment the dialog opens and empty until a folder is added, so the confirmation put into it is announced:
          a live region that is created together with its text often is not, and the success view below, which replaces the form, is
          created with its. It is not a live region itself, or the confirmation would be spoken twice. */}
      <span className="sr-only" role="status" aria-atomic="true">{success ? `Folder added. ${current.name}. ${current.message || 'Included in your next backup. No backup has been started.'}` : ''}</span>

      <div className="folder-picker-body">
        {success ? <motion.div className="folder-picker-success" initial={{ opacity: 0, scale: reducedMotion ? 1 : .94 }} animate={{ opacity: 1, scale: 1 }}>
          <span className="folder-picker-success-icon"><Check size={28} /></span><h3>Folder added</h3><strong>{current.name}</strong><p className="folder-full-path">{current.path}</p><p>{current.message || 'Included in your next backup. No backup has been started.'}</p>
        </motion.div> : <>
          <div className="folder-picker-section-label"><h3>Quick locations</h3><span>Already included locations are marked</span></div>
          <div className="folder-shortcuts">{current.suggestions.map((suggestion, i) => {
            const Icon = shortcutIcon(suggestion.name);
            const selected = suggestion.path === draft.trim();
            return <motion.button key={suggestion.path} type="button" className={`folder-shortcut ${selected ? 'is-selected' : ''}`} disabled={busy || checking || !connected || suggestion.protected}
              aria-label={`${suggestion.name}${suggestion.protected ? ', already included' : ''}`} aria-pressed={selected} title={suggestion.path}
              onClick={() => check(suggestion.path)} initial={{ opacity: 0, y: reducedMotion ? 0 : 6 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: reducedMotion ? 0 : .2, delay: reducedMotion ? 0 : Math.min(i * .025, .15) }}>
              <Icon size={18} /><span><strong>{suggestion.name}</strong><small>{suggestion.protected ? 'Already included' : 'Choose location'}</small></span>{suggestion.protected ? <Check size={14} /> : <ArrowRight size={14} />}
            </motion.button>;
          })}</div>
          <div className="folder-picker-divider"><span>Or choose any folder</span></div>
          <label className="folder-path-label" htmlFor="folder-picker-path">Folder path</label>
          <form onSubmit={event => { event.preventDefault(); if (draft.trim() && !busy && !checking && connected) check(draft); }}>
            <div className="folder-path-entry"><FolderOpen size={17} /><input ref={input} id="folder-picker-path" value={draft} onChange={event => setDraft(event.target.value)}
              placeholder={'C:\\Users\\you\\Documents'} spellCheck={false} autoComplete="off" maxLength={4096} disabled={busy || checking || !connected} aria-describedby="folder-picker-path-help"
              aria-invalid={failed && !changed ? true : undefined} />
              {draft && <button type="button" aria-label="Clear folder path" disabled={busy || checking} onClick={() => { setDraft(''); input.current?.focus(); }}><X size={14} /></button>}
            </div>
            <div className="folder-path-actions"><span id="folder-picker-path-help">Paste a full path, or browse this computer.</span><div>
              <Button type="button" size="sm" disabled={busy || checking || !connected} onClick={() => { dismissNotice(); send('browseSourcePicker'); }}><FolderOpen size={14} />Browse…</Button>
              <Button type="submit" size="sm" disabled={!draft.trim() || busy || checking || !connected}><Check size={14} />Check folder</Button>
            </div></div>
          </form>

          {/* The region is in the dialog for as long as it is open, and what it says is swapped inside it: a live region that is created together
              with its text is often not announced, and this one used to be created anew with every result. A result that is a problem is
              spoken at once, as an alert would be; the loader inside it leaves the speaking to it. */}
          <div role="status" aria-live={!changed && failed ? 'assertive' : 'polite'} aria-atomic="true">
          <AnimatePresence mode="wait" initial={false}><motion.div key={unavailable ? availability : changed ? 'unconfirmed' : current.status} className={`folder-selection-review ${!changed && failed ? 'is-error' : ready ? 'is-ready' : ''}`}
            initial={{ opacity: 0, y: reducedMotion ? 0 : 5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} transition={{ duration: reducedMotion ? 0 : .14 }}>
            {busy || checking ? <LoadingState label={current.message || (busy ? 'Waiting for Windows approval…' : 'Checking folder…')} variant="Orbit" live={false} /> : <>
              <span className="folder-review-icon">{!changed && (ready || current.status === 'duplicate' || current.status === 'covered') ? <Check size={18} /> : (!changed && failed) || !connected ? <CircleAlert size={18} /> : <Folder size={18} />}</span>
              <div><strong>{unavailable ? unavailable.title : changed ? 'Check this folder to continue' : ready ? 'Ready to add' : current.status === 'duplicate' || current.status === 'covered' ? 'Already included in your backup' : current.status === 'cancelled' ? 'Approval cancelled' : failed ? 'Choose another location' : 'Choose a folder to begin'}</strong>
                <p>{unavailable ? unavailable.text : changed ? 'Rewindle will check the location and your existing backup scope.' : current.message || 'Nothing changes until you choose Add folder and approve the request.'}</p>
                {ready && <span className="folder-full-path">{current.path}</span>}
                {connected && !changed && ['failed', 'cancelled'].includes(current.status) && <Button size="sm" className="folder-review-retry" onClick={() => check(draft)}><ArrowRight size={13} />Review again</Button>}
              </div>
            </>}
          </motion.div></AnimatePresence></div>
        </>}
        {/* Always there, so the error put into it is announced; it stays until it is dismissed. It is drawn with the success view too: an
            error that comes from there (Add another folder, Done) would otherwise wait unseen behind the dialog, which keeps the page's
            own notice away, and show up on the page once the dialog had closed. */}
        <div role="alert">{notice?.error && <div className="folder-picker-error">{notice.text}<button onClick={dismissNotice} aria-label="Dismiss folder error"><X size={14} /></button></div>}</div>
      </div>
      <footer className="folder-picker-footer"><span><LockKeyhole size={14} />{success ? 'No backup was started.' : 'Windows approval is required to save.'}</span><div>
        <Button size="md" onClick={close} disabled={busy} data-done={success ? '' : undefined}>{success ? 'Done' : 'Cancel'}</Button>
        {success ? <Button size="md" variant="primary" disabled={!connected} onClick={() => { dismissNotice(); send('addSource'); }}><FolderPlus size={15} />Add another folder</Button>
          : <Button size="md" variant="primary" disabled={!ready || busy || checking} onClick={() => { dismissNotice(); send('confirmSourcePicker', { path: current.path }); }}><FolderPlus size={15} />{busy ? 'Adding folder…' : 'Add folder'}</Button>}
      </div></footer>
    </motion.div>}
  </dialog>;
}
