import { CalendarClock, FlaskConical, HardDrive, History, Info, ShieldCheck } from 'lucide-react';
import { Callout } from '../ui';
import type { Wizard } from '../useWizard';
import { IssueList } from '../ui';
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
          <p>Rewindle installs alongside it and doesn’t change it. Each keeps its own backups, schedule and recovery key, so this PC will run both backups.</p>
          <p>The Rewindle app shows Rewindle’s backups. Keep the personal edition’s backups and recovery key until you no longer need its history.</p>
        </Callout>
      )}

      <IssueList errors={environment.errors} warnings={environment.warnings} />

      <p className="fine-print">
        <HardDrive size={14} aria-hidden="true" />
        <span>
          Free and open source under the MIT license.{' '}
          <button type="button" className="text-link" onClick={() => wizard.openLink('readme')}>Read the README</button>
          {' · '}
          <button type="button" className="text-link" onClick={() => wizard.openLink('license')}>License</button>
        </span>
      </p>
    </div>
  );
}
