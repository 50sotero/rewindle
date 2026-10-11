import { useState } from 'react';
import { Check, Copy, FileKey2, FolderSearch, KeyRound, Save, ShieldAlert, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { messageOf } from '../bridge';
import type { PlanVolume } from '../contract';
import { driveRoot, samePath } from '../format';
import { Callout } from '../ui';
import type { Wizard } from '../useWizard';

export interface RecoveryState { acknowledged: boolean; savedTo: string | null }

/**
 * Where a saved copy of the key stands against "this PC is lost": on the Windows drive or its disk it goes with the PC, and on the
 * backup drive it goes with the backups (and opens them for anyone who has that drive). `unknown` when the host named no drive.
 */
export type CopyPlace = 'away' | 'this-pc' | 'with-backups' | 'unknown';
export function copyPlace(savedTo: string | null, volumes: PlanVolume[], backupRoot: string): CopyPlace {
  const root = savedTo ? driveRoot(savedTo) : '';
  if (!root) return 'unknown';
  const volume = volumes.find(item => samePath(item.root, root));
  if (volume && (volume.isSystem || volume.sameDiskAsSystem)) return 'this-pc';
  return backupRoot && samePath(root, backupRoot) ? 'with-backups' : 'away';
}

/**
 * After a successful install: the recovery key. Saving a copy goes through the host (a Save dialog; the page never names the
 * file it copies). When the installer reports that the key is readable only by administrators, the wizard cannot copy it, so it
 * says where it is and how to copy it with Windows' own permission prompt.
 */
export function Recovery({ wizard, state, onChange }: { wizard: Wizard; state: RecoveryState; onChange: (next: RecoveryState) => void }) {
  const result = wizard.operation?.result;
  const path = result?.recoveryKeyPath ?? null;
  // Only an explicit "no" from the installer means the copy can't be made here; "unknown" is tried, and says so if it fails.
  const readable = result?.recoveryKeyReadableByUser !== false;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const volumes = wizard.base?.environment.volumes ?? [];
  const backupRoot = wizard.choices?.driveRoot ?? '';
  const place = copyPlace(state.savedTo, volumes, backupRoot);

  const save = async () => {
    setBusy(true); setError(null);
    try {
      const answer = await wizard.request<{ saved: boolean; path?: string }>('saveRecoveryKeyCopy');
      // A verified copy away from this PC and the backups is the one thing the checkbox stands for, so it ticks the box itself.
      if (answer?.saved) onChange({ ...state, savedTo: answer.path ?? 'the place you chose', acknowledged: state.acknowledged || copyPlace(answer.path ?? null, volumes, backupRoot) === 'away' });
    } catch (failure) {
      setError(messageOf(failure));
    } finally { setBusy(false); }
  };
  const show = async () => {
    setError(null);
    try { await wizard.request('showRecoveryKey'); } catch (failure) { setError(messageOf(failure)); }
  };
  const copyPath = async () => {
    if (!path) return;
    try { await wizard.request('copyText', { text: path }); setCopied(true); window.setTimeout(() => setCopied(false), 2400); } catch { /* unchanged */ }
  };

  return (
    <div className="screen-stack">
      <div className="key-explain">
        <span className="key-emblem"><KeyRound size={26} aria-hidden="true" /></span>
        <div>
          <p>Your backups are encrypted. The recovery key is the only way to open them if this PC is lost, broken or reset, for example to restore your files on a new PC.</p>
          <p>Rewindle keeps a copy on this PC, but that copy disappears with the PC. <strong>Save a copy somewhere else</strong>, like a USB drive you keep in a drawer, a password manager, or a printout in a safe place.</p>
        </div>
      </div>

      <div className="key-file">
        <FileKey2 size={22} aria-hidden="true" className="key-file-icon" />
        <div className="key-file-text">
          <strong>Your recovery key</strong>
          <span className="key-file-path" title={path ?? undefined}>{path ?? 'Setup did not report where the key was saved.'}</span>
        </div>
        {readable ? (
          <div className="key-file-actions">
            <Button variant="accent" className="setup-button" disabled={busy || !path} onClick={() => void save()}><Save size={15} aria-hidden="true" />{state.savedTo ? 'Save another copy…' : 'Save a copy…'}</Button>
            <Button className="setup-button" disabled={!path} onClick={() => void show()}><FolderSearch size={15} aria-hidden="true" />Show in folder</Button>
          </div>
        ) : (
          <div className="key-file-actions">
            <Button className="setup-button" disabled={!path} onClick={() => void copyPath()}><Copy size={15} aria-hidden="true" />{copied ? 'Copied' : 'Copy location'}</Button>
            <Button className="setup-button" disabled={!path} onClick={() => void show()}><FolderSearch size={15} aria-hidden="true" />Show in folder</Button>
          </div>
        )}
      </div>

      <div role="status" aria-live="polite">
        {state.savedTo && (place === 'this-pc' || place === 'with-backups'
          // The host reads every copy back and compares it, so "saved" always means "checked"; whether the place helps is up to the page.
          ? <p className="fit-line is-tight"><TriangleAlert size={16} aria-hidden="true" /><span><strong>Saved and checked, but not in a safe place.</strong> The copy at <strong className="break-anywhere">{state.savedTo}</strong> is {place === 'this-pc' ? 'on this PC’s own drive, so it won’t help if this PC is lost' : 'on the same drive as your backups, so losing that drive loses both, and anyone who has it could open your backups'}. Save another copy to a USB drive, or open the file and paste it into a password manager.</span></p>
          : <p className="fit-line is-good"><Check size={16} aria-hidden="true" /><span><strong>Saved and checked.</strong> {place === 'away' ? <>The copy at <strong className="break-anywhere">{state.savedTo}</strong> matches the original. Keep that drive somewhere safe, away from this PC.</> : 'The copy matches the original.'}</span></p>)}
      </div>
      {error && <Callout tone="error" title="The copy wasn’t saved">{error}</Callout>}

      {!readable && path && (
        <Callout tone="info" icon={<ShieldAlert size={18} aria-hidden="true" />} title="Only administrators can open this file">
          <ol className="steps-list">
            <li>Choose <strong>Show in folder</strong> to open it in File Explorer.</li>
            <li>Copy the file to a USB drive or another safe place. Windows asks for permission; choose <strong>Continue</strong>.</li>
            <li>Come back here and confirm below.</li>
          </ol>
        </Callout>
      )}

      <label className="ack">
        <input type="checkbox" checked={state.acknowledged} onChange={event => onChange({ ...state, acknowledged: event.target.checked })} />
        <span className="ack-box" aria-hidden="true">{state.acknowledged && <Check size={14} strokeWidth={3} />}</span>
        <span>I’ve saved my recovery key somewhere safe, away from this PC</span>
      </label>
    </div>
  );
}
