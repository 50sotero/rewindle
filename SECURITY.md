# Security policy

## Supported versions

This project is currently an alpha. Security fixes are applied to the newest
published release only.

## Reporting a vulnerability

Please do not open a public issue for vulnerabilities involving credential
exposure, privilege escalation, path traversal, unsafe ACLs, repository
corruption, or supply-chain verification. Use GitHub's private security
advisory flow for this repository instead.

Include the affected version, Windows version, reproduction steps, expected
impact, and whether any repository password or recovery key was exposed. Never
attach a real repository password, DPAPI envelope, recovery key, private file,
or backup repository.

## Security model

- In a backup with a password (the default), the repository password is
  randomly generated and stored in a Windows CurrentUser DPAPI envelope.
- In a backup with a password, Restic receives it through
  `--password-command`; it is not placed in task arguments or normal logs. A
  backup without a password has no password, no envelope and no password
  command: Restic is started with its `--insecure-no-password` option instead
  (see [Backups without a password](#backups-without-a-password)).
- The scheduled task runs a manifest-hashed runtime from Program Files through
  a kill-on-close native supervisor.
- VSS requires a Highest-level scheduled task. The installer therefore
  restricts the runtime and state trees against normal-user writes.
- The limited dashboard never writes protected configuration directly. Source
  changes require same-user UAC elevation, the shared backup lock, and strict
  path/overlap validation.
- The shared backup lock (`run.lock` in the state folder) can be opened only
  by Administrators and SYSTEM, so a program running with standard rights
  cannot hold it to stop backups and protected changes. The dashboard never
  opens it.
- **Back up now** validates the exact scheduled task, protected launcher,
  principal, working directory, and duplicate-run policy before asking a
  separate UAC-elevated System32 task utility to request it. The dashboard does
  not invoke Restic, Python, or the launcher directly, and accepted requests are
  not reported as successful backups until protected telemetry verifies them.
- **Edit schedule** applies only a reviewed schedule policy through a
  UAC-elevated manager that binds the request to the same user and exact task
  definition, then verifies the installed definition independently. It does
  not start a backup.
- **Cancel backup** targets a cryptographically random, per-run protected event
  after revalidating the current run, process creation identities, user SID,
  and exact task definition. The normal cancel path sends Restic a targeted
  Ctrl-Break and never calls Task Scheduler End or kills an arbitrary PID.
- Every action in the GitHub workflows is pinned to a full commit SHA. The
  release workflow records signed build provenance for the files it builds,
  which `gh attestation verify <file> --repo 50sotero/rewindle` checks (the
  README's "Download and verify" also limits it to release tag builds). The
  releases are not code-signed.
- In a backup with a password, the plaintext recovery key is intentionally
  separate. Anyone with that key and the repository can decrypt the backup. A
  backup without a password has no recovery key.
- `google_drivefs_stream` is an explicit storage-mode opt-in. Its synthetic
  FAT32 repository cannot carry the protected NTFS ACL policy, so only Restic
  objects are allowed there (encrypted with the backup's password, or, in a
  backup without a password, with Restic's empty password, which anyone who can
  read the folder can use); ProgramData state, the DPAPI envelope and recovery
  key (in a backup with a password), DriveFS cache, and recovery-tools bundle
  remain on NTFS.
- DriveFS relocation uses a nonce-bound stage and protected commit-manifest
  digest rather than weakening ACL validation globally. Promotion requires exact
  path/size/SHA-256 inventory agreement plus Restic identity, history, and
  structural verification.
- The optional DriveFS cloud verifier is a Highest/Interactive, verification-only
  task. It takes the protected run lock, uses only manifest-hashed Program Files
  code and hash/ACL-bound ProgramData rclone assets, and checks an exact
  read-only API inventory plus a direct-cloud canary restore. It does not use
  `PATH`, a user-writable helper, a local mirror, or repository write commands.
- Cloud proof is schema-2, immutable-run-backed evidence bound to the active
  plan, generation, repository path/ID, and latest successful snapshot. The
  dashboard rejects legacy mirror, pre-activation, incomplete, or stale proof,
  and its diagnostic export redacts paths and identity/hash fields.
- Change-anomaly acknowledgement remains exact and non-destructive, and its
  maintenance hold continues to gate future deletion/retention policy. It is not
  represented as an upload pause: a live DriveFS repository may already be
  synchronizing before the operator reviews it.
- Recovery Readiness never gives the dashboard a repository credential. A
  representative restore drill crosses one same-user UAC boundary through a
  nonce-, SID-, plan-, generation-, and config-hash-bound request. The elevated
  protected manager derives a new non-overlapping target, uses the restricted
  recovery key internally (a backup without a password has no key, and its
  drill uses none), invokes only read-only metadata and non-overwriting
  restore operations, and records bounded protected evidence only after all
  Restic, canary, inventory, and sample checks pass.
- Clean-up of old backups is off until the person turns it on, and it never
  runs on a schedule. Each step goes through the UAC-elevated
  `Manage-Retention.ps1`, bound to the user's SID, plan, generation and
  configuration hash. Listing what would go is a `--dry-run --no-lock` read; a
  removal names the exact list the person saw (the preview file's SHA-256 and
  a digest of its backup IDs), removes those IDs only, and only after a
  verified backup with no open change review, no pending journal and an
  identical fresh listing. The latest verified backup, the only checked
  backup of each kept period and the last backup before an unconfirmed change
  are always kept. The setting is bound to the plan, the repository and the
  installation (a random value the installer writes on every install), so
  every install, update or reinstall turns it off, while a change of folders
  or of the backup location does not. The dashboard and the clean-up helper
  trust the clean-up records only when only Administrators and SYSTEM can
  change them and the state folder that holds them.
- The guided restore asks Windows once per restore session instead of once per
  step. The elevated `Manage-Restore.ps1 -Operation session` serves any number
  of snapshot and folder listings and at most one restore, then ends; it also
  ends after 10 idle minutes, after 60 minutes in all, when the dashboard exits
  or closes Restore, when the protected plan changes, and on any protocol
  violation. Its named pipe allows only the requesting account (network logons
  are denied), has one instance and is created first or not at all, so a
  squatted name ends the session. The broker serves only the dashboard process
  that asked (Windows' client process ID and token SID) after it proves a
  random session token whose hash alone is on the elevated command line, and
  the dashboard sends nothing until Windows names the pipe's server as the
  process it started. Every request goes through the same validation, run
  lock, plan, journal, runtime-manifest, destination (no UNC, link, DOS alias,
  overwrite or overlap) and result checks as a single elevated request. Threat
  model: malware running as the same user can already drive the user's own
  dashboard, read its memory and start the same requests; an approved session
  gives it nothing beyond what that session may do: listings and one
  non-overwriting restore into a new or empty folder, within the session's
  limits. A session can also look for a file name in every backup (Find a
  file): a read-only `restic find` without a repository lock, run under the
  run lock for at most 20 seconds a page (the broker kills it at 35, and the
  job object takes Restic with it), with the text checked against the same
  rules by the page, the dashboard, the broker and restore.py and passed to
  Restic only as one pattern after `--`. It reads names, sizes and dates that
  folder listings already show, including those of files deleted since, and
  is refused while a backup runs or is about to start; there is no search
  outside a session, so the legacy engine has none. Standard users approving
  with another administrator's credentials are refused, as for every elevated
  request.

## Backups without a password

A password is the recommended default. Setup's Password page, and
`-RepositoryAccess no_password` in an unattended install, let a person start
new backups without one. Restic cannot write unencrypted backups: "no password"
means the backups are encrypted with Restic's empty password, and Rewindle
opens them with Restic's `--insecure-no-password` option on every command.
Anyone who can read the backup folder can do the same.

- **Confidentiality.** Anyone who can open the backup folder can restore every
  backed-up file, including saved sign-ins. Confidentiality then rests only on
  who can read the folder. On a local drive of this PC that is the Windows
  folder permissions Rewindle sets (your account, Administrators and SYSTEM).
  They do not travel with a drive, so a lost or removed USB drive, or a drive
  read on another PC, is open. A folder in Google Drive is open to anyone who
  can sign in to that Google account on any device that syncs it, to anyone it
  is shared with, and through Google Drive's version history and trash; the
  synthetic drive Google Drive for desktop shows carries no Windows
  permissions. Any copy of the folder is equally open.
- **Integrity.** Anyone who can write to the folder can add or change backups
  in a way Restic's and Rewindle's checks accept, so a verified backup shows
  that it is consistent, not that nobody changed it. With a password, a person
  who can write to the folder can still damage or delete backups, but cannot
  make ones that Restic accepts.
- **No key.** There is no recovery key and no saved password for such a
  backup. Rewindle creates, reads, rewrites and reports neither, and leaves
  any file an older installation left at those paths exactly as it is.
- **What does not change.** Rewindle's program and state protections, the
  Windows-approval steps for protected changes, the run lock and the
  verification of every backup (the restore test file, the structure checks
  and the Google Drive check) work as before. They protect Rewindle on this PC,
  not what is in the backup folder. Programs running as your own Windows
  account can already reach a backup with a password through its recovery key,
  a plain-text file in your profile folder, so a password does not protect
  against them either.
- **A choice made once.** Rewindle never switches a backup between the two
  ways. Existing backups keep the way they were made, and Setup does not ask
  about a location that already holds backups. If backups stop matching what
  Rewindle recorded for them, because they were changed outside Rewindle,
  Rewindle stops with a message instead of carrying on: Setup refuses to
  continue them, a backup run ends as `repository_access_mismatch`, and the
  recovery-readiness check says whether the backups now open without a
  password or now ask for one. See
  [Switching an existing backup](#switching-an-existing-backup).

## Switching an existing backup

Rewindle never switches a backup from a password to no password, or the other
way round, and it builds no way to do so. Restic can, with its own commands,
but then Rewindle has to be set up again for the backup as it now is, and no
switch makes the backup's earlier copies private again. In every case the safe
way is new backups: set Rewindle up with a new, empty backup location and the
choice you want, and keep the old backups until you no longer need them. Read
this whole section before you switch anything.

**From a password to no password.** Choose a time when no backup is running.
As soon as the key Rewindle uses is gone, Rewindle's own backups to that
location fail until you finish step 5.

1. Open PowerShell in the recovery-tools folder, which has the same
   `restic.exe` Rewindle uses, and give Restic the current password in that
   window only: the value on the `Password:` line of
   `ResticBackuper-RecoveryKey.txt`. Paste it at the prompt, so it never goes
   on a command line or into the command history:

   ```powershell
   $env:RESTIC_PASSWORD = [System.Net.NetworkCredential]::new('', (Read-Host 'Backup password' -AsSecureString)).Password
   ```

2. Replace the key with one that has no password. Do not add
   `--insecure-no-password` to this command: Restic refuses that option next to
   any password. `--new-insecure-no-password` is a different option, and it is
   the one that sets the new password to empty.

   ```powershell
   .\restic.exe --repo 'X:\Path\To\Repository' key passwd --new-insecure-no-password
   ```

3. Clear the password from the window, then check that the backups open
   without one. Restic also refuses `--insecure-no-password` while
   `RESTIC_PASSWORD_FILE` or `RESTIC_PASSWORD_COMMAND` is set, so clear those
   too if you use them.

   ```powershell
   Remove-Item Env:\RESTIC_PASSWORD
   .\restic.exe --insecure-no-password --repo 'X:\Path\To\Repository' snapshots
   ```

4. Remove Rewindle: Settings > Apps > Installed apps > Rewindle > Uninstall, or
   Uninstall in Rewindle Setup. Your backups, the recovery tools and
   Rewindle's saved state are kept. (Setup's Reinstall removes it too, but then
   carries on in the wizard, which cannot take part in step 5.)
5. Set Rewindle up again from a Command Prompt, in the folder you extracted the
   release ZIP to, and say that these backups have no password. It asks for
   the backup folder (it suggests the one your backups are in) and the folders
   to back up, as usual. Setup's records are from before the switch, so it may
   first warn that the backups "were made with a password".
   Setup then checks that the backups really open without a password, goes on
   if they do, and stops without changing anything if they do not.

   ```bat
   Install.cmd -RepositoryAccess no_password
   ```

Keys only wrap the backup's one master key: changing them re-encrypts nothing.
So every copy of the backup folder made while it has no password stays readable
by anyone who has it, for good: in Google Drive's version history, on a lost
USB drive. Going back to a password later does not close those copies. The old
recovery key still opens the earlier copies, the ones made while the backup had
a password. Rewindle leaves the old saved password and recovery key where they
are and never reads them, so decide on purpose whether to keep that key.

`key add --new-insecure-no-password` in step 2 adds the empty key and leaves the
password key working. Rewindle keeps treating the backup as one with a
password (it still opens with the saved password, and the dashboard still says
"Your backups are encrypted") until the password key is removed. `key list`
shows each key with its ID and marks the one you opened the backup with, and
`key remove <id>` removes one. Restic refuses to remove the key it opened the
backup with, so open the backup without a password, as in step 3, to remove
the password key.

**From no password to a password.** Rewindle cannot take over a password you
add with Restic: it makes and keeps its own password, and its recovery key, when
it starts new backups, and has no way to be given one. Adding a password does
not protect what was already copied either: the master key stays the same, so
anyone who has a copy made while the backup had no password can read it, and
can read what is backed up afterwards as soon as they can read the new files.
Start new backups with a password in another place instead.

**If a backup is switched outside Rewindle.** Rewindle does not follow. A
backup made without a password that now asks for one ends as
`repository_access_mismatch` ("These backups now ask for a password that
Rewindle doesn't have, usually because they were changed outside Rewindle.
Rewindle can't carry on with them. To keep backing up, start new backups in
another place."), and the recovery-readiness check says "These backups now ask
for a password, usually because one was added outside Rewindle. To keep backing
up, start new backups in another place." A backup with a password whose
password key was removed, so that it now opens without one, ends with
"Rewindle couldn't unlock your backups with its saved password", and the
readiness check then says "These backups now open without a password, usually
because it was removed outside Rewindle. To keep using them, see Switching an
existing backup in SECURITY.md on Rewindle's GitHub page, or start new backups
in another place." Either way, follow the steps above for the backups as they
now are, or start new backups in another place.

No backup tool can protect against every threat. In a backup with a password,
keep an offline recovery-key copy. Whatever you choose, test restores, and
maintain at least one repository copy that is not writable by ordinary desktop
applications.
