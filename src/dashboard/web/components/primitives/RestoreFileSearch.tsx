import { useEffect, useRef, useState, type ReactNode } from 'react';
import { CircleAlert, File, Folder, Info, RotateCcw, Search } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { ValuePill } from '@/components/atoms/ValuePill';
import LoadingState from '@/components/primitives/LoadingState';
import type { CommandName, RestoreFileSearch as SearchState, RestoreSearchResult, RestoreSearchVersion } from '@/src/native-types';
import { usePendingCommand } from '@/src/pendingCommands';
import {
  FIND_TEXT,
  checkSearchText,
  continueLabel,
  fill,
  folderLine,
  missingLine,
  outcomeFrom,
  statusFrom,
  versionLabel,
  versionLines,
  type WhenText,
} from '@/src/fileSearch';

type Run = (command: CommandName, payload?: Record<string, string | boolean>) => void;
// A search keeps up to 100 results; this many are drawn at first, and each "Show more" adds as many.
const RESULT_CHUNK = 25;

// Find a file, the second tab of Restore's first step. The host does the search (in the flow's approved restore session) and keeps
// the results; this draws them and sends the commands. `text` lives in the dialog, so its date tab can offer "Find a file named …".
export default function RestoreFileSearch({ search, text, onTextChange, busy, connected, waitReason, approvalWaiting, approvalHint, run, whenText, onChooseByDate, id, labelledBy }: {
  search: SearchState;
  text: string;
  onTextChange: (text: string) => void;
  busy: boolean;
  connected: boolean;
  /** Why Find cannot be used yet from what the page knows (the list is still opening, or there are no backups), or empty. */
  waitReason: string;
  approvalWaiting: boolean;
  approvalHint: ReactNode;
  run: Run;
  whenText: WhenText;
  onChooseByDate: () => void;
  id: string;
  labelledBy: string;
}) {
  const pending = usePendingCommand();
  const status = statusFrom(search.status);
  const outcome = outcomeFrom(search.outcome);
  const searching = status === 'searching';
  const results = search.results ?? [];
  const [limit, setLimit] = useState(RESULT_CHUNK);
  // A problem with the text shows once Find was pressed, or at once for one that no further typing can fix.
  const [submitted, setSubmitted] = useState(false);
  const outcomeRef = useRef<HTMLDivElement>(null);
  const wasSearchingRef = useRef(searching);
  const check = checkSearchText(text);
  const problem = check.error && (submitted || check.error === 'FORBIDDEN' || check.error === 'CONTROL' || check.error === 'LONG') ? check.message : '';
  const blocked = search.blocked || '';
  const locked = busy || !connected;
  const canFind = !locked && !waitReason && !blocked && !pending('restoreFlowFindFiles');

  // Another search starts the list again from its first results.
  useEffect(() => { setLimit(RESULT_CHUNK); }, [search.text, search.resultsTotal === 0]);
  // When a search ends, focus goes to what it found, but only if it was lost: the controls it came from were off while it ran.
  useEffect(() => {
    const was = wasSearchingRef.current;
    wasSearchingRef.current = searching;
    if (!was || searching) return;
    const active = document.activeElement as HTMLElement | null;
    if (!active || active === document.body || !active.isConnected || (active as HTMLButtonElement).disabled === true || active.tagName === 'DIALOG') {
      outcomeRef.current?.focus({ preventScroll: true });
    }
  }, [searching]);

  const find = () => {
    setSubmitted(true);
    if (check.error || !canFind) return;
    setSubmitted(false);
    run('restoreFlowFindFiles', { text: check.normalized });
  };
  const goOn = () => { if (!locked && search.canContinue && !pending('restoreFlowFindMore')) run('restoreFlowFindMore'); };
  const again = () => { if (!locked && !blocked && search.text && !pending('restoreFlowFindFiles')) run('restoreFlowFindFiles', { text: search.text }); };
  const pick = (result: RestoreSearchResult, version: RestoreSearchVersion) => {
    if (!locked && !pending('restoreFlowPickFound')) run('restoreFlowPickFound', { snapshotId: version.snapshotId, path: result.path });
  };

  const shown = results.slice(0, limit);
  const hidden = results.length - shown.length;
  const done = status === 'done';
  const failed = status === 'failed';
  const count = search.resultsTotal ?? results.length;

  return <div className="restore-find-panel" role="tabpanel" id={id} aria-labelledby={labelledBy}>
    <div className="restore-find-intro"><div><h4>{FIND_TEXT.heading}</h4><p>{FIND_TEXT.intro}</p></div>{done && count > 0 && <ValuePill tone="accent">{fill(FIND_TEXT.found, { count: count.toLocaleString() })}</ValuePill>}</div>
    <form className="restore-find-form" noValidate role="search" onSubmit={event => { event.preventDefault(); find(); }}>
      <label className="restore-flow-search"><Search size={14} aria-hidden="true" /><span className="sr-only">{FIND_TEXT.fieldLabel}</span>
        <input value={text} onChange={event => onTextChange(event.target.value)} maxLength={400} placeholder={FIND_TEXT.placeholder} disabled={locked} spellCheck={false} autoComplete="off"
          aria-invalid={problem ? true : undefined} aria-describedby={problem ? `${id}-problem` : undefined}
          onKeyDown={event => { if (event.key === 'Escape' && text) { event.preventDefault(); event.stopPropagation(); onTextChange(''); setSubmitted(false); } }} /></label>
      <Button size="sm" variant="primary" type="submit" disabled={!canFind}><Search size={13} aria-hidden="true" />{FIND_TEXT.find}</Button>
    </form>
    {problem && <p className="restore-find-problem" id={`${id}-problem`} role="alert"><CircleAlert size={13} aria-hidden="true" />{problem}</p>}
    {!searching && (waitReason || blocked) && <div className="restore-flow-inline-warning is-above" role="status"><Info size={15} aria-hidden="true" />{waitReason || blocked}</div>}

    {searching && <div className="restore-flow-empty restore-find-searching"><LoadingState label={approvalWaiting ? FIND_TEXT.waiting : FIND_TEXT.searching} variant="Orbit" live={false} />{approvalWaiting ? approvalHint : <p>{FIND_TEXT.searchingLine}</p>}</div>}

    <div className="restore-find-outcome" ref={outcomeRef} tabIndex={-1}>
      {failed && <div className="restore-tree-error restore-find-failed" role="alert"><CircleAlert size={15} aria-hidden="true" /><span><strong>{FIND_TEXT.failedTitle}</strong> {search.error}</span>
        <Button size="xs" disabled={locked || !!blocked || !search.text} onClick={again}><RotateCcw size={12} aria-hidden="true" />{FIND_TEXT.tryAgain}</Button>
        {search.listChanged && <Button size="xs" disabled={locked} onClick={() => run('restoreFlowBrowseSnapshots')}>{FIND_TEXT.reload}</Button>}</div>}
      {done && <div className={`restore-find-summary is-${outcome || 'complete'}`}><p>{search.message}</p><div className="restore-find-summary-actions">
        {search.canContinue && <Button size="xs" variant="secondary" disabled={locked || !!blocked || pending('restoreFlowFindMore')} onClick={goOn}><RotateCcw size={12} aria-hidden="true" />{continueLabel(search)}</Button>}
        {(outcome === 'tooSlow' || outcome === 'tooBroad' || count === 0) && <Button size="xs" variant="quiet" disabled={busy} onClick={onChooseByDate}>{FIND_TEXT.chooseByDate}</Button>}
        <Button size="xs" variant="quiet" disabled={locked} onClick={() => run('restoreFlowFindClear')}>{FIND_TEXT.clear}</Button></div></div>}
    </div>

    {!searching && results.length > 0 && <ul className="restore-find-results" aria-label={FIND_TEXT.results}>
      {shown.map(result => {
        const folder = result.type === 'dir';
        const missing = missingLine(result, whenText);
        return <li key={result.key} className="restore-find-result">
          <div className="restore-find-name">{folder ? <Folder size={16} aria-hidden="true" /> : <File size={16} aria-hidden="true" />}<strong title={result.name}>{result.name}</strong>{folder && <ValuePill tone="neutral">{FIND_TEXT.folder}</ValuePill>}</div>
          <p className="restore-find-where" title={folderLine(result)}>{folderLine(result)}</p>
          {missing && <p className="restore-find-missing"><Info size={13} aria-hidden="true" />{missing}</p>}
          <ul className="restore-find-versions">
            {result.versions.map(version => {
              const [what, where] = versionLines(version, result, whenText);
              return <li key={`${version.snapshotId}|${version.size}|${version.modified}`} className="restore-find-version">
                <span className="restore-find-version-text"><strong>{what}</strong><small>{where}</small></span>
                {version.isLegacyUnbound && <span title={FIND_TEXT.olderSetupTitle}><ValuePill tone="orange">{FIND_TEXT.olderSetup}</ValuePill></span>}
                <Button size="xs" variant="secondary" aria-label={versionLabel(version, result, whenText)} disabled={locked || pending('restoreFlowPickFound')} onClick={() => pick(result, version)}>{FIND_TEXT.restoreThis}</Button>
              </li>;
            })}
          </ul>
          {result.hasMoreVersions && result.type !== 'dir' && <p className="restore-find-more-versions">{FIND_TEXT.moreVersions}</p>}
        </li>;
      })}
    </ul>}
    {!searching && hidden > 0 && <div className="restore-snapshot-more"><Button size="sm" onClick={() => setLimit(value => value + RESULT_CHUNK)}>{FIND_TEXT.showMore}<span> · {fill(FIND_TEXT.notShown, { count: hidden.toLocaleString() })}</span></Button></div>}
  </div>;
}
