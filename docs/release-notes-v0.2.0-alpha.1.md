# Rewindle v0.2.0-alpha.1

> **Backup you can verify.**

The first Rewindle release from this repository. Rewindle pairs an encrypted,
incremental Restic engine for Windows with a desktop dashboard that shows what
is protected, what each run did, and how to get your files back. This is an
early public alpha for 64-bit Windows 10 and 11. It is free software under the
MIT License.

The product name is new; the engine's executable, task, install-path and
protected-state identifiers keep their `ResticBackuper` names so the
operational contracts stay stable.

## Highlights

- **One Windows approval per restore.** A guided restore asks once per restore
  session instead of at every step. An elevated session broker serves the
  snapshot list, folder listings and at most one restore over a named pipe
  that only your account can open, and each side verifies the other's process.
  Choosing a backup reads nothing until you click **Browse files**, and folders
  already listed are not read again.
- **A clearer Protection page.** Local backup, Off-site copy and Restore test
  each show their own evidence and time. An off-site copy is optional; without
  one, the page says so in one quiet line instead of showing a warning.
- **Keyboard-accessible Activity** with search, filters, run details and
  trend charts.
- **Guided restore** with destination checks (network paths, reparse points,
  overwrite conflicts), a free-space warning, inline retries, and **Open
  restored folder**.
- **Accessibility:** screen-reader announcements, focus management, contrast
  fixes in both themes, zoom from 80% to 200%, Windows High Contrast and
  reduced-motion support.
- **Resilience:** the dashboard recovers from WebView2 crashes and reports a
  missing runtime with Microsoft's download link.
- **Safer diagnostics:** exports redact paths, user and computer names,
  account IDs, e-mail addresses and tokens, and refuse to export anything that
  still looks private.
- **Settings > About Rewindle**, plus `--version` and `--help`.
- **Earlier personal edition:** the dashboard detects an installed
  `ResticPersonalBackup` engine and keeps working with it (there, each restore
  step still asks for approval).

See [`CHANGELOG.md`](../CHANGELOG.md) for the full list.

## Download and verify

Download the ZIP or the setup program from the GitHub release, plus its
`.sha256` file, and verify it before opening it:

```text
Rewindle-v0.2.0-alpha.1-windows-x64.zip
Rewindle-v0.2.0-alpha.1-windows-x64-setup.exe
```

The ZIP is the easiest way to inspect the payload and run `Install.cmd`. The
setup program embeds the same ZIP and launches the same reviewed PowerShell
installer; it is not a second installer implementation. Setup checks for the
Microsoft Edge WebView2 runtime and obtains Microsoft's signed bootstrapper
when it is missing.

## Requirements and boundaries

Windows PowerShell 5.1 and .NET Framework 4.8 are required. Backups run from
Task Scheduler through UAC-approved managers, with optional VSS capture and
CurrentUser DPAPI credentials. Verification of an off-site copy is supported
for Google Drive for desktop (DriveFS); other providers are not verified yet.

Test a restore before trusting Rewindle with irreplaceable data, and keep
another backup while you evaluate it. Rewindle does not automatically prune or
delete repository snapshots.

## Signing status

This alpha is not Authenticode-signed, so SmartScreen or antivirus software
may warn. The published checksums show the files were not altered after
release; they do not prove the publisher's identity.

## Validation

The release test extracts the published ZIP, verifies its payload manifest,
performs two Restic backups against a temporary fixture, runs the
recovery-key drill, and restores changed data independently. The engine's
Python and PowerShell suites and the dashboard's regression suite run in CI.
