# Dashboard ↔ engine contract

This document lists every interaction between the Rewindle dashboard (`src/dashboard`) and a backup engine, and states how
each of the two engines the dashboard supports provides it:

- **Rewindle engine**: the public engine in this repository (`src/`, installed by `installer/`). Its installed identities
  use the `ResticBackuper` name.
- **Legacy personal edition**: the earlier personal engine the dashboard was first written against. Its installed
  identities use the `ResticPersonalBackup` name. The dashboard keeps supporting existing installations of it.

In the tables below `<P>` stands for the engine's product name (`ResticBackuper` or `ResticPersonalBackup`),
`<install>` for `%ProgramFiles%\<P>` and `<state>` for `%ProgramData%\<P>`. Every name is owned by one class,
`src/dashboard/EngineProfile.cs`; no other dashboard file names an engine.

## 1. Engine selection

| Step | Behaviour |
| --- | --- |
| Probe | For each engine, `File.GetAttributes(<install>\backup-config.json)`, the same read-only test `SourceConfiguration.Load` uses. A missing file or a folder of that name is *absent*; a file is *present*; any other error (access denied, device error, an unusable Program Files folder) is *indeterminate* and counts as installed, so an unreadable root is never passed over for the other engine (fail closed). |
| Choice | `--engine rewindle` or `--engine legacy` wins. Otherwise the first installed engine in the order Rewindle, legacy. With neither installed, Rewindle is chosen and the page shows **Engine not installed** with both searched paths. |
| Timing | Once, in `Program.Main`, before any engine path is read, the single-instance mutex is taken or the administrator-launch refusal runs. |
| Install root | `Path.GetFullPath(<Program Files>\<P>)`; an empty or relative Program Files folder throws (unchanged validation). |
| State root | `<state>`, unless `--state-dir` is given (telemetry only; see section 7). |
| Version | Rewindle: the installer's `<install>\VERSION`, bounded, read without following a link, accepted only as a semantic version. Legacy: not recorded by that edition. Shown on the settings page, in the setup report and as `engine_profile`, `engine_name` and `engine_version` in every diagnostic bundle manifest. |

## 2. Identities

| Identity | Rewindle engine | Legacy personal edition |
| --- | --- | --- |
| Install root, protected state | `%ProgramFiles%\ResticBackuper`, `%ProgramData%\ResticBackuper` | `%ProgramFiles%\ResticPersonalBackup`, `%ProgramData%\ResticPersonalBackup` |
| Backup task (Task Scheduler root folder) | `ResticBackuper` | `ResticPersonalBackup` |
| Task launcher (the task's only action) | `<install>\ResticBackuperTaskLauncher.exe` | `<install>\ResticBackupTaskLauncher.exe` |
| Dashboard logon task | `ResticBackuperDashboard` (registered by the installer) | `ResticPersonalBackupDashboard` (that edition's own deployment) |
| Dashboard executable | `<install>\ResticBackuperDashboard.exe` | `ResticBackupDashboard.exe` in that edition's dashboard folder |
| Google Drive verification task (not queried by the dashboard) | `ResticBackuperGoogleDriveSync` | `ResticPersonalBackupGoogleDriveSync` |
| Cloud-verification folder | `%ProgramData%\ResticBackuperCloudVerification` | `%ProgramData%\ResticPersonalBackupCloudVerification` |
| Latest direct cloud proof | `…CloudVerification\evidence\latest-verification.json` | `…CloudVerification\latest-verification.json` |
| Failure record of a check that stopped (shown only when newer than the proof's `verified_utc` and about the installed plan) | `…CloudVerification\evidence\latest-failure.json` | None; that edition's check writes none |
| Protected recovery tools for a streamed Google Drive repository (a local repository keeps them beside it, as the plan's `recovery_tools_directory` says) | `%ProgramData%\ResticBackuperRecoveryTools` | None; only the plan-configured folder |
| Recovery-drill targets | `%ProgramData%\ResticBackuper-RestoreDrills\drill-<nonce>` | `%ProgramData%\ResticPersonalBackup-RestoreDrills\drill-<nonce>` |
| Retired per-user mirror status | `%LOCALAPPDATA%\ResticBackuperGoogleDriveSync\status.json` | `%LOCALAPPDATA%\ResticPersonalBackupGoogleDriveSync\status.json` |
| Dashboard presentation store | `%LOCALAPPDATA%\ResticBackuperDashboard` | `%LOCALAPPDATA%\ResticPersonalBackupDashboard` |
| Isolated presentation store (`--isolated-presentation-store`) | `%TEMP%\ResticBackuperBeautifulUI`, `%TEMP%\ResticBackuperDashboardBeautifulUIWebView2` | `%TEMP%\ResticPersonalBackupBeautifulUI`, `%TEMP%\ResticPersonalBackupBeautifulUIWebView2` |
| Single instance | `Local\ResticBackuperDashboard.Instance`, `.Show` (and `.Presentation.Instance`, `.Presentation.Show`) | `Local\ResticPersonalBackupDashboard.Instance`, `.Show` (and the presentation pair) |
| Cancel event | `Local\ResticBackuper.Cancel.<64 hex>` | `Local\ResticPersonalBackup.Cancel.<64 hex>` |
| Request domains | `ResticBackuper.SourceRequest.v1`, `.RestoreRequest.v2`, `.RepositoryRequest.v1`, `.RepositoryRecoveryRequest.v1`, `.ScheduleRequest.v1`, `.BackupControlRequest.v1`, task fingerprint `.TaskXml.v1` | the same suffixes with `ResticPersonalBackup.` |
| Result and report schemas | `ResticBackuper.SnapshotList.v1`, `.SnapshotTree.v1`, `.RestoreReport.v1`, `.RecoveryHealth.v1`, `.AnomalyReview.v1`, `.FileSearch.v1` (a restore session's file search, section 9); diagnostics `ResticBackuper.Diagnostics.v1` | the same suffixes with `ResticPersonalBackup.`; no `.FileSearch.v1` (no session) |
| Manager scripts | `Manage-Sources.ps1`, `Manage-Schedule.ps1`, `Manage-Backup.ps1`, `Manage-Repository.ps1`, `Manage-Restore.ps1` under `<install>` | same |
| Python | `<install>\Python\python.exe` with `-E -S -B` and scripts under `<install>` | same |
| Restore approval session (section 9) | Request domain `ResticBackuper.RestoreRequest.v3`, protocol `ResticBackuper.RestoreSession.v1`, pipe `\\.\pipe\ResticBackuper.RestoreSession.<64 hex>`, capability document `<install>\engine-capabilities.json` (`ResticBackuper.EngineCapabilities.v1`) | None: one elevated request per step |
| Clean-up of old backups (section 10) | Manager `<install>\Manage-Retention.ps1` (helper `retention.py`), request domain `ResticBackuper.RetentionRequest.v1`, records `ResticBackuper.RetentionPolicy.v1`, `.RetentionPreview.v1`, `.RetentionHistory.v1`, advertised in `engine-capabilities.json` | None: the card says clean-up isn't available and nothing is read |

## 3. Protected actions (elevated managers)

Every manager is started as `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile
-NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File <install>\<manager>` with `Verb = runas` (one UAC prompt
per request), working directory `<install>`. Each request carries a fresh 64-hex nonce and `-ExpectedUserSid`. The manager
refuses to run unelevated, from any other path, for another SID, or with a result path that is not
`<state>\<Results folder>\<nonce>.json`. It creates the result once (`CreateNew`) with owner Administrators, a protected
DACL, full control for SYSTEM and Administrators and read/execute only for the requesting user and OWNER RIGHTS. The
dashboard rejects a result unless the state root is named `<P>`, the result folder and file names match, no component is
a reparse point, those ACLs hold on the state root, the result folder and the open result handle, the size is within its
limit, and every binding field below equals the request. A digest is SHA-256 over UTF-8 (no BOM) of the listed fields
joined by LF. The dashboard builds every elevated command line, makes every nonce and checks these ACLs (also on the
restore and relocation progress files) in one place, `src/dashboard/ElevatedRequestSecurity.cs`, so every manager and
helper is held to the same rules.

| Action | Manager arguments | Digest fields (after the domain and SID) | Result folder, fields the dashboard binds | Rewindle | Legacy |
| --- | --- | --- | --- | --- | --- |
| Add / remove a protected folder | `-Add <path>` or `-Remove <path>`, `-ResultPath`, `-RequestNonce` | lower-case action, canonical path, nonce | `SourceManagerResults`: `schema_version` 1, `request_nonce`, `request_digest`, `request_user_sid`, `action`, `ok`; on success `plan_id`, `previous_config_generation` = current, `config_generation` = current + 1, `path` = the canonical path | **Ported** (was missing; see section 8) | Yes |
| List snapshots, list a tree, restore, recovery drill | `-Action list_snapshots\|list_tree\|restore\|restore_drill`, `-IncludesBase64`, `-ExpectedConfigSha256`, `-ExpectedPlanId`, `-ExpectedConfigGeneration`, `-AllowLegacyUnbound 0\|1`, `-ResultPath`, `-RequestNonce`, `-RequestDigest`, optional `-SnapshotId`, `-TreePath`, `-Target` | action, config SHA-256, plan, generation, legacy flag, snapshot, tree path, target, includes SHA-256, nonce | `RestoreManagerResults` (+ `<nonce>.json.progress.json`): binding fields, `ok`, `backend_exit_code`, `payload` (`SnapshotList.v1`, `SnapshotTree.v1` or `RestoreReport.v1`), drill evidence (`history_recorded`, canary and sample fields) | Yes | Yes |
| Restore approval session: any number of snapshot and folder listings and file searches, and at most one restore (section 9). `find_files` is served only here; a single request for it is refused | `-Operation session`, `-ExpectedConfigSha256`, `-ExpectedPlanId`, `-ExpectedConfigGeneration`, `-ResultPath`, `-RequestNonce`, `-RequestDigest`, `-DashboardProcessId`, `-PipeName`, `-SessionTokenSha256`, `-IdleTimeoutSeconds`, `-LifetimeSeconds`, `-ConnectTimeoutSeconds` | `session`, config SHA-256, plan, generation, dashboard PID, pipe name, session-token SHA-256, idle, lifetime and connect timeouts, nonce (domain `RestoreRequest.v3`) | Results on the pipe, each the document above bound to the session's nonce and digest; `RestoreManagerResults\<nonce>.json` records how the session ended (`close_reason`, `operations`) | Yes (advertised in `engine-capabilities.json`) | No |
| Clean-up of old backups: turn on or off, list what would go, remove a confirmed list (section 10) | `-Action configure\|preview\|apply`; only the arguments the action takes of `-Enabled`, `-KeepDaily`, `-KeepWeekly`, `-KeepMonthly`, `-ExpectedPreviewSha256`, `-ExpectedRemoveSetSha256`, `-ExpectedRemoveCount`, `-ConfirmEarlierChanges`; always `-ExpectedUserSid`, `-ExpectedConfigSha256`, `-ExpectedPlanId`, `-ExpectedConfigGeneration`, `-ResultPath`, `-RequestNonce`, `-RequestDigest` | action, config SHA-256, plan, generation, enabled, daily, weekly, monthly, preview SHA-256, remove-set SHA-256, remove count, earlier-changes confirmation, nonce (an argument the action does not take counts as empty; domain `RetentionRequest.v1`) | `RetentionManagerResults` (+ progress): binding fields, `ok` (true exactly when the exit code is 0), `state`, `refusal_code`, `policy_sha256`, `preview_sha256`, `remove_count`, `removed_count`, `removed_set_sha256`, `removal_unverified`, `prune_completed`, `check_completed`, `check_unfinished`, `history_recorded` | Yes (advertised in `engine-capabilities.json`) | No |
| Move the repository | `-Relocate -NewRepository -ExpectedCurrentRepository -ExpectedConfigSha256 -ResultPath -RequestNonce -RequestDigest` | `relocate`, current, new, config SHA-256, nonce | `RepositoryManagerResults` (+ progress): binding fields, `changed`, `old_repository_retained`, optional generation transition | Yes | Yes |
| Recover an interrupted move | `-Recover -ExpectedJournalSha256 -ResultPath -RequestNonce -RequestDigest` | `recover`, journal SHA-256, nonce | `RepositoryManagerResults`: binding fields, `plan_id`, generations, repositories | Yes | Yes |
| Change the schedule | `-Cadence -Time [-Days] -StartWhenAvailable -WakeToRun -AllowStartOnBatteries -StopIfGoingOnBatteries -Enabled -ExpectedCurrentFingerprint -ResultPath -RequestNonce` | `apply`, baseline task fingerprint, cadence, time, days, the five flags, nonce | `ScheduleManagerResults`: binding fields, `backup_started` false, `installed_fingerprint`, `schedule` (8 keys); the dashboard then re-reads the task and requires the same fingerprint | Yes | Yes |
| Cancel the running backup | `-Action Cancel -RunId -ExpectedWrapperPid -ExpectedTaskFingerprint -ResultPath -RequestNonce` | `cancel`, run ID, wrapper PID, task fingerprint, nonce | `BackupManagerResults`: binding fields, `run_id`, `requested`, `already_finished` | Yes (preflight phases added; section 8) | Yes |
| Back up now | `%SystemRoot%\System32\schtasks.exe /Run /TN <backup task>` with `runas`, only after the task XML validates, is enabled and allows a manual start | — | — | Yes | Yes |

Elevated Python helpers, each `<install>\Python\python.exe -E -S -B <install>\<script> --config <install>\backup-config.json
--expected-config-sha256 --expected-plan-id --expected-generation --expected-user-sid` with `runas`; the dashboard
re-inspects readiness afterwards instead of reading a result file:

| Helper | Extra arguments | Exit codes | Rewindle | Legacy |
| --- | --- | --- | --- | --- |
| `credential_repair.py` | — | 0, 2 | Yes | Yes |
| `stale_lock_repair.py` | — | 0, 3 (locks remain), 2 | Yes | Yes |
| `key_rotation.py` | — | 0, 3, 2 | Yes | Yes |
| `anomaly_review.py` | `--expected-run-id`, `--expected-snapshot-id`, `--expected-evidence-sha256` (SHA-256 of `last-success.json`) | 0, 2 | Yes, scope `anomaly_review_acknowledgement` | Yes, scope `offsite_promotion` |

**Restore target (Rewindle `restore.py`).** A target inside Windows, either Program Files folder or ProgramData is refused
with `restore target must not be inside a Windows or program folder`, compared after short names are expanded. No
environment variable is consulted, because the requesting user can set them for the elevated process: Windows and the
Program Files folders come from the known-folder API, and ProgramData from the machine's `ProfileList\ProgramData`
record with `%SystemDrive%` taken from the Windows folder's drive (the known-folder API would expand it from the caller's
environment). The recovery drill's own folder under ProgramData is the one exception. The target is opened one folder at
a time from the drive root, each relative to the handle of the folder above it and without following links, and is held
open without delete sharing until the restore ends, so neither it nor any folder above it can be renamed. Restic's
`--target` is a new hidden folder `<target>\.rewindle-restore-<16 hex>` created with a protected DACL for SYSTEM and
Administrators only (the user is added only when `restore.py` runs unelevated). Afterwards every restored item gets,
through its own handle, the DACL it would inherit in the target, deepest first (a folder's own DACL is written after
everything inside it), and is moved into the target by handle without replacing anything. Links are never followed,
permissions Restic restored as protected are kept, and a file with a second name (a hard link) is left as it is, so after
an elevated restore it keeps the restore folder's administrator-only entries. A move that fails with access denied or a
sharing violation is tried again for a few seconds. An item that still cannot move stays in that folder, which is then
left visible and open, and the report is `partial` with an `error` that names the folder and says whether a name appeared
in the target meanwhile or another program was using the item. The report's `target` is still the chosen folder. If
`restore.py` is stopped during the restore (a power cut, for example), the hidden folder stays in the target with its
administrator-only DACL; nothing removes it automatically yet (`src/RECOVERY.md` says how to delete it). Other new
refusals: `restore target changed while it was being prepared`, `restore target must be on a drive that keeps folder
permissions` (a drive without permissions that can hold links), `restore target path is too long`, `restore target
contains an invalid folder name`, `Windows and program folders could not be identified` and `the current Windows account
could not be identified` (only when `restore.py` runs unelevated). The dashboard words all of them plainly and refuses
the same system folders at the destination step for both profiles; the legacy engine's own `restore.py` does neither.

**Chosen items (Rewindle `restore.py`).** Each `--include` is one item's path as Restic lists it (inside the source with
`--source`, or inside the folder that a `--snapshot <id>:<folder>` selector names), taken literally: `restore.py` writes
every `[` as `[[]` for Restic. It refuses more than 64 includes (`at most 64 include patterns are allowed`), an empty
one (`include patterns must not be empty`) and one with a NUL or more than 1024 characters (`an include pattern is
invalid or too long`). The dashboard (`RestoreManagerLauncher.ValidateRequestFields`, which every restore request goes
through, the older restore window's typed paths included) and `Manage-Restore.ps1` refuse those first, in their own
words, so these three never reach a person through the dashboard, which does not word them. Any other include that is not `/` and then each name, with `/`
between names (so no `\`, no empty, `.` or `..` name, and no `*` or `?`), is refused with an error that starts `an
include must be one item's path`; no drive letter is required. Without `--report` every refusal comes before the
configuration is read or Restic is started, so nobody is asked for the password first. With `--report` it comes after
the report is bound to the snapshot and before anything is restored, so the protected manager, whose Restic reads the
stored credential, accepts the report and passes the refusal on. The manager records that `error` report in
`restore-history.json` like any other restore; when the history already holds 50 entries, the oldest manual restore
entry makes room, and a recovery drill entry goes only when no manual one is left, so restores never push out the drill
entries `recovery_health.py` reads. Restic ends a restore that matched nothing with exit code 0, so after it exits 0
every chosen item is looked for (by `lstat`) in the target, or in the restore folder for an item below a name the
hand-over left there. When one is missing the report is `partial`, not verified, with `restic_exit_code` 0 and the error
`Restic finished without restoring every chosen item (N of M missing); the alternate target was retained for
inspection`; when the hand-over also left items, its plain message gets a plain sentence counting the missing ones
instead. The dashboard words that refusal and the error plainly, and reads N and M to say whether none or only some of
the chosen items came back.

**Moving the repository (Rewindle `Manage-Repository.ps1`).** The stages `.restic-repository-<nonce>.staging` and
`.restic-recovery-<nonce>.staging` are held open (list access, read and write sharing, no delete access, no delete
sharing) from their creation until they have their final names, so neither a stage nor any folder above it can be
renamed or swapped for a junction during the copy, the ACL reset or the checks. A held folder's path within its volume,
its volume serial and, when Windows gives one, its drive-letter path must equal the checked path. Promotion reopens the
stage with delete access, requires the same file ID and renames it through that handle without replacing anything; the
promoted folders stay held until the move is committed. Rollback and recovery hold a folder and prove its file ID before
emptying it. Before the journal of a move to DriveFS is written, the same steps run on a throwaway folder
`.resticbackuper-hold-<32 hex>.tmp` in the destination's parent (hold, final-path check, rename through the handle to
`.resticbackuper-hold-<32 hex>.commit`, hold again by file ID under the new name); if any fails, the move is refused with `Google Drive could not keep a folder in
place while it was renamed, so the backup location was not moved and nothing was changed. ...` before anything is
copied. Only Restic's own files are copied: `config`, 64-hex files in `keys`, `index` and `snapshots`, and 64-hex
files in `data\<two hex>` that start with those two digits; `locks` is skipped as before. Anything else is left in the
current repository, refused in a local stage or destination (`The copy of the backup holds something that is not part of
the backup: <relative path>`) and ignored in a DriveFS folder. The result documents are unchanged. The legacy engine's
`Manage-Repository.ps1` does neither.

## 4. Task Scheduler contract

Read with `schtasks.exe /Query /TN "<backup task>" /XML` (as the user, 15 s, 256 K characters) and the
`Schedule.Service` COM object for state, next run, last run and the last run's result (`LastRunTime` and `LastTaskResult`,
each read on its own and best effort: a value that cannot be read is left unknown and never fails the schedule read; a
`LastRunTime` before 2000 means the task never ran). The backup alerts read the launcher's exit codes (64-66: the program is
not as installed; 75: busy; 67-74 and 76-78: it could not start or watch the run) and Task Scheduler's own results from
`LastTaskResult`, so both engines' launchers must keep these meanings. The XML
must have exactly one `Exec` action whose command is the launcher, no arguments, working directory `<install>`; exactly
one principal that resolves to the current user, with `InteractiveToken` and `HighestAvailable`; `URI` = `\<backup task>`;
`IgnoreNew`, `ExecutionTimeLimit` `PT0S`, priority 7, no idle or network conditions, hard terminate and on-demand start
allowed; exactly one daily or weekly calendar trigger. The fingerprint is SHA-256 of `<TaskXml domain>` + LF + the
canonical document element. The Rewindle installer registers exactly this shape. Both engines' tasks set
`StartWhenAvailable`; with it, a slot that passed while the PC was off, asleep or signed out is shown as catching up rather
than overdue until the task has run since the slot, or for at most 45 minutes after the sign-in or wake.

## 5. State the dashboard reads (read-only, never written)

| File | Fields the dashboard uses | Rewindle | Legacy |
| --- | --- | --- | --- |
| `<install>\backup-config.json` (≤ 1 MiB, read with full sharing, retried once) | `plan_id` (canonical UUID), `config_generation` (> 0), `cloud_placeholder_policy`, `repository`, `state_directory`, `sources` (canonical, unique), `source_identities` (one 8-hex serial per source), `canary_file` (inside a source), `topology_paths`, `recovery_tools_directory` (source-picker guard only); for the Backup location card only, and never a reason to refuse the plan: `minimum_free_gib` (the reserve: a number 0 or more, converted to bytes as the engine does; anything else is unknown) and `repository_storage_mode` (`google_drivefs_stream` or anything else, read as a local drive); `repository_access` (`password`, `no_password` or absent, which means `password`; anything else is unknown and the page claims nothing about encryption either way; section 11) | Yes (written by the installer and `Manage-Sources.ps1`) | Yes |
| `<install>\runtime-manifest.json`, `VERSION` | Diagnostics (redacted) and the engine version; the manifest's `installation_id` (a new random value the installer writes on every install, kept by the managers that rewrite the manifest) binds the clean-up setting (section 10) | Yes | Manifest only |
| `<install>\engine-capabilities.json` (≤ 16 KiB, no link, strict UTF-8 JSON) | `schema` `<P>.EngineCapabilities.v1`, `schema_version` 1, `restore_session.protocol`, `.request_domain`, `.manager`: whether restore approval sessions are used, and `restore_session.find_files` (`<P>.FileSearch.v1`): whether a session also serves Find a file (section 9); `retention.manager`, `.request_domain`, `.policy_schema`, `.preview_schema`, `.history_schema`: whether clean-up of old backups is offered (section 10) | Yes (shipped in the payload, in the runtime manifest) | Not shipped |
| `<state>\status.json` | Run identity, `state`, progress, summary, errors, cancel channel (`wrapper_pid`, `wrapper_start_filetime`, `launcher_pid`, `launcher_start_filetime`, `cancel_channel_id`, `cancel_channel_fingerprint`), plan binding, `repository_storage_mode`, `repository_access` (read only to word a failed authentication; absent means `password`), `maintenance_hold`, `change_anomaly`, `failure_code` (a run stopped by `repository_low_space` is not repeated by the Backup location card's hero sentence). A backup's new, changed and unchanged file counts are Restic's own `summary.files_new`, `.files_changed` and `.files_unmodified` (all three non-negative integers, or none is shown; never for a dry run). Rewindle only, and not read by the dashboard: `unarchivable_links`, the WSL links and special files the run left out because Restic cannot store them (`null` until the source check has passed): `count`, up to 20 `samples` (paths), `tags` (counts for `lx_symlink`, `lx_fifo`, `lx_chr`, `lx_blk`), and `not_left_out` (`count`, `reasons` counted by `case_twin`, `control_character`, `invalid_unicode`, `trailing_dot_or_space`, `too_long` or `over_limit`, up to 20 `samples` with `path`, `tag` and `reason`), and, only on a run that ends as `partial` because WSL had put a regular file or folder at a left-out path by the time Restic finished, `replaced` (`count` and up to 20 `samples`). A sample path longer than 1,000 characters keeps its start and its end; `last-success.json` carries the same | Yes | Yes |
| `<state>\last-success.json` | Verified run evidence; its SHA-256 binds anomaly reviews. For the Backup location card: `repository_bytes_after` (what the backups take after that run, a whole number of bytes or `null`), otherwise the Google Drive count before the run, `repository_readiness.total_bytes` (Rewindle) or `repository_storage_preflight.total_bytes` (legacy), plus `summary.data_added_packed` (else `data_added`), shown as an estimate. Anything that is not a whole number of bytes 0 or more is unknown. How far back the backups go is `snapshot_inventory` (`schema_version` 1, `count` 1 to 1,000,000, `oldest_utc` no later than `newest_utc`, `counted_utc`, `rule` `restore_browse`: the backups the Restore list offers, counted from the listing the backup already reads), bound to the record's own `plan_id` and `repository`, read only from a verified record and only shown. `status.json` carries the same key, which is not read. The record also carries `repository_access` next to `repository_storage_mode`, as `status.json` does (informational: nothing requires it) | Yes (`repository_bytes_after` after every verified backup since this change; `null` when the size could not be measured; `snapshot_inventory` too) | Yes (never `repository_bytes_after`; the Google Drive count only; no `snapshot_inventory`: the backup range comes from the Restore list, section 6) |
| `<state>\dry-run-latest.json` | Dry-run result and summary (the Rewindle report also carries `repository_access` next to `repository_storage_mode`; informational) | Yes | Yes |
| `<state>\retention-policy.json` (≤ 16 KiB) | `schema` `<P>.RetentionPolicy.v1`, `schema_version` 1, `enabled`, `keep_daily`, `keep_weekly`, `keep_monthly`, `group_by` `host,paths`, `plan_id`, `repository_id`, `install_id`, `policy_sha256`: clean-up is on only while every binding and the digest hold (section 10) | Yes (written only by `Manage-Retention.ps1`) | Not written |
| `<state>\retention-preview.json` (≤ 8 MiB) | `schema` `<P>.RetentionPreview.v1`, `state` (`ready`, `blocked`, `error`, `disabled`), `blocked_reason`, `error_code`, plan, generation, `evidence.last_success_sha256`, `policy.policy_sha256`, `remove` and `keep` (ID, time, files, reasons), their counts, `remove_set_sha256` (checked against the listed IDs), `earlier_changes`, `earlier_changes_unknown`, `needs_files_confirmed`, `prune_pending`, `future_dated_utc`; its own SHA-256 binds a removal | Yes (written only by `Manage-Retention.ps1`) | Not written |
| `<state>\retention-history.json` (≤ 1 MiB) | `schema` `<P>.RetentionHistory.v1`, `plan_id`, the newest entry's `request_nonce`, `outcome`, `confirmed_count`, `removed_count`, `prune_completed`, `check_completed`, `check_unfinished`, `removal_unverified`, `free_bytes_before`, `free_bytes_after`; from every entry that removed backups (`removed_count` above 0 or `removal_unverified`) or freed their space (`prune_completed`, or `outcome` `space_pending`), its `finished_utc` and `free_bytes_after` minus `free_bytes_before`, which the Backup location card's forecast takes away (section 10). A record that exists but cannot be trusted leaves the forecast unknown | Yes (written only by `Manage-Retention.ps1`) | Not written |
| `<state>\retention-confirmed.json` (≤ 2 MiB) | `schema` `<P>.RetentionConfirmed.v1`, `plan_id`, `repository_id`, `request_nonce`, `runs`: the backup runs (`<run>` of each `backup-<run>.jsonl.log`) that were changes to look over when the person last ticked that their files looked right; a later run is not on it, whatever its recorded time (section 10). The dashboard does not read it | Yes (written only by `Manage-Retention.ps1`) | Not written |
| `<state>\anomaly-acknowledgement.json` | `schema` `<P>.AnomalyReview.v1`, `decision` `approved`, the engine's scope, plan, generation, repository, run, snapshot, evidence hash, `maintenance_hold_remains`, no snapshot or repository modification | Yes | Yes |
| `<state>\repository-relocation.journal.json` | Presence, protected ACL, size and SHA-256 (gates every mutation). Rewindle's manager also writes `owner_process_id` (integer) and `owner_process_creation_filetime_utc` (the process creation FILETIME as an exact decimal string, like `wrapper_start_filetime`) for the process running the move; a journal without them must keep working. The dashboard reports a running move, not an interrupted one (no Repair, every mutation still gated), while it waits for the manager it started itself, or while `OpenProcess`/`GetProcessTimes` find that same process running; otherwise, and for any journal without valid owner fields, it is an interrupted move as before | Yes | Yes (no owner fields: only a move this dashboard started is reported as running) |
| `<state>\logs\backup-<run>.jsonl.log`, `dry-run-<run>.jsonl.log` | Run details timeline and failure events (newest 4 MB) | Yes | Yes |
| Latest direct cloud proof (section 2) | `schema_version` 2, `proof_kind`, `verification_phase` `post_activation`, `verification_mode`, `repository_storage_mode` `google_drivefs_stream`, My Drive paths, repository identities, exact inventory, direct restore, timestamps bound to the latest verified backup | Yes (also bound to `immutable_proof_sha256`, `cloud_verification_assets_manifest_sha256`, `native_capture_mode` `binary_stream_copy`) | Yes (pinned to that edition's single streamed repository) |
| `<state>\google-drive-sync-status.json` | Only a proof-shaped document is interpreted; anything else reads "direct cloud verification required" | Not written | Not written |
| Retired per-user mirror status (section 2) | Presence only; never parsed | Written by the optional sync script | Written by that edition's sync script |
| `<state>\recovery-health-latest.json` | Diagnostics only | Not written | Not written |

An active `status.json` (a running state) is believed only while its writer is alive: the process
`wrapper_pid`, opened as the user with `PROCESS_QUERY_LIMITED_INFORMATION`, must have exactly the creation time
`wrapper_start_filetime` (a canonical decimal FILETIME string) and must not have exited, or the file must have been written
in the last two minutes. Otherwise the run is shown as interrupted. A status without a valid `wrapper_start_filetime` (an
older engine build) falls back to the process ID and a start time within five minutes of `started_utc`. Both engines write
both fields, and must keep doing so.

The read-only readiness check runs `<install>\Python\python.exe -E -S -B <install>\recovery_health.py --config …` as the
user (60 s, 4 MiB stdout) and binds `schema` `<P>.RecoveryHealth.v1`, plan, generation, repository, and the check IDs
`active_credential`, `recovery_key`, `rotation_rollback_key`, `pending_transaction`, `restore_drill`, `recovery_bundle`
and `last_verification` (both engines; Rewindle adds `repository_storage` and `data_check`). The Rewindle report also has a
top-level `repository_access` (absent means `password`), which must equal the configuration's, or the dashboard does not use the
report; for `no_password` it has no `recovery_key` and no `rotation_rollback_key` check (section 11).

## 6. Dashboard-owned files

All under the presentation store (section 2): `settings.json` and `tray-hint-shown.json` (appearance), the motion
preference, the text size (`zoom.json`), the Low space warning (`space-warning.json`: `schema_version` 1 and
`warn_weeks` 4, 8 or 12; anything else means 8), `run-history.json` (schema 1, at most 400 runs), `backup-range.json`, `heartbeat.json`, `crash.log` (+ `.old`), and the WebView2
profile in `WebView2\`. With `--isolated-presentation-store` the isolated folders are used instead and history and
heartbeat writes are off.

`alerts.json` (backup alerts, beside `settings.json`): `schema_version` 1, `notify` (bool, default true), `user_paused`
(bool, optional, default false: the schedule was turned off in the dashboard's Edit schedule, and no read since has shown it
on; that pause is not told) and `told` (at most 8 entries of `key` `<reason>|<last verified UTC or none>` and `at_utc`;
entries older than 30 days are dropped). At
most 16 KiB, strict UTF-8, written atomically, never through a reparse point. A missing or damaged file gives the
defaults; one that cannot be read just now, or that a newer version wrote, is left untouched and this run keeps its
choices in memory. With `--isolated-presentation-store`, or a `--state-dir` other than the engine's own, it is neither
read nor written and no notification is shown (the tray mark still is).

A backup record in `run-history.json` may carry `files_new`, `files_changed` and `files_unmodified` (all three or none;
optional keys, so the schema stays 1 and an older build reads and rewrites the file, dropping only them).
`backup-range.json` (schema 1, `source` `restore`, `plan_id`, `repository`, `count` 0 to 1,000,000, `oldest_utc` and
`newest_utc` when `count` > 0, `counted_utc`) is how far back the backups went when the Restore list was last read, for the
plan and location named; it is written by the dashboard's background refresh after a listing, and with either engine. The page shows whichever of
it and `snapshot_inventory` belongs to the plan and location in use and was counted later, or nothing. With an engine that has
clean-up of old backups, nothing is shown while a count is older than the newest clean-up that removed backups (or may have:
`removal_unverified`) in `retention-history.json`, or while that record is not read yet or cannot be trusted, until the next
backup or a Restore listing counts them again (section 10). Both files can be
written by anything running as the user, so they are display-only: parsed defensively, never used to allow, refuse, keep or
delete anything, and never read by the anomaly review or by anything that removes backups.

## 7. Known limitations (unchanged)

- `--state-dir` changes where telemetry is read; the protected managers and the cancellation pre-check always use the
  engine's own `<state>`, because that is where the elevated managers write.
- The engine is chosen once per process; installing or removing an engine while the dashboard runs needs a restart to
  switch engines.
- The dashboard checks task XML defaults more leniently than the elevated managers (a missing optional element the
  dashboard defaults may still be refused by `Manage-Schedule.ps1` or `Manage-Backup.ps1`); the managers decide.
- The diagnostic bundle's latest-run log is looked up with the backup prefix, so a dry run's log is not included.
- `google-drive-sync-status.json` and `recovery-health-latest.json` are read but not written by either engine.

## 8. Mismatches found and how they were resolved

| Mismatch | Resolution |
| --- | --- |
| Every identity (roots, task, launcher, request domains, schemas, mutex and event names, cloud and dashboard folders) was the personal edition's. | All moved into `EngineProfile`; the Rewindle profile is the default. |
| `Manage-Sources.ps1` (Rewindle) had no result channel: no `-ResultPath`/`-RequestNonce`, no `SourceManagerResults`, no `SourceRequest.v1` digest. The dashboard requires a bound result. | Ported into `src/Manage-Sources.ps1` with the Rewindle identities and its journaled updates intact; installed runs now require the channel. Covered by `tests/Test-ManageSources.ps1`. |
| Anomaly review scope: Rewindle writes `anomaly_review_acknowledgement` (an acknowledgement that gates nothing), the dashboard accepted only `offsite_promotion`, so a successful review was reported as failed. | Each profile accepts its engine's scope (Rewindle also accepts `offsite_promotion` from earlier alphas) and uses wording that matches what the review does. |
| Cloud proof location: Rewindle writes `evidence\latest-verification.json`. | Per-profile proof path. |
| Cloud proof binding: the dashboard required one hard-coded personal My Drive repository. | Rewindle derives the cloud path from the proof's own repository and My Drive root (bound to the backup telemetry); the legacy profile keeps its edition's pinned repository. |
| Cloud proof: the dashboard no longer required the immutable-evidence, asset-manifest and binary-stream bindings Rewindle writes. | Required again for the Rewindle profile (the legacy verifier never wrote them). |
| Backup states `checking_repository_storage`, `preflighting_sources`, `authenticating_repository` (and the legacy `verifying_repository_storage`) were unknown to the dashboard and to `Manage-Backup.ps1`, so a run in them showed "Unknown" and could not be cancelled although the wrapper passes a cancellation checkpoint in each. | Mapped in the dashboard; accepted as cancellable by `src/Manage-Backup.ps1` (covered by `tests/Test-ManageBackup.ps1`). |
| Restore results up to the engine's 8 MiB limit failed the serializer's 2 M-character default. | The result reader's limit matches the file-size limit. |
| Drill progress carried the drill's snapshot while the dashboard expected none, so only the first update was shown. | Drill progress accepts an exact snapshot ID, as the final result already did. |
| Diagnostics no longer redacted cloud-proof hashes and paths. | Redacted again for both engines. |
| The dashboard build produced `ResticBackupDashboard.exe`; the release build, installer and uninstaller expect `ResticBackuperDashboard.exe`. | `src/dashboard/build.ps1` emits `ResticBackuperDashboard.exe` and the same `dashboard-assets.json` format. |
| `repository_storage_unavailable` had no remediation text in run details. | Added. |

## 9. Restore approval session (one Windows approval per restore)

The guided restore (`DashboardWindow.RestoreFlow.cs`, `RestoreManager.cs`) asks Windows once per restore instead of once per
step. The elevated broker is `Manage-Restore.ps1 -Operation session`; the dashboard side is `RestoreSessionHost` (one per open
Restore flow) and `RestoreSessionClient` (one running session).

**When it is used.** Only when the engine profile has a broker (`RestoreSessionRequestDomain`; the legacy personal edition has
none) and `<install>\engine-capabilities.json` (section 5) names the same protocol, request domain and manager. The file is
read from the protected install root only, ≤ 16 KiB, never through a link; anything else, including an older Rewindle engine
without the file, keeps one elevated request per step (section 3). The folder cache and the deferred root read below apply in
both cases.

**Launch.** As every manager (section 3): System32 `powershell.exe` with `runas`, working directory `<install>`, one UAC prompt.
The request (`RestoreRequest.v3`, digest fields in section 3) carries a fresh nonce, the user SID, the plan, generation and
configuration SHA-256, the dashboard's process ID, a pipe name of 256 random bits, the SHA-256 of a 256-bit session token (the
token itself is only ever sent on the pipe) and the timeouts the dashboard asks for (idle 600 s, lifetime 3600 s, connect
120 s). The broker refuses an idle limit over 600 s, a lifetime over 3600 s, a connect wait over 300 s or any under 5 s.
Before anything else it makes the same host checks as a single request (elevated, same SID, installed script path, plan and
generation), checks the digest and opens `RestoreManagerResults` exactly as a single request does.

**Channel.** `\\.\pipe\ResticBackuper.RestoreSession.<64 hex>`, byte mode, one instance, created with
`FILE_FLAG_FIRST_PIPE_INSTANCE` (so a name that already exists ends the session as `pipe_unavailable`: no squatting), DACL
protected with an allow for the requesting SID only and a deny for `NETWORK`. The broker accepts exactly one client and checks it
before reading anything: `GetNamedPipeClientProcessId` must equal the requested dashboard PID. The client connects at
identification level; after its hello the broker reads the client token's SID (`RunAsClient`) and requires the requested SID,
the hello's own PID and the token whose hash it was given. The dashboard sends nothing until `GetNamedPipeServerProcessId`
equals the PID of the process `runas` returned, and accepts the `ready` only with the request's nonce, digest, that PID and the
timeouts it asked for. The broker's P/Invoke stub is emitted in memory (`Reflection.Emit`); nothing is compiled to disk.

**Messages.** Each is a 4-byte little-endian length and one UTF-8 JSON object with exactly the listed fields; client to broker
at most 256 KiB, broker to client at most 8 MiB (the result-file limit). Anything else (a frame over its limit or empty, one
that stops for 30 s, invalid UTF-8 or JSON, an unknown type or field, a request out of sequence, a request the single-request
validation refuses, a recovery drill) ends the session.

| Message | Direction | Fields |
| --- | --- | --- |
| `hello` | dashboard → broker | `type`, `protocol` (`ResticBackuper.RestoreSession.v1`), `session_token` (64 hex), `dashboard_process_id` |
| `ready` | broker → dashboard | `type`, `protocol`, `request_nonce`, `request_digest`, `broker_process_id`, `idle_timeout_seconds`, `lifetime_seconds` |
| `request` | dashboard → broker | `type`, `request_id` (1, 2, 3, …), `action` (`list_snapshots`, `list_tree`, `find_files` or `restore`), `snapshot_id`, `tree_path`, `target`, `includes_base64`, `allow_legacy_unbound` (`"0"`/`"1"`) — the single request's `-SnapshotId`, `-TreePath`, `-Target`, `-IncludesBase64`, `-AllowLegacyUnbound`; a `find_files` request also has `find_text` and `find_from_snapshot_id`, and no other request may |
| `progress` | broker → dashboard | `type`, `request_id`, `stage`, `message`, `percent` (what a single request writes to its progress file) |
| `result` | broker → dashboard | `type`, `request_id`, `exit_code` (what a single request exits with), `result` (the document a single request writes to its result file, bound to the session's nonce and digest; for `find_files` also `find_text_sha256` and `find_from_snapshot_id`) |
| `close` | dashboard → broker | `type` |
| `closed` | broker → dashboard | `type`, `reason` (sent when the session ends while idle, and in answer to `close`) |

**What a session serves.** Any number of `list_snapshots` and `list_tree` requests and at most one `restore`; the session ends
after the restore whatever its outcome. Each request runs `Initialize-RestoreRequest` and `Invoke-RestoreOperation`, the same
functions the single request uses, so the field validation, run lock (taken per request, never while idle), journal gate,
plan and configuration checks, runtime-manifest check, destination guards, restore history and payload checks are identical.
The dashboard validates each result with the same `RestoreManagerLauncher.ValidateResult`.

**Find a file (`find_files`).** Served only by a session whose capability document names `restore_session.find_files`, and
never as a single request. The request carries `find_text` (trimmed of spaces; 2 to 200 UTF-16 code units; no control
character, unpaired surrogate or `\ / : * ? " < > |`; the same rules, in the same order, in `fileSearch.ts`,
`RestoreFileSearch.cs`, `Manage-Restore.ps1` and `restore.py`, with the shared cases in
`tests/fixtures/file-search-text-cases.json`) and `find_from_snapshot_id` (the exact 64-hex ID of the newest backup the dashboard
lists, then the `next_from_snapshot_id` of the page before); its selectors, includes and legacy flag are empty. The broker
refuses a text that is not already in that form, takes the run lock, and runs
`restore.py --find-json --no-restic-lock --find-text=<text> --find-from-snapshot=<id> --find-seconds=20` (each a single token, so
a text that starts with `-` is never an option). restore.py puts itself in a kill-on-close job, lists the plan's backups and
runs `restic find --json --ignore-case --snapshot <id>… -- *<text>*` over them, newest first, in batches of 1, 2, 4 up to 32
backups, each as large as the time left allows; Restic writes nothing to the repository. Each batch stops at 32 MiB or 100,000
nodes of output. The page is `<P>.FileSearch.v1`: `binding` (plan), `query` (text and start), `status` (`complete`, `more`,
`too_many` past 100 items, `too_broad` when a batch hit its cap, `too_slow` when no backup could be searched in the time because
the list or the first backup after it took it all; `more` always means at least one backup was searched),
`snapshots_total`, `snapshots_searched`, the newest and oldest time searched, `next_from_snapshot_id` (none for `complete`, and
possibly none for `too_many`), and at most 100 matches of at most 10 versions (size and change time, the newest and oldest backup
that hold it, `plan` or `legacy_unbound`). A backup cut by the deadline is not counted. The broker kills restore.py, and with it
Restic, after 35 s, and fails a start that is no longer listed (restore.py exit 4) with "The backup to search from is no longer in
the list." The result is bound to `find_text_sha256` (SHA-256 of the UTF-8 text) and `find_from_snapshot_id`; the dashboard
checks both, the page's plan and query, every limit, and then that every backup the page names is in the list on screen with the
same binding. The search state lives only in the dashboard's memory; the session record counts `find_files` and never holds the
text. On the page the Find tab exists only while the host sends `restoreFlow.search`, which it does only for such a session; a
search is refused while a backup, a settings change or a clean-up step runs (section 10), while Windows catches up on a missed
backup, and in the two minutes before a scheduled one.

**Lifetime.** The session ends after 10 idle minutes, after 60 minutes in all (checked between requests; a running restore is
never interrupted), when the client disconnects or the dashboard process exits, when the protected configuration's SHA-256
changes (checked every 2 s, read with full sharing), when the dashboard sends `close` (closing Restore, Reload Restore, a
changed plan, exiting the app; the engine is chosen once per process), after its restore, and on a protocol violation.
`RestoreManagerResults\<nonce>.json` records `close_reason` (a fixed code such as `restore_completed`, `client_closed`,
`idle_timeout`, `lifetime_expired`, `config_changed`, `client_process_mismatch`, `token_mismatch`, `schema_violation`,
`frame_too_large`, `pipe_unavailable`), a fixed sentence and the operation counts; nothing the client sent is quoted.

**Dashboard behaviour.** The host starts a session the first time a protected step needs one and reuses it until it can no
longer serve (ended, restore used, within 30 s of its idle or absolute limit, or bound to another plan); then the next step
starts a new one, with a new prompt. A session that had already ended before it read a request (`closed` first, or a channel
that was gone) is replaced once, transparently; a session that ends while serving a request is never asked again for it.
Choosing a backup (`restoreFlowNavigate` with `step` `files` and a `snapshotId`) reads none of its folders; the root is read
only on **Browse files**, and "Everything in this snapshot" needs no read. Every folder read is cached by snapshot ID and path
(at most 256 folders) and the cache is cleared when the snapshot, the plan or the flow changes. While Windows shows a prompt the
page is told (`restoreFlow.approval.waiting`) and says "Windows will ask once to allow Rewindle to read and restore from your
backup." for a session; a declined prompt is a cancelled step with the existing retry routing.

**Tests.** `tests/Test-ManageRestore.ps1` unit-tests the protocol functions (loaded from the manager's source with the parser)
and runs sessions end to end in the disposable mode, non-elevated: framing, size limits, schema rejection, the single-restore
rule, idle/lifetime/connect limits, client PID, SID and token mismatches, a squatted pipe name, a changed plan, and, with a
built dashboard, the dashboard's own client against the broker (including a search); file searches end to end (a bound page,
a text that starts with `-`, a start that left the list, a search cut at the broker's time limit, the session going on after it,
and the single request refused). The disposable mode needs `-TestRoot` below the user's
temporary folder, a copy of the script inside that test root (the manager-path check), a script outside the protected install
root and a non-elevated token, so the installed copy can never run in it.
`src/dashboard/tests/restore-flow-regressions.ps1` covers the deferred root read, the cache, the session-or-per-step choice
and the session lifecycle against a stand-in broker, and Find a file: the capability (never for the legacy edition), the
launcher's bindings, the flow's refusals, merged and bounded pages, a list that changed, and Restore this. `tests/test_restore.py`
covers restore.py's find mode (the budget, the batch caps, the job object, a real Restic), and
`tests/test_dashboard_file_search.py` the page's rules and words.

## 10. Clean-up of old backups

Clean-up keeps the last backup of each of the last N days, weeks and months that have a backup, and removes the rest, but only
a list the person looked at and confirmed. The elevated manager is `Manage-Retention.ps1`; it runs the helper `retention.py`
with the embedded Python, the run lock held and a fixed environment. The dashboard side is `RetentionManager.cs` and
`DashboardWindow.Retention.cs`. Nothing in the scheduled backup task lists or removes backups.

**Off by default.** No setting exists until the person saves one (`-Action configure -Enabled 1`, counts 7–90 days, 4–104 weeks,
6–120 months; the page suggests 14, 8 and 24). A setting counts only while it names this plan, the repository ID of the latest
verified backup and this installation, and its `policy_sha256` (SHA-256 over the schema, plan, repository, `install_id`, the
three counts and `host,paths`, LF-joined) matches. `install_id` is SHA-256 over `ResticBackuper.RetentionInstall.v1`, the runtime
manifest's `installation_id` (32 random bytes in lower-case hex that the installer writes on every install;
`Manage-Sources.ps1` and `Manage-Repository.ps1` keep it when they rewrite the manifest), its `version`, and
`<lower-case relative path>\t<sha256>` for every manifested file except `backup-config.json` (which those managers rewrite),
sorted, LF-joined. Every install therefore turns clean-up off, an update or a reinstall of the same release alike, while a
change of folders or a move of the backup location does not; the card says so, and nothing is removed. A manifest without
a valid `installation_id` binds no setting. Turning it off (`-Enabled 0`) needs neither the backup location nor a clean
journal state.

**When the dashboard offers it.** Only when the engine profile names a clean-up manager (the legacy personal edition does not:
its card says clean-up isn't available, every clean-up command is refused and nothing is read) and `engine-capabilities.json`
has a `retention` block with the same manager, request domain and schemas (otherwise the card asks for Reinstall or repair).
Only for a local NTFS backup location: a Google Drive location is refused (`google_drive_not_supported`). The dashboard believes
a record only when only Administrators or SYSTEM can change it and the state folder that holds it (the same rule as
`secret_store.admin_only_writable_problem`, with an owner limited by an OWNER RIGHTS entry, which is safe only while nobody
else can create files in that folder; `retention.py` checks the folder too), and a list only when its IDs give its
`remove_set_sha256`. Each `earlier_changes` entry carries its `kind`: `hold` (the run's unusual changes held clean-up back),
`not_compared` (`change_anomaly_status` `not_comparable` or `disabled`: the first backup, or the first after a folder,
exclusion or location change) or `unknown` (an older backup service's log does not say). Only `hold` is worded as unusual
changes; the others ask the person to check their files because those backups could not be compared.

**Listing.** `preview` (and `configure` when it turns clean-up on) runs `restic --no-lock forget --dry-run --json --host <host>
--tag restic-backuper-plan:<plan> --group-by host,paths --keep-daily D --keep-weekly W --keep-monthly M`; every other read
passes `--no-lock` too, so listing writes nothing to the backup location. Backups of other plans or computers are never
listed. Restic's proposal is then made safer: the latest verified backup stays; a checked backup that is the only checked one
of a kept day, week or month stays; and the newest backup before each unusual change the person has not confirmed
(`change_anomaly`) stays until they tick "my files look right". Ticking it in a removal records, in
`retention-confirmed.json`, every backup run that was a change to look over at that moment (the run lock is held, so no
backup runs in between); a later run counts until the next confirmed removal, whatever time it was recorded with, so a
clock that was wrong or set back cannot clear a change nobody looked at. Without that record (the first clean-up for
this plan and backup location) every change counts and the person is asked to check their files. The list is blocked,
with one of these reasons, when
`no_verified_backup`, `last_backup_not_verified`, `folders_changed`, `change_review_open`, `pending_change` (any
`*.journal.json`), `clock_problem`, `future_dated_backup`, `backup_location_unavailable`, `google_drive_not_supported` or
`policy_inactive`. A list is stale for the dashboard once `last-success.json` changes; the card then offers Check now. The
manager refuses `preview`, `apply` and turning clean-up on with `backup_location_unavailable` before anything runs when the
backup location's folder or its `config` file is not there (an unplugged drive).

**Removing.** `apply` is refused unless the preview file's SHA-256, its remove set (`ResticBackuper.RetentionRemoveSet.v1`
over the sorted IDs) and its count equal the request, the gates above still pass, and the earlier-changes confirmation is
given when the list asks for it (`preview_mismatch`, `earlier_changes_not_confirmed`, `busy` for a held run lock). A fresh dry
run must give the identical list; otherwise a new list is written and nothing is removed (exit 3). Then `forget <IDs>` in
batches of 50 with no keep rules, a fresh list that must show none of the removed and every kept backup, `prune --max-unused 5%`
(`unlimited` when free space is below the plan's minimum), `check`, and a history entry. These are the only commands that take
Restic's exclusive lock, and only this approved step runs them. If the list cannot be read back after a removal, the result
is `partial` with `removal_unverified` and nothing more runs. A batch that fails, or that cannot be started or logged (a
full disk), stops the removal; the fresh list then says what earlier batches removed, and that is recorded.

**Time limits.** Each `retention.py` step runs while the manager holds the run lock, so each has a hard limit: 8 minutes for
`configure`, `preview` and `apply-record`, 2 hours for `apply-forget`, 24 hours for `apply-prune` and `apply-check`. A step
still running then is ended with every process it started (`taskkill /T /F`; `retention.py` also runs Restic in a Windows job
that ends with it), the lock is let go, and the step counts as failed. Once `apply-forget` has started, no later failure is
reported as a clean-up that removed nothing: a removal step that was stopped or whose answer cannot be read ends as `partial`
with `removal_unverified` and `removed_count` 0 (nobody knows which backups on the list went); freeing the space that stops,
cannot be read or cannot report its progress ends as `space_pending`; a check that does not finish after the space was freed
ends as `check_failed` with `check_unfinished` (it found no problem). The history entry is written in each case (with
`removal_unverified` and `check_unfinished`), and an entry with `removal_unverified` makes the next list offer to free the
space.

| Exit code | State |
| --- | --- |
| 0 | `configured`, `disabled`, `previewed`, `removed`, `nothing_to_remove` |
| 1 | `failed` |
| 2 | `refused` (with `refusal_code`) |
| 3 | `preview_changed` |
| 4 | `partial` |
| 5 | `space_pending` (removed, space not freed yet) |
| 6 | `check_failed` (removed, the check found a problem, or with `check_unfinished` did not finish) |

**Dashboard behaviour.** The page gets counts, month totals and one page of 100 rows of the list, never the whole list. While
the list is open no other command runs; while a step runs, the protected actions are turned off with the reason and refused
before any other routing. Remove sends the count the person saw and both confirmations; the host re-reads the preview file
first and binds the request to the list it captured. A result is believed only when every binding matches, `ok` agrees with
the exit code, the state is one the action can end in, and a fresh read of the records agrees (the setting for `configure`,
the list for `preview`, the newest history entry for `apply`); `check_unfinished` is believed only on `check_failed` after
the space was freed. A list that a backup made stale while it was open ends before the approval prompt, in the words of a
`preview_mismatch` refusal: nothing was removed, close the list and choose Check now. The result screen says when the backups
were removed but freeing their space or checking the rest did not finish, with the next step, and claims no count for a
removal nobody could confirm.

**Other cards.** The Backup location card's forecast is net growth: from every history entry that removed backups or freed
their space, it takes away `free_bytes_after` minus `free_bytes_before` for each one that finished after the oldest backup of
its 8-week window. An entry in that window without both numbers leaves the forecast learning ("Old backups were removed
lately, so Rewindle needs up to 8 more weeks of backups to tell when the drive will be full.") until it is older than the
window; a history file that exists but cannot be trusted, or records not read yet, leave it unknown. Neither ever gives a
"full in N weeks" from what the backups added alone. How far back the backups go (section 6) is not shown once a clean-up
removed backups after it was counted, until a later listing counts them again.

**Tests.** `tests/test_retention.py` (the helper, with a fake Restic), `tests/Test-ManageRetention.ps1` (the manager in its
disposable mode against a stand-in `restic.exe` that refuses any read without `--no-lock`), `tests/test_dashboard_retention.py`
(the dashboard's reading, digests and result checks against the helper's, and the page's wording) and the clean-up section
of `src/dashboard/tests/restore-flow-regressions.ps1`.

## 11. Backups with a password or without one

Backups are opened either with a password (the default and the recommended way: a generated password kept in a DPAPI
envelope, and a recovery key) or, when the person chose so for a new backup, without one. Restic 0.19.1 cannot write
unencrypted backups: "no password" is Restic's empty password, and every Restic command that opens such backups carries
`--insecure-no-password`. Anyone who can open the backup folder can then restore every file, including saved sign-ins.
Rewindle never switches the way existing backups open and builds no switching; `SECURITY.md` ("Switching an existing
backup") says how a person can do it with Restic and what that does not undo. The installer's side (parameter, plan and result
fields, finding codes) is in `docs/setup-contract.md`, section 2.8. Rewindle engine only; the legacy edition has no such
choice, and a configuration without the field means a password, as it always did.

**The setting.** `repository_access` in `<install>\backup-config.json`: exactly `password` or `no_password`, in lower case.
The installer writes it right after `repository_storage_mode` for every new install, with either value. Absent means
`password`: every configuration written before the choice existed, and its recovery copy. Anything else (another text, a
different case, a number, `null`) is refused by every reader that acts on the backups (`restic_common.repository_access`,
`restore.py` and `refresh_recovery_tools.py` raise `unsupported repository_access`; `Get-RepositoryAccess` in
`Manage-Repository.ps1`, `Manage-Restore.ps1`, `Manage-Sources.ps1` and the Google Drive check throws the same text) and is
read as unknown, never as a default, by the readers that must not fail: the installer and uninstaller
(`Get-RecordedRepositoryAccess` gives null) and the dashboard (`SourceConfiguration.ReadRepositoryAccess` gives null, and the
page then says nothing about encryption either way). The key name contains none of the words the diagnostics redactor hides, so
a problem report shows its value. `secret_file` and `recovery_key_file` stay in every configuration with their default
paths. Nothing ever changes the value for existing backups, and a recovery copy that names the other value is refused
(compared with absent counted as `password`), never copied over.

**No password, in the engine.** `restic_common.restic_base` (and `restore.py`'s own copy) adds `--insecure-no-password`
instead of the `--password-command` pair. Restic refuses that option next to any non-empty password source
(`RESTIC_PASSWORD`, `RESTIC_PASSWORD_FILE`, `RESTIC_PASSWORD_COMMAND`, `--password-file`, `--password-command`,
`--new-password-file`), but only after it has run a password command, so the engine refuses to start such a command
(`restic_child_environment`, and the same check in `restore.py`), and no component builds a password command in this mode.
Nothing creates, reads, rewrites, deletes or reports a DPAPI envelope or a recovery key either: files an older installation
left at `secret_file` and `recovery_key_file` stay exactly as they are. Backups that ask for a password and are opened with the
option answer Restic exit 12 (also an empty or not yet downloaded `keys` folder); backups without a password that are opened
without it fail at once with exit 1 when standard input is closed, and wait for a password when it is open, so every Restic
child of the engine, the managers and the Google Drive check has its standard input closed.

| Record | Carries |
| --- | --- |
| `<state>\repository.json` (written by the initializer, rewritten by a move) | `repository_access` (the verified mode); without a password also `secret_created`, `recovery_key_created` and `recovery_key_names_other_repository` all false |
| `recovery-manifest.json` and `RecoveryTools\backup-config.json` | `repository_access`, normalised (absent becomes `password` when the manifest is written); it is not a recovery-local field. The manifest's `note` says by mode: with a password, "The repository password is intentionally not stored in this bundle."; without one, "These backups have no password: anyone who can read the backup folder can restore them." |
| `status.json`, `last-success.json`, the dry-run report | `repository_access` next to `repository_storage_mode`; informational, and no reader may require it |
| the recovery-readiness report (`<P>.RecoveryHealth.v1`) | optional top-level `repository_access` (absent means `password`) |
| install plan and result, uninstall result | `resolved.repository_access`, `resolved.existing_repository_access`, `existing_install.kept_repository_access`; `repository_access` after `version` on the install result; `kept.repository_access` (`docs/setup-contract.md`) |

**The initializer** (`initialize_repository.py`, run by the installer). Exit codes:

| Exit code | Meaning |
| --- | --- |
| 0 | Done |
| 1 | Any other failure (the wrapper maps every exception to it) |
| 2 | A command line the parser refuses; the installer reads it as "can't tell" |
| 4 | The configuration says `no_password`, but the backups in that location need a password |
| 5 | The configuration says `password`, but the backups in that location have none |
| 6 | The existing backups could not be opened to tell how they open: with `no_password`, `cat config` failed with anything but exit 12; with `password` and no saved password, the read-only look could not tell, or Restic said they need a password but their `keys` folder holds no file (a missing, empty or not yet downloaded folder: no password opens backups that hold no key); the same empty `keys` folder when the saved password did not open them (also `--detect-access` when it can't tell) |
| 7 | The configuration says `password` and the backups need one, but this PC has no saved password that opens them: no saved password and the read-only look says they need a password, or the saved password did not open them (Restic exit 12) and they do not open without one either; in both the `keys` folder holds at least one file. No new password is ever made for them |
| 20, 21, 22 | `--detect-access` only: the backups open without a password (20), need one (21), or are not there (22) |

Exit 4, 5, 6 and 7 print one plain line on stderr ("The backups in this location don't match the choice made in Setup." for 4
and 5, "Setup couldn't open the backups in this location." for 6, "This PC has nothing saved that opens the backups in this
location." for 7) with none of Restic's text, and write nothing (the secret, the key, the recovery tools and `repository.json`
are not created or changed); the installer undoes its own changes and leaves the backups as they were. It words them for the
person itself (`docs/setup-contract.md`): 4 and 5 are `repository_access_mismatch`, 6 is `repository_access_unreadable`, 7 is
`repository_password_unavailable`. In `no_password` mode an existing backup (a `config` file) is opened with `cat config`
through `restic_base`: exit 0 goes on, Restic exit 12 returns 4, anything else returns 6. A new one is created with
`init --repository-version 2` and checked with `cat config`; Restic's `init` text, which always warns about "knowledge of your
password", is never shown, and `init` is never used as a probe. In `password` mode the old flow runs first, and only where it
refuses an existing backup (no saved password, or the saved password does not open it) does a read-only look run: if the
backups open without a password the answer is 5. Otherwise, with no saved password, the look's answer decides: "needs a
password" is 7, and anything else (it could not tell, or there is no backup after all) is 6; with a saved password that Restic
answered with exit 12, the answer is 7. Either 7 becomes 6 when the backups' `keys` folder holds no file, because Restic
answers exit 12 for backups that hold no key at all just as it does for a password that was not given, so only the folder
tells a password this PC lacks from backups that can't be opened. Any other failure of `cat config` with a saved password
stays the old error (exit 1). The look is never run when the saved password opens the backups, so a backup that opens both
ways keeps working with its password.

`--detect-access --repository <path> --restic <restic.exe>` is exclusive with `--config` and `--commit-recovery-key`
(otherwise exit 2), loads no configuration and writes nothing. It runs one read-only
`restic --repo <path> --insecure-no-password --no-lock --no-cache cat config` with standard input closed, a minimal
environment and a 180-second limit: exit 0 gives 20, Restic exit 12 gives 21, exit 10 with no `config` file there gives 22,
and anything else, including exit 10 next to a `config` file (a half-synced folder), a time-out or Restic not starting,
gives 6. Restic's text is never returned. `--commit-recovery-key` in `no_password` mode takes no run lock, reads no
secret, prints `{"recovery_key_file": null, "recovery_key": "none"}`, exits 0 and leaves an older key file byte for byte as it
was. The stdout summary adds `repository_access` and gives `secret_file` and `recovery_key_file` as `null` in that mode.

**Failure code `repository_access_mismatch`.** When `backup.py` authenticates backups whose configuration says `no_password`
and Restic exits 12, the run fails with `failure_code` `repository_access_mismatch`, `failure_phase`
`repository_authentication` and the message "these backups now ask for a key that Rewindle doesn't have": the backups were
changed outside Rewindle or replaced by others. Every other failure of that step, and every failure in `password` mode, stays
`repository_authentication_failed`. The message holds none of the words the dashboard's filters hide. The dashboard words the
code the same in every mode (run details and the Protection status line): "These backups now ask for a password that Rewindle
doesn't have, usually because they were changed outside Rewindle. Rewindle can't carry on with them. To keep backing up, start
new backups in another place." For `repository_authentication_failed` it words the next step by mode (read from
`status.json`). The installer has findings of the same name for its own refusals (`docs/setup-contract.md`).

**Recovery readiness.** `recovery_health.py` reads the mode first. For `no_password` it opens the backups with the option and
no password source, and its report has no `recovery_key` and no `rotation_rollback_key` check; the other checks stay.
`active_credential` passes with "Rewindle can open your backups."; when it fails it says "Rewindle couldn't open your backups.
Check that the backup drive or Google Drive folder is connected, then run the checks again.", and, on Restic exit 12, "These
backups now ask for a password, usually because one was added outside Rewindle. To keep backing up, start new backups in
another place." In `password` mode nothing changes unless `active_credential` fails with exit 12: one read-only look (the
option, `cat config`, `--no-lock --no-cache`, 20 seconds) then says "These backups now open without a password, usually
because it was removed outside Rewindle. To keep using them, see Switching an existing backup in SECURITY.md on Rewindle's
GitHub page, or start new backups in another place." when it succeeds; it never runs when the saved password works.
`restore_drill` counts a history entry only when its `credential_source` matches the mode. The recovery copy's
`repository_access` is compared with the live configuration's (normalised), and a difference fails `recovery_bundle` with
`Recovery configuration drift: repository_access`. The dashboard uses a report only when its `repository_access` (absent means
`password`) equals the configuration's, shows no recovery-key row for `no_password`, hides credential repair and key rotation,
and gates **Run restore drill** on `active_credential`, `recovery_bundle`, `last_verification`, `pending_transaction` and no
locks. `credential_repair.py` and `key_rotation.py` refuse a `no_password` backup at once, before they read a key, secret or
journal, with exit 2 and a `failed` document: "This backup opens without a key, so there is nothing to repair." and "This
backup opens without a key, so there are no keys to rotate."; the dashboard's launchers refuse in the same words before any
prompt. `stale_lock_repair.py` runs its four Restic calls with the option and no password source.

**Restore and the restore drill.** `restore.py` in `no_password` mode adds the option to every Restic call, never passes
`--password-command` (not even when an older DPAPI file is still there), never reads a recovery key, never prompts (standard
input is closed), and refuses `--recovery-key-file` with "This backup opens without a key, so there is no key file to use."
`--find-json` works the same way; the file-search refusal for backups with a password is "File search needs Rewindle's saved
key or your recovery key." When Restic answers exit 12 (the backups now ask for a password) to any way `restore.py` reads
backups without a password (a listing, a folder, a search, a restore, the drill), `restore.py` says "These backups now ask
for a password that Rewindle doesn't have, usually because they were changed outside Rewindle, so Rewindle can't open them.
If you know that password, Restic can still restore your files with it, as RECOVERY.md in the recovery tools folder next to
your backups explains." It says it as the whole of its last stderr line after `RESTORE FAILED: ` when a query ends the run, and
as the `error` of the report when Restic itself ends a restore or the drill's restore with exit 12 (the last line is then
`RESTORE INCOMPLETE: ...`). `Manage-Restore.ps1` has its own copy of that text and passes it on, for every request kind
(listing, folder, search, restore, drill), when it is the whole of `restore.py`'s last stderr line after `RESTORE FAILED: ` for
backups without a password and the run failed without timing out; it then reads no report, and it reads no other stderr, so no
other word of the backend's output reaches the dashboard. A restore that Restic itself ended with exit 12 prints another line
last, so the manager keeps its report and history entry, and that report's `error` is the same text. The restore drill runs
with no key and reports
`credential_source` `none` (with a password: `recovery_key`); `drill_kind` stays `recovery_key_representative` and the history
entry kind stays `recovery_key_representative_drill`. `Manage-Restore.ps1` then neither requires the recovery key file nor
checks its ACL nor passes `--recovery-key-file`, and accepts only the `credential_source` that matches the mode;
`RestoreManager.cs` does the same (`none` only for a `no_password` configuration, `recovery_key` only for `password`).

**Managers and the Google Drive check.** `Manage-Repository.ps1` (a move of the backup location) and `Manage-Sources.ps1`
read the field with `Get-RepositoryAccess` and refuse "Recovery repository_access is not synchronized with the protected
configuration." when the recovery copy of the configuration or the manifest names the other mode. A move of backups without a
password runs every Restic command with the option, builds no password command, requires no saved-secret file, `secret_store.py`
or recovery key, keeps `repository_access` in the protected configuration, the recovery copy, the manifest and `repository.json`,
and never changes it. The nightly Google Drive check puts the option after `--repo` on all four Restic runs (the local and the
cloud `cat config`, `snapshots` and the canary `restore`), sets no `RESTIC_PASSWORD*` variable for them, and does not look for
the saved-password file or `secret_store.py`; its reason and next-step texts hold none of the words `Telemetry.CleanOffsiteDetail`
hides. The rclone side (its encrypted configuration and `RCLONE_PASSWORD_COMMAND`) is unchanged: that password is rclone's own.
