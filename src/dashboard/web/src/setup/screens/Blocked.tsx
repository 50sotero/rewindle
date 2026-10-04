import { ExternalLink, Trash2, WifiOff } from 'lucide-react';
import { issuesFor, type RemovedParts } from '../contract';
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

// The sentence about what an uninstall removed, from the parts it reports (older results without them get the full list).
function removedSentence(removed: RemovedParts | null | undefined): string {
  if (!removed) return 'The Rewindle app, its scheduled backups, the Start menu shortcut and the Installed apps entry were removed.';
  const parts = [
    removed.installRoot ? 'The Rewindle app' : null,
    removed.scheduledTasks.length > 0 ? 'its scheduled backups' : null,
    removed.startMenuShortcut ? 'the Start menu shortcut' : null,
    removed.installedAppsEntry ? 'the Installed apps entry' : null,
  ].filter((part): part is string => part !== null);
  const sentence = parts.length === 0 ? '' : `${parts.length === 1 ? parts[0] : `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`} ${parts.length === 1 ? 'was' : 'were'} removed.`;
  const lead = removed.installRoot ? '' : 'The Rewindle program files were already gone. ';
  return (lead + (sentence ? sentence.charAt(0).toUpperCase() + sentence.slice(1) : 'There was nothing else of Rewindle to remove.')).trim();
}

// Findings about entries the uninstaller kept because they weren't provably Rewindle's: a new setup refuses to run over them.
const KEPT_ENTRY_WARNINGS = ['shortcut_kept_unexpected_target', 'registration_kept_unexpected_owner'];

/** After a successful uninstall. */
export function Uninstalled({ wizard }: { wizard: Wizard }) {
  const result = wizard.operation?.result;
  const kept = result?.kept;
  const keptEntries = (result?.warnings ?? []).filter(warning => KEPT_ENTRY_WARNINGS.includes(warning.code));
  const places = kept ? [
    kept.repository ? { label: 'Your backups', path: kept.repository } : null,
    kept.recoveryKey ? { label: 'Your recovery key', path: kept.recoveryKey } : null,
    kept.recoveryTools ? { label: 'Recovery tools', path: kept.recoveryTools } : null,
  ].filter((place): place is { label: string; path: string } => place !== null) : [];
  return (
    <div className="screen-stack">
      <div className="blocked-emblem is-neutral"><Trash2 size={26} aria-hidden="true" /></div>
      <ul className="done-facts">
        <li><span>{removedSentence(result?.removed)}</span></li>
        <li><span><strong>Your backups and recovery key were kept.</strong> Keep the recovery key: you need it to restore anything from those backups.</span></li>
        {places.length > 0 && (
          <li><span>{places.map(place => <span key={place.label} className="kept-place"><span>{place.label}</span><span className="inline-path">{place.path}</span></span>)}</span></li>
        )}
        {keptEntries.length > 0 && (
          <li><span>
            {keptEntries.map(warning => <span key={warning.code} className="kept-place"><span>{warning.message}</span></span>)}
            Setup won’t install Rewindle again while {keptEntries.length === 1 ? 'it is' : 'they are'} there. Check {keptEntries.length === 1 ? 'it' : 'them'} and remove {keptEntries.length === 1 ? 'it' : 'them'} yourself if {keptEntries.length === 1 ? 'it isn’t' : 'they aren’t'} needed.
          </span></li>
        )}
        <li><span>To protect this PC again, run Rewindle Setup again. <button type="button" className="text-link" onClick={() => wizard.openLink('readme')}>Read the README</button></span></li>
      </ul>
    </div>
  );
}
