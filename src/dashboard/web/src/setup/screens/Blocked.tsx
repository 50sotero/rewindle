import { CircleSlash, ExternalLink, Trash2, WifiOff } from 'lucide-react';
import { issuesFor } from '../contract';
import { Callout, IssueList } from '../ui';
import type { Wizard } from '../useWizard';

/** This PC cannot run Rewindle. Says what is missing; there is nothing to choose, so the only way on is Close. */
export function Unsupported({ wizard }: { wizard: Wizard }) {
  const environment = wizard.base!.environment;
  const { errors, warnings } = issuesFor(wizard.validation.plan, 'environment');
  const reasons: string[] = [];
  if (!environment.os.supported) reasons.push(`Rewindle needs 64-bit Windows 10 or Windows 11. This PC runs ${environment.os.caption}${environment.os.build ? ` (build ${environment.os.build})` : ''}.`);
  if (!environment.os.x64) reasons.push('Rewindle needs a 64-bit version of Windows.');
  if (!environment.dotnetFramework48) reasons.push('Rewindle needs the Microsoft .NET Framework 4.8, which Windows Update can install.');
  // The installer's own sentences say it better when it sent them.
  const shown = errors.length > 0 ? [] : reasons;
  return (
    <div className="screen-stack">
      <div className="blocked-emblem"><CircleSlash size={28} aria-hidden="true" /></div>
      {shown.length > 0 && (
        <ul className="reason-list">
          {shown.map(reason => <li key={reason}>{reason}</li>)}
        </ul>
      )}
      <IssueList errors={errors} warnings={warnings} />
      <p className="fine-print">
        <ExternalLink size={14} aria-hidden="true" />
        <span>Nothing was changed. <button type="button" className="text-link" onClick={() => wizard.openLink('requirements')}>See what Rewindle needs</button></span>
      </p>
    </div>
  );
}

/** Setup could not even describe this PC (the installer's plan failed). */
export function HostError({ wizard }: { wizard: Wizard }) {
  return (
    <div className="screen-stack">
      <Callout tone="error" icon={<WifiOff size={18} aria-hidden="true" />} title="Setup couldn’t check this PC">
        <p className="failure-message">{wizard.hostError}</p>
        <p>Nothing was changed. Choose <strong>Try again</strong>. If it keeps happening, <button type="button" className="text-link" onClick={() => wizard.openLink('issues')}>report the problem</button>.</p>
      </Callout>
    </div>
  );
}

/** After a successful uninstall. */
export function Uninstalled({ wizard }: { wizard: Wizard }) {
  return (
    <div className="screen-stack">
      <div className="blocked-emblem is-neutral"><Trash2 size={26} aria-hidden="true" /></div>
      <ul className="done-facts">
        <li><span>The Rewindle app, its scheduled backups, the Start menu shortcut and the Installed apps entry were removed.</span></li>
        <li><span><strong>Your backups and recovery key were kept.</strong> Keep the recovery key: you need it to restore anything from those backups.</span></li>
        <li><span>To protect this PC again, run Rewindle Setup again. <button type="button" className="text-link" onClick={() => wizard.openLink('readme')}>Read the README</button></span></li>
      </ul>
    </div>
  );
}
