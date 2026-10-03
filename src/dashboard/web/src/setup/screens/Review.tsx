import { CalendarClock, Cloud, FolderCheck, HardDrive, Pencil, PlayCircle } from 'lucide-react';
import type { ReactNode } from 'react';
import { Button } from '@/components/atoms/Button';
import { issuesFor } from '../contract';
import { driveLetter, folderName, formatBytes, formatTime, plural, samePath } from '../format';
import { Callout, IssueList, Spinner, Switch } from '../ui';
import { selectedPaths, selectedTotal, type Screen, type Wizard } from '../useWizard';
import { driveName } from './Location';

function Row({ icon, title, edit, onEdit, children }: { icon: ReactNode; title: string; edit: string; onEdit: () => void; children: ReactNode }) {
  return (
    <div className="review-row">
      <span className="review-icon">{icon}</span>
      <div className="review-body">
        <h2 className="review-title">{title}</h2>
        <div className="review-value">{children}</div>
      </div>
      <Button size="sm" variant="quiet" onClick={onEdit} aria-label={edit}><Pencil size={13} aria-hidden="true" />Edit</Button>
    </div>
  );
}

/** Step 4: every choice on one page, each with a way back to change it, and the one decision left: the first backup. */
export function Review({ wizard }: { wizard: Wizard }) {
  const choices = wizard.choices!;
  const environment = wizard.base!.environment;
  const locale = wizard.host?.locale;
  const plan = wizard.validation.plan;
  const total = selectedTotal(choices, wizard.sizes);
  const paths = selectedPaths(choices);
  const names = choices.folders.filter(folder => folder.selected && folder.exists).map(folder => folder.key ?? folderName(folder.path));
  const cloud = choices.storageMode === 'google_drivefs_stream';
  const volume = environment.volumes.find(item => samePath(item.root, choices.driveRoot));
  const go = (screen: Screen) => () => wizard.goTo(screen);
  const all = issuesFor(plan, 'environment', 'sources', 'repository', 'storage_mode', 'schedule');

  return (
    <div className="screen-stack">
      {wizard.notice && <Callout tone="error" title="Nothing was installed">{wizard.notice}</Callout>}
      <div className="review-card">
        <Row icon={<FolderCheck size={18} aria-hidden="true" />} title="What to protect" edit="Edit what to protect" onEdit={go('folders')}>
          <p className="review-main">
            {plural(paths.length, 'folder', 'folders')}
            <span className="review-dim"> · {total.measuring ? <><Spinner size={12} /> measuring</> : formatBytes(total.bytes, locale)}</span>
          </p>
          <ul className="chip-list" aria-label="Folders">
            {names.map((name, index) => <li key={`${name}${index}`} className="chip">{name}</li>)}
          </ul>
        </Row>
        <Row icon={cloud ? <Cloud size={18} aria-hidden="true" /> : <HardDrive size={18} aria-hidden="true" />} title="Backup location" edit="Edit the backup location" onEdit={go('location')}>
          <p className="review-main review-path">{choices.repository}</p>
          <p className="review-dim">
            {cloud ? 'Google Drive, uploaded by Google Drive for desktop'
              : volume ? `${driveName(volume)} · ${formatBytes(volume.freeBytes, locale)} free` : driveLetter(choices.driveRoot)}
          </p>
        </Row>
        <Row icon={<CalendarClock size={18} aria-hidden="true" />} title="Schedule" edit="Edit the schedule" onEdit={go('schedule')}>
          <p className="review-main">Every day at {formatTime(choices.schedule, locale)}</p>
          <p className="review-dim">{choices.vss ? 'Includes files that are open' : 'Files that are open may be skipped'}</p>
        </Row>
      </div>

      <div className="review-card">
        <div className="review-row is-toggle">
          <span className="review-icon"><PlayCircle size={18} aria-hidden="true" /></span>
          <div className="review-body">
            <Switch checked={choices.startBackup} onChange={value => wizard.actions.setStartBackup(value)}
              label="Run my first backup right after setup"
              description={choices.startBackup
                ? 'The first one copies everything, so it can take a while. It runs in the background while you use your PC.'
                : `The first backup will run at ${formatTime(choices.schedule, locale)}, or you can start it from Rewindle.`} />
          </div>
        </div>
      </div>

      <IssueList errors={all.errors} warnings={all.warnings} />
      {wizard.validation.error && <Callout tone="warning" title="Setup couldn’t check your choices">{wizard.validation.error} They will be checked again when you choose Install.</Callout>}
    </div>
  );
}
