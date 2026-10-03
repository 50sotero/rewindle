import { useEffect, useRef, useState } from 'react';
import { Check, ChevronDown, Circle, Copy, Minus, ShieldAlert, X } from 'lucide-react';
import { motion } from 'motion/react';
import { Button } from '@/components/atoms/Button';
import { Callout, ShieldIcon, Spinner } from '../ui';
import { listedPhases, operationProgress, type ListedPhase, type OperationState, type Wizard } from '../useWizard';

function PhaseIcon({ state }: { state: ListedPhase['state'] }) {
  switch (state) {
    case 'completed': return <span className="phase-icon is-done"><Check size={13} strokeWidth={3} aria-hidden="true" /></span>;
    case 'started': return <span className="phase-icon is-active"><Spinner size={15} /></span>;
    case 'failed': return <span className="phase-icon is-failed"><X size={13} strokeWidth={3} aria-hidden="true" /></span>;
    case 'skipped': return <span className="phase-icon is-skipped"><Minus size={13} strokeWidth={3} aria-hidden="true" /></span>;
    default: return <span className="phase-icon is-pending"><Circle size={8} aria-hidden="true" /></span>;
  }
}

const STATE_WORDS: Record<ListedPhase['state'], string> = { completed: 'done', started: 'in progress', failed: 'failed', skipped: 'not needed', pending: 'waiting' };

/**
 * What a failed install left, in the words the installer's contract allows: before it copied anything (the `payload` phase) nothing of
 * Rewindle is on the PC, and from then on the installer undoes its changes and says so itself in its error message, which is shown as
 * it is. Only an installer that ended without a result line (it was stopped) gets guidance of the wizard's own.
 */
export function describeOutcome(operation: OperationState): string[] {
  const reached = new Set(operation.phases.map(phase => phase.phase));
  const changed = ['payload', 'canary', 'credential', 'repository', 'recovery_key', 'permissions', 'tasks', 'dashboard', 'verification'].some(phase => reached.has(phase));
  const lines: string[] = [];
  if (!operation.result) {
    lines.push('If Setup was stopped part-way, some files may have been left behind. Run Setup again: it tells you what is in the way, and you can remove a leftover Rewindle from Settings › Apps › Installed apps.');
  } else if (!changed) {
    lines.push('Nothing of Rewindle was installed.');
  }
  return lines;
}

/** The install (or uninstall) as it happens: one progress bar, every phase with its state, and the installer's own lines on request. */
export function OperationView({ wizard, operation }: { wizard: Wizard; operation: OperationState }) {
  const [details, setDetails] = useState(false);
  const [copied, setCopied] = useState(false);
  const log = useRef<HTMLPreElement>(null);
  const finished = operation.finished;
  const failed = !!finished && finished.outcome !== 'succeeded';
  const allPhases = listedPhases(operation);
  // After a failure or a cancellation the list says what happened, so the steps that never ran are left out.
  const phases = failed ? allPhases.filter(phase => phase.state !== 'pending') : allPhases;
  const progress = operationProgress(operation);
  const percent = Math.round(progress * 100);
  const current = [...phases].reverse().find(phase => phase.state === 'started');
  const uninstall = operation.operation === 'uninstall';

  useEffect(() => {
    if (details && log.current) log.current.scrollTop = log.current.scrollHeight;
  }, [details, operation.lines.length]);

  // The step that is running stays in view when the list is longer than the window.
  const currentId = current?.id;
  const reduced = wizard.theme?.reducedMotion ?? false;
  useEffect(() => {
    if (!currentId) return;
    document.querySelector('.phase[data-state="started"]')?.scrollIntoView({ block: 'nearest', behavior: reduced ? 'auto' : 'smooth' });
  }, [currentId, reduced]);

  const copyDetails = async () => {
    const header = [
      `Rewindle Setup ${wizard.host?.version ?? ''}, ${uninstall ? 'uninstall' : 'install'}`,
      finished ? `Outcome: ${finished.outcome}${finished.exitCode !== null ? ` (exit code ${finished.exitCode})` : ''}` : 'Outcome: still running',
    ];
    if (finished?.message) header.push(`Message: ${finished.message}`);
    const text = [...header, '', ...operation.lines].join('\n');
    try {
      await wizard.request('copyText', { text: text.slice(0, 60_000) });
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2400);
    } catch { /* the button stays as it was */ }
  };

  return (
    <div className="screen-stack">
      {!failed && operation.stage === 'preparing' && (
        <div className="stage-card">
          <Spinner size={20} />
          <div><strong>{uninstall ? 'Getting ready to remove Rewindle' : 'Checking your choices one last time'}</strong><p>Nothing has been changed yet{uninstall ? '' : ', so you can still cancel'}.</p></div>
        </div>
      )}
      {!failed && operation.stage === 'elevating' && (
        <div className="stage-card is-waiting">
          <span className="stage-shield"><ShieldIcon size={22} /></span>
          <div><strong>Waiting for your permission</strong><p>Choose <strong>Yes</strong> in the Windows prompt. If it asks for a password, use the one for the account you’re signed in with. If you don’t see the prompt, look for a flashing shield on the taskbar.</p></div>
        </div>
      )}

      {(operation.stage === 'running' || operation.stage === 'finished') && !failed && (
        <div className="progress-block">
          <div className="progress-head">
            <span className="progress-current">{finished?.outcome === 'succeeded' ? (uninstall ? 'Rewindle was removed' : 'Everything is in place') : current?.title ?? 'Working…'}</span>
            <span className="progress-percent">{percent}%</span>
          </div>
          <div className="setup-progress" role="progressbar" aria-label={uninstall ? 'Uninstall progress' : 'Install progress'} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}>
            <motion.span className="setup-progress-fill" initial={false} animate={{ width: `${Math.max(3, percent)}%` }} transition={{ duration: 0.45, ease: [0.16, 1, 0.3, 1] }} />
          </div>
        </div>
      )}

      {failed && finished && <FailureNotice wizard={wizard} operation={operation} onCopy={() => void copyDetails()} copied={copied} />}

      {(phases.length > 0 || operation.stage === 'running') && (
        <ol className="phase-list" aria-label={uninstall ? 'Uninstall steps' : 'Install steps'}>
          {phases.map(phase => (
            <li key={phase.id} className="phase" data-state={phase.state}>
              <PhaseIcon state={phase.state} />
              <span className="phase-text">
                <span className="phase-title">{phase.title}</span>
                {phase.detail && (phase.state === 'failed' || phase.state === 'completed') && phase.detail !== operation.result?.error?.message && <span className="phase-detail">{phase.detail}</span>}
              </span>
              <span className="sr-only">, {STATE_WORDS[phase.state]}</span>
            </li>
          ))}
        </ol>
      )}

      {operation.lines.length > 0 && (
        <div className="details">
          <div className="details-bar">
            <button type="button" className="advanced-toggle" aria-expanded={details} aria-controls="install-details" onClick={() => setDetails(value => !value)}>
              <ChevronDown size={16} aria-hidden="true" className="advanced-chevron" />Details
            </button>
            {!failed && <Button size="sm" variant="quiet" onClick={() => void copyDetails()}><Copy size={13} aria-hidden="true" />{copied ? 'Copied' : 'Copy details'}</Button>}
          </div>
          {details && <pre id="install-details" ref={log} className="details-log" tabIndex={0} aria-label="Installer messages">{operation.lines.join('\n')}</pre>}
        </div>
      )}
    </div>
  );
}

function FailureNotice({ wizard, operation, onCopy, copied }: { wizard: Wizard; operation: OperationState; onCopy: () => void; copied: boolean }) {
  const finished = operation.finished!;
  const uninstall = operation.operation === 'uninstall';
  if (finished.outcome === 'cancelled') {
    const declined = /permission|declin|uac/i.test(finished.message) || operation.phases.length === 0;
    return (
      <Callout tone="info" icon={<ShieldAlert size={18} aria-hidden="true" />} title={declined ? 'Windows permission wasn’t given' : 'Setup was cancelled'}>
        <p>Nothing on this PC was changed.</p>
        <p>{uninstall ? 'To remove Rewindle,' : 'To install Rewindle,'} choose <strong>Try again</strong> and select <strong>Yes</strong> when Windows asks.</p>
      </Callout>
    );
  }
  const notes = uninstall ? [] : describeOutcome(operation);
  const message = operation.result?.error?.message || finished.message || 'The installer stopped without saying why.';
  return (
    <Callout tone="error" title="What went wrong">
      <p className="failure-message">{message}</p>
      {notes.map(note => <p key={note}>{note}</p>)}
      {uninstall && <p>Your backups and recovery key were not touched. Try again, or remove Rewindle from Settings › Apps › Installed apps.</p>}
      <div className="callout-actions">
        <Button size="sm" onClick={onCopy}><Copy size={13} aria-hidden="true" />{copied ? 'Copied' : 'Copy details'}</Button>
        <button type="button" className="text-link" onClick={() => wizard.openLink('issues')}>Report the problem</button>
      </div>
    </Callout>
  );
}
