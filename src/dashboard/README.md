<p align="center">
  <img src="web/public/rewindle-icon.svg" width="72" height="72" alt="Rewindle" />
</p>

<h1 align="center">Rewindle dashboard</h1>

<p align="center">Developer notes for the desktop app in <code>src/dashboard</code>.</p>

---

This folder holds the Rewindle dashboard, `ResticBackuperDashboard.exe`: the
window people use to watch their backups, change folders and the schedule, and
restore files. It does not back anything up itself. It reads the state of an
installed backup engine and asks the engine's protected helpers, through
Windows approval (UAC), to make every change.

For what Rewindle is, how to install it and how to use it, see the
[root README](../../README.md). For contribution rules, including the
protections that must never be weakened, see
[CONTRIBUTING.md](../../CONTRIBUTING.md). The exact interface between this app
and an engine is in [docs/engine-contract.md](../../docs/engine-contract.md).

## Contents

- [How it is built](#how-it-is-built)
- [Engines](#engines)
- [What the dashboard starts](#what-the-dashboard-starts)
- [Build](#build)
- [Work on the interface with sample data](#work-on-the-interface-with-sample-data)
- [Run a build](#run-a-build)
- [Tests](#tests)
- [Behavior to preserve](#behavior-to-preserve)
- [Installed layout](#installed-layout)
- [Source guide](#source-guide)
- [Credits](#credits)

## How it is built

| Layer | Technology | Where |
| --- | --- | --- |
| Native host | C# on .NET Framework 4.8, WPF, compiled with the Framework's `csc.exe` (no project file) | `*.cs`, `build.ps1` |
| Web view | Microsoft Edge WebView2 (SDK 1.0.4191.47, pinned by hash in `build.ps1`) | `DashboardWindow.Web.cs` |
| Interface | React 19, TypeScript, Vite 7, Tailwind CSS 4, Motion, Liveline, Lucide | `web/` |
| Components | Beautiful UI sources, copied at a pinned commit | `web/components/`, `web/vendor/UPSTREAM.md` |

The host maps the bundled `web` folder to a local virtual host
(`https://restic.local`) and loads `index.html` from it. Every other request
gets an empty `403` response, and the host refuses navigation away from that
host, new windows, downloads, permission requests, external URI schemes and
basic authentication. Developer tools, the default context menu and the
browser's accelerator keys are off. `index.html` carries a strict Content
Security Policy (`default-src 'self'`).

The page and the host talk over the WebView2 message bridge. The page sends
commands from a fixed list (`CommandName` in `web/src/native-types.ts`), and the
host acts only on those it allows. The host publishes the dashboard state to
the page and tells it the app is alive at least every five seconds, so the page
can tell when it has lost the app. Commands that open a folder in File Explorer
carry no path from the page; the host decides which folder to open.

`--native` starts an older WPF-only presentation instead of the web view, for
diagnosis.

If WebView2 fails, the host recovers by itself where it can: a crashed renderer
or browser process is reloaded automatically up to three times in five
minutes, then the app offers **Reload**; a page that stops responding is given
15 seconds before the app offers **Keep waiting** or **Reload**; a missing
runtime gets a notice with a button for Microsoft's download page.

## Engines

Every name the dashboard uses to find an engine, ask it for something and
trust its answer lives in one class, `EngineProfile.cs`. No other file may name
an engine. Two profiles are built in:

| | Rewindle (default) | Legacy personal edition |
| --- | --- | --- |
| Install root | `C:\Program Files\ResticBackuper` | `C:\Program Files\ResticPersonalBackup` |
| Protected state | `C:\ProgramData\ResticBackuper` | `C:\ProgramData\ResticPersonalBackup` |
| Backup task and launcher | `ResticBackuper`, `ResticBackuperTaskLauncher.exe` | `ResticPersonalBackup`, `ResticBackupTaskLauncher.exe` |
| Request domains and schemas | `ResticBackuper.*` | `ResticPersonalBackup.*` |
| Direct cloud proof | `ResticBackuperCloudVerification\evidence\latest-verification.json`, also bound to its evidence and asset manifest | `ResticPersonalBackupCloudVerification\latest-verification.json` |
| Anomaly review | An acknowledgement; Google Drive upload is never paused | An approval that releases one generation for off-site promotion |
| Restore approvals | One per restore session (advertised by `engine-capabilities.json`) | One per step |
| Dashboard folder | `%LOCALAPPDATA%\ResticBackuperDashboard` | `%LOCALAPPDATA%\ResticPersonalBackupDashboard` |
| Version shown | The `VERSION` file the installer puts in the install root | Not recorded by that edition |

For both engines, a direct cloud proof is accepted only for the repository of
the installed plan: the proof's repository must be the plan's, its My Drive
root an ancestor of it, and its cloud path the repository's path below that
root.

The profile is chosen once, in `Program.Main`, before any engine path is read:
the engine whose protected install root holds `backup-config.json` (Rewindle
first when both do), or the one `--engine rewindle` or `--engine legacy` names.
A root Windows will not let the app inspect counts as installed, so it is never
passed over for the other engine. With neither installed, Protection, Restore
and Settings show **Engine not installed** with every place the app looked,
**Check again**, and a line with the app, engine, Windows and WebView2 versions
to paste into an issue; nothing that would change a backup is offered. A
profile changes only names: every check made with them (UAC, nonce- and
digest-bound requests, path, ACL and reparse-point checks, the runtime
manifest) is the same for both.

## What the dashboard starts

The dashboard runs with standard rights and refuses an administrator launch.
It never reads the repository password and never runs Restic. Everything that
touches the backup is done by helpers under the active engine's protected
install root or in `System32`, started by fixed path.

| The dashboard starts | To | How |
| --- | --- | --- |
| `schtasks.exe /Query` | Read the installed backup task and its schedule. | As the user. Read-only, with a time limit and an output cap. |
| `schtasks.exe /Run` | Ask Windows to start the engine's backup task. | After a UAC prompt, only for a task whose definition validates, is enabled and allows a manual start. Task Scheduler starts the task and its launcher; the dashboard never does. |
| Windows PowerShell running `Manage-Sources.ps1`, `Manage-Schedule.ps1`, `Manage-Repository.ps1`, `Manage-Restore.ps1` or `Manage-Backup.ps1` from the install root | Change protected folders, the schedule or the repository location, browse and restore backups, cancel a run. | After a UAC prompt for each request. A request names the user's SID and carries a one-time nonce inside a request digest, and the result is accepted only from the protected results folder when it is bound to that exact request. |
| `Python\python.exe` running `recovery_health.py` from the install root | Inspect recovery readiness. | As the user, with no prompt. Read-only, 60 seconds at most, with an output cap. |
| `Python\python.exe` running `credential_repair.py`, `stale_lock_repair.py`, `anomaly_review.py` or `key_rotation.py` | Repair the credential, clear stale locks, acknowledge a held change set, rotate keys. | After a UAC prompt. Each is bound to the plan, its generation, the plan file's SHA-256 and the user's SID (an anomaly review also to the exact run, snapshot and evidence). |
| `explorer.exe` | Show a folder the user asked for, such as a finished restore or the licenses folder. | As the user. The host chooses the folder. |

A request Windows does not approve changes nothing, and the dashboard reads
each result back and checks it against the request before reporting a change.

**Export diagnostics** writes a new ZIP after redacting it: whole paths (either
slash direction), Windows user and computer names, account IDs, email
addresses, long tokens and cloud-proof hashes. A final check refuses the export
if anything remains, and leaves the crash log out if it cannot be made safe.
`manifest.json` names the engine and lists every skipped document with its
reason.

## Build

Requirements:

- Windows x64 with the .NET Framework 4.8 compiler and WPF assemblies.
- Node.js 22.12 or newer (20.19 and later 20.x also work) with npm on `PATH`.
  `web/package.json` declares the range and the repository's `.node-version`
  names the release CI uses. `build.ps1` checks both before it downloads or
  compiles anything.
- Internet access for the first build (the WebView2 SDK from NuGet and the npm
  packages).

From the repository root:

```powershell
pwsh .\src\dashboard\build.ps1
```

The build:

1. Copies the version from the repository's `VERSION` file into
   `web/package.json` and its lockfile if they differ (commit them together).
2. Installs the locked web dependencies with `npm ci --ignore-scripts`, checks
   TypeScript and bundles the interface into `dist/web`.
3. Downloads the pinned WebView2 SDK and refuses it if its SHA-256 differs.
4. Compiles `dist/ResticBackuperDashboard.exe` with version resources from
   `VERSION`.
5. Rebuilds `dist/licenses` from the Beautiful UI license, the WebView2 SDK
   license and notice, and the license files of every runtime web dependency. A
   dependency that ships no license file stops the build.
6. Writes `dist/dashboard-assets.json`, a SHA-256 manifest of the web assets,
   licenses and WebView2 DLLs, and prints the executable's and the manifest's
   hashes.

`.\build.ps1 -SkipWeb` recompiles only the native host, reusing an earlier web
build and its installed dependencies. `build\Build-Release.ps1` at the
repository root runs this script and packages `dist` with the engine; keep the
executable, the three WebView2 DLLs, `web/`, `licenses/` and
`dashboard-assets.json` together, because the installer refuses a bundle whose
files do not match the manifest. The executable embeds its build time, so two
compiles of the same source print different hashes.

## Work on the interface with sample data

The interface can run in an ordinary browser with invented sample data: made-up
folders, a month of run history, charts, run details and the animation
preview. Use it for UI work and for screenshots, so no real folders or history
appear in an image.

```powershell
Set-Location src\dashboard\web
npm ci --ignore-scripts
npm run dev          # http://127.0.0.1:5178 with sample data
npm run dev:demo     # the same in the demo build mode
npm run typecheck    # TypeScript only; writes nothing
npm run build:demo   # static sample-data build in src\dashboard\build-output\demo
```

Everything that would touch a backup, a schedule, a folder or the file system
answers "Sample data is read-only." The sample lives in `web/src/demo/` and is
reached only through a build-time guarded import in `web/src/main.tsx`, so the
bundle that `build.ps1` ships does not contain it. Check real workflows in the
built desktop app.

## Run a build

```powershell
.\src\dashboard\dist\ResticBackuperDashboard.exe --isolated-presentation-store
```

`--isolated-presentation-store` uses a separate temporary presentation store
and single-instance identity, with history and heartbeat writes off, so a
development build can run beside the installed app. It still reads the real
engine, and protected actions still go through the installed helpers. Start it
normally, not as administrator.

| Option | Purpose |
| --- | --- |
| `--minimized` | Start in the notification area without opening the window. A second `--minimized` launch does not bring the running window up. |
| `--native` | Use the WPF-only presentation instead of the web interface. |
| `--preview` | Start the labelled backup animation preview; protected actions stay off while it runs. |
| `--isolated-presentation-store` | Keep appearance settings separate and write no run history or heartbeat. |
| `--engine rewindle` or `--engine legacy` | Report on that engine even when the other one is installed. |
| `--state-dir <absolute folder>` | Read backup status from this folder instead of the engine's own. The protected managers always use the engine's own state folder. |
| `--self-test [--self-test-output <absolute file>]` | Check the backup status files without opening a window, and write the result as JSON. |
| `--version`, `--help` | Show the version, or these options, in a message box (the app has no console window; with `--self-test` they print instead). |

An unknown option is reported in a message box instead of exiting silently.

## Tests

The regression checks load the built executable, so build first. Run them with
Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File src\dashboard\tests\restore-flow-regressions.ps1 -SkipInstalledChecks
```

They run against a temporary fixture (a synthetic plan, synthetic telemetry,
and every engine folder moved under the temporary folder) and never run a real
restore, start Restic, or change anything outside that folder. They cover the
restore flow (snapshot selection, scope, review invalidation, retries, path
limits, destination restrictions), diagnostics redaction, run history and its
limits, status-file read failures, backup freshness across clock changes, the
tray, the crash log cap, the setup and engine-not-installed states, the
dialogs' shared design tokens, and engine selection with the identities each
profile owns.

Two checks re-read an installed backup plan when one exists and report
`SKIPPED` otherwise; `-SkipInstalledChecks` leaves them out everywhere. CI runs
the suite with that switch after the release build.

The Python suite at the repository root (`py -3.14 -m unittest discover -s
tests`) also checks the dashboard sources against the engine contract
(`tests/test_dashboard_*.py`, `tests/test_neutral_release.py`), and several
PowerShell suites in `tests/` compile dashboard classes into their harnesses.

To inspect the telemetry reader on its own:

```powershell
$resultFile = Join-Path $env:TEMP 'rewindle-self-test.json'
Start-Process -FilePath .\src\dashboard\dist\ResticBackuperDashboard.exe -ArgumentList @(
    '--self-test',
    '--self-test-output',
    ('"' + $resultFile + '"')
) -WindowStyle Hidden -Wait
Get-Content -LiteralPath $resultFile
```

The self-test reads telemetry and writes the result file. It does not exercise
the web view or prove that a backup or restore works.

## Behavior to preserve

Beyond the never-weaken list in [CONTRIBUTING.md](../../CONTRIBUTING.md), keep
these user-facing rules when you change the dashboard:

- **Evidence stays separate.** Local backup, Off-site copy and Restore test
  each show their own evidence and time, on Protection and in Settings. The
  off-site card names a provider only when the evidence names one; without an
  off-site copy it is one quiet line, "Off-site copy · Not set up (optional)".
- **An accepted request is not a verified backup.** Only the engine's protected
  status can report a run as verified. If Windows accepts **Back up now** but no
  run appears, the app says so instead of claiming success.
- **An unreadable status is not a failed backup.** The last good reading stands
  in briefly; a longer gap is a warning that names the reason, never a failure.
  A missing state folder means **Engine not installed**, not "no backups yet".
- **The run history is never replaced by a guess.** An unreadable
  `run-history.json` is retried and only set aside (never overwritten) if it
  stays unreadable; a history written by a newer version is left as it is.
- **The retired per-user mirror status is never trusted.** It sits where any
  program running as the user can write it, so only the protected direct-cloud
  proof can show an off-site copy as verified.
- **Busy means disabled, with a reason.** Protected actions are disabled while
  a backup, a repair or another protected operation runs, and in sample-data
  and preview modes, with the reason shown or attached for assistive
  technology.
- **Restore never overwrites.** Destinations must be new or empty, local, and
  outside sources, the repository and Rewindle's folders; network paths and
  reparse points are refused. A started restore cannot be cancelled from the
  UI, because the restore manager cannot do it.
- **Accessibility is a feature.** Status is never shown by color alone; every
  page is a named region; screen readers hear when a backup starts, progresses,
  finishes, fails or is cancelled; focus returns where it belongs when a dialog
  closes; Windows High Contrast and reduced motion are honored.

<details>
<summary><strong>Keyboard shortcuts</strong></summary>

| Shortcut | Action |
| --- | --- |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` / `Ctrl+4` | Open Protection / Activity / Restore / Settings. |
| `/` | Focus search on Activity, or on Protection once it lists more than eight folders. |
| `F5` | Refresh dashboard state. |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | Zoom in / zoom out / back to 100% (80% to 200%). Works in dialogs too. |
| `↑` / `↓` / `Home` / `End` / `PageUp` / `PageDown` on an Activity row | Move between runs. `Tab` leaves the table. |
| `Enter` / `Space` on an Activity row | Open run details / select the run. |
| `Esc` in the Activity search field | Clear the search and keep focus in the field. |
| `←` / `→` / `Home` / `End` on a trend chart, then `Enter` | Move between runs and select the one shown. |
| `Esc` in a Restore search, date or filter field | Clear the field first; with the field empty, `Esc` closes Restore. |

Page shortcuts pause while typing or while a dialog is open.

</details>

## Installed layout

The Rewindle installer (`installer\Install-ResticBackuper.ps1`) installs the
dashboard with the engine. `ResticBackuperDashboard.exe`, the three WebView2
DLLs, `web\`, `licenses\` and `dashboard-assets.json` go into the protected
install root `C:\Program Files\ResticBackuper`, checked against the payload
manifest and `dashboard-assets.json`. The installer adds the WebView2 Runtime
if it is missing, registers the `ResticBackuperDashboard` logon task (standard
rights, `--minimized --state-dir C:\ProgramData\ResticBackuper`) and a Start
menu shortcut. There is no separate dashboard installer.

The dashboard's own per-user data lives in `%LOCALAPPDATA%\ResticBackuperDashboard`
(`ResticPersonalBackupDashboard` for the legacy profile): appearance and motion
settings, `run-history.json` (at most 400 runs), `heartbeat.json`, `crash.log`
and the WebView2 profile. Uninstalling Rewindle removes the install root, the
logon task and the shortcut, and leaves that folder in place. A launch with
`--isolated-presentation-store` uses `ResticBackuperBeautifulUI` and
`ResticBackuperDashboardBeautifulUIWebView2` in `%TEMP%` instead.

## Source guide

| Location | Responsibility |
| --- | --- |
| `Program.cs` | Start-up: options, engine selection, administrator refusal, single instance, crash handling. |
| `EngineProfile.cs` | The two engine profiles, engine selection, and every identity derived from them. |
| `DashboardWindow.cs` | The main window, its state, and the WPF-only presentation. |
| `DashboardWindow.Web.cs` | WebView2 hosting and policy, the message bridge, command handling and published state. |
| `DashboardWindow.SourcePicker.cs` / `DashboardWindow.RestoreFlow.cs` | Folder review and guided restore state. |
| `Telemetry.cs` / `BackupFreshness.cs` | Status, run history, verification evidence and freshness. |
| `SourceConfiguration.cs` / `TaskSchedule.cs` | Reading the installed plan and the backup task. |
| `*Manager.cs`, `*Controller.cs`, `ScheduleManagerLauncher.cs` | Adapters to the engine's protected managers and helpers. |
| `*Window.cs` | The schedule, location, recovery-readiness, restore and run-details windows. |
| `DiagnosticExporter.cs` / `CrashLog.cs` | Redacted diagnostics and the local crash log. |
| `DashboardTheme.cs` / `DashboardMotion.cs` / `DashboardVisualStyle.cs` | Appearance, motion and Windows accessibility preferences. |
| `web/src/` | Application shell (`App.tsx`), bridge types, state hook, and `project.ts` (the project address, written once). |
| `web/src/demo/` | Sample data and a stand-in bridge. Dev server and demo build only. |
| `web/src/setup/`, `web/setup.html` | The setup wizard's pages (its own Vite entry, built by `installer/setup/build.ps1` and never part of this app's bundle) and their sample-data bridge. See [installer/setup](../../installer/setup/README.md). |
| `web/components/` | Beautiful UI components and Rewindle's folder, health, run-details and restore views. |
| `web/styles/` | Shared appearance, layout and motion. |
| `web/vendor/` | Beautiful UI provenance and license. |
| `tests/restore-flow-regressions.ps1` | Hermetic regression checks (see [Tests](#tests)). |
| `build.ps1` | The build (see [Build](#build)). |

Build output (`dist/`, `obj/`, `.packages/`, `build-output/`, `web/node_modules/`)
is ignored by Git. Real backup configuration, credentials, repositories and
history never belong in this checkout.

## Credits

The interface incorporates source components from
[Beautiful UI](https://github.com/slev12397/beautiful-ui), pinned to commit
`ff0f74d62d8be9d89bcb735b3632e31a6ccf88dc`. The
[upstream record](web/vendor/UPSTREAM.md) lists the copied files and every
integration change, and their [MIT license](web/vendor/BEAUTIFULUI-MIT-LICENSE.txt)
is kept. The interface also uses React, Motion, Liveline, Lucide and the Inter
and JetBrains Mono fonts from Fontsource; the native host uses WPF and
Microsoft Edge WebView2. The build packages every bundled license notice with
the app; see [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
