# Contributing to Rewindle

Thanks for helping. Bug reports, Windows compatibility reports, documentation
fixes and focused pull requests are all welcome. Rewindle is a backup tool, so
changes are reviewed first for what they could do to someone's data or to the
Windows privilege boundary, and only then for everything else.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security
problems privately, as described in [SECURITY.md](SECURITY.md), never in a
public issue or pull request.

This repository is Windows-only. It contains the engine (`src/`), the task
launcher (`src/task_launcher/`), the Rewindle dashboard (`src/dashboard/`), the
installer and the release build. There is no macOS host or website here.

## Prerequisites

- 64-bit Windows 10 or 11.
- Windows PowerShell 5.1 (built in) and PowerShell 7 (`pwsh`).
- .NET Framework 4.8 with its C# compiler
  (`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`).
- Node.js 22.12 or newer (20.19 and later 20.x also work) with npm on `PATH`.
  `.node-version` names the release CI uses.
- Python 3.14, available as `py -3.14`, for the tests.
- Git, and internet access for the first build: it downloads the pinned Python,
  Restic and WebView2 SDK packages and the npm dependencies.

You do not need an installed copy of Rewindle to build or test it.

## Build

From the repository root:

```powershell
# Dashboard only: writes src\dashboard\dist\ResticBackuperDashboard.exe and its assets
pwsh .\src\dashboard\build.ps1

# Full release: task launcher, dashboard, payload manifest, ZIP, setup.exe and checksums in artifacts\
pwsh .\build\Build-Release.ps1
```

`src\dashboard\build.ps1 -SkipWeb` recompiles only the native host and reuses
the previous web build. See [src/dashboard/README.md](src/dashboard/README.md)
for the dashboard's own build notes.

### Sample-data mode

The dashboard interface can run in an ordinary browser with invented sample
data, for UI work and screenshots, without an installed engine:

```powershell
Set-Location src\dashboard\web
npm ci --ignore-scripts
npm run dev          # dev server on 127.0.0.1:5178 with sample data
npm run dev:demo     # the same, in the demo build mode
npm run build:demo   # static sample-data build in src\dashboard\build-output\demo
```

Every action that would touch a backup answers "Sample data is read-only." The
sample lives in `src/dashboard/web/src/demo/` and is left out of the build that
ships in the app. Use it for screenshots instead of a real installation, so no
real folders or history end up in an image.

## Tests

Run these from PowerShell in the repository root before you open a pull
request:

```powershell
# Python unit tests, dashboard source checks and repository hygiene
py -3.14 -m unittest discover -s tests

# Dashboard regression checks, with Windows PowerShell 5.1 (build the dashboard first)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File src\dashboard\tests\restore-flow-regressions.ps1 -SkipInstalledChecks

# PowerShell suites for the managers and helpers you touched, for example:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-ManageSources.ps1

# After a release build: two real backups and an independent restore from the ZIP
pwsh .\tests\Test-ReleaseArtifact.ps1
```

Notes:

- `test_key_rotation` runs the real `restic.exe` from the release build output
  and is skipped until you have run `Build-Release.ps1`.
- The PowerShell suites live in `tests\*.ps1`. They build disposable fixtures
  in your temporary folder and do not change an installed copy.
- `-SkipInstalledChecks` keeps the dashboard regressions from reading an
  installed backup plan.
- CI (`.github/workflows/ci.yml`) compiles the Python sources, parses every
  `.ps1` file with the PowerShell parser, and runs the Python tests,
  `Test-ManageSources.ps1`, the release build, the dashboard regressions and
  `Test-ReleaseArtifact.ps1`.

To check that your PowerShell parses, as CI does:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | Where-Object FullName -notmatch '\\node_modules\\' | ForEach-Object {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    $errors | ForEach-Object { "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }
}
```

## The version number

`VERSION` is the only place the version is written. The builds read it for the
version resources of the dashboard, the task launcher and the setup program,
and for the dashboard's application manifest. `src\dashboard\build.ps1` copies
it into `src/dashboard/web/package.json` and its lockfile with npm, and the
release build refuses to package a binary whose version disagrees.

To change the version, edit `VERSION`, run the dashboard build, and commit
`VERSION`, `package.json` and `package-lock.json` together. The hygiene tests
also expect a matching `docs/release-notes-v<VERSION>.md`, and the version in
the README warning, the README download names and `docs/architecture.md`.
Never hard-code a version number anywhere else.

## Never weaken these

These protections are why Rewindle can run an elevated backup task next to an
unelevated dashboard. A pull request that loosens one will not be merged. If
you believe one is wrong, open an issue (or a private advisory, if it is a
vulnerability) to discuss it first.

1. **The UAC and elevation boundary.** The dashboard runs with standard rights
   and never writes protected configuration, reads the repository password, or
   runs Restic, Python or the task launcher to make a change. Every change goes
   through a manager or helper under the protected install root, started by
   fixed path with a UAC prompt and bound to the requesting user's SID.
   Program Files and ProgramData stay writable only by Administrators and
   SYSTEM.
2. **Nonce- and digest-bound requests.** Every manager request carries a fresh
   random nonce and a domain-separated SHA-256 digest of its fields. Results are
   created once in the protected results folder with the expected ACL, and the
   dashboard rejects any result whose bindings, size, location or ACL do not
   match. Repair helpers stay bound to the plan, generation, configuration
   hash and SID.
3. **Path guards.** No UNC or network paths; no junctions, symbolic links or
   other reparse points in a protected or restore path; DOS 8.3 short-name
   aliases expanded before paths are compared; no overlap between sources, the
   repository, the runtime and the state folders; restore targets that are new
   or empty, restored with `--overwrite never` and verification. Existing files
   are never overwritten.
4. **Runtime-manifest hashes.** The installer verifies every payload file
   against its SHA-256 manifest, and the managers that check the installed
   runtime against `runtime-manifest.json` keep doing so. Do not add exemptions
   or unmanifested files.
5. **Administrator-launch refusal.** The dashboard refuses to start with an
   administrator token. Keep it that way.
6. **Disabled-while-busy actions.** Protected actions stay disabled, with a
   stated reason, while a backup, a repair or another protected operation is
   running, and in sample-data and preview modes. The managers' own run lock
   and journal checks remain the final authority.

Also: retention, `forget`, `prune`, repository deletion and state purging must
never run automatically or be enabled by default.

## Commits and pull requests

- Keep each pull request to one logical change, and keep commits focused.
- Write the subject as `area: what changed`, as in the existing history
  (`engine:`, `dashboard:`, `installer:`, `build:`, `tests:`, `ci:`, `docs:`).
  Use the body to explain why, and any safety implications.
- Add or update tests for every behavior change, and run the commands above.
- Update the README, `docs/` and the `Unreleased` section of
  [CHANGELOG.md](CHANGELOG.md) when behavior a user can see changes.
- If you touch ACLs, elevation, scheduled tasks, password handling, restore
  behavior or repository writes, say so in the pull request and explain the
  effect on the invariants above.
- If a change alters how the dashboard talks to an engine, update
  [docs/engine-contract.md](docs/engine-contract.md). Only
  `src/dashboard/EngineProfile.cs` may name an engine's identities.
- Never commit real paths, user names, host names, volume serials, logs,
  repositories, DPAPI envelopes, recovery keys, or generated build output. Use
  placeholders such as `C:\Users\you\Documents`. `tests/test_repository_hygiene.py`
  checks for some of this, but you are the first check.
- Do not add a `.gitattributes` that rewrites line endings: some tests and
  manifests depend on exact bytes.

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE).
