# Rewindle Setup

The graphical setup program: one executable, `Rewindle-v<version>-windows-x64-setup.exe`, that asks a few
questions in a window and runs the installer for you. It is a .NET Framework 4.8 WPF host (compiled with the
Framework's `csc.exe`, like the dashboard) around a WebView2 control that shows the wizard's pages. The pages are
React and TypeScript in `src/dashboard/web/src/setup/`, built with their own Vite entry (`setup.html`,
`vite.setup.config.ts`) and the dashboard's tokens, fonts and components.

```
wizard pages (React, in a WebView2 control)
      │  requests and events (the bridge: a fixed list of commands, each one validated)
      ▼
SetupBridge ──▶ PlanRunner ──▶ powershell.exe Install-ResticBackuper.ps1 -PlanOnly    plan.json, no UAC, changes nothing
      │
      └──────▶ SetupOperation ──▶ one UAC prompt ──▶ elevated powershell.exe ... -Unattended -ProgressPath
                     ▲                                          │
                     └──── ProgressTail ◀──── progress.jsonl ◀──┘     one JSON line per phase, then a result line
```

Setup unpacks the release ZIP, the wizard's web files and the WebView2 libraries from its own resources into
`%TEMP%\RewindleSetup-<guid>\`, serves the pages from there through a virtual host, and deletes the folder when it
exits. Nothing on the PC is changed until **Install**, and then only by the installer.

## Files

| File | Responsibility |
| --- | --- |
| `Program.cs` | Entry point: single instance, the log, the workspace, the WebView2 libraries, then the window. |
| `WebViewLibraries.cs` | Makes the embedded WebView2 libraries loadable (assembly resolver and the native loader). |
| `SetupWorkspace.cs`, `SafeZip.cs` | The temporary folders, safe unpacking of the embedded ZIPs, cleanup and the sweep of old folders. |
| `SetupWindow.cs` | The WPF window, the web view and its policy, theme, closing rules; implements `IBridgeServices`. |
| `StatusPanel.cs`, `WebViewRuntime.cs` | The plain native screen for a missing WebView2 Runtime, and its signed download and install. |
| `BridgeProtocol.cs`, `SetupBridge.cs` | The message format, the list of commands and what each one checks. |
| `InstallerContract.cs` | The installer's command line, plan file and progress lines: the host's half of the contract. |
| `PlanRunner.cs` | Plan mode: runs the installer without elevation and reads the plan it writes. |
| `SetupOperation.cs`, `ProgressTail.cs` | Install and uninstall: the last check, the one elevated start, following the progress file. |
| `FolderMeasurer.cs`, `FolderPicker.cs` | Cancellable folder sizes (links skipped, access denied counted) and the Windows folder chooser. |
| `CommandLine.cs`, `Json.cs`, `ProjectLinks.cs`, `SystemTheme.cs`, `SetupLog.cs` | Small helpers. |
| `build.ps1` | Builds the wizard and the host and embeds everything (called by `build\Build-Release.ps1`). |

## The contract with the installer

The wizard reads the plan (`Rewindle.InstallPlan.v1`) and the progress lines (`Rewindle.InstallProgress.v1`) in
`web/src/setup/contract.ts`; the host builds the command lines in `InstallerContract.cs`. Those two files are the
only places that know the contract's shapes, so a change to `docs/setup-contract.md` is a change there.

- **Plan mode** (`getPlan`, not elevated, changes nothing):
  `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Install-ResticBackuper.ps1 -PlanOnly -PlanOutput <json in the temp folder> [-Repository p] [-RepositoryStorageMode m] [-DriveFsMyDriveRoot p] [-SourceList "a;b"] [-Schedule HH:mm] [-DisableVss]`.
  The plan is read when the process exits, with a time limit; a newer request replaces one still running.
- **Install**: the same plan check once more, then one elevated start (`runas`) with `-Unattended -ExpectedUserSid <sid>
  -ProgressPath <progress.jsonl in a folder Setup made> ...` and `-StartBackup` if asked. A declined Windows prompt is
  a cancellation, not an error. Cancel works until Windows has been asked.
- **Uninstall**: `Uninstall-ResticBackuper.ps1 -Unattended -ExpectedUserSid <sid> -ProgressPath ...`, from the installed
  (administrator-protected) copy when there is one, otherwise from the bundle.
- The progress file is read line by line while another process writes it: it may not exist yet, a line may be half
  written, a character may be split, and the file starts with a byte-order mark. An installer that ends without a
  result line is a failure that says so.

## The bridge

The page asks with `{type:"request", id, command, payload}` and gets exactly one `{type:"response", id, ok, result|error}`;
the host also sends events (`theme`, `measure`, `operationStage`, `operationLine`, `operationFinished`). A message is
dropped unless it comes from the page's own address, is a JSON object under 256 KB, and has an id of letters, digits,
`_` and `-`. A well-formed request for a command that is not listed gets an error. The page's list of commands
(`bridge.ts`) and the host's (`BridgeProtocol.cs`) are kept equal by `tests/test_setup_wizard.py`.

| Command | What it does and what is checked |
| --- | --- |
| `hello` | Host version, theme, contrast, motion, locale. |
| `getPlan` | `inputs` are checked (absolute drive-letter paths without quotes, control characters or `..`; at most 64 folders, none containing `;`; a `HH:mm` time; known storage modes) and become an argument array. |
| `browseFolder`, `browseRepositoryFolder` | The Windows folder chooser, shown after the message handler returns; the answer must be an existing folder. |
| `measureFolders`, `cancelMeasure` | Up to 32 checked paths; sizes stream as events, two folders at a time; junctions and symbolic links are not followed. |
| `install`, `uninstall`, `cancelInstall` | `choices` must be complete and valid; one operation at a time; cancel only before the Windows prompt. |
| `openDashboard` | Starts the installed dashboard only: `ResticBackuperDashboard.exe` in `%ProgramFiles%\ResticBackuper`; a path the installer reported is not trusted beyond that. |
| `saveRecoveryKeyCopy`, `showRecoveryKey` | Work on the key path the installer reported (a `.txt`, under 64 KB, not a link), never one the page names; the copy is read back and compared. If only administrators can read the key, the page is told to show it in Explorer instead. |
| `copyText` | At most 64 KB to the clipboard. |
| `openUrl` | One of `readme`, `issues`, `license`, `requirements`, each a fixed address of the project's own. |
| `setZoom` | `in`, `out` or `reset`. |
| `close` | Closes the window, unless an elevated install is working. |

## Security

- Setup runs `asInvoker`; only the installer it starts is elevated, once. The window cannot be closed while that
  installer works, because it reads the files Setup unpacked and deletes on exit.
- No user input is joined into a command line: every value is one element of an argument array, quoted by
  `CommandLine.Quote` (tested against `CommandLineToArgvW`). The page never names a program, a script or a file to copy.
- The web view maps one virtual host (`rewindle-setup.local`) to the unpacked pages with CORS denied and a content security
  policy of `'self'`; navigation, new windows, downloads, permission prompts, external schemes, authentication prompts,
  certificate errors and every request to another address are refused; developer tools, context menus, script dialogs,
  autofill and browser shortcuts are off; there is no remote content.
- Embedded ZIPs are unpacked by `SafeZip` (no rooted, `..`, drive-qualified, duplicate or oversized entries).
- The WebView2 bootstrapper is downloaded only from Microsoft's fixed address, and run only after a valid Authenticode
  signature naming Microsoft (the check `Install-ResticBackuper.ps1` makes).
- The log (`%TEMP%\Rewindle-Setup.log`) holds what Setup did, never file contents, passwords or the recovery key.
- The unpacked bundle sits in the user's temp folder, which any program the user runs can change, also while Windows'
  permission prompt is showing. So an elevated run of the installer (or of the bundled uninstaller) never runs it from
  there: `ElevatedBootstrap.cs` passes a short bootstrap as `-EncodedCommand` that creates a new folder under ProgramData
  with an access list only Administrators and SYSTEM can change (set as the folder is created), copies the script, the
  payload manifest and the payload into it (refusing links), checks the copies of the script and manifest against the
  SHA-256 values Setup took while unpacking its own resources, checks the argument file the same way, and only then runs
  the script from there; the installer verifies every payload file against that manifest. Anything that doesn't match
  ends the run with exit code 70 before the script starts. The uninstaller installed in Program Files is run where it is.
  The console path (`Install.cmd` from the ZIP) still runs from wherever the ZIP was extracted.

## Build and test

```powershell
pwsh .\build\Build-Release.ps1             # builds everything, including the setup program, into artifacts\
pwsh .\installer\setup\build.ps1 -BundleArchive .\artifacts\Rewindle-v<version>-windows-x64.zip -Output "$env:TEMP\setup.exe"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SetupHost.ps1       # the host's logic; no installer is run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SetupWindow.ps1 -Output "$env:TEMP\shots"   # the real window against fakes
cd src\dashboard\web; npm run dev:setup     # the wizard in a browser, with sample computers
```

`build.ps1` builds the wizard (`npm run build:setup` type-checks the whole web project first), checks the bundle for the
sample bridge and for source maps, zips it, and compiles every `*.cs` here with the version from `VERSION`,
`app.manifest` (per-monitor DPI v2, long paths) and the release ZIP, the web files, the icon and the three WebView2
libraries as resources. The pinned WebView2 SDK is shared with the dashboard (`build\RewindleWebView2.ps1`).

Only `SetupWindow.cs` names a WebView2 type, and `Program.Main` installs the assembly resolver before anything in it can
be compiled; keep it that way, or the embedded libraries cannot be found.
