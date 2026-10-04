import { useEffect, useState } from 'react';
import { ChevronDown, Clock, Moon, Sun, Sunset } from 'lucide-react';
import { issuesFor, SCHEDULE_PATTERN } from '../contract';
import { formatTime } from '../format';
import { InfoTip, IssueList, Switch } from '../ui';
import type { Wizard } from '../useWizard';

const PRESETS = [
  { time: '02:00', label: 'Overnight', hint: 'Recommended', icon: Moon },
  { time: '12:30', label: 'Midday', hint: 'Over lunch', icon: Sun },
  { time: '19:00', label: 'Evening', hint: 'After work', icon: Sunset },
];

/**
 * Step 3: when the daily backup runs. What the copy promises is what the installer's scheduled task does: a daily trigger with
 * "start when available" (a missed time runs as soon as possible), "wake to run", and an interactive principal (it runs while
 * the person is signed in to Windows). See Install-ResticBackuper.ps1, New-ScheduledTaskSettingsSet.
 */
export function Schedule({ wizard }: { wizard: Wizard }) {
  const choices = wizard.choices!;
  const locale = wizard.host?.locale;
  const [advanced, setAdvanced] = useState(!choices.vss);
  const [draft, setDraft] = useState(choices.schedule);
  const { errors, warnings } = issuesFor(wizard.validation.plan, 'schedule');
  const vssIssues = issuesFor(wizard.validation.plan, 'sources').errors.filter(issue => /vss|open/i.test(issue.code));
  const valid = SCHEDULE_PATTERN.test(draft);
  const { setScheduleDraftValid } = wizard.actions;

  // Next must follow what the field shows, not the last valid time; leaving the page puts the field back to that time.
  useEffect(() => { setScheduleDraftValid(valid); }, [setScheduleDraftValid, valid]);
  useEffect(() => () => setScheduleDraftValid(true), [setScheduleDraftValid]);

  const commit = (value: string) => {
    setDraft(value);
    if (SCHEDULE_PATTERN.test(value)) wizard.actions.setSchedule(value);
  };

  return (
    <div className="screen-stack">
      <div className="time-card">
        <div className="time-card-main">
          <Clock size={22} aria-hidden="true" className="time-card-icon" />
          <label htmlFor="backup-time" className="time-label">Back up every day at</label>
          <input id="backup-time" type="time" className="time-input" value={draft} required step={60}
            aria-invalid={!valid} aria-describedby="time-help"
            onChange={event => commit(event.target.value)} />
        </div>
        <div className="preset-row" role="group" aria-label="Suggested times">
          {PRESETS.map(preset => {
            const Icon = preset.icon;
            const active = choices.schedule === preset.time;
            return (
              <button key={preset.time} type="button" className="preset" aria-pressed={active} onClick={() => commit(preset.time)}>
                <Icon size={16} aria-hidden="true" />
                <span className="preset-text"><strong>{preset.label}</strong><span>{formatTime(preset.time, locale)} · {preset.hint}</span></span>
              </button>
            );
          })}
        </div>
      </div>

      {!valid && <p className="callout is-error" role="alert">Enter a time, like {formatTime('02:00', locale)}.</p>}

      <div id="time-help" className="explain-list">
        <p><strong>Missed a backup because your PC was off or asleep?</strong> Rewindle catches up as soon as it can once you’re signed in, and Windows may wake a sleeping PC to run it.</p>
        <p>Backups run while you’re signed in to Windows, and you can keep working while they do. You can change the time later in Rewindle’s settings.</p>
      </div>

      <IssueList errors={errors} warnings={warnings} />

      <div className="advanced">
        <button type="button" className="advanced-toggle" aria-expanded={advanced} aria-controls="advanced-panel" onClick={() => setAdvanced(value => !value)}>
          <ChevronDown size={16} aria-hidden="true" className="advanced-chevron" />Advanced
        </button>
        {advanced && (
          <div id="advanced-panel" className="advanced-panel">
            <Switch checked={choices.vss} onChange={value => wizard.actions.setVss(value)}
              label={<>Back up files that are open (recommended) <InfoTip label="About backing up open files">Rewindle asks Windows for a snapshot of your drives (Volume Shadow Copy), so files that are open or in use, like a mailbox or a database, are copied in a consistent state.</InfoTip></>}
              description={choices.vss
                ? 'With this on, every folder must be on a drive that isn’t removable and is formatted as NTFS.'
                : 'Files that are in use while a backup runs may be skipped or copied mid-change. Turn this off only to include folders on a USB drive or a drive that isn’t NTFS.'} />
            <IssueList errors={vssIssues} warnings={[]} />
          </div>
        )}
      </div>
    </div>
  );
}
