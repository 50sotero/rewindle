import { CalendarClock, FlaskConical, HardDrive, History, Info, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { Callout, IssueList, Spinner } from '../ui';
import type { Wizard } from '../useWizard';
import { issuesFor } from '../contract';

/** The first screen: what Rewindle is, in three lines, and the honest notice that this is an early release. */
export function Welcome({ wizard }: { wizard: Wizard }) {
  const legacy = wizard.base?.environment.existingInstall.legacyPersonalEdition;
  const environment = issuesFor(wizard.validation.plan, 'environment');
  return (
    <div className="screen-stack">
      <ul className="welcome-points" aria-label="What Rewindle does">
        <li>
          <span className="point-icon"><CalendarClock size={18} aria-hidden="true" /></span>
          <span><strong>Backs up the folders you choose, every day.</strong> Encrypted, to a drive you pick, and only what changed.</span>
        </li>
        <li>
          <span className="point-icon"><ShieldCheck size={18} aria-hidden="true" /></span>
          <span><strong>Checks every backup.</strong> After each one, Rewindle restores a test file and compares it, so you know recovery works.</span>
        </li>
        <li>
          <span className="point-icon"><History size={18} aria-hidden="true" /></span>
          <span><strong>Brings files back from any saved day.</strong> A guided restore walks you through it.</span>
        </li>
      </ul>

      <Callout tone="warning" icon={<FlaskConical size={18} aria-hidden="true" />} title="Early test release">
        This is an alpha version of Rewindle. Keep another backup of anything important while you try it.
      </Callout>

      {legacy && (
        <Callout tone="info" icon={<Info size={18} aria-hidden="true" />} title="You also have the earlier personal edition">
          <p>Rewindle installs alongside it and doesn’t change it. It can’t take over the personal edition’s backups, so it starts its own in a new, empty backup location, with its own schedule and recovery key. This PC will run both.</p>
          <p>Keep the personal edition’s backups and recovery key for as long as you need their history.</p>
        </Callout>
      )}

      <IssueList errors={environment.errors} warnings={environment.warnings} />
      {environment.errors.length > 0 && (
        // These findings name what to remove; once it is gone, this asks the installer again without starting Setup over.
        <div className="callout-actions">
          <Button size="sm" disabled={wizard.refreshing || wizard.validation.checking} onClick={() => void wizard.actions.refreshDrives()}>
            {(wizard.refreshing || wizard.validation.checking) && <Spinner size={12} />}Check again
          </Button>
        </div>
      )}

      <p className="fine-print">
        <HardDrive size={14} aria-hidden="true" />
        <span>
          Free and open source under the MIT license.{' '}
          <button type="button" className="text-link" onClick={() => wizard.openLink('readme')}>How Rewindle works</button>
          {' · '}
          <button type="button" className="text-link" onClick={() => wizard.openLink('license')}>License</button>
        </span>
      </p>
    </div>
  );
}
