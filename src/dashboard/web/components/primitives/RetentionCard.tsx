import { useId, useState } from 'react';
import { Archive, CircleAlert, CircleCheck, Info, LoaderCircle, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { usableLocale, type CommandName, type DashboardState, type RetentionState } from '@/src/native-types';
import { cardModel, type CardButton } from '@/src/retention';
import { usePendingCommand } from '@/src/pendingCommands';
import { RetentionCountsDialog, RetentionReviewDialog, RetentionTurnOffDialog } from './RetentionDialogs';
import './old-backups.css';

type Send = (command: CommandName, payload?: Record<string, string | boolean>, onResult?: (ok: boolean) => void) => void;
const noticeIcons = { info: Info, success: CircleCheck, warning: TriangleAlert, error: CircleAlert };

// Settings > Backup plan > Old backups. The card only reads the host's state; the counts and Turn off dialogs and the list of old
// backups are where anything is asked for, and the host checks every request again.
export default function RetentionCard({ state, send, quiet = false }: { state: DashboardState; send: Send; quiet?: boolean }) {
  const retention = state.retention;
  const [dialog, setDialog] = useState<'counts' | 'turnOff' | null>(null);
  const pending = usePendingCommand();
  const titleId = useId();
  if (!retention) return null;
  const locale = usableLocale(state.locale);
  const model = cardModel(retention, locale);
  const toneClass = `old-backups-tone-${model.tone}`;
  const Icon = retention.notice ? noticeIcons[retention.notice.tone] ?? Info : Info;
  const blockedForPage = state.demo || state.preview;
  const press = (button: CardButton) => {
    if (button.command === 'configure') setDialog('counts');
    else if (button.command === 'turnOff') setDialog('turnOff');
    else if (button.command === 'review') send('retentionOpenReview');
    else if (button.command === 'checkNow') send('retentionCheckNow');
    else send('refresh');
  };
  const commandOf = (button: CardButton): CommandName =>
    button.command === 'review' ? 'retentionOpenReview' : button.command === 'checkNow' ? 'retentionCheckNow' : 'retentionConfigure';
  return <section className={`surface setting-row wide-row old-backups-card ${toneClass}`} aria-labelledby={titleId}>
    <div className="setting-copy">
      <h3 className="info-heading" id={titleId}><Archive size={15} />Old backups</h3>
      <p className="info-main">{model.busy && <LoaderCircle size={15} className="old-backups-spinner" aria-hidden="true" />}{model.main}</p>
      {/* Always present, so a step that starts, moves on or ends is announced. */}
      <div role="status" aria-live="polite">
        {model.lines.map(line => <p key={line} className="muted-copy old-backups-line">{line}</p>)}
        {retention.operation.active && retention.operation.percent != null && <div className="progress-rail old-backups-progress" role="progressbar"
          aria-label="Clean-up progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(retention.operation.percent)}>
          <div className="progress-bar" style={{ width: `${Math.max(0, Math.min(100, retention.operation.percent))}%` }} /></div>}
        {retention.notice && <p className={`source-notice old-backups-notice ${retention.notice.tone}`}><Icon size={14} aria-hidden="true" />{retention.notice.text}</p>}
      </div>
    </div>
    {model.buttons.length > 0 && <div className="setting-controls">
      {model.buttons.map(button => {
        const off = blockedForPage || (button.ability !== null && !button.ability.enabled) ||
          (button.command !== 'refresh' && button.command !== 'turnOff' && pending(commandOf(button)));
        const help = button.ability && !button.ability.enabled ? button.ability.help : '';
        return <span key={button.command} className="context-action" title={quiet && help ? help : undefined}>
          <Button size="sm" variant={button.primary ? 'primary' : 'secondary'} disabled={off} title={help || undefined} onClick={() => press(button)}>{button.label}</Button>
          {help && !quiet && button.primary && <span className="action-disabled-reason">{help}</span>}
        </span>;
      })}
    </div>}
    <RetentionCountsDialog open={dialog === 'counts'} retention={retention} send={send} onClose={() => setDialog(null)} reducedMotion={state.reducedMotion} />
    <RetentionTurnOffDialog open={dialog === 'turnOff'} send={send} onClose={() => setDialog(null)} />
    <RetentionReviewDialog retention={retention} send={send} locale={locale} />
  </section>;
}

export type { RetentionState };
