// How the backups are opened, and the few words that depend on it. A backup made with a password (the default, and every backup made
// before the choice existed) is encrypted and opened with a password Rewindle keeps; a backup made without one is opened by anyone who
// can read its folder. The host sends which one it is (`repository.repositoryAccess`); the page words what it says about protection
// from that, and says nothing either way when it is not known (the configuration could not be read, or names something this version
// does not know), because a claim of protection that is not true is worse than no claim.
// Erasable TypeScript only, with no imports: tests/test_dashboard_repository_access.py runs this file with Node as it is.

export type RepositoryAccess = 'password' | 'no_password';

/** What the host sent, read strictly: only the two exact words count. Anything else (a missing field, null, another text, a newer host's word) is null. */
export const repositoryAccessOf = (value: unknown): RepositoryAccess | null => value === 'password' || value === 'no_password' ? value : null;

/** What the footer's label says, as a sentence, for a backup without a password. It is the label's accessible name and its tooltip. */
export const NO_PASSWORD_NOTE = 'You chose to back up without a password, so anyone who can open the backup folder can restore these files.';

/** What the Save the backup step of a backup run does, in the words that are true for how these backups are opened. */
export const saveStepExplanation = (access: RepositoryAccess | null): string => access === 'password'
  ? 'Saves an encrypted copy of your files as one backup.'
  : 'Saves a copy of your files as one backup.';
