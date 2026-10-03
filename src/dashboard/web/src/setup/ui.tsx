// Small pieces the wizard's screens share. They follow the dashboard's look (tokens in styles/, the vendored Button) and add
// what a setup needs: the Windows shield, issue lists from the installer, a switch, an info tip and a confirmation dialog.
import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { AlertTriangle, CircleAlert, Info, LoaderCircle } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import type { PlanIssue } from './contract';

/** The Windows security shield that marks a button which asks for administrator permission. */
export function ShieldIcon({ size = 16 }: { size?: number }) {
  return (
    <svg className="shield-icon" width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <defs>
        <clipPath id="shield-clip"><path d="M8 .9 2 3.1v4.3c0 3.6 2.5 6.5 6 7.7 3.5-1.2 6-4.1 6-7.7V3.1L8 .9Z" /></clipPath>
      </defs>
      <g clipPath="url(#shield-clip)">
        <rect className="shield-a" x="0" y="0" width="8" height="8" />
        <rect className="shield-b" x="8" y="0" width="8" height="8" />
        <rect className="shield-b" x="0" y="8" width="8" height="8" />
        <rect className="shield-a" x="8" y="8" width="8" height="8" />
      </g>
      <path className="shield-edge" d="M8 .9 2 3.1v4.3c0 3.6 2.5 6.5 6 7.7 3.5-1.2 6-4.1 6-7.7V3.1L8 .9Z" fill="none" />
    </svg>
  );
}

/** Rewindle's mark, as the dashboard draws it. */
export function BrandMark({ size = 30 }: { size?: number }) {
  return <img className="brand-mark" src="./rewindle-icon.svg" alt="" width={size} height={size} />;
}

export function Spinner({ size = 14, label }: { size?: number; label?: string }) {
  return <LoaderCircle className="spin" size={size} aria-hidden={label ? undefined : true} aria-label={label} role={label ? 'img' : undefined} />;
}

/**
 * The installer's errors and warnings for one screen, in plain sentences. Errors first; they stop the wizard from going on. `action`
 * can put a button beside a finding (the way to fix it, for a finding about a folder the person can take out of the list).
 */
export function IssueList({ errors, warnings, className = '', action }: {
  errors: PlanIssue[]; warnings: PlanIssue[]; className?: string; action?: (issue: PlanIssue) => ReactNode;
}) {
  if (errors.length === 0 && warnings.length === 0) return null;
  return (
    <div className={`issue-list ${className}`}>
      {errors.map((issue, index) => (
        <div key={`e${index}${issue.code}${issue.path ?? ''}`} className="callout is-error"><CircleAlert size={16} aria-hidden="true" /><span>{issue.message}</span>{action?.(issue)}</div>
      ))}
      {warnings.map((issue, index) => (
        <div key={`w${index}${issue.code}${issue.path ?? ''}`} className="callout is-warning"><AlertTriangle size={16} aria-hidden="true" /><span>{issue.message}</span>{action?.(issue)}</div>
      ))}
    </div>
  );
}

export function Callout({ tone, icon, title, children, className = '' }: { tone: 'info' | 'warning' | 'error' | 'success' | 'accent'; icon?: ReactNode; title?: ReactNode; children?: ReactNode; className?: string }) {
  return (
    <div className={`callout is-${tone} ${className}`}>
      {icon}
      <div className="callout-body">
        {title && <strong className="callout-title">{title}</strong>}
        {children && <div className="callout-text">{children}</div>}
      </div>
    </div>
  );
}

export function Switch({ checked, onChange, label, description, disabled }: { checked: boolean; onChange: (value: boolean) => void; label: ReactNode; description?: ReactNode; disabled?: boolean }) {
  const id = useId();
  return (
    <div className="switch-row">
      <div className="switch-copy">
        <label htmlFor={id} className="switch-label">{label}</label>
        {description && <p id={`${id}-description`} className="switch-description">{description}</p>}
      </div>
      <button id={id} type="button" role="switch" aria-checked={checked} disabled={disabled}
        aria-describedby={description ? `${id}-description` : undefined}
        className="switch" onClick={() => onChange(!checked)}>
        <span className="switch-thumb" />
      </button>
    </div>
  );
}

/** A small "i" button that explains a term. The explanation opens on hover, on focus and on click, and Esc closes it. */
export function InfoTip({ label, children }: { label: string; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <span className="info-tip" onMouseEnter={() => setOpen(true)} onMouseLeave={() => setOpen(false)}>
      <button type="button" className="info-tip-button" aria-label={label} aria-expanded={open} aria-describedby={open ? id : undefined}
        onClick={() => setOpen(value => !value)} onFocus={() => setOpen(true)} onBlur={() => setOpen(false)}
        onKeyDown={event => { if (event.key === 'Escape' && open) { event.stopPropagation(); setOpen(false); } }}>
        <Info size={14} aria-hidden="true" />
      </button>
      {open && <span role="tooltip" id={id} className="info-tip-bubble">{children}</span>}
    </span>
  );
}

/** A modal question with two answers. It is a native <dialog>: focus stays inside it and Esc answers "no". */
export function ConfirmDialog({ open, title, children, confirm, cancel, onConfirm, onCancel, danger, confirmIcon }: {
  open: boolean; title: string; children: ReactNode; confirm: string; cancel: string; onConfirm: () => void; onCancel: () => void; danger?: boolean; confirmIcon?: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);
  return (
    <dialog ref={ref} className="setup-dialog" aria-labelledby={titleId} onCancel={event => { event.preventDefault(); onCancel(); }}>
      <h2 id={titleId} className="setup-dialog-title">{title}</h2>
      <div className="setup-dialog-body">{children}</div>
      <div className="setup-dialog-actions">
        <Button className="setup-button" onClick={onCancel} autoFocus>{cancel}</Button>
        <Button variant="primary" className={`setup-button ${danger ? 'is-danger' : ''}`} onClick={onConfirm}>{confirmIcon}{confirm}</Button>
      </div>
    </dialog>
  );
}

/** A bar of how full a drive is, with the part the chosen folders would take shown on top. */
export function SpaceBar({ size, free, adding, label }: { size: number; free: number; adding?: number; label: string }) {
  const used = Math.max(0, size - free);
  const usedShare = size > 0 ? Math.min(1, used / size) : 0;
  const addShare = size > 0 && adding ? Math.min(1 - usedShare, adding / size) : 0;
  return (
    <span className="space-bar" role="img" aria-label={label}>
      <span className="space-used" style={{ width: `${usedShare * 100}%` }} />
      {addShare > 0 && <span className="space-adding" style={{ left: `${usedShare * 100}%`, width: `${Math.max(addShare * 100, 0.8)}%` }} />}
    </span>
  );
}
