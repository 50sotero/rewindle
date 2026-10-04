import { ArrowUpRight, Check, LayoutDashboard, RefreshCw, Trash2, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { Callout, ShieldIcon } from '../ui';
import type { Wizard } from '../useWizard';

/** When Rewindle is already installed: open it, set it up again, or remove it. */
export function Maintenance({ wizard, onReinstall, onUninstall, openDashboard }: {
  wizard: Wizard; onReinstall: () => void; onUninstall: () => void; openDashboard: () => void;
}) {
  const installed = wizard.base?.environment.existingInstall.rewindle;
  const setupVersion = wizard.host?.version ?? wizard.base?.environment.version ?? '';
  const legacy = wizard.base?.environment.existingInstall.legacyPersonalEdition;
  const same = installed?.version && setupVersion && installed.version === setupVersion;
  // Windows still lists Rewindle (or its shortcut or tasks remain) but the program folder is gone: the installer reports the
  // program folder as `already_installed` only when it exists. Uninstall clears such leftovers, so the choices below still work.
  const leftoversOnly = !!installed && !(wizard.base?.errors ?? []).some(issue => issue.code === 'already_installed');
  return (
    <div className="screen-stack">
      {leftoversOnly ? (
        <div className="installed-card">
          <span className="installed-emblem is-warning"><TriangleAlert size={20} aria-hidden="true" /></span>
          <div className="installed-text">
            <strong>Rewindle’s program files are missing</strong>
            <span>Windows still lists Rewindle, but its program files are gone. Uninstall removes what was left behind, so setup can run again.</span>
          </div>
        </div>
      ) : (
        <div className="installed-card">
          <span className="installed-emblem"><Check size={20} strokeWidth={3} aria-hidden="true" /></span>
          <div className="installed-text">
            <strong>Rewindle {installed?.version ?? ''} is installed</strong>
            <span>{installed?.installRoot ?? 'On this PC'}{same ? ' · the same version as this setup' : installed?.version && setupVersion ? ` · this setup has ${setupVersion}` : ''}</span>
          </div>
          <Button variant="primary" className="setup-button" onClick={openDashboard}><LayoutDashboard size={15} aria-hidden="true" />Open Rewindle<ArrowUpRight size={14} aria-hidden="true" /></Button>
        </div>
      )}

      <div className="choice-list">
        <button type="button" className="choice" onClick={onReinstall}>
          <span className="choice-icon"><RefreshCw size={18} aria-hidden="true" /></span>
          <span className="choice-text">
            <strong>Reinstall or repair <ShieldIcon size={13} /></strong>
            <span>Remove the app, then go through the setup steps again. Your existing backups and recovery key stay where they are.</span>
          </span>
        </button>
        <button type="button" className="choice" onClick={onUninstall}>
          <span className="choice-icon is-danger"><Trash2 size={18} aria-hidden="true" /></span>
          <span className="choice-text">
            <strong>Uninstall <ShieldIcon size={13} /></strong>
            <span>Remove the Rewindle app and its scheduled backups. Your backups and recovery key are kept.</span>
          </span>
        </button>
      </div>

      {legacy && (
        <Callout tone="info" icon={<TriangleAlert size={18} aria-hidden="true" />} title="The earlier personal edition is installed too">
          Setup doesn’t change it, whatever you choose here.
        </Callout>
      )}
    </div>
  );
}
