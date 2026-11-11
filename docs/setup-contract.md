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
    [-MinimumFreeGiB <n>] [-DriveFsCacheDirectory <path>] [-SkipDashboard] [-RepositoryAccess password|no_password]
```

The last line lists optional parameters beyond the minimal set; they mean what they mean for a real install, and a plan
should be given the same ones the install will get. `-RepositoryAccess` says whether new backups have a password (section 2.8). `-Unattended`, `-StartBackup` and `-ExpectedUserSid` are accepted and
ignored. `-ProgressPath` is refused.

### 2.1 Guarantees

* **No changes, no prompts, no downloads, no elevation.** The plan runs the same validation functions as a real install
  (they are shared code in `Install-ResticBackuper.ps1`) but never calls the ones that create, write, install or register
  anything. The only thing it writes is `-PlanOutput`. (Windows itself may refresh its certificate cache, or fetch a
  missing intermediate certificate, while the Microsoft signature of `powershell.exe` and `icacls.exe` is verified; that is
  outside the script.)
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
    "repository": "D:\\Backups\\Rewindle", "storage_mode": "local_ntfs", "repository_access": "password",
    "existing_repository_access": null, "drivefs_my_drive_root": null,
    "sources": ["C:\\Users\\you\\Documents"], "canary_source": "C:\\ProgramData\\ResticBackuper\\Canary",
    "schedule": "02:00", "vss": true, "minimum_free_bytes": 10737418240, "estimated_source_bytes": null
  },
  "defaults": {
    "repository": "D:\\ResticBackups\\Personal", "storage_mode": "local_ntfs",
    "sources": ["C:\\Users\\you\\Documents"], "schedule": "02:00"
  },
  "environment": {
    "version": "0.2.0-alpha.2",
    "os": { "caption": "Microsoft Windows 11 Pro", "build": "26100", "x64": true, "supported": true },
    "powershell": "5.1.26100.1", "dotnet_framework_48": true, "elevated": false, "webview2": "126.0.2592.87",
    "existing_install": { "rewindle": null, "legacy_personal_edition": false, "kept_repository": null, "kept_repository_access": null },
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
| `resolved.repository_access` | string or null | How the backups are opened: `password` (the recommended default, and what every installation made before the choice existed uses) or `no_password`. Null only when the backup folder already holds backups that no record describes (the install then asks the backups themselves), or when the backup folder was not understood (a `repository` error). Section 2.8. |
| `resolved.existing_repository_access` | string or null | How the backups already in the backup folder are opened, from the records an earlier installation left: `password`, `no_password`, or `unknown` when the folder holds backups that no record describes. Null when the folder holds no backups (a wizard may then offer the choice) or was not understood. Section 2.8. |
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
| `environment.existing_install.kept_repository` | string or null | The repository folder of an earlier installation, from the state folder an uninstall keeps (`C:\ProgramData\ResticBackuper`): the newest of `repository.json` (written when that repository was set up, and rewritten with `relocated_utc` when a move of it completes) and `last-success.json` and `status.json` (written by every backup, so they name the repository each backup used), judged by their UTC times. Reported whether or not Rewindle is still installed. Null when there is no such record, when the state folder is a link or Administrators or SYSTEM don't own it (see `state_folder_untrusted`; an owner the plan's account can't read counts as such here), when the plan's account can't read the record (the installer gives only the installing account access), when it is malformed, names anything but a full path below a drive letter or a way of opening the backups that setup doesn't know, or when that repository has a password and the stored password (`repository-password.dpapi.json`) is gone, since setup could not carry on with that repository then (a repository without a password needs none). The plan reads only those files, never the repository folder, so the folder may be missing or on a drive that is not connected. Informational: never an error or a warning, and `defaults.repository` does not change. |
| `environment.existing_install.kept_repository_access` | string or null | How that kept repository is opened, from the same record: `password` or `no_password`; a record that doesn't say (every record written before the choice existed) means `password`. Null whenever `kept_repository` is null. |
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
| `system_tool_untrusted` | environment | One of them is not signed by Microsoft itself: a valid signature whose signer has one organization, exactly `Microsoft Corporation`, through a chain that ends at Microsoft Root Certificate Authority 2010 or 2011 (or that Windows reports as one of its own files). A name that merely contains "Microsoft" is not enough. |
| `dotnet_framework_missing` | environment | .NET Framework 4.8 is missing or older. |
| `scheduled_tasks_module_missing` | environment | The Windows ScheduledTasks module is missing. |
| `payload_missing` | environment | `payload\` or `payload-manifest.json` is not next to the script. |
| `payload_corrupt` | environment | The manifest is invalid, or a file is missing, unexpected, unsafe, or has the wrong size or SHA-256 value. |
| `payload_incomplete` | environment | A required program file is absent from the payload. Dashboard files are required unless `-SkipDashboard`. |
| `payload_version_invalid` | environment | `payload\VERSION` is not a version number. |
| `already_installed` | environment | `C:\Program Files\ResticBackuper` exists. This alpha does not upgrade in place. |
| `stale_registration` | environment | Rewindle's entry in Installed apps exists. |
| `preserved_state_unreadable` | environment | The state folder an earlier installation left (`C:\ProgramData\ResticBackuper`) has a `plan-state.json` that can't be read, or names an invalid backup-plan identity. A reinstall continues the plan recorded there, so it can't go on. Checked at install time when plan mode can't read the folder. |
| `preserved_state_inconsistent` | environment | That state folder names more than one backup plan. |
| `state_folder_untrusted` | environment | `C:\ProgramData\ResticBackuper` exists but Administrators or SYSTEM don't own it. Any account can create a folder there, so nothing in it is read or used, with or without a stored password; moving it away is left to the user. When plan mode can't read the owner, the install checks it (and refuses an owner it can't read); the install checks again just before it uses the folder. |
| `start_menu_shortcut_exists` | environment | `ResticBackuper.lnk` exists in the Start menu (only matters with the dashboard). |
| `task_name_in_use` | environment | A scheduled task named `ResticBackuper`, `ResticBackuperDashboard` or `ResticBackuperGoogleDriveSync` (a Google Drive verification task an earlier installation left behind) exists. `path` is the task name. Without elevation, tasks of other accounts may be invisible; the install checks again. |
| `recovery_key_stale` | environment | `%USERPROFILE%\ResticBackuper-RecoveryKey.txt` exists but the stored password it belongs to does not, and the backups have a password (never for backups without a password, or while it is not yet known which kind they are). |
| `recovery_key_path_unsafe` | environment | The recovery key path is a link or a folder (not checked for backups without a password, which have no recovery key). |
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
| `repository_access_invalid` | repository | `-RepositoryAccess` is not exactly `password` or `no_password` in lower case (Windows PowerShell accepts other capitals for a parameter, but every part of Rewindle that reads the configuration refuses them). |
| `repository_access_rotation_pending` | repository | The choice is `no_password`, but the state folder an earlier installation kept holds an unfinished change to the keys of earlier backups (`credential-rotation.journal.json`), which only a password can finish. `path` is the state folder. The message says to finish it with a password, or to move the folder aside to start new backups without one. |
| `repository_password_unavailable` | repository | The choice is `password`, the recovery tools beside the backup folder record its backups as having a password (their `backup-config.json` and `recovery-manifest.json` both name this folder and agree: `resolved.existing_repository_access` is `password`), the folder holds backups (a Restic `config` file) and the stored password file (`C:\ProgramData\ResticBackuper\repository-password.dpapi.json`) is not there, so these backups can't be continued and a new password would not open them. The kept record of an earlier installation never raises it on its own: a record that names the folder as having a password counts only while the stored password file exists (`Get-KeptRepository` drops it otherwise, as it does for `kept_repository`), and with the file there nothing is unavailable; once it is dropped, the recovery tools' record decides. `path` is the backup folder. The message is "The backups in this location have a password that Rewindle doesn't have on this PC, so Setup can't continue them. Choose another location for new backups. You can still restore files from these backups with their recovery key." It is reported before anything is changed, by a plan and by an install's preflight, and it carries no "Setup undid its changes" ending. Never raised for a choice of `no_password` (the install asks the backups themselves), for backups no record describes (`existing_repository_access` is `unknown`: the install asks them, and its initializer refuses with exit 7 if they need a password this PC lacks), or when the stored password exists. |
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
| `repository_access_differs` | repository | `-RepositoryAccess` contradicts how the backups already in the folder are recorded (`resolved.existing_repository_access`): "The backups in this location were made without a password. If they still open without one, Setup stops before changing anything. Choose no password to continue them, or choose another location." (for backups made with a password: "The backups in this location were made with a password. If they still need one, Setup stops before changing anything. Choose a password to continue them, or choose another location."). An install with that choice stops before changing anything when the backups still open the recorded way, with `repository_access_mismatch` (section 3.5); backups switched by hand since the records were written go on. Only a given parameter raises it; nothing is ever switched. |
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

### 2.8 With a password or without one

Restic backups are opened either with a password (Rewindle makes a strong one, keeps it protected for the account and writes a
recovery key; this is the recommended default and what every earlier installation has) or, when the person chooses so, with no
password at all. **Anyone who can open the backup folder can then restore every backed-up file, including saved sign-ins.
That includes the folder in Google Drive or on a lost USB drive.** A wizard has to say that, in plain words, before it offers
the choice. The choice is made once per set of backups and never changed afterwards: Rewindle never switches existing backups
from one kind to the other, and a contradiction is refused, never "fixed".

`-RepositoryAccess password|no_password` (optional, in lower case) is the choice. What `resolved.repository_access` becomes:

| `-RepositoryAccess` | The backup folder | `resolved.repository_access` |
| --- | --- | --- |
| given | anything | the value given (the install checks it against the backups themselves and refuses a contradiction) |
| absent | holds no backups | `password`; the console installer asks first (section 3.4), a wizard sends the person's pick |
| absent | holds backups with a record | the recorded way (`resolved.existing_repository_access`) |
| absent | holds backups with no record | null in a plan; the install asks the backups themselves and keeps what it finds |

`resolved.existing_repository_access` is read from, in this order: the state folder an earlier uninstall kept, when its record
names this folder (the same record as `kept_repository`, which for backups with a password counts only while their stored
password file is there); the `backup-config.json` and `recovery-manifest.json` in the
`RecoveryTools` folder next to the backup folder, when both name this folder and agree; otherwise `unknown` when the folder
holds a Restic `config` file, and null when it holds none. A record that doesn't say means `password`; a record that names anything
else is ignored (in the kept state) or makes the answer `unknown` (in the recovery tools). A wizard should offer the choice only when `existing_repository_access` is null (and may send
`-RepositoryAccess` only then), and otherwise tell the person that their backups keep the way they are opened.

## 3. Install with a progress feed

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-ResticBackuper.ps1 -Unattended
    -ExpectedUserSid <sid> -ProgressPath <absolute .jsonl path>
    -Repository <path> -SourceList "<p1>;<p2>" [-Schedule HH:mm] [-RepositoryStorageMode ...] [-DisableVss]
    [-SkipDashboard] [-StartBackup] [-MinimumFreeGiB <n>] [-DriveFsMyDriveRoot <path>] [-DriveFsCacheDirectory <path>]
    [-RepositoryAccess password|no_password]
```

`-ProgressPath` requires `-Unattended`. It is meant for a wizard that starts the script already elevated (and passes its own
`-ExpectedUserSid`). If the script is started unelevated it asks Windows for approval with the same account, passes
`-ProgressPath` along and the elevated copy writes the feed. **If the approval is declined, no feed is ever created**; the
exit code is non-zero.

Once elevated, the installer keeps its temporary files, and those of the programs it starts (Python, Microsoft's WebView2
installer), in a new folder `%ProgramData%\RewindleSetup-<32 hex>` that only Administrators and SYSTEM can change, and
removes it when it exits. It opens the progress file before that, so the file is still checked against the account's own
temporary folder (3.1). Python starts with a cleared environment that names this folder as `TEMP` and `TMP`; the Restic it
starts keeps its temporary files in the `temp` folder of the protected state directory. A folder an interrupted run leaves
behind matches the name pattern of the Setup bootstrap's own folders, so a later Setup run removes it once it is over a day
old.

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
 "version":"0.2.0-alpha.2","repository_access":"password","warnings":[]}
```

| Property | Meaning |
| --- | --- |
| `ok` | The installation is complete and verified. |
| `error` | null, or `{ "code", "message", "detail" }`. `code` is a validation code from section 2.4, or one of the failure codes in section 3.5. `message` is a plain sentence to show; on a failure after setup changed things it ends with a sentence saying setup undid its changes and kept the repository and recovery key, or, when some program files could not be removed, what to do about them (section 3.5). `detail` is the technical text for a log. |
| `install_root` | `C:\Program Files\ResticBackuper`. |
| `recovery_key_path` | The recovery key file, or null when none exists (a failure before it was written) and always null for backups without a password, even when an older key is still in the profile folder. |
| `recovery_key_readable_by_user` | `true` or `false` as section 5 determines it; null when there is no key or it could not be determined, and always null for backups without a password. |
| `dashboard_executable` | The dashboard program, or null with `-SkipDashboard` or on failure. |
| `version` | The installed version, or null when unknown. |
| `repository_access` | `password` or `no_password`: how the backups are opened. Null on a failure that happened before it was known (or while it is still to be asked of the backups), and a wizard treats null as "has a password". A wizard drops its recovery key page only when this is exactly `no_password`. |
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
| 2 | `webview2` | Making sure Microsoft Edge WebView2 is available | Look for the runtime; if missing, download Microsoft's installer into a new folder only administrators can change, check its signature and run it, holding the file open from the check until it exits. `detail` says "Already installed" or "Installed" with the version | `-SkipDashboard` |
| 3 | `payload` | Copying Rewindle onto this PC | Create the repository's parent folder (Google Drive mode: write and rename a test file there), copy the program files to Program Files, check them against the manifest, write the engine configuration and the runtime manifest | never |
| 4 | `canary` | Preparing the restore test file | Create the ProgramData state folder and the protected restore canary the engine backs up and restores | never |
| 5 | `credential` | Creating the backup password and storing it for your account | Generate the repository password and protect it for the account (DPAPI) | never |
| 6 | `repository` | Creating the encrypted backup location | Initialize the Restic repository, or reuse an existing one (`detail` says so) | never |
| 7 | `recovery_key` | Writing your recovery key | Write the plain-text recovery key to the user's profile folder and fill the recovery-tools folder | never |
| 8 | `permissions` | Locking the Rewindle folders so only administrators can change them | Protect Program Files\ResticBackuper, the ProgramData state, the repository (local mode) and the recovery tools | never |
| 9 | `tasks` | Scheduling the daily backup and registering Rewindle with Windows | Register the daily backup task and the entry in Installed apps | never |
| 10 | `dashboard` | Setting up the Rewindle dashboard | Register the start-at-logon task, create the Start menu shortcut and try to start the dashboard | `-SkipDashboard` |
| 11 | `verification` | Checking that everything was installed correctly | Read-only checks that the tasks, shortcut, registration, password, repository, recovery key, restore canary and every installed file are in place and intact, and whether the user can read the recovery key (for backups without a password: no password or recovery key is required or read) | never |
| 12 | `first_backup` | Starting the first backup | Start the backup task | no `-StartBackup`, or the task could not be started (`detail` says so) |

Phases 5, 6 and 7 are one step of the engine (its repository initializer). They are reported when it finishes: either all
three complete, or the one that failed (decided from what exists on disk) is `failed` and the earlier ones are `completed`.
Do not read their timing as separate durations.

**Backups without a password.** All twelve phases are still reported, in the same order. There is no password to create and
no recovery key to write, so `credential` is `skipped` (`detail`: "No password: this backup opens without one."), `repository`
completes, and `recovery_key` completes with the `detail` "This backup has no password, so there is no recovery key.". The
three phases carry other titles then (the table below); the other nine keep the titles above. When the backup folder already
holds backups, `repository` says "Your existing backups in this location were kept and reused.", followed by " They have no
password." for backups without a password; when the install had to ask the backups themselves, by " They have a password, so
Setup kept that." or " They have no password, so Setup kept that.".

| Phase | Title for backups without a password |
| --- | --- |
| `credential` | Choosing no password |
| `repository` | Creating the backup location |
| `recovery_key` | Saving the recovery tools |

Typical durations: payload copy and verification take seconds; repository creation takes seconds locally and longer in
Google Drive mode; a WebView2 download can take a minute. Show activity for the phase in progress; there is no percentage.

### 3.4 Exit codes and the console

0 when the install completed; 1 when it did not (validation, a failed phase, a refused progress path, a declined approval).
When the script elevated itself, its exit code is the elevated copy's. The console output is what it always was, including
the JSON summary on standard output after success (it carries `repository_access` after `repository_storage_mode`, and a null
`recovery_key_file` for backups without a password); a wizard should ignore it and read the feed.

The console installer asks about the password only for a backup folder that holds no backups and when `-RepositoryAccess` was
not given. It asks once the backup folder and the folders to back up are chosen, before the checks that depend on the answer
and before the summary, so an old recovery key file in the profile folder, which matters only to backups with a password,
doesn't stop someone who chooses none. It says "Anyone who can open the backup folder can restore every backed-up file,
including saved sign-ins. That includes the folder in Google Drive or on a lost USB drive." and "You can't change this later
for these backups.", then asks "Make backups without a password? Type yes for no password, or press Enter to keep the
password (recommended)". Yes (or y) means no password; no, n or Enter means a password; anything else is asked again ("Please
type yes or no, or press Enter."). A backup folder that holds backups is not asked about: the console says "These backups
were made with a password, so Setup keeps them that way.", "These backups were made without a password, so Setup keeps them
that way." or "Setup will check whether these backups have a password and keep them that way.". The summary shows
"Password   : yes (recommended)", or "Password   : none" followed by the same two sentences as a warning, before the
confirmation. `-Unattended` never asks and uses the password unless `-RepositoryAccess` says otherwise.

### 3.5 Failure semantics

A failure before `payload` starts (any validation, a WebView2 problem) leaves nothing of Rewindle behind: no program folder,
state, task or registration (a WebView2 Runtime that was installed stays, since it is a Microsoft component). A failure from
`payload` on makes the installer remove what it created: the scheduled tasks, the Start menu
shortcut, the entry in Installed apps and the program folder. It keeps what must never be lost: the repository, the
recovery key, the recovery-tools folder and the ProgramData state, **if they were created**. The result line comes after
that cleanup.

The order matters, because the dashboard is started (phase `dashboard`) before the last checks. The installer first stops
the dashboard and the backup task launcher it started, through Task Scheduler while their tasks are still registered and
then by their exact program files in the program folder. It then removes the tasks, the shortcut and the Installed apps
entry, and finally the program folder, with `runtime-manifest.json` last: the uninstaller removes a program folder only
when that file lists every file in it. If something in the folder still cannot be removed (a file stays in use), the
manifest stays, or is written for exactly what is left when the install failed before writing it or it lacks a file that
is left; reparse points are never followed or removed. Whether the folder is gone is checked before the result is
written. Only when the folder is gone does `error.message` end with "Setup undid
its changes. Backups and the recovery key it had already created were kept." (for backups without a password, or when it is
not known which kind they are, there is no recovery key to mention: "Setup undid its changes. Backups it had already created
were kept."). The failures that say how the backups open, `repository_access_mismatch`, `repository_access_unreadable` and
`repository_password_unavailable` below (the last as the initializer's refusal; its plan and preflight form carries no
ending), end by themselves with "Setup undid its changes, and your backups were not touched." and take no other tail.
Otherwise it says that some program files could not be removed yet and tells the user to restart the PC, then run Setup again
and choose **Reinstall or repair** (which runs the uninstaller first); the next plan reports `already_installed` until then.

The installer reads the exit code of the engine's repository initializer (`docs/engine-contract.md`) like this: 4 or 5 is
`repository_access_mismatch`, 6 is `repository_access_unreadable` and 7 is `repository_password_unavailable`. Each is a
refusal that changes nothing and fails the phase that is running at that moment (`credential` for backups with a password,
`repository` for backups without one). Any other exit code that is not 0 is a failure of the phase named from what is on disk
(`credential`, `repository` or, once the backup folder holds backups, `recovery_key`), with that phase's own words. Only
`repository_password_unavailable` also has a plan and preflight form (section 2.4); the other refusals are found by asking the
backups, which only an install does.

In addition to the validation codes of section 2.4, `result.error.code` can be:

| Code | Phase | Meaning |
| --- | --- | --- |
| `preflight_failed` | preflight | An unexpected problem while checking. |
| `webview2_install_failed` | webview2 | The runtime could not be downloaded or installed. |
| `webview2_installer_untrusted` | webview2 | The download failed Microsoft's signature check (the rule of `system_tool_untrusted`). |
| `drivefs_provider_failed` | payload | Google Drive did not accept the test file. |
| `payload_copy_failed` | payload | Copying or checking the installed files failed. |
| `canary_failed` | canary | The restore test file could not be prepared. |
| `credential_failed` | credential | The repository password could not be created or stored. |
| `repository_initialization_failed` | repository | Restic could not create or open the repository. For backups without a password, or when it is not known which kind they are, the message is "Setup could not create the backup location." |
| `repository_access_mismatch` | credential or repository | The backups in the folder are opened the other way from the one chosen or recorded (the initializer refused with exit 4 or 5: "The backups in this location are protected by a password, but you chose no password...", or the reverse; when the choice came from a record or from asking the backups, "These backups no longer match what Setup recorded for them, usually because they were changed outside Rewindle. Setup can't carry on with them here. Choose another location, or see Switching an existing backup in SECURITY.md on Rewindle's GitHub page."). Each is followed by "Setup undid its changes, and your backups were not touched." `credential` for backups with a password, `repository` for backups without one. Nothing was changed. |
| `repository_access_unreadable` | payload, credential or repository | Setup could not open the backups in the folder to find out how (the detection in `payload`), or to continue them (the initializer's exit 6; for backups with a password also when the backups hold no key at all): "Setup couldn't open the backups in this location to continue them. Check that the backup drive or Google Drive folder is connected and available, then try again. If they still can't be opened, they may be damaged: choose another location for new backups, and keep this folder until you've checked it." followed by "Setup undid its changes, and your backups were not touched." Nothing was changed. |
| `repository_password_unavailable` | credential | The backups in the folder have a password and this PC has no saved password that opens them (the initializer's exit 7), found after the preflight (backups no record describes, or a saved password that does not open them): "The backups in this location have a password that Rewindle doesn't have on this PC, so Setup can't continue them. Choose another location for new backups. You can still restore files from these backups with their recovery key." followed by "Setup undid its changes, and your backups were not touched." Nothing was changed, and no new password was made. A plan and the preflight raise the same code earlier for backups recorded as having a password (section 2.4), with the text alone. |
| `recovery_key_failed` | recovery_key | The recovery key or recovery tools could not be written (for backups without a password, or when it is not known which kind they are, the message is "Setup could not save the recovery tools." instead of "Setup could not write your recovery key.", because there is no key; the phase and the code stay). |
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
| `kept` | What an uninstall never deletes, so a wizard can tell the user: `state_root` (`C:\ProgramData\ResticBackuper`: settings, history, restore canary), `repository`, `repository_access` (`password` or `no_password`, from the installed configuration, where a missing value means `password`; null when it could not be read or names a way of opening the backups that is not known), `recovery_key` (null for backups without a password, which have none), `recovery_tools` (paths from the installed configuration; null when it could not be read) and `cloud_verification_root` (null unless it exists). |
| `warnings` | `uninstall_metadata_unreadable`, `shortcut_kept_unexpected_target`, `registration_kept_unexpected_owner`. |

**Leftovers of a removed program folder.** When `C:\Program Files\ResticBackuper` no longer exists but the Installed apps entry, the Start menu shortcut or a scheduled task under Rewindle's names remains, the uninstaller removes those instead of stopping with `not_installed` (which it still reports when nothing at all remains). Each leftover goes through the same ownership check as in a full uninstall, and one that is not provably Rewindle's is kept with a warning. This is what lets setup clear a `stale_registration` that would otherwise block a new install, since Windows' own uninstall entry points at the missing uninstaller.

Uninstall removes the **application**, not the backups. Tell the user so: the repository, its snapshots, the recovery key and
the recovery tools stay, and a later install can reuse them. (Backups without a password have no recovery key: say "Your
backups are kept", and use `kept.repository_access` to tell the two apart; the console says "Backups have no password, so there
is no recovery key.")

Failure codes of the uninstaller: `expected_user_mismatch`, `not_installed` (no program folder), `install_not_owned` (the
folder does not match its manifest, so nothing is removed), `task_not_owned`, `cloud_task_not_owned`, `process_not_stopped`
(a task did not stop within 20 seconds; the program files are kept), `preflight_failed`, `stop_failed`,
`task_removal_failed`, `program_files_removal_failed`, `shortcut_removal_failed`, `registration_removal_failed`,
`verification_failed`, `uninstall_failed` and `uninstall_interrupted`.

## 5. The recovery key

**Only for backups with a password.** Backups without a password (section 2.8) have no recovery key: none is written, none is
checked, `recovery_key_path` is null in the result and the `recovery_key_not_readable_by_user` warning is never raised, even
when an older key from other backups is still in the profile folder (it is left exactly as it is).

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
  planned with (the password choice goes with the install alone, see below). A plan with `ok: false` would fail the real
  install at the same place.
* **A repository path.** Any new or empty folder on an eligible volume. `RecoveryTools` is created beside it, so prefer a
  folder with a parent that is not a drive root if the drive's top level should stay tidy.
* **A reinstall.** When `environment.existing_install.kept_repository` is set, propose that folder (in Google Drive mode
  when it is inside `environment.drivefs.my_drive_root`), even though it is not `defaults.repository`: the reinstall then
  carries on with the backups already there (`repository_exists`). When the person chooses another folder, say before the
  install that setup starts a new, empty repository there, which needs room for a full first backup and does not show the
  earlier backups. An uninstall your wizard ran itself reports the folder it kept (`kept.repository`), read from the
  installed configuration; prefer that one in the same session. The console installer suggests the same kept folder at its
  prompt.
* **The password choice.** Offer it only when the plan's `resolved.existing_repository_access` is null (the backup folder
  holds no backups), with the sentences of section 2.8 before it and "You can't change this later for these backups.", and
  pass `-RepositoryAccess` only then; otherwise leave it out, and the installer uses the way the backups are recorded or
  asks them. The plans a wizard asks for while the person chooses describe the location alone and never carry the pick: with
  it, the installer would warn about a mode the person never saw at a location that may already have backups. The plan the
  setup host makes just before an install, to find a problem before Windows is asked for anything, carries the choice exactly
  when the install does, so it describes the install that follows. Recovery-key screens are skipped only when the
  result's `repository_access` is exactly `no_password` (or, while installing, when `credential` is `skipped`).
* **Findings that depend on the password.** The plans a wizard asks for while the person chooses never carry the pick, so the
  plan of a location with no backups assumes a password, and can raise `recovery_key_stale` and
  `recovery_key_path_unsafe` before the person has chosen. The wizard never
  stops its first page for them. It counts them, on Review and so for Install, only while the backups have, or may have, a
  password: not when the person picked no password for a new location, and not when the backups there are known to have
  none. Every other finding counts as it always did.
* **Backups Setup can't carry on with.** `repository_access_mismatch` and `repository_password_unavailable` both end an
  install with nothing changed, and trying the same location again would end the same way. The wizard's next step for both
  is to go back and change the backup location, not to try again.
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
* **Extra properties** (additive): `path` and `detail` on findings; `ineligible_message` on volumes; `kept_repository` in
  `environment.existing_install`; `schema`, `seq`, `time` and `warnings` on the result line; `operation`, `removed` and
  `kept` on the uninstall result; `resolved.repository_access`, `resolved.existing_repository_access`,
  `existing_install.kept_repository_access`, `repository_access` on the install result and `kept.repository_access` on the
  uninstall result (the optional password, section 2.8).
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
