import { Check, Clapperboard, CloudOff, Download, FileText, Folder, FolderPlus, Image, Monitor, Music, Star, X } from 'lucide-react';
import { useId, type ComponentType } from 'react';
import { Button } from '@/components/atoms/Button';
import { issuesFor, type KnownFolderKey } from '../contract';
import { folderName, formatBytes, formatCount, plural, samePath } from '../format';
import { IssueList, Spinner } from '../ui';
import { selectedTotal, type FolderChoice, type FolderSize, type Wizard } from '../useWizard';

const ICONS: Record<KnownFolderKey, ComponentType<{ size?: number; 'aria-hidden'?: boolean }>> = {
  Desktop: Monitor, Documents: FileText, Pictures: Image, Music, Videos: Clapperboard, Downloads: Download, Favorites: Star,
};

/** A folder's size as it is measured: a spinner, then the total. `compact` leaves out the number of files (it goes in the tooltip). */
function SizeLine({ size, exists, locale, compact }: { size?: FolderSize; exists: boolean; locale?: string; compact?: boolean }) {
  if (!exists) return <span className="size-line is-muted">Not on this PC</span>;
  if (!size) return <span className="size-line is-muted"><Spinner size={12} /> Measuring…</span>;
  if (size.error) return <span className="size-line is-muted">{size.error}</span>;
  return (
    <span className="size-line" title={`${plural(size.files, 'file', 'files')}${size.done ? '' : ' so far'}`}>
      {!size.done && <Spinner size={12} />}
      <span>{formatBytes(size.bytes, locale)}</span>
      {!compact && <><span className="size-dot" aria-hidden="true">·</span><span>{plural(size.files, 'file', 'files')}{!size.done && '…'}</span></>}
    </span>
  );
}

function FolderCard({ folder, size, onToggle, locale }: { folder: FolderChoice; size?: FolderSize; onToggle: () => void; locale?: string }) {
  const Icon = folder.key ? ICONS[folder.key] : Folder;
  const name = folder.key ?? folderName(folder.path);
  const sizeId = useId();
  return (
    <button type="button" role="checkbox" aria-checked={folder.selected} disabled={!folder.exists}
      className="folder-card" data-selected={folder.selected} onClick={onToggle} title={folder.path}
      aria-label={name} aria-describedby={sizeId}>
      <span className="folder-card-icon"><Icon size={18} aria-hidden={true} /></span>
      <span className="folder-card-text">
        <strong>{name}</strong>
        <span id={sizeId}><SizeLine size={size} exists={folder.exists} locale={locale} compact /></span>
      </span>
      <span className="check-box" aria-hidden="true">{folder.selected && <Check size={13} strokeWidth={3} />}</span>
    </button>
  );
}

/** Step 1: the folders to protect. Windows' own folders are cards; anything else is a row that can be removed. */
export function Folders({ wizard }: { wizard: Wizard }) {
  const choices = wizard.choices!;
  const locale = wizard.host?.locale;
  const known = choices.folders.filter(folder => !folder.custom);
  const custom = choices.folders.filter(folder => folder.custom);
  const total = selectedTotal(choices, wizard.sizes);
  const { errors, warnings } = issuesFor(wizard.validation.plan, 'sources');
  const sizeOf = (folder: FolderChoice) => wizard.sizes[folder.path.toLowerCase()];
  const placeholders = choices.folders.filter(folder => folder.selected && (sizeOf(folder)?.placeholderFiles ?? 0) > 0);
  const denied = choices.folders.filter(folder => folder.selected && (sizeOf(folder)?.skippedFolders ?? 0) > 0);
  const selectedCount = choices.folders.filter(folder => folder.selected && folder.exists).length;

  return (
    <div className="screen-stack">
      <section aria-labelledby="known-heading">
        <h2 id="known-heading" className="section-label">Your folders</h2>
        <div className="folder-grid">
          {known.map(folder => (
            <FolderCard key={folder.path} folder={folder} size={sizeOf(folder)} locale={locale} onToggle={() => wizard.actions.toggleFolder(folder.path)} />
          ))}
        </div>
      </section>

      <section aria-labelledby="other-heading">
        <div className="section-row">
          <h2 id="other-heading" className="section-label">Other folders</h2>
          <Button size="sm" onClick={() => void wizard.actions.addFolder()}><FolderPlus size={14} aria-hidden="true" />Add a folder…</Button>
        </div>
        {custom.length === 0
          ? <p className="empty-line">Add any other folder you want to keep safe, like a projects folder or a photo archive on another drive.</p>
          : (
            <ul className="custom-list">
              {custom.map(folder => (
                <li key={folder.path} className="custom-row" data-selected={folder.selected}>
                  <button type="button" role="checkbox" aria-checked={folder.selected} className="custom-toggle"
                    onClick={() => wizard.actions.toggleFolder(folder.path)} aria-label={`Protect ${folderName(folder.path)}`}>
                    <span className="check-box" aria-hidden="true">{folder.selected && <Check size={13} strokeWidth={3} />}</span>
                  </button>
                  <Folder size={18} className="custom-icon" aria-hidden="true" />
                  <span className="custom-text">
                    <strong>{folderName(folder.path)}</strong>
                    <span className="custom-path" title={folder.path}>{folder.path}</span>
                  </span>
                  <SizeLine size={sizeOf(folder)} exists={folder.exists} locale={locale} />
                  <Button size="icon-sm" variant="quiet" aria-label={`Remove ${folderName(folder.path)}`} title="Remove" onClick={() => wizard.actions.removeFolder(folder.path)}>
                    <X size={14} aria-hidden="true" />
                  </Button>
                </li>
              ))}
            </ul>
          )}
      </section>

      {placeholders.length > 0 && (
        <p className="callout is-warning">
          <CloudOff size={16} aria-hidden="true" />
          <span>
            {placeholders.map(folder => folder.key ?? folderName(folder.path)).join(', ')} {placeholders.length === 1 ? 'has' : 'have'}{' '}
            {plural(placeholders.reduce((sum, folder) => sum + (sizeOf(folder)?.placeholderFiles ?? 0), 0), 'online-only file', 'online-only files')}.
            {' '}Rewindle can only back up files that are stored on this PC. In OneDrive, choose “Always keep on this device” for {placeholders.length === 1 ? 'that folder' : 'those folders'}.
          </span>
        </p>
      )}
      {denied.length > 0 && (
        <p className="callout is-info">
          <span className="callout-dot" aria-hidden="true" />
          <span>Some folders inside {denied.map(folder => folder.key ?? folderName(folder.path)).join(', ')} couldn’t be opened to measure them, so the size shown may be a little low.</span>
        </p>
      )}

      <IssueList errors={errors} warnings={warnings.filter(warning => !(placeholders.length > 0 && warning.code.includes('placeholder')))}
        action={issue => {
          // A finding about one folder comes with the way out: take that folder off the list (or, for a Windows folder, untick it).
          const folder = issue.path ? choices.folders.find(item => samePath(item.path, issue.path as string)) : undefined;
          if (!folder || !folder.selected && folder.exists) return null;
          const name = folder.key ?? folderName(folder.path);
          return folder.custom
            ? <Button size="sm" className="issue-action" onClick={() => wizard.actions.removeFolder(folder.path)}>Remove {name}</Button>
            : <Button size="sm" className="issue-action" onClick={() => wizard.actions.toggleFolder(folder.path)}>Don’t protect {name}</Button>;
        }} />

      <p className="sr-only" role="status" aria-live="polite">
        {total.measuring ? '' : `${plural(selectedCount, 'folder', 'folders')} selected, ${formatBytes(total.bytes, locale)}, ${formatCount(total.files, locale)} files.`}
      </p>
    </div>
  );
}
