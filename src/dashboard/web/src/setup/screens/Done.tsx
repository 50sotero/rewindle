import { useState } from 'react';
import { motion } from 'motion/react';
import { BookOpen, Check, CalendarClock, KeyRound, LayoutDashboard, PlayCircle } from 'lucide-react';
import { messageOf } from '../bridge';
import { formatBytes, formatTime, nextRunDay, plural } from '../format';
import { selectedPaths, selectedTotal, type Wizard } from '../useWizard';
import type { RecoveryState } from './Recovery';

/** The end: what is set up, when the first backup runs, what is still to do (an unsaved recovery key), and where to find Rewindle. */
export function Done({ wizard, recovery }: { wizard: Wizard; recovery: RecoveryState }) {
  const choices = wizard.choices!;
  const count = selectedPaths(choices).length;
  const locale = wizard.host?.locale;
  const result = wizard.operation?.result;
  const firstBackup = wizard.operation?.phases.find(phase => phase.phase === 'first_backup');
  const started = choices.startBackup && firstBackup?.state === 'completed' && !result?.warnings.some(warning => warning.code === 'first_backup_not_started');
  const noAutostart = !!result?.warnings.some(warning => warning.code === 'dashboard_autostart_failed');
  // "Skip for now" (or a tick without a saved copy) leaves the key only on this PC; this page is the last place to say so.
  const keyPath = result?.recoveryKeyPath ?? null;
  const keyUnsaved = !recovery.savedTo && !recovery.acknowledged;
  const total = selectedTotal(choices, wizard.sizes);
  const when = `${nextRunDay(choices.schedule)} at ${formatTime(choices.schedule, locale)}`;
  const reduced = wizard.theme?.reducedMotion;
  const [keyError, setKeyError] = useState<string | null>(null);

  return (
    <div className="screen-stack done">
      <div className="done-hero">
        <motion.span className="done-emblem" initial={reduced ? false : { scale: 0.6, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
          transition={{ type: 'spring', stiffness: 380, damping: 22, delay: 0.05 }}>
          <Check size={30} strokeWidth={3} aria-hidden="true" />
        </motion.span>
        {/* "Set up to protect", not "protecting": until the first backup has finished, nothing has been copied yet. */}
        <p className="done-headline">Rewindle is set up to protect {plural(count, 'folder', 'folders')}.</p>
      </div>

      <ul className="done-facts">
        {keyUnsaved && (
          <li>
            <span className="point-icon is-warning"><KeyRound size={18} aria-hidden="true" /></span>
            <span>
              <strong>Your recovery key is still only on this PC.</strong> Copy {keyPath ? <span className="inline-path">{keyPath}</span> : 'it'} to a USB drive or a password manager soon.
              {' '}Without it, your backups can’t be opened if this PC is lost.
              {keyPath && <>{' '}<button type="button" className="text-link" onClick={() => { setKeyError(null); wizard.request('showRecoveryKey').catch(error => setKeyError(messageOf(error))); }}>Show in folder</button></>}
              {keyError && <span role="alert"> {keyError}</span>}
            </span>
          </li>
        )}
        <li>
          <span className="point-icon">{started ? <PlayCircle size={18} aria-hidden="true" /> : <CalendarClock size={18} aria-hidden="true" />}</span>
          <span>
            {started ? <><strong>Your first backup has started.</strong> It copies everything once{total.measuring ? '' : ` (${formatBytes(total.bytes, locale)})`}, so a large library can take hours. You can keep using your PC, and closing this window doesn’t stop it. Open Rewindle to watch its progress.</>
              : choices.startBackup ? <><strong>Your first backup didn’t start on its own.</strong> It will run {when}, or open Rewindle and choose Back up now.</>
                : <><strong>Your first backup runs {when}.</strong> If your PC is off or asleep then, it runs when you next sign in. To start sooner, open Rewindle and choose Back up now.</>}
          </span>
        </li>
        <li>
          <span className="point-icon"><LayoutDashboard size={18} aria-hidden="true" /></span>
          {noAutostart
            ? <span><strong>Rewindle won’t start with Windows by itself.</strong> Open it from the Start menu to see each backup and restore files.</span>
            : <span><strong>Rewindle starts with Windows</strong> and waits in the notification area. Open it from there or from the Start menu to see each backup and restore files.</span>}
        </li>
        <li>
          <span className="point-icon"><BookOpen size={18} aria-hidden="true" /></span>
          <span>New to Rewindle? <button type="button" className="text-link" onClick={() => wizard.openLink('readme')}>See how Rewindle works</button>: backups, checks and restores.</span>
        </li>
      </ul>
    </div>
  );
}
