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
| Protected recovery tools for a streamed Google Drive repository (a local repository keeps them beside it, as the plan's `recovery_tools_directory` says) | `%ProgramData%\ResticBackuperRecoveryTools` | None; only the plan-configured folder |
| Recovery-drill targets | `%ProgramData%\ResticBackuper-RestoreDrills\drill-<nonce>` | `%ProgramData%\ResticPersonalBackup-RestoreDrills\drill-<nonce>` |
| Retired per-user mirror status | `%LOCALAPPDATA%\ResticBackuperGoogleDriveSync\status.json` | `%LOCALAPPDATA%\ResticPersonalBackupGoogleDriveSync\status.json` |
| Dashboard presentation store | `%LOCALAPPDATA%\ResticBackuperDashboard` | `%LOCALAPPDATA%\ResticPersonalBackupDashboard` |
| Isolated presentation store (`--isolated-presentation-store`) | `%TEMP%\ResticBackuperBeautifulUI`, `%TEMP%\ResticBackuperDashboardBeautifulUIWebView2` | `%TEMP%\ResticPersonalBackupBeautifulUI`, `%TEMP%\ResticPersonalBackupBeautifulUIWebView2` |
| Single instance | `Local\ResticBackuperDashboard.Instance`, `.Show` (and `.Presentation.Instance`, `.Presentation.Show`) | `Local\ResticPersonalBackupDashboard.Instance`, `.Show` (and the presentation pair) |
| Cancel event | `Local\ResticBackuper.Cancel.<64 hex>` | `Local\ResticPersonalBackup.Cancel.<64 hex>` |
| Request domains | `ResticBackuper.SourceRequest.v1`, `.RestoreRequest.v2`, `.RepositoryRequest.v1`, `.RepositoryRecoveryRequest.v1`, `.ScheduleRequest.v1`, `.BackupControlRequest.v1`, task fingerprint `.TaskXml.v1` | the same suffixes with `ResticPersonalBackup.` |
| Result and report schemas | `ResticBackuper.SnapshotList.v1`, `.SnapshotTree.v1`, `.RestoreReport.v1`, `.RecoveryHealth.v1`, `.AnomalyReview.v1`; diagnostics `ResticBackuper.Diagnostics.v1` | the same suffixes with `ResticPersonalBackup.` |
| Manager scripts | `Manage-Sources.ps1`, `Manage-Schedule.ps1`, `Manage-Backup.ps1`, `Manage-Repository.ps1`, `Manage-Restore.ps1` under `<install>` | same |
| Python | `<install>\Python\python.exe` with `-E -S -B` and scripts under `<install>` | same |
| Restore approval session (section 9) | Request domain `ResticBackuper.RestoreRequest.v3`, protocol `ResticBackuper.RestoreSession.v1`, pipe `\\.\pipe\ResticBackuper.RestoreSession.<64 hex>`, capability document `<install>\engine-capabilities.json` (`ResticBackuper.EngineCapabilities.v1`) | None: one elevated request per step |

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
joined by LF.

| Action | Manager arguments | Digest fields (after the domain and SID) | Result folder, fields the dashboard binds | Rewindle | Legacy |
| --- | --- | --- | --- | --- | --- |
| Add / remove a protected folder | `-Add <path>` or `-Remove <path>`, `-ResultPath`, `-RequestNonce` | lower-case action, canonical path, nonce | `SourceManagerResults`: `schema_version` 1, `request_nonce`, `request_digest`, `request_user_sid`, `action`, `ok`; on success `plan_id`, `previous_config_generation` = current, `config_generation` = current + 1, `path` = the canonical path | **Ported** (was missing; see section 8) | Yes |
| List snapshots, list a tree, restore, recovery drill | `-Action list_snapshots\|list_tree\|restore\|restore_drill`, `-IncludesBase64`, `-ExpectedConfigSha256`, `-ExpectedPlanId`, `-ExpectedConfigGeneration`, `-AllowLegacyUnbound 0\|1`, `-ResultPath`, `-RequestNonce`, `-RequestDigest`, optional `-SnapshotId`, `-TreePath`, `-Target` | action, config SHA-256, plan, generation, legacy flag, snapshot, tree path, target, includes SHA-256, nonce | `RestoreManagerResults` (+ `<nonce>.json.progress.json`): binding fields, `ok`, `backend_exit_code`, `payload` (`SnapshotList.v1`, `SnapshotTree.v1` or `RestoreReport.v1`), drill evidence (`history_recorded`, canary and sample fields) | Yes | Yes |
| Restore approval session: any number of snapshot and folder listings and at most one restore (section 9) | `-Operation session`, `-ExpectedConfigSha256`, `-ExpectedPlanId`, `-ExpectedConfigGeneration`, `-ResultPath`, `-RequestNonce`, `-RequestDigest`, `-DashboardProcessId`, `-PipeName`, `-SessionTokenSha256`, `-IdleTimeoutSeconds`, `-LifetimeSeconds`, `-ConnectTimeoutSeconds` | `session`, config SHA-256, plan, generation, dashboard PID, pipe name, session-token SHA-256, idle, lifetime and connect timeouts, nonce (domain `RestoreRequest.v3`) | Results on the pipe, each the document above bound to the session's nonce and digest; `RestoreManagerResults\<nonce>.json` records how the session ended (`close_reason`, `operations`) | Yes (advertised in `engine-capabilities.json`) | No |
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

## 4. Task Scheduler contract

Read with `schtasks.exe /Query /TN "<backup task>" /XML` (as the user, 15 s, 256 K characters) and the
`Schedule.Service` COM object for state and next run. The XML must have exactly one `Exec` action whose command is the
launcher, no arguments, working directory `<install>`; exactly one principal that resolves to the current user, with
`InteractiveToken` and `HighestAvailable`; `URI` = `\<backup task>`; `IgnoreNew`, `ExecutionTimeLimit` `PT0S`, priority 7,
no idle or network conditions, hard terminate and on-demand start allowed; exactly one daily or weekly calendar trigger.
The fingerprint is SHA-256 of `<TaskXml domain>` + LF + the canonical document element. The Rewindle installer registers
exactly this shape.

## 5. State the dashboard reads (read-only, never written)

| File | Fields the dashboard uses | Rewindle | Legacy |
| --- | --- | --- | --- |
| `<install>\backup-config.json` (≤ 1 MiB, read with full sharing, retried once) | `plan_id` (canonical UUID), `config_generation` (> 0), `cloud_placeholder_policy`, `repository`, `state_directory`, `sources` (canonical, unique), `source_identities` (one 8-hex serial per source), `canary_file` (inside a source), `topology_paths`, `recovery_tools_directory` (source-picker guard only) | Yes (written by the installer and `Manage-Sources.ps1`) | Yes |
| `<install>\runtime-manifest.json`, `VERSION` | Diagnostics (redacted) and the engine version | Yes | Manifest only |
| `<install>\engine-capabilities.json` (≤ 16 KiB, no link, strict UTF-8 JSON) | `schema` `<P>.EngineCapabilities.v1`, `schema_version` 1, `restore_session.protocol`, `.request_domain`, `.manager`: whether restore approval sessions are used (section 9) | Yes (shipped in the payload, in the runtime manifest) | Not shipped |
| `<state>\status.json` | Run identity, `state`, progress, summary, errors, cancel channel (`wrapper_pid`, `wrapper_start_filetime`, `launcher_pid`, `launcher_start_filetime`, `cancel_channel_id`, `cancel_channel_fingerprint`), plan binding, `repository_storage_mode`, `maintenance_hold`, `change_anomaly` | Yes | Yes |
| `<state>\last-success.json` | Verified run evidence; its SHA-256 binds anomaly reviews | Yes | Yes |
| `<state>\dry-run-latest.json` | Dry-run result and summary | Yes | Yes |
| `<state>\anomaly-acknowledgement.json` | `schema` `<P>.AnomalyReview.v1`, `decision` `approved`, the engine's scope, plan, generation, repository, run, snapshot, evidence hash, `maintenance_hold_remains`, no snapshot or repository modification | Yes | Yes |
| `<state>\repository-relocation.journal.json` | Presence, protected ACL, size and SHA-256 (gates every mutation) | Yes | Yes |
| `<state>\logs\backup-<run>.jsonl.log`, `dry-run-<run>.jsonl.log` | Run details timeline and failure events (newest 4 MB) | Yes | Yes |
| Latest direct cloud proof (section 2) | `schema_version` 2, `proof_kind`, `verification_phase` `post_activation`, `verification_mode`, `repository_storage_mode` `google_drivefs_stream`, My Drive paths, repository identities, exact inventory, direct restore, timestamps bound to the latest verified backup | Yes (also bound to `immutable_proof_sha256`, `cloud_verification_assets_manifest_sha256`, `native_capture_mode` `binary_stream_copy`) | Yes (pinned to that edition's single streamed repository) |
| `<state>\google-drive-sync-status.json` | Only a proof-shaped document is interpreted; anything else reads "direct cloud verification required" | Not written | Not written |
| Retired per-user mirror status (section 2) | Presence only; never parsed | Written by the optional sync script | Written by that edition's sync script |
| `<state>\recovery-health-latest.json` | Diagnostics only | Not written | Not written |

The read-only readiness check runs `<install>\Python\python.exe -E -S -B <install>\recovery_health.py --config …` as the
user (60 s, 4 MiB stdout) and binds `schema` `<P>.RecoveryHealth.v1`, plan, generation, repository, and the check IDs
`active_credential`, `recovery_key`, `rotation_rollback_key`, `pending_transaction`, `restore_drill`, `recovery_bundle`
and `last_verification` (both engines; Rewindle adds `repository_storage`).

## 6. Dashboard-owned files

All under the presentation store (section 2): `settings.json` and `tray-hint-shown.json` (appearance), the motion
preference, `run-history.json` (schema 1, at most 400 runs), `heartbeat.json`, `crash.log` (+ `.old`), and the WebView2
profile in `WebView2\`. With `--isolated-presentation-store` the isolated folders are used instead and history and
heartbeat writes are off.

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
| `request` | dashboard → broker | `type`, `request_id` (1, 2, 3, …), `action` (`list_snapshots`, `list_tree` or `restore`), `snapshot_id`, `tree_path`, `target`, `includes_base64`, `allow_legacy_unbound` (`"0"`/`"1"`) — the single request's `-SnapshotId`, `-TreePath`, `-Target`, `-IncludesBase64`, `-AllowLegacyUnbound` |
| `progress` | broker → dashboard | `type`, `request_id`, `stage`, `message`, `percent` (what a single request writes to its progress file) |
| `result` | broker → dashboard | `type`, `request_id`, `exit_code` (what a single request exits with), `result` (the document a single request writes to its result file, bound to the session's nonce and digest) |
| `close` | dashboard → broker | `type` |
| `closed` | broker → dashboard | `type`, `reason` (sent when the session ends while idle, and in answer to `close`) |

**What a session serves.** Any number of `list_snapshots` and `list_tree` requests and at most one `restore`; the session ends
after the restore whatever its outcome. Each request runs `Initialize-RestoreRequest` and `Invoke-RestoreOperation`, the same
functions the single request uses, so the field validation, run lock (taken per request, never while idle), journal gate,
plan and configuration checks, runtime-manifest check, destination guards, restore history and payload checks are identical.
The dashboard validates each result with the same `RestoreManagerLauncher.ValidateResult`.

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
built dashboard, the dashboard's own client against the broker. The disposable mode needs `-TestRoot` below the user's
temporary folder, a copy of the script inside that test root (the manager-path check), a script outside the protected install
root and a non-elevated token, so the installed copy can never run in it.
`src/dashboard/tests/restore-flow-regressions.ps1` covers the deferred root read, the cache, the session-or-per-step choice
and the session lifecycle against a stand-in broker.
