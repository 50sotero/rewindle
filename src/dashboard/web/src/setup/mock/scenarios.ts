// Sample computers for working on the setup wizard in an ordinary browser (`npm run dev:setup`). Everything here is invented:
// the drives, the folders, the sizes and the installer's answers describe no real PC. The files are reached only through the
// guarded import in ../main.tsx, so the setup program's own build does not contain them.
//
// The plans follow the installer contract's JSON (snake_case), the way the real installer writes them, so the wizard's parser
// (../contract.ts) is exercised by the sample too.

export type ScenarioName =
  | 'fresh' | 'no-second-drive' | 'drivefs' | 'existing-install' | 'legacy-installed'
  | 'unsupported-os' | 'plan-errors' | 'install-failure' | 'uac-declined' | 'key-unreadable';

export const SCENARIOS: readonly ScenarioName[] = [
  'fresh', 'no-second-drive', 'drivefs', 'existing-install', 'legacy-installed',
  'unsupported-os', 'plan-errors', 'install-failure', 'uac-declined', 'key-unreadable',
];

const GB = 1024 ** 3;
const MB = 1024 ** 2;
// The placeholder user name the repository's hygiene checks allow in sample paths.
export const HOME = 'C:\\Users\\you';

export interface SampleVolume {
  root: string; label: string; filesystem: string; drive_type: string; size_bytes: number; free_bytes: number;
  is_system: boolean; same_physical_disk_as_system: boolean; eligible: boolean; ineligible_reason: string | null; ineligible_message: string | null; recommended: boolean;
}

export interface SampleFolder { bytes: number; files: number; placeholderFiles?: number; placeholderBytes?: number; deniedFolders?: number }

export interface Scenario {
  name: ScenarioName;
  os: { caption: string; build: string; x64: boolean; supported: boolean };
  dotnet: boolean;
  volumes: SampleVolume[];
  drivefs: { detected: boolean; my_drive_root: string | null };
  existing: { rewindle: null | { version: string; install_root: string }; legacy_personal_edition: boolean };
  knownFolders: { key: string; path: string; exists: boolean; default_selected: boolean }[];
  defaultSources: string[];
  defaultRepository: string | null;
  /** Folder sizes the sample "measures", by path (lower case). Anything else is a small folder. */
  sizes: Record<string, SampleFolder>;
  /** Folders that exist only for the sample's checks; anything not listed and not under a sample folder is "missing". */
  missing: string[];
  /** Repository folders that already hold other files. */
  nonEmpty: string[];
  install: 'success' | 'failure' | 'declined' | 'key-unreadable';
  environmentErrors?: { code: string; message: string }[];
  /** Folders the "Add a folder…" button offers, one per click, and the backup folders "Choose a different folder…" offers. */
  browseFolders: string[];
  browseRepositories: string[];
}

const volume = (root: string, label: string, sizeGb: number, freeGb: number, extra: Partial<SampleVolume> = {}): SampleVolume => ({
  root, label, filesystem: 'NTFS', drive_type: 'fixed', size_bytes: Math.round(sizeGb * GB), free_bytes: Math.round(freeGb * GB),
  is_system: false, same_physical_disk_as_system: false, eligible: true, ineligible_reason: null, ineligible_message: null, recommended: false, ...extra,
});

const SYSTEM = volume('C:\\', 'Windows', 476, 182, { is_system: true, same_physical_disk_as_system: true });
const DATA = volume('D:\\', 'Data', 465, 318, { same_physical_disk_as_system: true });
const EXTERNAL = volume('E:\\', 'Backup Drive', 1863, 1652, { drive_type: 'removable', recommended: true });
/** The external drive the no-second-drive sample "plugs in" when Setup is asked to look for drives again. */
export const SPARE_DRIVE = EXTERNAL;
const STICK = volume('F:\\', 'USB STICK', 29, 21, {
  filesystem: 'FAT32', drive_type: 'removable', eligible: false,
  ineligible_reason: 'not_ntfs', ineligible_message: 'This drive uses FAT32. Backups need a drive formatted as NTFS.',
});
const OPTICAL = volume('H:\\', 'DVD Drive', 0, 0, {
  filesystem: '', drive_type: 'cdrom', eligible: false, ineligible_reason: 'optical_drive', ineligible_message: 'Discs can’t hold backups that change every day.',
});
const DRIVEFS = volume('G:\\', 'Google Drive', 15, 9.2, {
  filesystem: 'FAT32', eligible: false,
  ineligible_reason: 'not_ntfs', ineligible_message: 'This is Google Drive for desktop. Choose “Google Drive” below to keep backups there.',
});

const KNOWN = ['Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads', 'Favorites'];
const knownFolders = (overrides: Record<string, string> = {}) => KNOWN.map(key => ({
  key, path: overrides[key] ?? `${HOME}\\${key}`, exists: true, default_selected: true,
}));

const size = (gb: number, files: number, extra: Partial<SampleFolder> = {}): SampleFolder => ({ bytes: Math.round(gb * GB), files, ...extra });

const SIZES: Record<string, SampleFolder> = {
  [`${HOME}\\Desktop`.toLowerCase()]: size(2.31, 412),
  [`${HOME}\\Documents`.toLowerCase()]: size(18.6, 9_841, { deniedFolders: 1 }),
  [`${HOME}\\Pictures`.toLowerCase()]: size(64.2, 23_117),
  [`${HOME}\\Music`.toLowerCase()]: size(12.1, 2_904),
  [`${HOME}\\Videos`.toLowerCase()]: size(41.8, 318),
  [`${HOME}\\Downloads`.toLowerCase()]: size(9.4, 1_266),
  [`${HOME}\\Favorites`.toLowerCase()]: { bytes: 14_336, files: 9 },
  [`${HOME}\\Saved Games`.toLowerCase()]: { bytes: Math.round(380 * MB), files: 1_142 },
  [`${HOME}\\Projects`.toLowerCase()]: size(6.8, 48_310),
  ['d:\\photo archive']: size(212, 61_034),
  ['f:\\camera roll']: size(7.2, 1_904),
  [`${HOME}\\OneDrive\\Documents`.toLowerCase()]: size(11.3, 7_102, { placeholderFiles: 214, placeholderBytes: Math.round(3.4 * GB) }),
};

const base: Scenario = {
  name: 'fresh',
  os: { caption: 'Microsoft Windows 11 Home', build: '26200', x64: true, supported: true },
  dotnet: true,
  volumes: [SYSTEM, DATA, EXTERNAL, STICK, OPTICAL],
  drivefs: { detected: false, my_drive_root: null },
  existing: { rewindle: null, legacy_personal_edition: false },
  knownFolders: knownFolders(),
  defaultSources: [...KNOWN.map(key => `${HOME}\\${key}`), `${HOME}\\Saved Games`],
  defaultRepository: 'E:\\Rewindle\\Backups',
  sizes: SIZES,
  missing: [],
  nonEmpty: ['d:\\backups', 'e:\\backups'],
  install: 'success',
  browseFolders: [`${HOME}\\Projects`, 'D:\\Photo Archive', 'F:\\Camera Roll'],
  browseRepositories: ['E:\\Backups\\Rewindle', 'D:\\Backups'],
};

export function scenario(name: ScenarioName): Scenario {
  switch (name) {
    case 'no-second-drive':
      return {
        ...base, name, volumes: [volume('C:\\', 'Windows', 476, 141, { is_system: true, same_physical_disk_as_system: true }), OPTICAL],
        defaultRepository: 'C:\\Rewindle\\Backups', browseFolders: [`${HOME}\\Projects`], browseRepositories: ['C:\\Backups\\Rewindle'],
      };
    case 'drivefs':
      return {
        ...base, name, volumes: [SYSTEM, DATA, DRIVEFS], drivefs: { detected: true, my_drive_root: 'G:\\My Drive' },
        defaultRepository: 'D:\\Rewindle\\Backups', browseRepositories: ['D:\\Backups\\Rewindle'],
      };
    case 'existing-install':
      return { ...base, name, existing: { rewindle: { version: '0.2.0-alpha.1', install_root: 'C:\\Program Files\\ResticBackuper' }, legacy_personal_edition: false } };
    case 'legacy-installed':
      return { ...base, name, existing: { rewindle: null, legacy_personal_edition: true } };
    case 'unsupported-os':
      return {
        ...base, name, os: { caption: 'Microsoft Windows 8.1 Pro', build: '9600', x64: true, supported: false }, dotnet: false,
        environmentErrors: [
          { code: 'os_unsupported', message: 'Rewindle needs 64-bit Windows 10 or Windows 11. This PC runs Windows 8.1.' },
          { code: 'dotnet_missing', message: 'Rewindle needs the Microsoft .NET Framework 4.8, which is not installed.' },
        ],
      };
    case 'plan-errors':
      return {
        ...base, name,
        knownFolders: knownFolders({ Documents: `${HOME}\\OneDrive\\Documents` }).map(folder =>
          folder.key === 'Favorites' ? { ...folder, exists: false, default_selected: false } : folder),
        defaultSources: [`${HOME}\\Desktop`, `${HOME}\\OneDrive\\Documents`, `${HOME}\\Pictures`, `${HOME}\\OneDrive\\Documents\\Taxes`, `${HOME}\\Old Projects`],
        defaultRepository: 'D:\\Backups',
        missing: [`${HOME}\\Old Projects`.toLowerCase()],
      };
    case 'install-failure':
      return { ...base, name, install: 'failure' };
    case 'uac-declined':
      return { ...base, name, install: 'declined' };
    case 'key-unreadable':
      return { ...base, name, install: 'key-unreadable' };
    default:
      return base;
  }
}

export const GIB = GB;
