# Changelog

All notable changes to Rewindle are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with pre-release
labels. Releases before 0.2.0 were published under the name ResticBackuper.

## [Unreleased]

### Added

- **Rewindle Setup wizard.** The setup program is now a graphical wizard
  (`installer/setup`: a WPF and WebView2 host; the pages are
  `src/dashboard/web/src/setup`) in place of the console prompts: Welcome, What
  to protect (folder cards with live sizes), Backup location (drive cards with
  free space and plain warnings), Schedule, Review, Install, Recovery key and
  Done, with a maintenance page when Rewindle is already installed. It runs as
  the person who started it, asks the installer to describe the PC and check
  the choices without elevation, asks Windows for permission once to run the
  install, and shows the installer's progress. It offers to install a missing
  WebView2 Runtime after checking Microsoft's signature on the download.
- `npm run dev:setup` serves the wizard in a browser with invented sample
  computers (`?scenario=fresh`, `no-second-drive`, `drivefs`,
  `existing-install`, `legacy-installed`, `unsupported-os`, `plan-errors`,
  `install-failure`, `uac-declined`, `key-unreadable`), and
  `npm run build:setup-demo` makes a static copy. The sample is not part of the
  setup program; the build checks the bundle for it.
- `tests\Test-SetupHost.ps1` checks the setup program's logic without starting
  it or the installer, `tests\Test-SetupWindow.ps1` opens the real window against
  fakes and takes a screenshot of every page, and CI runs the first.

### Changed

- `build\Build-Release.ps1` builds the setup program with
  `installer\setup\build.ps1`. The ZIP still carries `Install.cmd` for console
  installs. The WebView2 SDK pin and the deterministic ZIP helper moved to
  `build\RewindleWebView2.ps1` and `build\RewindleZip.ps1`, shared by the
  dashboard and setup builds.

## [0.2.0-alpha.1] - 2026-10-03

The first Rewindle release from this repository: the engine and the Rewindle
dashboard are built, installed and tested together. Windows x64 only.

### Added

- The Rewindle dashboard (WPF host, WebView2, React interface) ships with the
  engine. The release build packages it, the installer puts it in the
  protected install root, and it starts in the notification area at logon.
- Engine profiles. Every engine identity (install and state roots, tasks,
  launcher, request domains, result schemas, mutex and event names, cloud and
  dashboard folders) lives in one `EngineProfile`. The default profile is this
  repository's engine (`ResticBackuper` names); a legacy profile keeps
  installations of the earlier personal edition (`ResticPersonalBackup`)
  working. The dashboard chooses the installed engine automatically (Rewindle
  first), `--engine rewindle|legacy` overrides, and with neither installed it
  shows an **Engine not installed** screen listing where it looked, with a
  details line to copy into a bug report. See `docs/engine-contract.md`.
- **Settings > About Rewindle**: app version, engine and engine version, MIT
  License, "Powered by Restic", the project address, and **Open licenses
  folder**. The engine and its version also appear in diagnostics.
- `--version` and `--help` command-line options.
- A guided restore asks Windows for approval once: `Manage-Restore.ps1
  -Operation session` serves the snapshot list, any number of folder listings
  and one restore over a private, verified named pipe, then ends (also after 10
  idle or 60 total minutes, when Restore closes or the plan changes). Choosing
  a backup no longer reads its root, folders already read are not read again,
  and engines without `engine-capabilities.json` (and the legacy edition) keep
  one approval per step. See `docs/engine-contract.md`, section 9.
- A sample-data mode for the dashboard interface (`npm run dev`,
  `npm run dev:demo`, `npm run build:demo`) for development and screenshots.
  It is not part of the build that ships in the app.
- A backup can be cancelled during the wrapper's preflight phases (checking
  repository storage, preflighting sources, authenticating the repository).

### Changed

- Dashboard UX overhaul:
  - **Protection status consistency.** Local backup, Off-site copy and Restore
    test each have their own card with their own evidence and time, and
    Settings shows the same cards. The status line says when the last backup
    was verified and flags a missing folder or backup drive. A status file that
    is briefly unreadable is not shown as a failed backup, and the page dims
    instead of looking live when it loses the desktop app.
  - **Off-site copy is optional and neutral.** The card is called "Off-site
    copy" and names a provider only when the evidence does. Without an
    off-site copy, one quiet line says **Off-site copy · Not set up
    (optional)**.
  - **Keyboard-accessible Activity.** Arrow keys, `Home`, `End`, `PageUp` and
    `PageDown` move between runs, `Enter` opens run details, `Space` selects,
    `/` focuses the search and `Esc` clears it; the trend charts are keyboard
    navigable too. Filtered views say how many runs they show, and failed or
    cancelled runs are marked on the charts instead of plotted.
  - **Guided restore improvements.** Clearer steps, selections kept when you
    return to the same snapshot, a clickable folder path, paging for long
    folders, destination checks (network paths, reparse points, overwrite
    conflicts) with a free-space warning, inline **Try again** for unreadable
    folders and after a declined approval, and **Open restored folder** bound
    to the folder the restore manager reported.
  - **Accessibility and contrast.** Screen-reader announcements for backup
    progress and results, named page regions, focus that returns where it
    belongs, status that never relies on color alone, contrast fixes in both
    themes, and `Ctrl+=` / `Ctrl+-` / `Ctrl+0` zoom from 80% to 200% with a
    layout that reflows. Windows High Contrast and reduced motion are respected.
  - **WebView2 crash recovery.** A crashed page or browser process is reloaded
    automatically (up to three times in five minutes) before the app offers
    **Reload**; a page that stops responding gets **Keep waiting** or **Reload**
    after 15 seconds; a missing runtime offers Microsoft's download.
  - **Diagnostics redaction.** Exports replace whole paths (with either slash
    direction), Windows user and computer names, account IDs, email addresses,
    long tokens and cloud-proof hashes. A final check refuses the export if
    anything remains, the crash log is left out if it cannot be made safe, and
    the manifest lists every skipped document with its reason.
  - The sidebar shows the Rewindle mark and name; protected folders are shown
    by their own names.
- A direct Google Drive (DriveFS) proof is bound to the repository of the
  installed backup plan instead of a fixed path, for both engine profiles.
- `VERSION` is the only version source. The dashboard, task launcher and setup
  program take their version resources from it, `web/package.json` follows it,
  and the release build refuses binaries whose version disagrees.
- The dashboard executable is `ResticBackuperDashboard.exe`, the name the
  release build, installer and uninstaller expect.
- The installer suggests only standard Windows folders as default sources. The
  Installed apps entry names the publisher and links to the project.
- CI builds the dashboard and runs its regression checks.

### Removed

- The macOS desktop host, the landing site and the macOS release workflow.
  They are not part of this Windows-only repository.
- The sidebar's single-item workspace switcher and the top-bar breadcrumb.

### Fixed

- A successful anomaly review was reported as failed because the dashboard
  expected a different acknowledgement scope; each profile now accepts its
  engine's scope and uses wording that matches it.
- Preflight backup states showed as "Unknown" and could not be cancelled.
- Restore results larger than 2 million characters (up to the engine's 8 MiB
  limit) failed to parse.
- Recovery-drill progress showed only its first update.
- Run details had no explanation for `repository_storage_unavailable`.
- The folder picker now also refuses the engine's protected recovery-tools
  folders.

### Security

- `Manage-Sources.ps1` answers through the dashboard's nonce-bound,
  digest-checked protected result channel (`SourceManagerResults`), and
  installed runs require it.
- The dashboard again requires the immutable-evidence, asset-manifest and
  binary-stream bindings of a direct cloud proof, reads the proof from the
  verifier's `evidence` folder, and redacts cloud-proof hashes and paths from
  diagnostics.

## [0.1.0-alpha.8]

### Added

- Adds an in-app, same-user-UAC recovery drill that restores a bounded sample
  from the latest current-plan snapshot with the independent recovery key and
  keeps the protected result available for review.

### Changed

- Requires Restic verification plus independent canary, size, and exact-
  inventory checks before atomically recording protected restore evidence.
  Failed or partial output is retained but cannot clear Recovery Readiness.
- Binds qualifying history to the current plan, configuration generation,
  repository identity, exact snapshot, plan binding, and representative-drill
  credential source; malformed, stale, legacy, partial, or writable evidence
  fails closed.

### Security

- Hardens the bounded dashboard probe and restore-manager result channels, and
  extends regression and release-artifact coverage for the guided workflow.

## [0.1.0-alpha.7]

### Fixed

- Fixes direct-cloud latest-snapshot verification under Windows PowerShell 5.1
  by explicitly normalizing Restic's top-level JSON array instead of allowing
  `ConvertFrom-Json` to preserve it as one pipeline object.
- Validates every direct-cloud snapshot object, full lowercase identity, and
  RFC3339 timestamp before restore. Malformed JSON shapes, missing or
  non-string fields, duplicate identities, invalid offsets, and timestamps with
  unsupported precision fail closed.
- Orders Restic RFC3339Nano timestamps without losing the eighth or ninth
  fractional digit, normalizes numeric offsets to UTC, and requires the
  protected last-success snapshot to be among the newest direct-cloud
  snapshots before publishing verification evidence.

## [0.1.0-alpha.6]

### Added

- Adds an explicit `google_drivefs_stream` storage mode whose sole live Restic
  repository is a strict descendant of Google Drive for desktop's **My Drive**
  streaming mount. Recovery tools, credentials, protected state, and the
  recovery key stay on NTFS outside DriveFS.
- Publishes immutable schema-2 cloud evidence only after repository identity,
  case-sensitive paths, byte counts, MD5/SHA-256 hashes, unique provider IDs,
  the latest complete snapshot, and a direct-cloud canary restore agree. The
  dashboard rejects stale, legacy, or differently bound evidence.

### Changed

- Makes repository relocation into DriveFS transactional: copy into a
  nonce-bound sibling stage, verify an exact path/size/SHA-256 inventory,
  repository identity, snapshot history, and `restic check`, then publish with
  a same-parent rename while retaining the old repository.
- Replaces the alpha.5 local-mirror design with an optional verification-only
  task. It compares the live repository against an exact read-only Google Drive
  API inventory and performs an independent canary restore through the direct
  cloud backend; it never copies, deletes, prunes, or rewrites repository
  objects.
- Clarifies destructive-change review in DriveFS mode: acknowledgement controls
  later maintenance decisions but cannot pause uploads from the sole live
  streamed repository.
- Extends release and regression coverage for DriveFS validation, transactional
  repository moves, cloud inventory and verifier behavior, verification-task
  installation, dashboard evidence handling, and a disposable real Restic
  backup-and-restore test from the packaged artifact.

### Fixed

- Keeps primary and cloud-verifier task-definition evidence distinct, permits
  Task Scheduler's valid omission of the default-enabled XML field, tolerates
  inherit-only `OWNER RIGHTS` entries omitted by the .NET managed ACL view, and
  uses real same-directory backup paths for Windows PowerShell 5.1/.NET atomic
  replacement of cloud evidence and dashboard state.

### Security

- Protects the cloud verifier with the shared run-lock handshake, an elevated
  interactive task, a four-file size/hash manifest, strict ProgramData ACL and
  reparse-point checks, CurrentUser DPAPI, and binary-safe native-output
  capture.

## [0.1.0-alpha.5]

### Added

- Adds an optional, post-install Google Drive for desktop mirror task that keeps
  the live Restic repository on local storage, stages only missing immutable
  files outside the provider root, promotes complete files without overwrite or
  deletion, and publishes a committed generation only after exact SHA-256/MD5
  inventory checks, Restic authentication/check/restore, and DriveFS upload
  confirmation.
- Uses the protected backup run lock through a read-only byte-range handshake,
  so the limited-user mirror task coordinates with backup and configuration
  operations without weakening the protected ACL or running user-writable code
  elevated.
- Adds bounded off-site telemetry to the dashboard, distinguishing failure,
  in-progress, locally verified, provider-confirmed, and restore-verified states.
- Ships fail-closed DriveFS metadata verification, repository-ID-scoped public
  destinations, a 48-hour task ceiling with one 24-hour provider deadline, and
  disposable transaction/provider regression tests.

### Fixed

- Fixes strict cloud-placeholder preflight on large Windows source trees by
  using extended-length paths, pruning only directories definitely covered by
  the active Restic exclusion file, and tolerating only descendants that
  disappear during enumeration. Included access errors and cloud-only content
  continue to fail closed.

## [0.1.0-alpha.4]

### Added

- Adds a dedicated **Restore** page and UAC-protected Restore Center for
  browsing immutable snapshot IDs and restoring selected content to a new or
  empty non-overlapping destination with verification and bound reports.
- Safely surfaces pre-plan snapshots as **Legacy / unbound** only when their
  computer, scheduled tags, and complete source set exactly match the current
  protected configuration. Browsing or restoring one requires its full
  immutable ID and restore adds a separate explicit warning; metadata is never
  rewritten or retagged.
- Adds **Recovery Readiness** checks for repository identity, the active DPAPI
  credential, the independent recovery key, portable recovery tools, capacity,
  Restic locks, and an alternate-location restore drill.
- Adds guided credential repair, Restic-confirmed stale-lock cleanup, and
  journaled key rotation that proves the new key while retaining the prior key
  and recovery document for rollback.
- Adds a protected repository-location workflow that copies to an empty local
  destination, verifies repository identity and snapshot history, atomically
  activates the new path, and deliberately retains the old repository.
- Makes repository relocation crash-safe across copy and every publication
  boundary with a durable recovery journal, destination ownership proof, exact
  rollback, and a dashboard recovery surface.
- Introduces stable plan IDs, monotonic configuration generations, exact
  source-volume identities, and strict cloud-placeholder preflight so stale
  requests, drive-letter reuse, and online-only data fail closed.
- Adds schedule-aware freshness monitoring that detects overdue protection even
  when process telemetry is stale or absent.
- Adds structured failure records, a bounded run-details dialog with suggested
  recovery actions, and redacted diagnostic ZIP export.
- Detects anomalously large deletion/change sets and holds their promotion for
  explicit, plan-bound review without deleting or modifying snapshots.

### Changed

- Refreshes portable recovery tools transactionally after protected plan
  changes while preserving their recovery-local executable and credential
  paths.
- Extends protected-operation interlocks so backups, source changes, schedule
  changes, restores, repository moves, and credential operations do not consume
  partially published state.
- Expands the automated suite with plan/source preflight, cancellation races,
  freshness, restore, repository-relocation interruption recovery, recovery
  health and repair, anomaly review, run-details, diagnostic redaction, and
  credential-rotation integration coverage.

### Fixed

- Runs the DPAPI password helper with isolated, no-site, no-bytecode Python
  flags so repository reads cannot create unmanifested runtime cache files.

## [0.1.0-alpha.3]

### Added

- Adds a confirmation-protected **Back up now** action that validates and
  requests the existing hardened scheduled task through Windows approval,
  without launching Restic or Python from the dashboard.
- Adds an **Edit schedule** workflow for daily or selected-day triggers and the
  supported missed-run, wake, and battery settings. A separate elevated manager
  binds the request to the installed task, verifies the result, and rolls back
  failed changes without starting a backup.
- Adds cooperative **Cancel backup** control for an exact active run. A
  per-run protected event requests one targeted Ctrl-Break; task termination and
  generic PID killing are not used, and child-exit races preserve normal success
  or failure semantics.
- Adds live System, Midnight, and Daylight dashboard themes with a persistent
  per-user selector and automatic Windows High Contrast handling.
- Provides an immediate, explicitly low-confidence ETA from comparable recent
  runs when no matching folder-set history exists, while preferring matching
  history as soon as it is available.
- Adds a responsive 1080-DIP layout that stacks backup scope and run-history
  views at narrower widths while keeping source management prominent.

### Changed

- Replaces the transient add-folder message with durable approval, applying,
  verification, success, cancellation, and failure states; motion follows the
  Windows animation and High Contrast preferences.
- Introduces a semantic color system across cards, charts, dialogs, tables,
  source controls, status badges, selections, and keyboard focus indicators.
- Refreshes dashboard hierarchy, spacing, headings, and contrast without
  adding telemetry or backup-health claims the protected state cannot prove.
- Replaces the web-style card grid with a compact native Windows utility:
  status and recent activity on the left, protected folders on the right,
  inline metrics, flat surfaces, and a compact activity-header sparkline.
- Targets a 1280 × 720 default window, shows more source paths above the fold,
  and stacks status, sources, then activity below 1080 DIPs while retaining a
  single page scrollbar.

## [0.1.0-alpha.2]

### Added

- Adds a persistent, high-contrast **Add folder** action and an explicit
  per-folder **Remove from future backups** action.

### Changed

- Moves the protected-folder inventory into the above-the-fold backup overview
  so the configured sources are visible without scrolling past telemetry.
- Clarifies that removing a source changes future backups only and preserves
  every existing snapshot; the required canary source remains protected.
- Makes four-file source-list changes crash-safe with a flushed protected undo
  journal. Backup and dry-run wrappers fail closed until an interrupted change
  is reconciled to its exact previous state.
- Aligns installation and later folder changes on the same local-drive policy:
  fixed or removable drive-letter sources, tightened to fixed NTFS while VSS is
  enabled; UNC and network sources remain unsupported.
- Improves dashboard keyboard navigation, focus visibility, accessible control
  names, action sizing, contrast, and status cues that do not rely on color
  alone.
- Compresses the backup-health presentation and gives source management
  priority over detailed metrics and run history, including on shorter windows.
- Documents an example nightly workflow: protection for software projects, a
  local Google Drive mirror, and personal folders, while excluding reproducible
  dependencies and build output.

## [0.1.0-alpha.1]

### Added

- Initial public alpha.
- Encrypted, incremental Restic snapshots on Windows.
- Optional VSS capture of open files.
- Highest-level Task Scheduler automation through a kill-on-close launcher.
- Read-only animated dashboard with run history and ETA estimates.
- Dashboard folder inventory with UAC-protected add/remove management; source
  removal does not delete historical snapshots.
- Exact source-set validation, repository structural checks, and canary restore
  verification before a run is marked successful.
- Guided ZIP installer with pinned, checksum-verified Restic and Python
  runtimes.
- Conservative uninstaller that preserves repositories, state, credentials,
  recovery keys, and recovery tools.

[Unreleased]: https://github.com/50sotero/rewindle/compare/v0.2.0-alpha.1...HEAD
[0.2.0-alpha.1]: https://github.com/50sotero/rewindle/releases/tag/v0.2.0-alpha.1
