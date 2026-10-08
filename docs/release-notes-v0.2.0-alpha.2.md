# Rewindle v0.2.0-alpha.2

> **Backup you can verify.**

This alpha replaces the console installer with **Rewindle Setup**, a graphical
wizard. Download the setup program, answer a few questions, approve one Windows
permission prompt, and Rewindle is protecting your folders. Rewindle is free
software under the MIT License, for 64-bit Windows 10 and 11.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/50sotero/rewindle/v0.2.0-alpha.2/docs/images/setup/welcome-dark.png">
    <img src="https://raw.githubusercontent.com/50sotero/rewindle/v0.2.0-alpha.2/docs/images/setup/welcome-light.png" width="720" alt="Rewindle Setup's Welcome page, with the eight steps listed on the left">
  </picture>
</p>

## Rewindle Setup

Eight pages: **Welcome**, **What to protect**, **Backup location**,
**Schedule**, **Review**, **Install**, **Recovery key** and **Done**. The
suggestions on each page suit most people, so you can just choose **Next**.

- **What to protect** shows your Windows folders with their sizes, measured
  while you look, and explains a folder that is missing, inside another chosen
  folder, or full of online-only OneDrive files.
- **Backup location** shows each drive with its free space, says which is the
  Windows drive or on the same disk, recommends a separate drive, and checks
  that your folders fit.
- **Review** shows every choice with an Edit link. Nothing on your PC changes
  before **Install**: until then the pages only ask the installer to describe
  the PC and check your choices, without administrator rights.
- **Install** asks Windows for permission once and shows each step of the
  installation. If something fails, it says what was and wasn't changed.
- **Recovery key** explains the key and helps you save a copy away from the PC.
- If Rewindle is already installed, Setup opens a maintenance page instead:
  open Rewindle, reinstall or repair, or uninstall. Your backups and recovery
  key are always kept.
- A missing Microsoft Edge WebView2 Runtime is offered for install after Setup
  checks Microsoft's signature on the download.
- Light and dark themes follow Windows, with High Contrast and keyboard support.

<table>
  <tr>
    <td><img src="https://raw.githubusercontent.com/50sotero/rewindle/v0.2.0-alpha.2/docs/images/setup/folders.png" alt="What to protect: folder cards with their sizes"></td>
    <td><img src="https://raw.githubusercontent.com/50sotero/rewindle/v0.2.0-alpha.2/docs/images/setup/location.png" alt="Backup location: drive cards with free space, a recommended backup drive and warnings"></td>
  </tr>
  <tr>
    <td><img src="https://raw.githubusercontent.com/50sotero/rewindle/v0.2.0-alpha.2/docs/images/setup/review.png" alt="Review: the chosen folders, backup location and schedule, each with an Edit link"></td>
    <td><img src="https://raw.githubusercontent.com/50sotero/rewindle/v0.2.0-alpha.2/docs/images/setup/installing.png" alt="Install: progress through each step of the installation"></td>
  </tr>
</table>

## Also in this release

- **Reinstalling keeps your backup history going.** A reinstall over the state
  an uninstall kept continues the same backup plan. If it uses another backup
  location, the kept recovery key is updated to name it once the reinstall has
  succeeded; a reinstall that fails leaves the key as it was.
- **A cleaner uninstall.** The uninstaller removes a leftover Installed apps
  entry whose program folder is already gone, and keeps, with a warning, a
  Start menu shortcut or Installed apps entry it can't prove is Rewindle's.
- **Safer setup.** Setup runs as you. Only the installer and the uninstaller
  run elevated, and a script from Setup's own bundle runs from a copy staged in
  an administrator-only folder and checked against the hashes Setup took when it
  unpacked the bundle. Setup trusts only progress reports written by
  the elevated installer, keeps the files it loads or runs locked from the
  moment it checks them, and serves its own pages from memory.
- **For integrators:** the installer has a plan mode that checks choices
  without changing anything, and an unattended mode with a JSON progress feed,
  both specified in
  [`docs/setup-contract.md`](https://github.com/50sotero/rewindle/blob/v0.2.0-alpha.2/docs/setup-contract.md).

See the
[changelog](https://github.com/50sotero/rewindle/blob/v0.2.0-alpha.2/CHANGELOG.md)
for the full list.

## Download and verify

Download the setup program (recommended) or the ZIP from this release, plus its
`.sha256` file, and verify it before opening it:

```text
Rewindle-v0.2.0-alpha.2-windows-x64-setup.exe
Rewindle-v0.2.0-alpha.2-windows-x64.zip
```

```powershell
(Get-FileHash .\Rewindle-v0.2.0-alpha.2-windows-x64-setup.exe -Algorithm SHA256).Hash.ToLower()
Get-Content .\Rewindle-v0.2.0-alpha.2-windows-x64-setup.exe.sha256
```

The setup program carries the same ZIP and runs the same reviewed PowerShell
installer for you. The ZIP is for inspecting the payload, or for installing from
a console with `Install.cmd`.

## Upgrading from v0.2.0-alpha.1

This alpha does not upgrade in place. Run the new setup program and choose
**Reinstall or repair**: it removes the installed app (Windows asks for
permission), then goes through the steps again. Choose the same backup location
to carry on with your existing backups. Your backups and recovery key are kept.

## Requirements and boundaries

64-bit Windows 10 or 11 with Windows PowerShell 5.1 and .NET Framework 4.8.
Backups run from Task Scheduler through UAC-approved managers, with optional VSS
capture of open files and credentials protected for your account (DPAPI).
Verification of an off-site copy is supported for Google Drive for desktop;
other providers are not verified yet.

Test a restore before trusting Rewindle with irreplaceable data, and keep
another backup while you evaluate it. Rewindle does not automatically prune or
delete repository snapshots.

## Signing status

This alpha is not Authenticode-signed, so SmartScreen or antivirus software may
warn. The published checksums show the files were not altered after release;
they do not prove the publisher's identity.

## Validation

The release workflow runs the engine's Python suite, builds the setup program,
runs the dashboard's regression checks, and extracts the published ZIP to
perform real Restic backups and an independent restore. CI also installs,
reinstalls and uninstalls Rewindle for real on a hosted Windows runner through
the same unattended interface Setup uses, and checks Setup's own logic. Setup's
window itself is tested against a scripted installer.
