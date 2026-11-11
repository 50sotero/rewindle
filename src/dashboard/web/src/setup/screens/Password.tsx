import { Info, LockKeyhole, LockKeyholeOpen } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { Spinner } from '../ui';
import type { Wizard } from '../useWizard';

/**
 * What a backup without a password means, in the owner's words. It is always on the page next to the option it is about, whole, and
 * never behind a tooltip or a click: this is what a person must read before choosing that option.
 */
const EXPOSURE = 'Anyone who can open the backup folder can restore every backed-up file, including saved sign-ins. That includes the folder in Google Drive or on a lost USB drive.';

/**
 * Step 4: whether the new backups have a password. With a password (the default and the recommended way) Setup makes one and keeps it
 * safely; without one, anyone who can open the backup folder can restore every file. The choice is for backups that are being
 * started. A location that already holds backups keeps the kind they have (backups can't switch), and the page says so instead of
 * asking. The title and the lead above come from SetupApp's headerFor, from the same state.
 */
export function Password({ wizard }: { wizard: Wizard }) {
  const page = wizard.passwordPage;
  const pick = wizard.choices!.repositoryAccess;
  const goToLocation = (label: string) => (
    <div className="callout-actions">
      <Button size="sm" onClick={() => wizard.goTo('location')}>{label}</Button>
    </div>
  );

  if (page.kind === 'checking') {
    return (
      <div className="screen-stack">
        <p className="fit-line" role="status"><Spinner size={14} /><span>This takes a moment. Nothing is changed.</span></p>
      </div>
    );
  }

  if (page.kind === 'unavailable') {
    return <div className="screen-stack">{goToLocation('Go to Backup location')}</div>;
  }

  if (page.kind === 'kept') {
    return (
      <div className="screen-stack">
        {page.access === 'password' && (
          <p className="fit-line"><LockKeyhole size={16} aria-hidden="true" /><span>You’ll get a recovery key to keep at the end of Setup.</span></p>
        )}
        {page.access === 'no_password' && (
          <p className="fit-line is-tight"><LockKeyholeOpen size={16} aria-hidden="true" /><span>{EXPOSURE} There’s no recovery key to keep, and nothing to remember.</span></p>
        )}
        {goToLocation('Choose another location')}
      </div>
    );
  }

  return (
    <div className="screen-stack">
      <fieldset className="drive-group" aria-labelledby="screen-title">
        <label className="drive-card access-card" data-selected={pick === 'password'}>
          <input type="radio" name="backup-password" className="sr-only" checked={pick === 'password'}
            onChange={() => wizard.actions.setRepositoryAccess('password')} aria-describedby="access-password-detail" />
          <span className="drive-icon"><LockKeyhole size={20} aria-hidden="true" /></span>
          <span className="drive-main">
            <span className="drive-title"><strong>Yes, protect them with a password</strong><span className="badges"><span className="badge is-accent">Recommended</span></span></span>
            <span className="drive-meta" id="access-password-detail">
              Setup makes a strong password and keeps it safely on this PC, so you never have to type it. You’ll also get a recovery key: keep it somewhere safe, because it’s what lets you restore your files on another PC.
            </span>
          </span>
          <span className="radio-dot" aria-hidden="true" />
        </label>
        <label className="drive-card access-card" data-selected={pick === 'no_password'}>
          <input type="radio" name="backup-password" className="sr-only" checked={pick === 'no_password'}
            onChange={() => wizard.actions.setRepositoryAccess('no_password')} aria-describedby="access-none-detail" />
          <span className="drive-icon"><LockKeyholeOpen size={20} aria-hidden="true" /></span>
          <span className="drive-main">
            <span className="drive-title"><strong>No password</strong></span>
            <span className="drive-meta" id="access-none-detail">
              <span className="access-warning">{EXPOSURE}</span>
              <span className="access-line">There’s no recovery key to keep, and nothing to remember. If that worries you, choose a password above.</span>
            </span>
          </span>
          <span className="radio-dot" aria-hidden="true" />
        </label>
      </fieldset>
      <p className="fine-print">
        <Info size={14} aria-hidden="true" />
        <span>You can’t change this later for these backups. To choose differently, you’d start new backups in another place.</span>
      </p>
    </div>
  );
}
