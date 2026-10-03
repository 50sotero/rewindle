<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/lockup-light.svg">
    <img src="brand/lockup-dark.svg" alt="Rewindle" width="320">
  </picture>
</p>

<p align="center"><strong>Backup you can verify.</strong></p>

<p align="center">
  A free, open-source backup app for Windows, powered by <a href="https://restic.net/">Restic</a>.<br>
  Encrypted snapshots, a restore test after every run, and a dashboard that shows the evidence.
</p>

<p align="center">
  <a href="https://github.com/50sotero/rewindle/releases">Download</a> ·
  <a href="#install">Install</a> ·
  <a href="#restore-files">Restore</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="SECURITY.md">Security</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

Rewindle backs up the folders you choose to an encrypted [Restic](https://restic.net/)
repository every day. A run only counts as successful after Restic has checked
the repository and Rewindle has restored a small test file from the new
snapshot and checked its SHA-256 hash. The Rewindle dashboard shows that
evidence, your run history, and guided restores, and asks Windows for approval
before anything changes.

> [!WARNING]
> **v0.2.0-alpha.1 is an early public test release.** Rewindle is a pet project,
> provided as is under the [MIT License](LICENSE), with no warranty. The
> executables are not code-signed, so SmartScreen or antivirus software may warn
> about them. It has been tested on only a small number of Windows machines.
> Before you rely on it, restore some of your own files and open them, and keep
> another backup that does not depend on Rewindle.

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Install](#install)
- [Your first backup](#your-first-backup)
- [Restore files](#restore-files)
- [Upgrading](#upgrading)
- [Uninstall](#uninstall)
- [Build from source](#build-from-source)
- [Tests](#tests)
- [Project layout](#project-layout)
- [Security model](#security-model)
- [Privacy](#privacy)
- [Contributing](#contributing)
- [License and credits](#license-and-credits)

## Features

Rewindle runs on Windows 10 and 11 (x64). The dashboard has four pages.

### Protection

- One status line says when the last backup was verified and calls out a
  protected folder or backup drive that cannot be found.
- Separate **Local backup**, **Off-site copy** and **Restore test** cards, each
  with its own evidence and time. With no off-site copy set up, the card is
  replaced by one quiet line: **Off-site copy · Not set up (optional)**.
- **Back up now**, live progress (throughput, elapsed time, estimate), and
  **Cancel backup**, which asks Restic to stop cooperatively. Existing
  snapshots are never touched.
- Protected folders: **Add folder** checks a folder before it is saved;
  removing one stops future backups of it and keeps its old snapshots.
- An unusually large set of deletions or changes is held for **Review
  changes**. Reviewing never deletes or rewrites a snapshot.

### Activity

- Every run Rewindle has observed (the newest 400), with search, date and
  result filters, and run details: an event timeline, the snapshot, and
  suggested next steps for a failure.
- Duration and size trends of verified runs. Failed or cancelled runs are
  marked on the chart, never plotted as values.
- Works from the keyboard: arrow keys, `Home`, `End`, `PageUp` and `PageDown`
  move between runs, `Enter` opens details, `/` focuses the search and `Esc`
  clears it.
- **Export diagnostics** writes a redacted ZIP you can attach to a bug report.

### Restore

- **Open Restore Center** walks through four steps: choose a backup, choose
  files, choose an empty destination, then review and **Restore now**. Restic
  verifies what it restores and never overwrites a file.
- **Check recovery readiness** inspects the repository, the active credential,
  the recovery key, the recovery-tools folder, locks and free space without a
  prompt. From there you can **Run restore drill** (restore a sample with the
  recovery key into a new folder and check it), repair a credential or stale
  locks, and **Rotate keys**.

### Settings

- Appearance (System, Dark or Light; Windows High Contrast is respected) and
  motion (System, Full or Reduced).
- **Change location** moves the repository: it copies to an empty folder,
  verifies the copy and then switches, keeping the old repository.
  **Edit schedule** sets daily or selected-day backups and their run conditions.
- The same three verification cards as Protection, **Export diagnostics**, and
  **About Rewindle**: version, engine, MIT License, and **Open licenses folder**.

Rewindle lives in the notification area. Closing the window never stops a
running backup. `Ctrl+1` to `Ctrl+4` switch pages, `F5` refreshes, and
`Ctrl+=` / `Ctrl+-` / `Ctrl+0` zoom between 80% and 200%. Status is never shown
by color alone, and a screen reader is told when a backup starts, finishes,
fails or is cancelled.

Rewindle does **not** prune snapshots or delete repository data. The repository
grows until you deliberately set up and test a retention policy yourself.

## How it works

Rewindle has two parts that run separately:

- **The engine** is installed in `C:\Program Files\ResticBackuper`. It contains
  PowerShell managers, Python scripts with an embedded Python 3.14 runtime,
  Restic 0.19.1, and a small native task launcher. A scheduled task runs it
  every day and it writes its status to `C:\ProgramData\ResticBackuper`.
- **The dashboard** (`ResticBackuperDashboard.exe`) is a WPF window that hosts a
  React interface in Microsoft Edge WebView2. It runs as you, reads the
  engine's status files, and asks the engine's protected helpers to make any
  change.

A backup run is only marked successful when all of these hold:

1. Restic finished a complete snapshot of exactly the configured folders.
2. `restic check` found the repository structure intact.
3. The restore-test file (a small "canary" file the installer adds to the
   backup) was restored from the new snapshot and its SHA-256 matched.
4. On the configured weekday (Sunday by default), one rotating part of the
   repository data was also read back and checked.

The restore test proves the repository can be found, decrypted and restored
from. It does not prove every file is healthy, so test real restores too.

The executables, tasks and folders keep their `ResticBackuper` names so that
installations of earlier alphas keep working.

### Why Windows asks for approval

Volume Shadow Copy (VSS), which lets Restic read files that are open, needs
administrator rights, so the backup task runs with your account's highest
privileges. Anything that task runs or reads as configuration must therefore be
out of reach of ordinary programs running as you; otherwise malware could
change what runs elevated or redirect your backups. The installer makes
`C:\Program Files\ResticBackuper` and `C:\ProgramData\ResticBackuper` writable
only by Administrators and SYSTEM, and every change goes through a User Account
Control (UAC) prompt.

| What | Runs as | Why |
| --- | --- | --- |
| Backup task `ResticBackuper` (launcher, embedded Python, Restic) | Your account, highest privileges, at the scheduled time while you are signed in | VSS needs administrator rights; your account unlocks the DPAPI-protected repository password |
| Dashboard | Your account, standard rights. It refuses to start as administrator | It only reads status and requests changes |
| **Back up now** | `schtasks.exe /Run` after a UAC prompt | Starts the installed task. The dashboard never starts Restic itself |
| Folder, schedule, location, cancel and restore managers (`Manage-*.ps1`), and the repair helpers | Elevated, after a UAC prompt for each request, for your account only | They change protected configuration, the task or the repository, or read backups to restore them |
| Recovery readiness check | Your account, no prompt, read-only | Inspection only |
| Installer and uninstaller | Elevated, with the same account that started them | Program Files, ProgramData, Task Scheduler and the Installed apps entry |
| Optional Google Drive verifier task | Your account, highest privileges, daily at 03:00 | Shares the protected run lock and reads protected credentials |

**Restore approvals.** A guided restore asks for Windows approval once per
restore session, not at every step. An elevated session broker
(`Manage-Restore.ps1 -Operation session`) serves the snapshot list, folder
listings and at most one restore over a named pipe that only your account can
open; each side checks the other's process, and the session ends after its
restore, when Restore closes, when the plan changes, or after 10 idle or 60
total minutes. Choosing a backup reads nothing until you click **Browse
files**, and folders already listed are not read again. With the legacy
engine, each step still asks separately. The protocol is in
[`docs/engine-contract.md`](docs/engine-contract.md), section 9.

### Where things live

| Purpose | Location |
| --- | --- |
| Engine, dashboard and backup configuration (protected) | `C:\Program Files\ResticBackuper` |
| DPAPI password envelope, restore-test file, status, logs and run records (protected) | `C:\ProgramData\ResticBackuper` |
| Repository | The folder you choose |
| Recovery tools (Restic, restore script, `RECOVERY.md`; no password) | `RecoveryTools` beside a local repository, or `C:\ProgramData\ResticBackuperRecoveryTools` for Google Drive mode |
| Recovery key (plain text) | `%USERPROFILE%\ResticBackuper-RecoveryKey.txt` |
| Dashboard settings, run history and crash log | `%LOCALAPPDATA%\ResticBackuperDashboard` |
| Google Drive verifier assets and evidence (optional) | `C:\ProgramData\ResticBackuperCloudVerification` |

See [docs/architecture.md](docs/architecture.md) for the full data flow and
trust boundaries.

## Install

### Requirements

- 64-bit Windows 10 or Windows 11 with Windows PowerShell 5.1 and .NET
  Framework 4.8 (the installer checks .NET before changing anything).
- A Windows account that is an administrator, with User Account Control on.
  Approve the UAC prompt with that same account: the repository password is
  protected for your account (DPAPI), so the installer refuses an approval from
  a different administrator account.
- Microsoft Edge WebView2 Runtime. If it is missing, the installer downloads
  Microsoft's bootstrapper, checks its Microsoft signature and installs it.
- A repository folder on a local NTFS drive, new or empty, with at least
  10 GiB free. A separate physical drive is strongly recommended; the installer
  warns if you pick the Windows drive.
- Source folders on local fixed or removable drives with drive letters. Network
  and UNC paths are not supported. With VSS on (the default) every source must
  be on a fixed NTFS drive.
- You must be signed in for scheduled backups to run.

No separate Restic or Python installation is needed: the release contains
pinned, checksum-verified builds of both.

### Download and verify

From the [Releases page](https://github.com/50sotero/rewindle/releases),
download either the setup program or the ZIP, plus its `.sha256` file:

- `Rewindle-v0.2.0-alpha.1-windows-x64-setup.exe`: a small bootstrapper that
  unpacks the same ZIP to a temporary folder and runs its `Install.cmd`.
- `Rewindle-v0.2.0-alpha.1-windows-x64.zip`: extract it, review the scripts if
  you like, then double-click `Install.cmd`.

Compare the checksum before you run anything:

```powershell
(Get-FileHash .\Rewindle-v0.2.0-alpha.1-windows-x64-setup.exe -Algorithm SHA256).Hash.ToLower()
Get-Content .\Rewindle-v0.2.0-alpha.1-windows-x64-setup.exe.sha256
```

The two values must match. A checksum shows the file is the one published; it
does not prove who published it. Do not turn off SmartScreen or antivirus
protection globally to run the installer.

### What the installer does

The installer opens a console window, asks for UAC approval, and then:

1. Checks every file in the package against its SHA-256 manifest.
2. Asks for the **repository folder**. It suggests a folder on the non-system
   NTFS drive with the most free space.
3. Asks for the **folders to back up**, separated by semicolons. It suggests
   the standard folders that exist on your PC (Desktop, Documents, Pictures,
   Videos, Music, Favorites, Downloads and Saved Games). Folders may not
   contain one another or overlap the repository.
4. Shows a summary and asks you to confirm. Nothing is created before you
   answer `y`.
5. Installs WebView2 if needed, copies the engine and dashboard into
   `C:\Program Files\ResticBackuper`, initializes the encrypted repository with
   a random password stored for your account (DPAPI), writes the plain-text
   recovery key to your profile folder, and creates the recovery-tools folder.
6. Restricts the protected folders so only Administrators and SYSTEM can
   change them.
7. Registers the daily backup task (02:00 by default; it starts as soon as
   possible after a missed time and may wake the PC), a logon task that starts
   the dashboard in the notification area, a Start menu shortcut (named
   `ResticBackuper`), and a **Rewindle** entry in Installed apps.

It does not start a backup. If anything fails, it removes what it created and
keeps the repository, recovery key, recovery tools and ProgramData state.

A default exclusion list skips reproducible folders such as `node_modules`,
Python virtual environments and build-tool caches. Change the schedule later in
**Settings > Edit schedule**, and add or remove folders on **Protection**.

<details>
<summary><strong>Unattended install and options</strong></summary>

From an extracted ZIP folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ResticBackuper.ps1 `
  -Repository 'D:\Backups\Rewindle' `
  -SourceList 'C:\Users\you\Documents;C:\Users\you\Pictures' `
  -Schedule '02:00' `
  -Unattended
```

| Option | Meaning |
| --- | --- |
| `-Repository <folder>` | Repository folder. Required with `-Unattended`. |
| `-SourceList <a;b;c>` | Folders to back up, separated by semicolons. Required with `-Unattended`. |
| `-Schedule HH:mm` | Daily start time, 24-hour clock (default `02:00`). |
| `-MinimumFreeGiB <n>` | Free space the repository drive must keep (default 10). |
| `-DisableVss` | Turn off VSS capture of open files. Allows local removable or non-NTFS sources. |
| `-SkipDashboard` | Install the engine only. |
| `-StartBackup` | Start the first backup when installation finishes. |
| `-Unattended` | No prompts. |
| `-RepositoryStorageMode google_drivefs_stream` | Keep the repository in Google Drive for desktop (see below), with `-DriveFsMyDriveRoot 'G:\My Drive'` and `-DriveFsCacheDirectory "$env:LOCALAPPDATA\Google\DriveFS"`. |

</details>

### Optional: an off-site copy

Rewindle never chooses a cloud destination for you, and it never reports a
local repository as an off-site copy. Without one, Protection shows **Off-site
copy · Not set up (optional)**.

The one off-site arrangement Rewindle can verify is a repository kept directly
in Google Drive for desktop's **My Drive** streaming folder. You choose it at
install time with `-RepositoryStorageMode google_drivefs_stream` and a
repository strictly below `G:\My Drive`. Google Drive for desktop must be
running, its cache must be on NTFS with at least 10 GiB free, and every
repository file must stay smaller than 4 GiB. Credentials, state, recovery
tools and the recovery key stay on your local disk.

An optional daily verification task can then compare every repository file
with a read-only Google Drive API listing and restore the test file directly
from the cloud. Its proof is bound to the repository of the installed backup
plan, and the **Off-site copy** card shows it. Setup (a reviewed rclone build,
a read-only Google token, and the task) is described in
[docs/google-drive-direct-verification.md](docs/google-drive-direct-verification.md).

This is not an offline copy: a mistake in, or loss of, the Google account can
still affect it. For a local repository, any off-site copy is up to you; use a
separate system you have tested.

## Your first backup

1. Open Rewindle from the notification area, or from the Start menu shortcut
   named `ResticBackuper`.
2. On **Protection**, choose **Back up now** and approve the Windows prompt.
   From an elevated PowerShell window, `Start-ScheduledTask -TaskName ResticBackuper`
   requests the same task.
3. Wait for the run to finish. The first backup reads everything and can take a
   long time; later runs only store what changed. Protection reports the backup
   as verified only after the checks above pass.
4. Copy `%USERPROFILE%\ResticBackuper-RecoveryKey.txt` somewhere off this PC:
   a password manager, an encrypted USB drive, or a printed copy in a safe
   place. Anyone with this key and the repository can read your backup. If you
   lose both your Windows profile and this key, the backup cannot be decrypted.
   Copy it rather than move it: the Restore Center, the readiness check and the
   restore drill expect the original at that path and refuse to run without it.
5. Restore a few real files to a new folder and open them (see below). Repeat
   this from time to time and after changing your setup.

## Restore files

**In the dashboard.** Go to **Restore > Open Restore Center**:

1. **Choose a backup.** Search and filter snapshots by date.
2. **Choose the files.** Browse the snapshot and select files or folders (up to
   64 items; select a parent folder to cover more), or the whole snapshot.
3. **Choose a destination.** It must be a new or empty local folder that does
   not overlap a protected folder, the repository or Rewindle's own folders.
   Network paths, junctions, symbolic links and OneDrive-synced folders are
   refused.
4. **Review and restore.** Check the snapshot, the selection and the
   destination together, then choose **Restore now** and approve the prompt
   (see [Restore approvals](#why-windows-asks-for-approval)).

Your original files are never touched. The result screen links to the restored
folder; check the files before putting them back into use. A restore that has
started cannot be cancelled from the dashboard.

**Without the dashboard.** The recovery-tools folder contains Restic, the
restore script and [`RECOVERY.md`](src/RECOVERY.md), which explains a restore on
the same PC and one with only the repository and the recovery key. For example,
with only those two:

```powershell
.\restic.exe --repo 'X:\Path\To\Repository' snapshots
.\restic.exe --repo 'X:\Path\To\Repository' restore `
  'latest:/C/Users/you/Documents' `
  --target 'X:\Restored-Documents' --overwrite never --verify
```

Restic asks for the password: paste the value from the `Password:` line of the
recovery key file.

## Upgrading

### From an earlier alpha

Earlier alphas (0.1.x, published as ResticBackuper) use the same names as this
release, and this alpha does not upgrade in place: the installer refuses to run
while an earlier version is installed. Uninstall it from Installed apps (your
repository, credential, recovery key and recovery tools are kept), then run the
new installer and choose the same repository folder. The installer reuses the
repository when the credential kept in `C:\ProgramData\ResticBackuper` still
opens it.

A new installation starts a new backup plan. Snapshots from the earlier plan
stay in the repository. The Restore page lists the current plan's snapshots,
plus snapshots made before plans existed that exactly match it (marked
**Legacy / unbound**); use the recovery tools to restore anything else.

### From the earlier personal edition

Before Rewindle, this engine existed as a personal edition installed under
`ResticPersonalBackup` names (`C:\Program Files\ResticPersonalBackup`, task
`ResticPersonalBackup`). The dashboard still supports it through its **legacy
engine profile**:

- The dashboard picks its engine when it starts: the Rewindle engine if it is
  installed, otherwise the personal edition. `--engine rewindle` or
  `--engine legacy` chooses explicitly. If neither is installed, it shows
  **Engine not installed** and where it looked.
- The two engines use different names, so the Rewindle installer neither
  detects nor changes a personal-edition installation.
- There is no migration. The Rewindle installer will not adopt the personal
  edition's repository, because it has no credential for it. Install Rewindle
  with a new, empty repository, and keep the old repository and its recovery
  key until you no longer need its history.
- With the legacy profile, the engine version is not shown, a held change set
  is approved for off-site promotion as that edition defines it, and restore
  approvals are asked per step.

The full list of differences is in [docs/engine-contract.md](docs/engine-contract.md).

## Uninstall

Open **Settings > Apps > Installed apps**, find **Rewindle** and choose
**Uninstall**, then confirm in the console window. Uninstalling stops a running
backup, so let it finish first. It removes:

- `C:\Program Files\ResticBackuper`,
- the backup, dashboard and (if present) Google Drive verification tasks,
- the Start menu shortcut and the Installed apps entry.

It deliberately keeps your repository, `C:\ProgramData\ResticBackuper` (the
password envelope, status and logs), the recovery tools, the recovery key,
any Google Drive verifier assets, and the dashboard's settings and history in
`%LOCALAPPDATA%\ResticBackuperDashboard`. Delete those yourself only when you
no longer need the backups. Deleting the repository deletes your backups.

## Build from source

You need 64-bit Windows with the .NET Framework 4.8 compiler, PowerShell 7
(`pwsh`), Node.js 22.12 or newer (20.19+ also works) with npm, and internet
access for the first build. Then, from the repository root:

```powershell
pwsh .\build\Build-Release.ps1
```

This downloads the Python and Restic archives and rejects any that do not match
the SHA-256 values in [`dependencies.json`](dependencies.json), fetches the
pinned WebView2 SDK and the locked npm dependencies, builds the task launcher
and the dashboard, and writes the release to `artifacts\`:
`Rewindle-v<VERSION>-windows-x64.zip`, the `-setup.exe`, and a `.sha256` file
for each.

To build only the dashboard:

```powershell
pwsh .\src\dashboard\build.ps1
```

Its output goes to `src\dashboard\dist\`. To work on the interface without an
installed engine, run it with invented sample data in a browser; see
[src/dashboard/README.md](src/dashboard/README.md).

The ZIP layout is normalized, but the .NET Framework compiler can produce
different executable bytes from the same source, so a rebuild is not
guaranteed to match a published checksum byte for byte. `VERSION` is the single
source of the version number.

## Tests

Run these from PowerShell in the repository root:

```powershell
# Python unit tests and source checks (test_key_rotation runs only after a release build,
# because it uses the real restic.exe)
py -3.14 -m unittest discover -s tests

# Dashboard regression checks (needs a built dashboard)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File src\dashboard\tests\restore-flow-regressions.ps1 -SkipInstalledChecks

# One of the PowerShell suites in tests\*.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-ManageSources.ps1

# Two real backups and an independent restore from the built release ZIP
pwsh .\tests\Test-ReleaseArtifact.ps1
```

The suites build disposable fixtures in your temporary folder and do not change
an installed copy. CI runs most of them on every pull request; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

| Path | Contents |
| --- | --- |
| `src/` | The engine: `backup.py`, `restore.py`, shared Python modules, the `Manage-*.ps1` managers, recovery helpers, the Google Drive verifier, `RECOVERY.md`, default `excludes.txt` and example configurations |
| `src/task_launcher/` | `ResticBackuperTaskLauncher.exe`, the native supervisor the backup task starts |
| `src/dashboard/` | The Rewindle dashboard: WPF host (C#) and React interface (`web/`); see its [README](src/dashboard/README.md) |
| `installer/` | `Install.cmd`, `Install-ResticBackuper.ps1`, `Uninstall-ResticBackuper.ps1` and the setup bootstrapper |
| `build/` | `Build-Release.ps1` and the `VERSION` helper |
| `tests/` | Python and PowerShell test suites and fixtures |
| `docs/` | Architecture, the dashboard and engine contract, Google Drive verification, release notes |
| `brand/` | Logo, icons and brand tokens |
| `licenses/` | Third-party license texts (Python's is added by the build) |
| `dependencies.json` | Pinned download URLs and SHA-256 values for Python and Restic |
| `VERSION` | The release version |

## Security model

- The dashboard runs without administrator rights, never reads the repository
  password, and never runs Restic. Every change is made by a protected helper
  started by fixed path after a UAC prompt.
- Each manager request names your Windows account and carries a one-time nonce
  inside a SHA-256 request digest. The dashboard accepts a result only from the
  protected results folder and only when every binding matches the request.
  Repair helpers are bound to the current plan, its generation, the
  configuration hash and your account.
- The repository password is random, stored with Windows DPAPI for your
  account, and handed to Restic through a password command, never on a command
  line or in a log. The recovery key is a separate copy for disaster recovery.
- The installer checks every file against a SHA-256 manifest, and the folder,
  location and restore managers re-check the installed runtime against its
  manifest before acting.
- Paths are checked strictly: no network or UNC paths, no junctions or other
  reparse points, short-name (8.3) aliases expanded before comparison, no
  overlap between sources, repository and protected folders, and restore
  targets that must be new or empty and are never overwritten.
- Nothing is deleted from the repository automatically.

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md). The
dashboard's exact interface with the engine is in
[docs/engine-contract.md](docs/engine-contract.md).

## Privacy

Rewindle has no telemetry, analytics, remote crash reporting or update check.
In this code base, "telemetry" means the local status files the engine writes
for the dashboard.

- The dashboard's web view loads only its own bundled files from a local
  virtual host. The app answers every other web request with an error and
  refuses new windows, downloads and external links. The project address in
  **About** is plain text, not a link.
- The dashboard opens a web page only when you choose the WebView2 download
  button that appears if the runtime is missing (Microsoft's download page, in
  your browser).
- The installer downloads Microsoft's WebView2 bootstrapper only if WebView2 is
  missing.
- The engine contains no network code of its own. With a local repository,
  Restic only reads and writes local files. In the optional Google Drive mode,
  Google Drive for desktop uploads the repository, and the optional verifier
  reads it back through the Google Drive API with rclone and your read-only
  token.
- Logs, run history and crash logs stay on your PC. A diagnostics ZIP is only
  created when you export one, and you decide whether to share it.
- Building from source downloads the pinned Python, Restic and WebView2 SDK
  packages and the npm dependencies.

Microsoft Edge WebView2 and Google Drive for desktop are separate products with
their own privacy terms.

## Contributing

Bug reports, Windows compatibility reports, documentation fixes and focused
pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and
the [Code of Conduct](CODE_OF_CONDUCT.md) first, and report security problems
privately as described in [SECURITY.md](SECURITY.md). When you open a bug
report, the diagnostics ZIP from **Activity > Export diagnostics** helps a lot;
review it before attaching it.

## License and credits

Rewindle is released under the [MIT License](LICENSE). Copyright (c) 2026
Victor Sotero.

Rewindle is an independent project, not affiliated with or endorsed by the
projects below. Release packages include:

- [Restic](https://restic.net/) 0.19.1, BSD 2-Clause License.
- Python 3.14 embeddable distribution, Python Software Foundation License.
- [Beautiful UI](https://github.com/slev12397/beautiful-ui) components, MIT
  License (provenance in
  [`src/dashboard/web/vendor/UPSTREAM.md`](src/dashboard/web/vendor/UPSTREAM.md)).
- Motion and Liveline (MIT), React, Lucide, and the Inter and JetBrains Mono
  fonts from Fontsource (SIL Open Font License 1.1).
- The Microsoft Edge WebView2 SDK libraries. The WebView2 Runtime itself is
  installed from Microsoft, not bundled.

Details are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and the build
copies every bundled component's license into the `licenses` folder beside the
app (**Settings > About Rewindle > Open licenses folder**).
