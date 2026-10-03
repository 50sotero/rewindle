import { useId } from 'react';
import { motion } from 'motion/react';
import { Check, CircleAlert, CircleCheck, Folder, FolderPlus, Info, LockKeyhole, Search, TriangleAlert, X } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { ValuePill } from '@/components/atoms/ValuePill';
import LoadingState from '@/components/primitives/LoadingState';
import type { CommandName, DashboardState } from '@/src/native-types';

export type FolderView = { query: string; unavailable: boolean };
type Send = (command: CommandName, payload?: Record<string, string | boolean>) => void;

const noticeIcons = { info: Info, success: CircleCheck, warning: TriangleAlert, error: CircleAlert };

// A handful of folders is read at a glance. Past this many the list gets a search box and the Unavailable filter.
const TOOLBAR_FROM_FOLDERS = 8;

// `lockReason` is the page-level sentence that already explains why changes are paused (a running
// backup, a repair, the sample data). When it is set, the folder controls keep their own reason for
// assistive technology and as a tooltip instead of repeating it on screen.
export default function ProtectedFolders({ state, send, view, setView, lockReason = '' }: {
  state: DashboardState; send: Send; view: FolderView; setView: (value: FolderView) => void; lockReason?: string;
}) {
  const noteId = useId();
  // The list is empty because the configuration could not be read, not because nothing is protected.
  const unreadable = !state.sources.length && !!state.setup?.problem;
  const missing = state.sources.filter(source => !source.exists);
  const unavailable = missing.length;
  const filtered = !!view.query.trim() || view.unavailable;
  // The toolbar is for a long list. A filter that is already on keeps it, so the filter can be turned off again, and a short list's
  // missing folders are called out by the note below, which also turns the Unavailable filter on.
  const showToolbar = state.sources.length > TOOLBAR_FROM_FOLDERS || filtered;
  // The folder that holds the restore test file is required, so it is the one folder that cannot be taken out of the backup as the way to stop the warning.
  const removable = missing.every(source => !source.isCanary);
  const one = unavailable === 1;
  const sources = state.sources.filter(source => (!view.unavailable || !source.exists) && `${source.name} ${source.path}`.toLowerCase().includes(view.query.trim().toLowerCase()));
  const operation = state.sourceOperation;
  const notice = state.sourceNotice ?? null;
  const NoticeIcon = notice ? noticeIcons[notice.tone] ?? Info : Info;
  // The inline operation card belongs to adding a folder. A removal has no stage of its own: it only
  // marks the operation active while Windows approval and the change are pending.
  const stagedOperation = !['Idle', 'Succeeded'].includes(operation.stage);
  const waitingOnRemoval = operation.active && !stagedOperation;
  const addEnabled = !!state.actions.addSource?.enabled;
  // The host's own reason first, then the page-level sentence, then a plain fallback.
  const lockText = addEnabled ? '' : state.actions.addSource?.help || lockReason
    || (operation.active ? 'Another folder change is in progress.' : 'Folder changes are unavailable right now.');
  return <section className="protected-folders" aria-labelledby="protected-folders-title">
    <div className="section-toolbar"><div><h2 className="section-title" id="protected-folders-title">Protected folders <span className="count-badge">{state.sources.length} added</span></h2>
      <p className="muted-copy" style={{ margin: '5px 0 0' }}>Each location includes its files and subfolders. Add more at any time.</p></div>
      <span title={lockText || undefined}><Button size="md" disabled={!addEnabled} aria-describedby={lockText ? noteId : undefined} title={state.actions.addSource?.help} onClick={() => send('addSource')}><FolderPlus size={15} />Add folder</Button></span>
    </div>
    {lockText && <p id={noteId} className={lockReason ? 'sr-only' : 'muted-copy folder-lock-note'}>{lockText}</p>}
    {showToolbar && <div className="folder-toolbar"><label className="search-field"><Search size={14} /><input aria-label="Search protected folders" placeholder="Find a folder or path…" value={view.query} onChange={event => setView({ ...view, query: event.target.value })} />
      {view.query && <button aria-label="Clear folder search" onClick={() => setView({ ...view, query: '' })}><X size={13} /></button>}</label>
      <div className="folder-filter-tabs" role="group" aria-label="Folder availability">
        <button aria-pressed={!view.unavailable} onClick={() => setView({ ...view, unavailable: false })}>All folders <span>{state.sources.length}</span></button>
        <button aria-pressed={view.unavailable} onClick={() => setView({ ...view, unavailable: true })}><CircleAlert size={12} />Unavailable <span>{unavailable}</span></button>
      </div>
      {filtered && <Button size="xs" variant="quiet" onClick={() => setView({ query: '', unavailable: false })}><X size={12} />Clear filters</Button>}
      <span className="muted-copy" role="status">{filtered ? `${sources.length} matching ${sources.length === 1 ? 'folder' : 'folders'}` : `${sources.length} ${sources.length === 1 ? 'folder' : 'folders'} in your backup`}</span>
    </div>}
    {/* The container is always present, so a folder that goes missing while the page is open is announced. A folder that cannot be found
        cannot be backed up, which the hero would otherwise not say and a small pill in the list only whispers. */}
    <div role="status">{unavailable > 0 && <div className="attention-note missing-folders">
      <strong><TriangleAlert size={14} className="inline mr-2" aria-hidden="true" />{one ? `${missing[0].name || missing[0].path} cannot be found` : `${unavailable} protected folders cannot be found`}</strong>
      <p>Files in {one ? 'it' : 'them'} cannot be backed up until {one ? 'it is' : 'they are'} available again. {removable ? `Reconnect the drive, or remove ${one ? 'it' : 'them'} from future backups.` : 'Reconnect the drive.'}</p>
      {!view.unavailable && state.sources.length > 1 && <Button size="xs" onClick={() => setView({ ...view, unavailable: true })}>{one ? 'Show only this folder' : 'Show only these folders'}</Button>}
    </div>}</div>
    {state.sourceStatus && state.sourceStatus !== notice?.text && /missing|unavailable|cannot|failed/i.test(state.sourceStatus) && <p className="source-warning" role="alert">{state.sourceStatus}</p>}
    {!state.sourcePicker?.open && (stagedOperation || waitingOnRemoval) && <div className={operation.active ? 'operation-note' : 'attention-note'} role={operation.stage === 'Failed' ? 'alert' : 'status'}>
      <div>{operation.active ? <LoadingState label={(stagedOperation ? operation.message : notice?.text) || 'Updating protected folders'} variant="Orbit" /> : <><strong>{operation.stage === 'Cancelled' ? 'Folder change cancelled' : 'Folder change needs attention'}</strong><p>{operation.message}</p></>}
        {stagedOperation && operation.path && <p className="folder-full-path">{operation.path}</p>}</div>
      {stagedOperation && <div className="actions">{(['retrySourceChange', 'dismissSourceChange'] as const).map(command => state.actions[command]?.visible && <Button key={command} size="sm" disabled={!state.actions[command]?.enabled} onClick={() => send(command)}>{state.actions[command]?.label}</Button>)}</div>}
    </div>}
    {notice && !waitingOnRemoval && !state.sourcePicker?.open && <p className={`source-notice ${notice.tone}`} role={notice.tone === 'error' ? 'alert' : 'status'}><NoticeIcon size={14} aria-hidden="true" />{notice.text}</p>}
    {sources.length ? <div className="surface protected-folder-list" role="list" aria-label="Protected folder locations">{sources.map((source, i) => <motion.div role="listitem" className="protected-folder-row" key={source.path}
      initial={{ opacity: 0, y: state.reducedMotion ? 0 : 5 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: state.reducedMotion ? 0 : .2, delay: state.reducedMotion ? 0 : Math.min(i * .02, .16) }}>
      <span className={`protected-folder-icon ${!source.exists ? 'is-unavailable' : ''}`}>{source.isCanary ? <LockKeyhole size={18} /> : <Folder size={19} />}</span>
      <div className="protected-folder-copy"><strong>{source.name}</strong><span title={source.path}>{source.path}</span>{source.isCanary && <small>Includes the test file Rewindle restores after every backup to prove recovery works.</small>}</div>
      {/* Only exceptions get a pill. Every folder in this list is included, so saying so on each row was noise. */}
      {!source.exists ? <ValuePill tone="orange">Unavailable</ValuePill> : source.isCanary ? <ValuePill tone="accent">Required</ValuePill> : null}
      {source.isCanary ? <span className="folder-row-lock" title="This location contains the required restore test file"><LockKeyhole size={14} /></span>
        : <span title={source.canRemove ? undefined : lockText || undefined}><Button size="sm" variant="quiet" disabled={!source.canRemove} aria-describedby={!source.canRemove && lockText ? noteId : undefined}
          aria-label={`Remove ${source.name} from future backups`} title={source.canRemove ? 'Remove from future backups. Existing snapshots are retained.' : undefined} onClick={() => send('removeSource', { path: source.path })}><X size={14} /><span className="folder-remove-label">Remove</span></Button></span>}
    </motion.div>)}</div> : <div className="surface empty-state">
      {/* An empty list is only "no folders" when the configuration was read. When it could not be (setup.problem is set), the list is not
          presented as a plan with nothing in it; the host's reason is the note above, which is where a disabled control's reason goes. */}
      {state.sources.length > 0 && view.unavailable && !view.query.trim() ? <Check size={26} /> : unreadable ? <CircleAlert size={26} /> : <Folder size={26} />}<strong>{!state.sources.length ? (unreadable ? 'Protected folders unavailable' : 'No protected folders to show') : view.unavailable && !view.query.trim() ? 'All protected folders are available' : 'No matching folders'}</strong>
      <p>{!state.sources.length ? (unreadable ? 'Your folders appear here as soon as Rewindle can read the backup configuration.' : state.sourceStatus || 'Choose a folder to include in future backups.') : view.unavailable && !view.query.trim() ? 'The Unavailable filter is on. Switch to All folders to see your backup scope.' : 'Try another folder name or clear your filters.'}</p>
      {!state.sources.length ? <span title={lockText || undefined}><Button size="sm" disabled={!addEnabled} aria-describedby={lockText ? noteId : undefined} onClick={() => send('addSource')}><FolderPlus size={13} />Add folder</Button></span> : <Button size="sm" onClick={() => setView({ query: '', unavailable: false })}>Show all folders</Button>}
    </div>}
    <p className="folder-list-footnote"><LockKeyhole size={12} />Folder changes require Windows approval. Adding a location does not start a backup.</p>
  </section>;
}
