# Setup contract: the installer's machine-readable backend

This document is the contract between the Rewindle installer scripts and a program that drives them, such as a graphical
setup wizard. The scripts keep their console behaviour; everything below is additive, switched on by parameters that are new
in 0.2.0.

| Document | Schema id | Written by |
| --- | --- | --- |
| Install plan (one JSON file) | `Rewindle.InstallPlan.v1` | `Install-ResticBackuper.ps1 -PlanOnly` |
| Progress feed (JSON Lines) | `Rewindle.InstallProgress.v1` | `Install-ResticBackuper.ps1 -Unattended -ProgressPath`, and the same parameters of `Uninstall-ResticBackuper.ps1` |

Everything here is for Windows PowerShell 5.1 (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`), 64-bit,
and for the scripts of one release. Property names are fixed; a reader must ignore properties it does not know, because
later releases may add some within the same schema id. A breaking change gets a new id (`...v2`).

Where the scripts are in a release: `Install-ResticBackuper.ps1` is at the root of the extracted bundle, next to `payload\`
and `payload-manifest.json`. `Uninstall-ResticBackuper.ps1` is in `payload\` and, once Rewindle is installed, in
`C:\Program Files\ResticBackuper\`. Do not launch the installer through `Install.cmd`; that wrapper pauses for a key press.

## 1. Launching

Always start the scripts the same way:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> <parameters>
```

Quote every path that may contain a space, and end no quoted path with a lone backslash (`"D:\"` is read as an escaped
quote). The scripts refuse a quote or NUL character in a value they pass on to an elevated copy of themselves.

| Mode | Elevation | Changes the PC? | Prompts? |
| --- | --- | --- | --- |
| `-PlanOnly -PlanOutput <file>` | None needed; also fine elevated | Writes only the plan file | Never |
| `-Unattended [-ProgressPath <file>]` (install) | Required. Started unelevated it asks Windows for approval with the same account and waits | Yes | Never |
| `-Unattended [-ProgressPath <file>]` (uninstall) | Same | Yes | Never |

Without `-PlanOnly` and `-Unattended` the scripts are the interactive console installer, unchanged.

## 2. Plan mode

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-ResticBackuper.ps1 -PlanOnly -PlanOutput <absolute .json path>
    [-Repository <path>] [-RepositoryStorageMode local_ntfs|google_drivefs_stream] [-DriveFsMyDriveRoot <path>]
    [-SourceList "<p1>;<p2>"] [-Schedule HH:mm] [-DisableVss]
    [-MinimumFreeGiB <n>] [-DriveFsCacheDirectory <path>] [-SkipDashboard]
```

The last line lists optional parameters beyond the minimal set; they mean what they mean for a real install, and a plan
should be given the same ones the install will get. `-Unattended`, `-StartBackup` and `-ExpectedUserSid` are accepted and
ignored. `-ProgressPath` is refused.

### 2.1 Guarantees

* **No changes, no prompts, no downloads, no elevation.** The plan runs the same validation functions as a real install
  (they are shared code in `Install-ResticBackuper.ps1`) but never calls the ones that create, write, install or register
  anything. The only thing it writes is `-PlanOutput`. (Windows itself may refresh its certificate cache while the
  Microsoft signature of `powershell.exe` and `icacls.exe` is verified; that is outside the script.)
* **Exit code 0 whenever the plan document was written, even if `ok` is false.** Non-zero only when no plan could be
  produced: `-PlanOutput` missing or refused, or an unexpected failure outside every check. Standard output is empty. On a
  non-zero exit, standard error holds `No plan was written: <reason>`.
* **It describes the account that runs it.** Folder existence, access rights and the volume list are what that account sees.
  Run it as the user who will install, not as another administrator.
* **Problems are collected, not thrown.** One problem per stage (environment, payload, schedule, storage mode, repository),
  and one per source folder, so a wizard can show everything wrong at once. A stage that cannot run because an earlier one
  failed is skipped rather than guessed at, and `resolved` shows only what was understood.
* **Omitted inputs resolve to defaults.** Without `-Repository` the plan uses `defaults.repository` (and reports
  `repository_required` when there is none); without `-SourceList` it uses `defaults.sources`; without `-Schedule`, `02:00`.
  With no parameters at all, the plan therefore answers "would the default install work here?".

### 2.2 The output file

* Create-new: a path that already exists, as a file or folder, is refused. Nothing is ever overwritten.
* An absolute path on a local drive, ending in `.json`, inside the caller's temporary folder
  (`[IO.Path]::GetTempPath()` of the plan process, which is `%TEMP%`). Short (8.3) and long names of the same folder are
  treated alike. The folder must already exist; the script does not create folders.
* No reparse point (junction, symbolic link) anywhere in the path, which is checked again after the file exists.
* UTF-8 without a byte-order mark; a single JSON object.

### 2.3 The document

```json
{
  "schema": "Rewindle.InstallPlan.v1",
  "ok": true,
  "errors": [],
  "warnings": [
    { "code": "webview2_missing", "field": "environment",
      "message": "The Microsoft Edge WebView2 component that the dashboard needs isn't installed. Setup will download it from Microsoft.",
      "path": null, "detail": null }
  ],
  "resolved": {
    "repository": "D:\\Backups\\Rewindle", "storage_mode": "local_ntfs", "drivefs_my_drive_root": null,
    "sources": ["C:\\Users\\you\\Documents"], "canary_source": "C:\\ProgramData\\ResticBackuper\\Canary",
    "schedule": "02:00", "vss": true, "minimum_free_bytes": 10737418240, "estimated_source_bytes": null
  },
  "defaults": {
    "repository": "D:\\ResticBackups\\Personal", "storage_mode": "local_ntfs",
    "sources": ["C:\\Users\\you\\Documents"], "schedule": "02:00"
  },
  "environment": {
    "version": "0.2.0-alpha.1",
    "os": { "caption": "Microsoft Windows 11 Pro", "build": "26100", "x64": true, "supported": true },
    "powershell": "5.1.26100.1", "dotnet_framework_48": true, "elevated": false, "webview2": "126.0.2592.87",
    "existing_install": { "rewindle": null, "legacy_personal_edition": false },
    "volumes": [
      { "root": "D:\\", "label": "Data", "filesystem": "NTFS", "drive_type": "fixed", "size_bytes": 1000203091968,
        "free_bytes": 640000000000, "is_system": false, "same_physical_disk_as_system": false,
        "eligible": true, "ineligible_reason": null, "ineligible_message": null, "recommended": true }
    ],
    "drivefs": { "detected": false, "my_drive_root": null },
    "known_folders": [
      { "key": "Documents", "path": "C:\\Users\\you\\Documents", "exists": true, "default_selected": true }
    ]
  }
}
```

Property by property:

| Property | Type | Meaning |
| --- | --- | --- |
| `ok` | boolean | `errors` is empty. A real install with the same inputs would pass its checks, except the ones in section 2.7. |
| `errors[]`, `warnings[]` | array | Findings (section 2.4). A warning never makes `ok` false. |
| `resolved.repository` | string or null | The repository folder as setup understood it (absolute, normalized). It can be set even when it was refused. |
| `resolved.storage_mode` | string | `local_ntfs` or `google_drivefs_stream`. |
| `resolved.drivefs_my_drive_root` | string or null | `G:\My Drive` in Google Drive mode, otherwise null. |
| `resolved.sources` | string[] | Only the source folders that passed, normalized, in the order given. The restore canary is not in this list. |
| `resolved.canary_source` | string | The protected folder `C:\ProgramData\ResticBackuper\Canary`. Setup always adds it as an extra backup source. |
| `resolved.schedule` | string or null | `HH:mm`, or null when the given time is invalid. |
| `resolved.vss` | boolean | Backing up open files (VSS); false with `-DisableVss`. |
| `resolved.minimum_free_bytes` | number | `-MinimumFreeGiB` in bytes (default 10 GiB). |
| `resolved.estimated_source_bytes` | null | Always null. The wizard sizes folders itself. |
| `defaults.repository` | string or null | `ResticBackups\Personal` on the recommended volume (section 2.5), or null when no volume is recommended. A wizard may also choose its own folder name; any new or empty folder works. Setup puts a `RecoveryTools` folder **next to** the repository folder, so a repository one level below a drive root puts it in the drive root. |
| `defaults.sources` | string[] | The existing standard folders: Desktop, Documents, Pictures, Videos, Music, Favorites, Downloads and Saved Games. |
| `environment.version` | string or null | The version in the bundle's `payload\VERSION` (or `VERSION` next to the script). |
| `environment.os` | object | `caption`, `build` (build number as a string), `x64`, and `supported`: 64-bit Windows 10 build 10240 or later. |
| `environment.powershell` | string | The running Windows PowerShell version. |
| `environment.dotnet_framework_48` | boolean | .NET Framework 4.8 or later is installed (release 528040+). |
| `environment.elevated` | boolean | The plan process is elevated. |
| `environment.webview2` | string or null | Version of the Microsoft Edge WebView2 Runtime, null when missing. |
| `environment.existing_install.rewindle` | object or null | `{ "version": string or null, "install_root": string }` when Rewindle's program folder, its entry in Installed apps, its Start menu shortcut or its backup or dashboard task exists, otherwise null. Without the program folder (no `already_installed` error) these are leftovers, which the uninstaller clears. |
| `environment.existing_install.legacy_personal_edition` | boolean | The earlier personal edition (`ResticPersonalBackup`) is installed. An unreadable folder counts as installed. Informational: it does not block Rewindle. |
| `environment.volumes[]` | array | Every drive letter Windows reports, in letter order (section 2.5). Strings are never null (`label` and `filesystem` are `""` when unknown). |
| `environment.drivefs` | object | `detected` is true only for a running Google Drive for desktop with its streaming drive at `G:\My Drive`, which is the only arrangement the installer accepts. |
| `environment.known_folders[]` | array | `key` in the order Desktop, Documents, Pictures, Music, Videos, Downloads, Favorites. `path` is null when Windows has none, `exists` says whether the folder is there, `default_selected` whether it is in `defaults.sources`. |

### 2.4 Findings: errors and warnings

Every finding is `{ "code", "field", "message", "path", "detail" }`. For example, an error:

```
{ "code": "repository_not_ntfs", "field": "repository",
  "message": "The drive for the backup folder is formatted as exFAT. Rewindle needs a drive formatted as NTFS.",
  "path": "E:\\", "detail": null }
```

The properties are:

* `code`: a stable snake_case identifier. Code on it, not on the text.
* `field`: where to show it: `repository`, `sources`, `schedule`, `storage_mode` or `environment`.
* `message`: one plain sentence for a non-technical user. Safe to show as is. It may contain the offending path.
* `path`: the folder, file or task the finding is about, or null. For a source folder it is the folder, so a wizard can mark
  the right row.
* `detail`: technical text for a log, never to be shown as the main message. Null except for `plan_internal_error` and
  `environment_probe_failed`.

The same codes are used by a real install: when an install fails its validation, `result.error.code` is one of the codes
below, and the console shows the text the installer has always shown for it.

**Errors**

| Code | Field | When |
| --- | --- | --- |
| `plan_internal_error` | the stage's own | A check failed unexpectedly (a bug or an odd PC). `detail` holds the technical text. |
| `os_not_64bit` | environment | Not 64-bit Windows with 64-bit Windows PowerShell. |
| `system_tool_missing` | environment | `powershell.exe` or `icacls.exe` is missing from System32. |
| `system_tool_untrusted` | environment | One of them does not carry a valid Microsoft signature. |
| `dotnet_framework_missing` | environment | .NET Framework 4.8 is missing or older. |
| `scheduled_tasks_module_missing` | environment | The Windows ScheduledTasks module is missing. |
| `payload_missing` | environment | `payload\` or `payload-manifest.json` is not next to the script. |
| `payload_corrupt` | environment | The manifest is invalid, or a file is missing, unexpected, unsafe, or has the wrong size or SHA-256 value. |
| `payload_incomplete` | environment | A required program file is absent from the payload. Dashboard files are required unless `-SkipDashboard`. |
| `payload_version_invalid` | environment | `payload\VERSION` is not a version number. |
| `already_installed` | environment | `C:\Program Files\ResticBackuper` exists. This alpha does not upgrade in place. |
| `stale_registration` | environment | Rewindle's entry in Installed apps exists. |
| `start_menu_shortcut_exists` | environment | `ResticBackuper.lnk` exists in the Start menu (only matters with the dashboard). |
| `task_name_in_use` | environment | A scheduled task named `ResticBackuper`, `ResticBackuperDashboard` or `ResticBackuperGoogleDriveSync` (a Google Drive verification task an earlier installation left behind) exists. `path` is the task name. Without elevation, tasks of other accounts may be invisible; the install checks again. |
| `recovery_key_stale` | environment | `%USERPROFILE%\ResticBackuper-RecoveryKey.txt` exists but the stored password it belongs to does not. |
| `recovery_key_path_unsafe` | environment | The recovery key path is a link or a folder. |
| `protected_path_reparse_point` | environment | A link or junction sits in Rewindle's own folders (Program Files, ProgramData, the recovery-tools folder). |
| `protected_path_not_directory` | environment | A file or link stands where a Rewindle folder belongs. |
| `system_volume_not_ntfs` | environment | Program Files, ProgramData or the user profile is not on NTFS. |
| `system_volume_unavailable` | environment | The drive of one of those folders is not usable. |
| `volume_serial_unreadable` | environment | Windows would not report a drive's identity. |
| `expected_user_mismatch` | environment | Install only: the elevated account is not `-ExpectedUserSid`. |
| `repository_required` | repository | No `-Repository` was given and there is no default. |
| `repository_not_absolute` | repository | The folder is not a full path. |
| `repository_path_invalid` | repository | The text is not a valid path. |
| `repository_not_local` | repository | A network (UNC) path or a path without a drive letter. Refused before anything touches the network. |
| `repository_is_drive_root` | repository | The top of a drive was given. |
| `repository_overlaps_install` | repository | The folder is inside, or contains, Rewindle's own folders. |
| `repository_overlaps_canary` | repository | The folder is inside, or contains, the restore canary folder. Normally reported as `repository_overlaps_install` first. |
| `repository_has_reparse_point` | repository | The folder or a folder above it is a link or junction. |
| `repository_not_a_folder` | repository | The path is a file or a link. |
| `repository_not_empty` | repository | The folder holds files but is not a Restic repository. |
| `recovery_tools_conflict` | repository | The `RecoveryTools` folder next to the repository holds something that is not Rewindle's. |
| `repository_not_in_drivefs` | repository | Google Drive mode, but the folder is not inside `G:\My Drive`. |
| `repository_drive_unavailable` | repository | The drive is not ready, or is not a fixed or removable drive. |
| `repository_not_ntfs` | repository | Local mode on a drive that is not NTFS. |
| `repository_low_space` | repository | The drive has less than `-MinimumFreeGiB` free. |
| `sources_required` | sources | No source folder. |
| `source_not_absolute` | sources | A source is not a full path. `path` is it. |
| `source_path_invalid` | sources | A source is not a valid path. |
| `source_not_local` | sources | A source is on the network or has no drive letter. |
| `source_drive_unavailable` | sources | A source drive is not ready or not a fixed or removable drive. |
| `source_vss_unsupported` | sources | Open-file backup is on and the source is not on a fixed NTFS drive. |
| `source_not_found` | sources | A source folder does not exist or cannot be opened. |
| `source_duplicate` | sources | A source is listed twice. |
| `sources_overlap` | sources | One source is inside another. |
| `source_has_reparse_point` | sources | A source is, or sits below, a link or junction. |
| `source_overlaps_repository` | sources | A source contains the repository or is inside it. |
| `source_overlaps_install` | sources | A source overlaps Rewindle's own folders. |
| `schedule_invalid` | schedule | The time is not `HH:mm` on the 24-hour clock. |
| `drivefs_options_without_mode` | storage_mode | DriveFS folders were given but the mode is `local_ntfs`. |
| `drivefs_root_unsupported` | storage_mode | The Google Drive folder is not exactly `G:\My Drive`. |
| `drivefs_cache_unsupported` | storage_mode | The cache folder is not `%LOCALAPPDATA%\Google\DriveFS`. |
| `drivefs_reparse_point` | storage_mode | A Google Drive folder is a link or junction. |
| `drivefs_unavailable` | storage_mode | `G:\My Drive` is not there. |
| `drivefs_not_running` | storage_mode | Google Drive for desktop is not running. |
| `drivefs_mount_unsupported` | storage_mode | The drive is not Google Drive's streaming drive. |
| `drivefs_cache_unavailable` | storage_mode | The cache folder is missing. |
| `drivefs_cache_not_ntfs` | storage_mode | The cache is not on NTFS. |
| `drivefs_cache_low_space` | storage_mode | The cache drive has too little free space (at least 10 GiB, or `-MinimumFreeGiB`). |
| `drivefs_object_too_large` | storage_mode | An existing repository file is 4 GiB or larger. |

**Warnings**

| Code | Field | When |
| --- | --- | --- |
| `repository_on_system_disk` | repository | The repository is on the Windows drive, or on another partition of the same physical disk. |
| `repository_exists` | repository | The folder already holds a Rewindle repository. Setup reuses it and keeps its snapshots. |
| `webview2_missing` | environment | The WebView2 Runtime is missing; the install downloads it from Microsoft. |
| `os_unsupported` | environment | Not 64-bit Windows 10 or 11. |
| `environment_probe_failed` | environment | Part of `environment` could not be read; it is empty or null. `detail` says which. |

### 2.5 Volumes

`environment.volumes[]` lists every drive letter with `root` (`D:\`), `label`, `filesystem` (as Windows reports it, for
example `NTFS`, `exFAT`, `FAT32`, `ReFS`), `drive_type` (`fixed`, `removable`, `network`, `cdrom`, `ram` or `unknown`),
`size_bytes`, `free_bytes` (0 when the drive is not ready), `is_system` (the Windows drive), and:

* `same_physical_disk_as_system`: whether the volume lives on the same physical disk as Windows. `true` for the system
  volume, `false` or `true` as determined from the volume's disk extents, and `null` when Windows will not say (a volume
  that is not ready, a network drive, or an unusual storage layout).
* `eligible`: whether a local repository could be kept there: a ready fixed or removable drive formatted as NTFS with at
  least `minimum_free_bytes` free. The Windows drive is eligible (with a warning when chosen). `ineligible_reason` is null
  or one of the codes below, and `ineligible_message` is a plain sentence.
* `recommended`: set on **at most one** volume: the eligible NTFS volume that is **known** to be on a different physical
  disk from Windows, preferring the most free space (ties: the lower drive letter). A volume whose disk is unknown is never
  recommended. If there is none, nothing is recommended and `defaults.repository` is null.

| Reason | Meaning |
| --- | --- |
| `network_drive` | A mapped network drive. |
| `optical_drive` | A CD or DVD drive. |
| `ram_disk` | A RAM disk. |
| `unknown_drive_type` | Windows does not say what it is. |
| `not_ready` | No media, locked or disconnected. |
| `not_ntfs` | Formatted as something else. Google Drive for desktop's streaming drive is listed here as a FAT32 fixed drive (with the size of a local disk), so it is never a local repository; use `environment.drivefs` for it. |
| `low_free_space` | Less than the minimum is free. |

### 2.6 What a plan does not do

A plan does not read your files to size them (`estimated_source_bytes` stays null), does not run Restic, and does not
look inside a repository except to see whether it is empty, already a Restic repository, or (in Google Drive mode) holds an
object of 4 GiB or more. That last scan walks every file of an existing repository, which can take a while for a large one on
Google Drive; plan Google Drive installs onto an existing repository sparingly.

### 2.7 Checked at install time

These need elevation, or change something, so a plan cannot say whether they will pass. Each reports its own result
code if it fails:

* That the elevated account is the one in `-ExpectedUserSid` — `expected_user_mismatch`.
* That a scheduled task name is free, for tasks the plan's account cannot see — `task_name_in_use`.
* Google Drive mode: a test file written and renamed in the backup folder's parent — `drivefs_provider_failed`.
* Installing WebView2 (download, signature check and install) — `webview2_install_failed`, `webview2_installer_untrusted`.
* Everything that creates or changes something: the copy of the program files, the credential, the repository, folder
  permissions, scheduled tasks and the verification afterwards (section 3).

## 3. Install with a progress feed

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-ResticBackuper.ps1 -Unattended
    -ExpectedUserSid <sid> -ProgressPath <absolute .jsonl path>
    -Repository <path> -SourceList "<p1>;<p2>" [-Schedule HH:mm] [-RepositoryStorageMode ...] [-DisableVss]
    [-SkipDashboard] [-StartBackup] [-MinimumFreeGiB <n>] [-DriveFsMyDriveRoot <path>] [-DriveFsCacheDirectory <path>]
```

`-ProgressPath` requires `-Unattended`. It is meant for a wizard that starts the script already elevated (and passes its own
`-ExpectedUserSid`). If the script is started unelevated it asks Windows for approval with the same account, passes
`-ProgressPath` along and the elevated copy writes the feed. **If the approval is declined, no feed is ever created**; the
exit code is non-zero.

### 3.1 The progress file

The elevated script creates it. The path must satisfy all of these, or the script exits non-zero before changing anything
(and writes no feed):

* `-ExpectedUserSid` is given, and is a valid SID. (When the script elevates itself it supplies the SID of the current
  account.)
* Absolute, on a local drive, ending in `.jsonl`.
* In a folder that is **below** the expected user's temporary folder (the file is not directly in `%TEMP%`), and every folder
  between that temporary folder and the file is **owned by the expected user's SID**. The wizard creates
  `%TEMP%\RewindleSetup-<guid>\` unelevated, which satisfies this. The expected user's temporary folder is
  `<profile>\AppData\Local\Temp` for that SID (from the Windows profile list) and, when the script runs as that user, the
  process's own `%TEMP%` if it lies inside the profile.
* No reparse point anywhere in the path, and nothing at the path yet (create-new).

The file takes the access rules of its folder, so the expected user can read it and delete it. It is opened with write
access and `FileShare.Read`, which means a reader must open it with `FileShare.ReadWrite` (and `FileAccess.Read`), for
example `new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)`. Opening it with `FileShare.Read`
fails with a sharing violation.

Each line is one JSON object, UTF-8 without a byte-order mark, ended by a line feed (`\n`), written and flushed to disk
before the next step starts. Read it by polling: remember how many complete lines you have handled. The file is never
rewritten; the script keeps it open until it exits, so delete the folder after the process ends.

If the feed cannot be written (disk full, the folder was deleted) the script stops writing it and carries on: a progress
problem never aborts a healthy install.

### 3.2 Lines

Every line has `schema` (`"Rewindle.InstallProgress.v1"`), `seq` (1, 2, 3, ... with no gaps), `time` (ISO-8601 UTC with
milliseconds, `2026-10-04T10:15:30.123Z`) and `type`.

Phase line:

```json
{"schema":"Rewindle.InstallProgress.v1","seq":3,"time":"2026-10-04T10:15:30.123Z","type":"phase","phase":"payload","state":"started","title":"Copying Rewindle onto this PC","detail":null}
```

* `phase`: one of the ids in section 3.3.
* `state`: `started`, `completed`, `skipped` or `failed`.
  * Phases run one at a time: a `started` is followed by `completed` or `failed` for the same phase before the next phase
    starts. A phase that does not apply appears once, as `skipped`, at the place it would have run.
  * At most one phase is `failed`, and it is the last phase line.
* `title`: a plain sentence fragment for the phase, fixed per phase and safe to show.
* `detail`: null, or a plain sentence. On `completed` it reports a non-fatal outcome (for example "The dashboard could not be
  started right now"); on `skipped` it says why; on `failed` it is the error message.

Result line, **always the last line**, written even when the install fails or is interrupted:

```json
{"schema":"Rewindle.InstallProgress.v1","seq":26,"time":"...","type":"result","ok":true,"error":null,
 "install_root":"C:\\Program Files\\ResticBackuper","recovery_key_path":"C:\\Users\\you\\ResticBackuper-RecoveryKey.txt",
 "recovery_key_readable_by_user":true,"dashboard_executable":"C:\\Program Files\\ResticBackuper\\ResticBackuperDashboard.exe",
 "version":"0.2.0-alpha.1","warnings":[]}
```

| Property | Meaning |
| --- | --- |
| `ok` | The installation is complete and verified. |
| `error` | null, or `{ "code", "message", "detail" }`. `code` is a validation code from section 2.4, or one of the failure codes in section 3.5. `message` is a plain sentence to show; on a failure after setup changed things it ends with a sentence saying setup undid its changes and kept the repository and recovery key. `detail` is the technical text for a log. |
| `install_root` | `C:\Program Files\ResticBackuper`. |
| `recovery_key_path` | The recovery key file, or null when none exists (a failure before it was written). |
| `recovery_key_readable_by_user` | `true` or `false` as section 5 determines it; null when there is no key or it could not be determined. |
| `dashboard_executable` | The dashboard program, or null with `-SkipDashboard` or on failure. |
| `version` | The installed version, or null when unknown. |
| `warnings` | `[{ "code", "message" }]` for non-fatal problems: `dashboard_autostart_failed`, `first_backup_not_started`, `recovery_key_not_readable_by_user`. |

If the process is killed, no result line can be written: treat a missing result line together with a non-zero exit code
(or a missing process) as a failed, interrupted setup.

### 3.3 Phases

Phases are listed in the order the script emits them. The set of twelve is the one in the original request; two of them are
**emitted in a different position from the order in which that request listed them**, because of how the engine works:
`canary` comes before the credential (the engine will not load its configuration until the canary file exists), and
`permissions` comes after the credential, repository and recovery key (the engine's initializer must write into the
protected folders first, and sealing them is the last step that touches them). Render the phases in this order.

| # | Phase | Title | What runs | `skipped` when |
| --- | --- | --- | --- | --- |
| 1 | `preflight` | Checking your PC and the choices you made | Elevation and account checks, every validation of section 2, the summary printed on the console, and (interactively) the confirmation | never |
| 2 | `webview2` | Making sure Microsoft Edge WebView2 is available | Look for the runtime; if missing, download Microsoft's installer, check its signature and run it. `detail` says "Already installed" or "Installed" with the version | `-SkipDashboard` |
| 3 | `payload` | Copying Rewindle onto this PC | Create the repository's parent folder (Google Drive mode: write and rename a test file there), copy the program files to Program Files, check them against the manifest, write the engine configuration and the runtime manifest | never |
| 4 | `canary` | Preparing the restore test file | Create the ProgramData state folder and the protected restore canary the engine backs up and restores | never |
| 5 | `credential` | Creating the backup password and storing it for your account | Generate the repository password and protect it for the account (DPAPI) | never |
| 6 | `repository` | Creating the encrypted backup location | Initialize the Restic repository, or reuse an existing one (`detail` says so) | never |
| 7 | `recovery_key` | Writing your recovery key | Write the plain-text recovery key to the user's profile folder and fill the recovery-tools folder | never |
| 8 | `permissions` | Locking the Rewindle folders so only administrators can change them | Protect Program Files\ResticBackuper, the ProgramData state, the repository (local mode) and the recovery tools | never |
| 9 | `tasks` | Scheduling the daily backup and registering Rewindle with Windows | Register the daily backup task and the entry in Installed apps | never |
| 10 | `dashboard` | Setting up the Rewindle dashboard | Register the start-at-logon task, create the Start menu shortcut and try to start the dashboard | `-SkipDashboard` |
| 11 | `verification` | Checking that everything was installed correctly | Read-only checks that the tasks, shortcut, registration, password, repository, recovery key, restore canary and every installed file are in place and intact, and whether the user can read the recovery key | never |
| 12 | `first_backup` | Starting the first backup | Start the backup task | no `-StartBackup`, or the task could not be started (`detail` says so) |

Phases 5, 6 and 7 are one step of the engine (its repository initializer). They are reported when it finishes: either all
three complete, or the one that failed (decided from what exists on disk) is `failed` and the earlier ones are `completed`.
Do not read their timing as separate durations.

Typical durations: payload copy and verification take seconds; repository creation takes seconds locally and longer in
Google Drive mode; a WebView2 download can take a minute. Show activity for the phase in progress; there is no percentage.

### 3.4 Exit codes and the console

0 when the install completed; 1 when it did not (validation, a failed phase, a refused progress path, a declined approval).
When the script elevated itself, its exit code is the elevated copy's. The console output is what it always was, including
the JSON summary on standard output after success; a wizard should ignore it and read the feed.

### 3.5 Failure semantics

A failure before `payload` starts (any validation, a WebView2 problem) leaves nothing of Rewindle behind: no program folder,
state, task or registration (a WebView2 Runtime that was installed stays, since it is a Microsoft component). A failure from
`payload` on makes the installer remove what it created: the scheduled tasks, the Start menu
shortcut, the entry in Installed apps and the program folder. It keeps what must never be lost: the repository, the
recovery key, the recovery-tools folder and the ProgramData state, **if they were created**. The result line comes after
that cleanup.

In addition to the validation codes of section 2.4, `result.error.code` can be:

| Code | Phase | Meaning |
| --- | --- | --- |
| `preflight_failed` | preflight | An unexpected problem while checking. |
| `webview2_install_failed` | webview2 | The runtime could not be downloaded or installed. |
| `webview2_installer_untrusted` | webview2 | The download failed Microsoft's signature check. |
| `drivefs_provider_failed` | payload | Google Drive did not accept the test file. |
| `payload_copy_failed` | payload | Copying or checking the installed files failed. |
| `canary_failed` | canary | The restore test file could not be prepared. |
| `credential_failed` | credential | The repository password could not be created or stored. |
| `repository_initialization_failed` | repository | Restic could not create or open the repository. |
| `recovery_key_failed` | recovery_key | The recovery key or recovery tools could not be written. |
| `permissions_failed` | permissions | Folders could not be locked down. |
| `task_registration_failed` | tasks | The backup task or the Installed apps entry could not be created. |
| `dashboard_setup_failed` | dashboard | The dashboard task or shortcut could not be created. |
| `verification_failed` | verification | A check of the finished installation failed. The message names what. |
| `setup_failed` | any | An unexpected failure that no phase explains. |
| `setup_interrupted` | any | The script ended before it could report anything (it was stopped). |

## 4. Uninstall

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\ResticBackuper\Uninstall-ResticBackuper.ps1"
    -Unattended -ExpectedUserSid <sid> -ProgressPath <absolute .jsonl path>
```

The same rules as section 3 apply to the parameters, the progress file, the lines, the exit codes and what happens when the
process is started unelevated. Phases:

| # | Phase | Title | What runs | `skipped` when |
| --- | --- | --- | --- | --- |
| 1 | `preflight` | Checking what is installed | Account check; the program folder must match its manifest and every Rewindle scheduled task must be Rewindle's own | never |
| 2 | `stop` | Stopping Rewindle | Stop a running backup, verification task, dashboard and task launcher (waits up to 20 seconds) | never |
| 3 | `tasks` | Removing the scheduled tasks | Remove the backup, dashboard and (if present) Google Drive verification tasks | never |
| 4 | `program_files` | Removing the Rewindle program files | Delete `C:\Program Files\ResticBackuper`; `skipped` when the folder was already gone | when the folder was already gone |
| 5 | `shortcut` | Removing the Start menu shortcut | Delete the shortcut if it points at Rewindle's dashboard | there is no shortcut |
| 6 | `registration` | Removing Rewindle from Installed apps | Delete the entry if it is Rewindle's | there is no entry |
| 7 | `verification` | Checking that Rewindle was removed | The program folder, the tasks and the entry are gone | never |

The result line has `type: "result"`, `ok`, `error` and:

| Property | Meaning |
| --- | --- |
| `operation` | `"uninstall"`. |
| `install_root` | The program folder. |
| `removed` | `{ "install_root": bool, "scheduled_tasks": [names], "start_menu_shortcut": bool, "installed_apps_entry": bool }`; null on failure. `install_root` is false when the program folder was already gone (see below); `start_menu_shortcut` and `installed_apps_entry` are false when there was none or when it did not belong to Rewindle and was kept (with a warning). |
| `kept` | What an uninstall never deletes, so a wizard can tell the user: `state_root` (`C:\ProgramData\ResticBackuper`: settings, history, restore canary), `repository`, `recovery_key`, `recovery_tools` (paths from the installed configuration; null when it could not be read) and `cloud_verification_root` (null unless it exists). |
| `warnings` | `uninstall_metadata_unreadable`, `shortcut_kept_unexpected_target`, `registration_kept_unexpected_owner`. |

**Leftovers of a removed program folder.** When `C:\Program Files\ResticBackuper` no longer exists but the Installed apps entry, the Start menu shortcut or a scheduled task under Rewindle's names remains, the uninstaller removes those instead of stopping with `not_installed` (which it still reports when nothing at all remains). Each leftover goes through the same ownership check as in a full uninstall, and one that is not provably Rewindle's is kept with a warning. This is what lets setup clear a `stale_registration` that would otherwise block a new install, since Windows' own uninstall entry points at the missing uninstaller.

Uninstall removes the **application**, not the backups. Tell the user so: the repository, its snapshots, the recovery key and
the recovery tools stay, and a later install can reuse them.

Failure codes of the uninstaller: `expected_user_mismatch`, `not_installed` (no program folder), `install_not_owned` (the
folder does not match its manifest, so nothing is removed), `task_not_owned`, `cloud_task_not_owned`, `process_not_stopped`
(a task did not stop within 20 seconds; the program files are kept), `preflight_failed`, `stop_failed`,
`task_removal_failed`, `program_files_removal_failed`, `shortcut_removal_failed`, `registration_removal_failed`,
`verification_failed`, `uninstall_failed` and `uninstall_interrupted`.

## 5. The recovery key

**Where.** `%USERPROFILE%\ResticBackuper-RecoveryKey.txt` of the installing account, written by the engine's initializer
(`initialize_repository.py`, through `secret_store.write_recovery_key`) while the installer is elevated. It is plain text with
the repository path and password.

**Who can read it.** The file is created with inheritance removed and an explicit full-control entry for the installing
user's SID, plus SYSTEM and Administrators. (The installer refuses an approval from a different account, so the SID in that
entry is the person using the wizard.) Its owner is whoever created it, normally the Administrators group. The user's
**unelevated** process therefore **can read it**, and delete it, because the entry names the user and not a group the
filtered token has lost.

**`recovery_key_readable_by_user`.** The installer does not take that on trust. At the end of the install it evaluates the
file's access-control list against the groups the same account has when **not** elevated (the elevated token's
Administrators membership is excluded, unless User Account Control is off or the account is the built-in administrator,
where the token is never filtered). It checks, in ACL order with denies first, that read access is granted. The answer is
`true` or `false`, or null when it could not be evaluated. This is an evaluation of the access list, not an attempt to open
the file as another token; it assumes the list is the only thing deciding (no other security layer) and that the profile
folder itself is open to its owner. The CI end-to-end test checks it on a real install.

A `false` also appears as the warning `recovery_key_not_readable_by_user`. The installer does not change the file's access
to fix it.

**If it is not readable — proposed, not implemented.** Do not loosen the file's access list, and do not have the wizard run
elevated to copy it itself. The safest export is a small, separate, reviewed elevated step:

1. The wizard asks for a destination in a normal save dialog (a folder the user owns, outside `C:\Program Files` and
   `C:\ProgramData`).
2. It starts a dedicated script, such as `Export-RecoveryKey.ps1` in the installed program folder (so it is protected by the
   same folder permissions and listed in the runtime manifest), with `Verb RunAs` and `-ExpectedUserSid`, passing only the
   destination.
3. The script takes the source path from the installed `backup-config.json` (`recovery_key_file`), never from the caller.
   It refuses reparse points on both paths, requires the destination folder to be owned by the expected user, creates the
   copy create-new, sets its access list to that user alone, and verifies the bytes. It prints nothing secret and refuses to
   overwrite.
4. It reports success or a reason to the wizard through the same kind of progress file.

The recovery key is a bearer secret, so the wizard must not display it, put it on the clipboard or log it; a file the user
saves and a printout are the supported ways to keep it.

## 6. Notes for the wizard

* **Plan, then install with the same inputs.** Pass the plan's `resolved.repository`, `resolved.sources` and the options you
  planned with. A plan with `ok: false` would fail the real install at the same place.
* **A repository path.** Any new or empty folder on an eligible volume. `RecoveryTools` is created beside it, so prefer a
  folder with a parent that is not a drive root if the drive's top level should stay tidy.
* **Plan again after the user changes a choice.** A plan takes a few seconds (about three on a development machine); most of
  it is reading drives, checking signatures and hashing the payload.
* **The progress folder.** Create `%TEMP%\RewindleSetup-<guid>\` as the unelevated user, pass
  `-ProgressPath %TEMP%\RewindleSetup-<guid>\progress.jsonl`, read with `FileShare.ReadWrite`, and delete the folder when
  the process has exited. Use the same long or short spelling of `%TEMP%` the process sees; both are accepted.
* **Elevation.** Start the installer elevated yourself and pass `-ExpectedUserSid` so you can tell a declined prompt (no
  process, no feed) from a failed install (a feed with a result line).
* **Test hook.** `REWINDLE_SETUP_TEST_ROOTS` points `-PlanOnly` at fixture folders for tests. A real install refuses to run
  when it is set. Do not use it in a product.

## 7. Deviations and additions relative to the original request

* **Phase order**: `canary` and `permissions` are emitted at the positions in section 3.3, not at the positions of the
  request's list, for the reasons given there. The twelve ids are unchanged.
* **Extra properties** (additive): `path` and `detail` on findings; `ineligible_message` on volumes; `schema`, `seq`, `time`
  and `warnings` on the result line; `operation`, `removed` and `kept` on the uninstall result.
* **Extra plan parameters**: `-MinimumFreeGiB`, `-DriveFsCacheDirectory` and `-SkipDashboard` are accepted by `-PlanOnly`.
* **`-Schedule`** is validated in the script body instead of by a parameter attribute, so that a plan can report it; the
  rule is the same and a real install checks it before anything else.
* **Early network check**: a network repository is refused before any probe, in the console path as well. The message is
  the one it always was.
* **New real checks**: the `verification` phase is new behaviour (read-only checks of the finished install) and a failed
  check fails the install like any other phase.
* **Order of two internal steps** changed so that phases are contiguous: the engine configuration and runtime manifest are
  written before the state and canary folders are created, and the entry in Installed apps is registered before the dashboard
  task. Nothing that existed before is skipped.
