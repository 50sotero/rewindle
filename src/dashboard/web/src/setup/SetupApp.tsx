// Rewindle Setup: the wizard's shell. A rail of steps on the left (a compact bar on narrow windows), the current screen, and a
// footer whose Back and Next sit in the same place on every screen. Enter means Next and Esc means Back, unless the focus is on
// something that uses those keys itself. Every screen's title takes the focus when it opens, so a screen reader reads it.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { AnimatePresence, MotionConfig, motion } from 'motion/react';
import { ArrowLeft, ArrowRight, Check, LayoutDashboard, RotateCcw, X } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { bridge } from './bridge';
import LoadingState from '@/components/primitives/LoadingState';
import { issuesFor, SCHEDULE_PATTERN } from './contract';
import { formatBytes, plural } from './format';
import { ConfirmDialog, ShieldIcon, Spinner } from './ui';
import { CHOICE_STEPS, STEPS, onlineOnlyPaths, phaseTitle, selectedPaths, selectedTotal, useWizard, type Screen, type Wizard } from './useWizard';
import { Welcome } from './screens/Welcome';
import { Folders } from './screens/Folders';
import { Location } from './screens/Location';
import { Schedule } from './screens/Schedule';
import { Review } from './screens/Review';
import { OperationView } from './screens/Installing';
import { Recovery, type RecoveryState } from './screens/Recovery';
import { Done } from './screens/Done';
import { Maintenance } from './screens/Maintenance';
import { HostError, Uninstalled, Unsupported } from './screens/Blocked';

interface FooterAction { label: string; onClick: () => void; disabled?: boolean; icon?: ReactNode; trailing?: ReactNode; variant?: 'primary' | 'secondary' | 'quiet' | 'accent' }
interface Footer { back?: FooterAction | null; next?: FooterAction | null; hint?: ReactNode }
interface Header { eyebrow?: string; title: string; lead?: ReactNode }

// Numbered like the rail, which counts Welcome through Done.
const NUMBERED: Partial<Record<Screen, number>> = { folders: 2, location: 3, schedule: 4, review: 5 };

function headerFor(wizard: Wizard): Header {
  const operation = wizard.operation;
  const outcome = operation?.finished?.outcome;
  const step = NUMBERED[wizard.screen];
  const eyebrow = step ? `Step ${step} of 8` : undefined;
  switch (wizard.screen) {
    case 'hostError': return { title: 'Setup couldn’t start' };
    case 'unsupported': return { title: 'Rewindle can’t be installed on this PC', lead: 'This PC is missing something Rewindle needs to run.' };
    case 'maintenance': return { eyebrow: 'Rewindle Setup', title: 'Rewindle is already on this PC', lead: 'Open it, set it up again, or remove it.' };
    case 'welcome': return { eyebrow: 'Rewindle Setup', title: 'Backup you can verify', lead: 'Set up daily, encrypted backups of your files in a few steps. The suggestions on each page suit most people, so you can just choose Next.' };
    case 'folders': return { eyebrow, title: 'What should Rewindle protect?', lead: 'Your main folders are already chosen. Add anything else you’d hate to lose.' };
    case 'location': return { eyebrow, title: 'Where should backups be kept?', lead: 'Choose a drive. A separate drive, like an external USB drive, keeps your files safest.' };
    case 'schedule': return { eyebrow, title: 'When should Rewindle back up?', lead: 'Rewindle backs up once a day and copies only what changed since the last time.' };
    case 'review': return { eyebrow, title: 'Ready to install', lead: 'Check your choices. You can change folders and the schedule later in Rewindle.' };
    case 'installing':
      if (outcome === 'succeeded') return { title: 'Rewindle is installed', lead: 'One more step: save your recovery key.' };
      if (outcome === 'cancelled') return { title: 'Rewindle wasn’t installed' };
      if (outcome === 'failed') return { title: 'Setup couldn’t finish' };
      return { title: 'Installing Rewindle', lead: operation?.stage === 'running' ? 'This usually takes a minute or two. You can keep using your PC.' : undefined };
    case 'recovery': return { title: 'Save your recovery key', lead: 'You’ll need it to get your files back if this PC is ever lost.' };
    case 'done': return { title: 'You’re all set' };
    case 'uninstalling':
      if (outcome === 'cancelled') return { title: 'Rewindle wasn’t removed' };
      if (outcome === 'failed') return { title: 'Rewindle couldn’t be removed' };
      return { title: 'Removing Rewindle', lead: operation?.reinstall ? 'Next, Setup takes you through the steps again.' : undefined };
    case 'uninstalled': return { title: 'Rewindle was removed' };
    default: return { title: 'Rewindle Setup' };
  }
}

/** True when the key press belongs to the focused control, not to the wizard's Next and Back. */
function ownsKey(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false;
  if (target.closest('dialog[open]')) return true;
  return target.matches('button, a, input, textarea, select, summary, [role="switch"], [role="checkbox"], [role="radio"], [contenteditable="true"]');
}

export default function SetupApp() {
  const wizard = useWizard();
  const { screen, choices, operation } = wizard;
  const [recovery, setRecovery] = useState<RecoveryState>({ acknowledged: false, savedTo: null });
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [confirmReinstall, setConfirmReinstall] = useState(false);
  const [confirmSkip, setConfirmSkip] = useState(false);
  const [openError, setOpenError] = useState<string | null>(null);
  const [spoken, setSpoken] = useState({ polite: '', assertive: '' });
  const titleRef = useRef<HTMLHeadingElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const reduced = wizard.theme?.reducedMotion ?? false;

  // Each screen opens at its top, whatever the one before it was scrolled to.
  useLayoutEffect(() => { scrollRef.current?.scrollTo({ top: 0 }); }, [screen]);

  // Theme, contrast and motion, before the frame that shows them.
  useLayoutEffect(() => {
    const theme = wizard.theme;
    if (!theme) return;
    const root = document.documentElement;
    root.classList.toggle('dark', theme.dark);
    root.classList.toggle('light', !theme.dark);
    root.style.colorScheme = theme.dark ? 'dark' : 'light';
    root.dataset.highContrast = String(theme.highContrast);
    root.dataset.reducedMotion = String(theme.reducedMotion);
  }, [wizard.theme]);

  const close = useCallback(() => { void wizard.request('close').catch(() => undefined); }, [wizard]);
  const openDashboard = useCallback(async () => {
    setOpenError(null);
    try { await wizard.request('openDashboard'); } catch (error) { setOpenError(error instanceof Error ? error.message : 'Rewindle could not be opened.'); }
  }, [wizard]);

  const plan = wizard.validation.plan;
  const footer = useMemo<Footer>(() => {
    const back = (to: Screen): FooterAction => ({ label: 'Back', icon: <ArrowLeft size={15} aria-hidden="true" />, onClick: () => wizard.goTo(to) });
    const next = (to: Screen, disabled = false): FooterAction => ({ label: 'Next', trailing: <ArrowRight size={15} aria-hidden="true" />, onClick: () => wizard.goTo(to), disabled, variant: 'primary' });
    const closeAction = (variant: FooterAction['variant'] = 'secondary'): FooterAction => ({ label: 'Close', onClick: close, variant });
    switch (screen) {
      case 'hostError': return { back: closeAction(), next: { label: 'Try again', icon: <RotateCcw size={15} aria-hidden="true" />, onClick: wizard.actions.retry, variant: 'primary' } };
      case 'unsupported': return { next: closeAction('primary') };
      case 'maintenance': return { next: closeAction() };
      case 'welcome': {
        // A problem with the PC itself (not with a choice) is told on this page, and there is no point going on until it is fixed.
        const blocked = issuesFor(plan, 'environment').errors.length > 0;
        return {
          back: wizard.maintenance ? back('maintenance') : { ...back('welcome'), disabled: true }, next: next('folders', blocked),
          hint: blocked ? 'Fix the problem above to continue' : undefined,
        };
      }
      case 'folders': {
        const total = selectedTotal(choices!, wizard.sizes);
        const count = selectedPaths(choices!).length;
        const errors = issuesFor(plan, 'sources').errors.length > 0;
        const onlineOnly = onlineOnlyPaths(choices!, wizard.sizes).length > 0;
        return {
          back: back('welcome'), next: next('location', count === 0 || errors || onlineOnly),
          hint: count === 0 ? 'Choose at least one folder' : onlineOnly ? 'Online-only files must be on this PC first' : <>{total.measuring && <Spinner size={12} />}<span>{plural(count, 'folder', 'folders')} · {formatBytes(total.bytes, wizard.host?.locale)}</span></>,
        };
      }
      case 'location': {
        const errors = issuesFor(plan, 'repository', 'storage_mode').errors.length > 0;
        return { back: back('folders'), next: next('schedule', !choices?.repository || errors) };
      }
      case 'schedule': {
        const errors = issuesFor(plan, 'schedule').errors.length > 0;
        return { back: back('location'), next: next('review', !SCHEDULE_PATTERN.test(choices?.schedule ?? '') || !wizard.scheduleDraftValid || errors) };
      }
      case 'review': {
        // Install also waits for the first scan of every chosen folder: online-only files are only known once the scan reaches
        // them, and the installed engine refuses such a folder on every backup.
        // Install itself scans them once more before the installer starts (wizard.checkingBeforeInstall meanwhile).
        const scanning = selectedTotal(choices!, wizard.sizes).measuring;
        const problems = (plan?.errors.length ?? 0) > 0 || selectedPaths(choices!).length === 0 || onlineOnlyPaths(choices!, wizard.sizes).length > 0;
        return {
          back: back('schedule'),
          next: { label: 'Install', icon: <ShieldIcon size={16} />, onClick: () => wizard.install(), disabled: problems || scanning, variant: 'primary' },
          hint: problems ? 'Fix the problems above to install'
            : wizard.checkingBeforeInstall ? <><Spinner size={12} /><span>Checking your folders once more…</span></>
              : scanning ? <><Spinner size={12} /><span>Checking your folders for online-only files…</span></>
                : 'Windows will ask for permission once',
        };
      }
      case 'installing':
      case 'uninstalling': {
        const outcome = operation?.finished?.outcome;
        // Retrying the removal half of a reinstall keeps going on to the setup steps afterwards.
        const retry = screen === 'installing' ? () => wizard.install()
          : operation?.reinstall ? () => void wizard.reinstall() : () => void wizard.uninstall();
        const returnTo: Screen = screen === 'installing' ? 'review' : 'maintenance';
        if (outcome === 'succeeded') {
          return screen === 'installing'
            ? { next: { label: 'Continue', trailing: <ArrowRight size={15} aria-hidden="true" />, onClick: () => wizard.goTo('recovery'), variant: 'primary' } }
            : { next: closeAction('primary') };
        }
        if (outcome === 'failed' || outcome === 'cancelled') {
          return {
            back: { label: screen === 'installing' ? 'Back to review' : 'Back', icon: <ArrowLeft size={15} aria-hidden="true" />, onClick: () => { wizard.clearOperation(); wizard.goTo(returnTo); } },
            next: { label: 'Try again', icon: screen === 'installing' ? <ShieldIcon size={16} /> : <RotateCcw size={15} aria-hidden="true" />, onClick: retry, disabled: wizard.checkingBeforeInstall, variant: 'primary' },
            hint: wizard.checkingBeforeInstall ? <><Spinner size={12} /><span>Checking your folders once more…</span></> : undefined,
          };
        }
        if (operation?.stage === 'preparing') {
          return { next: { label: operation.cancelling ? 'Cancelling…' : 'Cancel', icon: <X size={15} aria-hidden="true" />, onClick: () => void wizard.cancelOperation(), disabled: operation.cancelling } };
        }
        return { hint: operation?.stage === 'elevating' ? 'Waiting for Windows…' : <><Spinner size={12} /><span>{screen === 'installing' ? 'Installing' : 'Removing'}, please wait</span></> };
      }
      case 'recovery':
        return {
          back: { label: 'Skip for now', onClick: () => setConfirmSkip(true), variant: 'quiet' },
          next: { label: 'Finish', icon: <Check size={15} aria-hidden="true" />, onClick: () => wizard.goTo('done'), disabled: !recovery.acknowledged, variant: 'primary' },
          hint: recovery.acknowledged ? undefined : 'Confirm you’ve saved your key to finish',
        };
      case 'done':
        return { back: closeAction(), next: { label: 'Open Rewindle', icon: <LayoutDashboard size={15} aria-hidden="true" />, onClick: () => void openDashboard(), variant: 'primary' } };
      case 'uninstalled':
        return { next: closeAction('primary') };
      default:
        return {};
    }
  }, [choices, close, openDashboard, operation, plan, recovery.acknowledged, screen, wizard]);

  // Ctrl+= / Ctrl+- / Ctrl+0 make the page larger or smaller (Ctrl+wheel is the web view's own). The web view's browser shortcuts are
  // off, so the host does the zooming when it is asked. Outside the setup program the browser zooms by itself.
  useEffect(() => {
    if (!window.chrome?.webview) return;
    const onZoom = (event: KeyboardEvent) => {
      if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
      const zoom = event.key === '=' || event.key === '+' ? 'in' : event.key === '-' || event.key === '_' ? 'out' : event.key === '0' ? 'reset' : null;
      if (!zoom) return;
      event.preventDefault();
      if (event.repeat) return;
      bridge.request<{ message?: string }>('setZoom', { zoom })
        .then(answer => setSpoken({ polite: answer?.message ?? '', assertive: '' }))
        .catch(() => undefined);
    };
    window.addEventListener('keydown', onZoom);
    return () => window.removeEventListener('keydown', onZoom);
  }, []);

  // Enter for Next and Esc for Back, when nothing focused uses them.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.repeat) return;
      if (event.key === 'Enter' && !ownsKey(event.target) && footer.next && !footer.next.disabled) {
        event.preventDefault(); footer.next.onClick();
      } else if (event.key === 'Escape' && !ownsKey(event.target) && footer.back && !footer.back.disabled && footer.back.label !== 'Close' && footer.back.label !== 'Skip for now') {
        event.preventDefault(); footer.back.onClick();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [footer]);

  // Progress, read aloud: each phase as it finishes, and a failure at once.
  const lastPhase = useRef('');
  useEffect(() => {
    if (!operation) { lastPhase.current = ''; return; }
    const finished = operation.finished;
    if (finished) {
      const text = finished.outcome === 'succeeded' ? (operation.operation === 'install' ? 'Rewindle is installed.' : 'Rewindle was removed.')
        : finished.outcome === 'cancelled' ? 'Nothing was changed.' : `Setup couldn’t finish. ${operation.result?.error?.message ?? finished.message}`;
      setSpoken(finished.outcome === 'failed' ? { polite: '', assertive: text } : { polite: text, assertive: '' });
      return;
    }
    const latest = operation.phases[operation.phases.length - 1];
    const key = latest ? `${latest.phase}:${latest.state}` : operation.stage;
    if (key === lastPhase.current) return;
    lastPhase.current = key;
    const text = latest ? `${phaseTitle(operation.operation, latest.phase, latest.title)}${latest.state === 'completed' ? ', done' : latest.state === 'started' ? '…' : latest.state === 'skipped' ? ', not needed' : ', failed'}`
      : operation.stage === 'elevating' ? 'Waiting for permission. Choose Yes in the Windows prompt.' : '';
    setSpoken({ polite: text, assertive: '' });
  }, [operation]);

  const header = headerFor(wizard);
  const stepIndex = STEPS.findIndex(step => step.screen === screen);
  const inFlow = stepIndex >= 0;
  const locked = !!operation && screen !== 'review';

  const body = (() => {
    switch (screen) {
      case 'hostError': return <HostError wizard={wizard} />;
      case 'unsupported': return <Unsupported wizard={wizard} />;
      case 'maintenance': return <Maintenance wizard={wizard} onReinstall={() => setConfirmReinstall(true)} onUninstall={() => setConfirmUninstall(true)} openDashboard={() => void openDashboard()} />;
      case 'welcome': return <Welcome wizard={wizard} />;
      case 'folders': return <Folders wizard={wizard} />;
      case 'location': return <Location wizard={wizard} />;
      case 'schedule': return <Schedule wizard={wizard} />;
      case 'review': return <Review wizard={wizard} />;
      case 'installing': case 'uninstalling': return operation ? <OperationView wizard={wizard} operation={operation} /> : null;
      case 'recovery': return <Recovery wizard={wizard} state={recovery} onChange={setRecovery} />;
      case 'done': return <Done wizard={wizard} />;
      case 'uninstalled': return <Uninstalled wizard={wizard} />;
      default: return null;
    }
  })();

  if (screen === 'loading') {
    return (
      <div className="setup-loading">
        <img src="./rewindle-icon.svg" alt="" width="48" height="48" />
        <LoadingState label="Checking this PC" variant="Orbit" showElapsed={false} />
        <p>Looking at your drives and folders. Nothing is changed.</p>
      </div>
    );
  }

  const choiceIndex = CHOICE_STEPS.indexOf(screen);
  return (
    <MotionConfig reducedMotion={reduced ? 'always' : 'never'}>
      <div className="setup-shell">
        <div className="sr-only" role="status" aria-live="polite" aria-atomic="true">{spoken.polite}</div>
        <div className="sr-only" role="alert" aria-live="assertive" aria-atomic="true">{spoken.assertive}</div>

        <aside className="setup-rail" aria-label="Setup progress">
          <div className="rail-brand">
            <img src="./rewindle-icon.svg" alt="" width="32" height="32" />
            <span><strong>Rewindle</strong><span>Setup</span></span>
          </div>
          {inFlow ? (
            <ol className="rail-steps">
              {STEPS.map((step, index) => {
                const state = index < stepIndex ? 'done' : index === stepIndex ? 'current' : 'upcoming';
                const reachable = !locked && CHOICE_STEPS.includes(step.screen) && CHOICE_STEPS.indexOf(step.screen) <= wizard.furthest && index !== stepIndex;
                const content = <>
                  <span className="rail-dot" aria-hidden="true">{state === 'done' ? <Check size={12} strokeWidth={3} /> : index + 1}</span>
                  <span className="rail-label">{step.label}</span>
                </>;
                return (
                  <li key={step.screen} className="rail-step" data-state={state}>
                    {reachable
                      ? <button type="button" className="rail-link" onClick={() => wizard.goTo(step.screen)} aria-label={`${step.label}${state === 'done' ? ', done' : ''}. Go to this step`}>{content}</button>
                      : <span className="rail-link" aria-current={state === 'current' ? 'step' : undefined}>{content}<span className="sr-only">{state === 'done' ? ', done' : state === 'upcoming' ? ', not yet' : ''}</span></span>}
                  </li>
                );
              })}
            </ol>
          ) : (
            <p className="rail-tagline">Backup you can verify.</p>
          )}
          <div className="rail-foot">
            {wizard.host?.host === 'sample' && <span className="sample-badge" title="This window answers with invented data; nothing on this computer is read or changed.">Sample data · {wizard.host.scenario}</span>}
            <span className="rail-version">Version {wizard.host?.version ?? wizard.base?.environment.version}</span>
            <span className="rail-license">Free and open source · MIT</span>
          </div>
        </aside>

        <div className="setup-main">
          {inFlow && (
            <div className="compact-progress" aria-hidden="true">
              <img src="./rewindle-icon.svg" alt="" width="22" height="22" />
              <span className="compact-label">{STEPS[stepIndex]?.label}</span>
              <span className="compact-count">{stepIndex + 1} of {STEPS.length}</span>
              <span className="compact-bar"><span style={{ width: `${((stepIndex + 1) / STEPS.length) * 100}%` }} /></span>
            </div>
          )}
          <div className="setup-scroll" ref={scrollRef}>
            <AnimatePresence mode="wait" initial={false}>
              <motion.main key={screen} className="setup-page" aria-labelledby="screen-title"
                initial={{ opacity: 0, x: reduced ? 0 : 10 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: reduced ? 0 : -6, transition: { duration: reduced ? 0 : 0.1 } }}
                transition={{ duration: reduced ? 0 : 0.24, ease: [0.16, 1, 0.3, 1] }}
                onAnimationComplete={() => titleRef.current?.focus({ preventScroll: true })}>
                <header className="screen-header">
                  {header.eyebrow && <p className="screen-eyebrow">{header.eyebrow}</p>}
                  <h1 id="screen-title" ref={titleRef} tabIndex={-1} className="screen-title">{header.title}</h1>
                  {header.lead && <p className="screen-lead">{header.lead}</p>}
                </header>
                {body}
                {openError && (screen === 'done' || screen === 'maintenance') && <p className="callout is-error" role="alert"><span>{openError}</span></p>}
              </motion.main>
            </AnimatePresence>
          </div>

          <footer className="setup-footer" data-choice-step={choiceIndex >= 0}>
            <div className="footer-back">
              {footer.back && (
                <Button variant={footer.back.variant ?? 'secondary'} className="setup-button" disabled={footer.back.disabled} onClick={footer.back.onClick}
                  aria-keyshortcuts={footer.back.label === 'Back' ? 'Escape' : undefined}>
                  {footer.back.icon}{footer.back.label}
                </Button>
              )}
            </div>
            <div className="footer-hint" aria-live="polite">{footer.hint}</div>
            <div className="footer-next">
              {footer.next && (
                <Button variant={footer.next.variant ?? 'secondary'} className="setup-button" disabled={footer.next.disabled} onClick={footer.next.onClick}
                  aria-keyshortcuts={footer.next.variant === 'primary' ? 'Enter' : undefined}>
                  {footer.next.icon}{footer.next.label}{footer.next.trailing}
                </Button>
              )}
            </div>
          </footer>
        </div>

        <ConfirmDialog open={confirmUninstall} title="Uninstall Rewindle?" confirm="Uninstall" cancel="Keep Rewindle" danger confirmIcon={<ShieldIcon size={15} />}
          onCancel={() => setConfirmUninstall(false)} onConfirm={() => { setConfirmUninstall(false); void wizard.uninstall(); }}>
          <p>This removes the Rewindle app, its scheduled backups, the Start menu shortcut and its entry in Installed apps. A backup that is running is stopped.</p>
          <p><strong>Your backups and recovery key are kept</strong>, so you can still restore files or install Rewindle again. Windows will ask for permission.</p>
        </ConfirmDialog>
        <ConfirmDialog open={confirmReinstall} title="Set up Rewindle again?" confirm="Remove and set up again" cancel="Keep Rewindle" confirmIcon={<ShieldIcon size={15} />}
          onCancel={() => setConfirmReinstall(false)} onConfirm={() => { setConfirmReinstall(false); void wizard.reinstall(); }}>
          <p>Setup removes the Rewindle app and its scheduled backups first, then takes you through the setup steps again. Windows asks for permission for each part.</p>
          <p><strong>Your backups and recovery key are kept.</strong> Choose the same backup location in the steps to carry on with them.</p>
        </ConfirmDialog>
        <ConfirmDialog open={confirmSkip} title="Skip saving your recovery key?" confirm="Skip for now" cancel="Go back"
          onCancel={() => setConfirmSkip(false)} onConfirm={() => { setConfirmSkip(false); wizard.goTo('done'); }}>
          <p>Without a copy away from this PC, your backups can’t be opened if this PC is lost or its drive fails.</p>
          {operation?.result?.recoveryKeyPath && <p>You can copy it later from <span className="inline-path">{operation.result.recoveryKeyPath}</span>.</p>}
        </ConfirmDialog>
      </div>
    </MotionConfig>
  );
}
