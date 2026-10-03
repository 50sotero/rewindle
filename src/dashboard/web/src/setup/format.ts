// Figures and names as the wizard writes them. Sizes use the same binary units as the dashboard (KiB, MiB, GiB), shown the
// way Windows Explorer shows them (KB, MB, GB): a person comparing the wizard with Explorer sees the same numbers.

const UNITS = ['bytes', 'KB', 'MB', 'GB', 'TB', 'PB'];

export function formatBytes(value: number, locale?: string): string {
  let size = Math.max(0, value), unit = 0;
  while (size >= 1024 && unit < UNITS.length - 1) { size /= 1024; unit++; }
  if (unit === 0) return `${Math.round(size).toLocaleString(locale)} ${size === 1 ? 'byte' : 'bytes'}`;
  const digits = size >= 100 ? 0 : size >= 10 ? 1 : 1;
  return `${size.toLocaleString(locale, { minimumFractionDigits: 0, maximumFractionDigits: digits })} ${UNITS[unit]}`;
}

export const formatCount = (value: number, locale?: string) => Math.round(value).toLocaleString(locale);

export const plural = (n: number, one: string, many: string) => `${n.toLocaleString()} ${n === 1 ? one : many}`;

/** The last part of a path, for a folder's name. "D:\" stays "D:". */
export function folderName(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, '');
  const index = Math.max(trimmed.lastIndexOf('\\'), trimmed.lastIndexOf('/'));
  return index >= 0 ? trimmed.slice(index + 1) || trimmed : trimmed;
}

/** "D:\" for "D:\Backups\Rewindle", or "" when the path has no drive letter. */
export function driveRoot(path: string): string {
  const match = /^([A-Za-z]):(?:[\\/]|$)/.exec(path);
  return match ? `${match[1].toUpperCase()}:\\` : '';
}

/** "D:" for "D:\". */
export const driveLetter = (root: string) => root.replace(/[\\/]+$/, '').toUpperCase();

export const samePath = (a: string, b: string) => a.replace(/[\\/]+$/, '').toLowerCase() === b.replace(/[\\/]+$/, '').toLowerCase();

/** True when `child` is `parent` or inside it. */
export function isWithin(child: string, parent: string): boolean {
  const c = child.replace(/[\\/]+$/, '').toLowerCase() + '\\';
  const p = parent.replace(/[\\/]+$/, '').toLowerCase() + '\\';
  return c.startsWith(p);
}

export function joinPath(root: string, name: string): string {
  return root.endsWith('\\') ? root + name : `${root}\\${name}`;
}

/** "02:00" as the reader's clock writes it ("02:00" or "2:00 AM"). */
export function formatTime(hhmm: string, locale?: string): string {
  const [h, m] = hhmm.split(':').map(Number);
  const date = new Date(2026, 0, 1, h, m);
  return date.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' });
}

/** Whether a path is acceptable to send to the installer: absolute, on a drive letter, nothing the command line cannot carry. */
export function isUsablePath(path: string): boolean {
  return /^[A-Za-z]:\\/.test(path) && !/["\u0000-\u001f]/.test(path) && path.length <= 1024;
}
