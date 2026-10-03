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

- The repository password is randomly generated and stored in a Windows
  CurrentUser DPAPI envelope.
- Restic receives it through `--password-command`; it is not placed in task
  arguments or normal logs.
- The scheduled task runs a manifest-hashed runtime from Program Files through
  a kill-on-close native supervisor.
- VSS requires a Highest-level scheduled task. The installer therefore
  restricts the runtime and state trees against normal-user writes.
- The limited dashboard never writes protected configuration directly. Source
  changes require same-user UAC elevation, the shared backup lock, and strict
  path/overlap validation.
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
- The plaintext recovery key is intentionally separate. Anyone with that key
  and the repository can decrypt the backup.
- `google_drivefs_stream` is an explicit storage-mode opt-in. Its synthetic
  FAT32 repository cannot carry the protected NTFS ACL policy, so only encrypted
  Restic objects are allowed there; ProgramData state, the DPAPI envelope,
  recovery key, DriveFS cache, and recovery-tools bundle remain on NTFS.
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
  recovery key internally, invokes only read-only metadata and non-overwriting
  restore operations, and records bounded protected evidence only after all
  Restic, canary, inventory, and sample checks pass.
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
  limits. Standard users approving with another administrator's credentials
  are refused, as for every elevated request.

No backup tool can protect against every threat. Keep an offline recovery-key
copy, test restores, and maintain at least one repository copy that is not
writable by ordinary desktop applications.
