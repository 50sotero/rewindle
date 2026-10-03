import { motion } from 'motion/react';
import { BookOpen, Check, CalendarClock, LayoutDashboard, PlayCircle } from 'lucide-react';
import { formatTime, plural } from '../format';
import { selectedPaths, type Wizard } from '../useWizard';

/** The end: what is protected now, whether the first backup started, and where to find Rewindle. */
export function Done({ wizard }: { wizard: Wizard }) {
  const choices = wizard.choices!;
  const count = selectedPaths(choices).length;
  const locale = wizard.host?.locale;
  const firstBackup = wizard.operation?.phases.find(phase => phase.phase === 'first_backup');
  const started = choices.startBackup && firstBackup?.state === 'completed' && !wizard.operation?.result?.warnings.some(warning => warning.code === 'first_backup_not_started');
  const reduced = wizard.theme?.reducedMotion;

  return (
    <div className="screen-stack done">
      <div className="done-hero">
        <motion.span className="done-emblem" initial={reduced ? false : { scale: 0.6, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
          transition={{ type: 'spring', stiffness: 380, damping: 22, delay: 0.05 }}>
          <Check size={30} strokeWidth={3} aria-hidden="true" />
        </motion.span>
        <p className="done-headline">Rewindle is protecting {plural(count, 'folder', 'folders')}.</p>
      </div>

      <ul className="done-facts">
        <li>
          <span className="point-icon">{started ? <PlayCircle size={18} aria-hidden="true" /> : <CalendarClock size={18} aria-hidden="true" />}</span>
          <span>
            {started ? <><strong>Your first backup is running.</strong> It copies everything once, so it can take a while. You can keep using your PC, and closing this window doesn’t stop it.</>
              : choices.startBackup ? <><strong>Your first backup didn’t start on its own.</strong> It will run at {formatTime(choices.schedule, locale)}, or open Rewindle and choose Back up now.</>
                : <><strong>Your first backup runs at {formatTime(choices.schedule, locale)}.</strong> To start it sooner, open Rewindle and choose Back up now.</>}
          </span>
        </li>
        <li>
          <span className="point-icon"><LayoutDashboard size={18} aria-hidden="true" /></span>
          <span><strong>Rewindle starts with Windows</strong> and sits in the notification area. Open it from there or from the Start menu to see each backup and restore files.</span>
        </li>
        <li>
          <span className="point-icon"><BookOpen size={18} aria-hidden="true" /></span>
          <span>New to Rewindle? <button type="button" className="text-link" onClick={() => wizard.openLink('readme')}>Read the README</button> to learn how backups, checks and restores work.</span>
        </li>
      </ul>
    </div>
  );
}
