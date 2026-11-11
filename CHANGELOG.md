# Changelog

All notable changes to Rewindle are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with pre-release
labels. Releases before 0.2.0 were published under the name ResticBackuper.

## [Unreleased]

### Added

- **Backup alerts.** When backups are overdue, paused or have failed three
  times in a row, Rewindle shows one Windows notification for each problem and
  marks its icon in the notification area, amber or red, until the problem is
  put right. Protection says why a scheduled backup didn't run (the PC was off,
  asleep or signed out, the backup drive was unplugged, or Windows couldn't
  start it, with its error code) and what to do next, and the schedule card
  says when Windows last started the backup. Settings > Backup plan > Backup
  alerts turns the notifications off; the mark on the icon stays.
- **Backup drive space.** Protection and Settings show how much space your
  backups use (measured after each backup), how much is free on the backup
  drive (or in your Google storage) and about when it will be full at the rate
  your backups grow. The line turns amber within the Low space warning you
  choose in Settings (4, 8 or 12 weeks; 8 by default) and red when there is
  too little space for the next backup, each time with what to do, and never
  by deleting anything inside the backup folder. With the earlier personal
  edition the card shows the free space and says that the forecast isn't
  available with that backup program.
- **What each backup did.** Activity and a run's details count the files each
  backup found new, changed and unchanged ("312 new, 41 changed, 12,040
  unchanged"), and Protection and Restore say how far back your backups go
  ("412 backups, oldest 3 Mar 2025"). Runs recorded before this version, and
  anything Rewindle can't read, show nothing rather than a zero. With the
  earlier personal edition of the backup service, the backups are counted the
  first time Restore lists them.
- **Clean-up of old backups, off until you turn it on.** Settings has an Old
  backups card: choose how many days, weeks and months to keep, see exactly
  which backups would go and which stay, and confirm before anything is
  removed. Windows asks for your permission each time. Nothing is removed
  while the last backup didn't finish or needs a look, or while another
  change is unfinished. It works for a backup location on a drive of this PC
  (not yet for Google Drive), and installing, updating or reinstalling
  Rewindle turns it off until you turn it on again. If a clean-up stops
  part-way, it says what was removed and what is left to do. The backup drive
  forecast takes away the space a clean-up frees, and how far back your
  backups go is counted again after one. The earlier personal edition says
  clean-up isn't available.
- **Restore can find a file in all your backups.** On the first step, choose
  Find a file and type part of a name, such as Budget. Rewindle looks through
  your backups, newest first, and lists each version it finds with when it
  changed, its size and its folder, and says when a file is gone from the newer
  backups. Restore this picks that version, and the usual steps follow. The
  search only reads your backups, uses the Windows permission Restore already
  asked for, looks for about 20 seconds at a time (Look further back goes on),
  and is not offered while a backup is running or about to start (the Find a
  file tab says why). It is not available with the earlier personal edition of
  the backup service.
- **Backups without a password, if you choose them.** Setup has a new
  Password page, and an unattended install takes `-RepositoryAccess
  no_password`, to make backups that have no password. A password stays the
  recommended default: Setup makes a strong one, keeps it safely for your
  account and gives you a recovery key. Without one, anyone who can open the
  backup folder can restore every backed-up file, including saved sign-ins.
  That includes the folder in Google Drive or on a lost USB drive. There is no
  recovery key to keep, so the Recovery key page, the key checks and the key
  repair and rotation buttons don't appear for those backups, and the
  instructions that come with them use Restic's `--insecure-no-password`
  option. The choice is made once for a set of backups: backups you already
  have, with or without a password, keep the way they were made, and Rewindle
  never switches them. SECURITY.md has the details and a guide to switching an
  existing backup yourself with Restic.

### Changed

A pass over every page of the dashboard and Setup, so that nothing raises an
alarm without saying what to do, each fact is said once, and the words are
ones a home user reads without a glossary.

- **Activity** no longer treats every failed or incomplete run as something to
  act on. A run that a later successful backup put right is marked
  **Resolved**, in a neutral color, and its details say that nothing needs
  doing. The page warns, with a link to the details, only when no backup has
  succeeded since a run that failed. The figures at the top are successful
  backups, the usual backup time and the new data in the last backup; the
  filter chips are Successful, Problems (or Resolved) and Cancelled, with date
  presets; the two charts sit side by side, and a run that worked keeps its log
  folded.
- **Protection** names what is wrong (an unplugged backup drive, a missing
  folder, an empty plan, a schedule that can't be read) with one next step, and
  colors the page only when there is something to do. A failed run is
  described in a plain sentence from its failure code, with a "See what
  happened" button. The last verified backup reads "yesterday at 2:03 AM", the
  off-site copy waits calmly for its next check, and the folder list says
  "Stop backing up".
- **Restore** says once per step what to do, shows the newest backup first
  with a "Newest" mark, explains why files go to a separate folder (and where
  inside it they land), and turns refusals from the backup service into plain
  sentences. `npm run dev:demo` can walk the whole flow on invented data.
- **Settings** has three sections (Backup plan, Appearance with a Text size
  card, Help and about with the problem report and keyboard shortcuts). The
  sidebar no longer repeats recent runs, the header drops the always-on
  "connected" light, and the theme button steps through System, Light and Dark.
  The text size is kept between launches.
- **Times** everywhere come from one formatter in the viewer's own clock,
  including the next run and the schedule ("Daily at 2:00 AM").
- **Words**: the dashboard, its tray texts, the folder picker, the recovery
  readiness window and the uninstaller no longer say repository, snapshot,
  engine, canary, Restic or "protected task" to the user; they say backup,
  backup location, backup service and restore test file. Retry buttons say
  "Try again". The unusual-change review asks the person to "Confirm these
  changes".
- **Folder picker** warns before adding a OneDrive folder or one whose files
  are stored only in the cloud, with a bounded check that never refuses a
  folder on a guess.
- **Setup** renames its steps Protected folders and Automatic backups, explains
  how to format a FAT32 or exFAT drive as NTFS, walks through OneDrive's
  "Always keep on this device", marks the recovery key "Saved and checked",
  ignores Enter on the Review page so a stray key press never installs, and
  uses a slightly larger type scale, shared with the dashboard.
- **Restore** waits less at every step. The backup service's check of its own
  files walks each folder once instead of once per file in it (with the full
  Python library the earlier personal edition ships, that check alone took
  about 7 seconds, and now takes under 1). Listing backups and
  opening folders read through the cache the backup keeps, so only what is new
  is fetched from the backup location, and they no longer write and remove a
  lock file there (the run lock already keeps backups out meanwhile); a restore
  keeps its lock, and the recovery drill still reads only the backup location.
  While it works, the dialog says what each stage means instead of showing the
  service's log line.

### Fixed

- **An update or a reinstall no longer makes the next backup read every file
  again.** Every update is installed as a reinstall, and after each one the
  next backup read all your folders again to add almost nothing (about two
  hours on a PC with 114 GiB of files). Until it finished, the nightly Google
  Drive check wouldn't run, and Recovery readiness asked for a new backup and
  a new restore drill. A reinstall or update that keeps your folders, this PC
  and your backup location now carries on from your last checked backup, so
  none of that happens. When something else changed, such as the list of files
  Rewindle leaves out, or after you move your backups to another place, the
  first backup afterwards still reads only the files that changed since your
  last checked backup, as long as it backs up the same folders on the same
  drives.
- **The nightly Google Drive check can unlock its Google Drive connection.**
  The check keeps its Google Drive connection locked, and a small password
  helper unlocks it each time the check starts. A mistake in the check asked
  Windows to start a program that does not exist instead of that helper, so
  every check stopped within seconds, before it looked at the copy in Google
  Drive, and the dashboard went on showing the off-site copy as not set up.
  The check now starts the password helper correctly.
- **The nightly Google Drive check no longer opens a window.** Task Scheduler
  started Windows PowerShell for the check itself, and a program started that
  way shows a console window for a moment, even when told to hide it. With
  Windows Terminal as the default terminal a whole terminal window opened, at
  03:00 or whenever Windows made up for a missed night, over a full-screen
  game too. The check now starts through the task launcher the backup uses,
  which runs it without any window and with Windows' own settings only, and
  ends every program it started when the task is stopped. Setting the check up
  also records which rclone it uses and refuses one older than 1.65.0, which
  can't read Google Drive's file checksums. A check set up with an earlier
  version opens the window until it is set up again, as Rewindle's guide to
  Google Drive describes.
- **The nightly Google Drive check can pass.** The check proves the copy in
  Google Drive can be restored by restoring a small test file from it, and the
  backup program also rebuilt each folder above that file with its original
  owner and permissions. C:\ProgramData belongs to Windows and lets every user
  add files to it, so the check's own safety test rejected its work folder. A
  check that got that far failed at its very end, the folders it left behind
  made every later check fail at its start, and the dashboard went on showing
  the off-site copy as not set up. The check now restores only the test file's
  own folder, as each backup does when it tests a restore, and stops if
  anything else comes back. If you set the check up with an earlier version,
  sign in as the person who set it up, open
  `C:\ProgramData\ResticBackuperCloudVerification\runs` in File Explorer,
  delete the folders inside it and approve the administrator prompt. Keep the
  `runs` folder itself, and if Windows offers to give you access to a folder,
  cancel instead.
- **The Off-site copy card says when the nightly Google Drive check failed.**
  A check that failed left no trace the dashboard could show, so until a first
  check had passed the card said "Not set up (optional)", and after one it
  said nothing was wrong for two days. The card now says the check failed,
  which step it stopped at, why, and what to do next. A failure from before
  Rewindle was set up again, or before the backup moved or its settings
  changed, isn't shown, and a problem report now includes the check's record
  of why it stopped. "Google Drive copy verified" also no longer lasts for
  ever when no newer backup comes: once no check has worked for two days, the
  card says the copy hasn't been checked lately, with what to do about it.
- **The automatic backup no longer moves by an hour when the clocks change.**
  Setup wrote the backup time in UTC, which Windows keeps at one UTC moment all
  year, so a backup set for 02:00 ran at 01:00 all winter. The dashboard took
  it as due at 02:00 and called a backup that had run on time **Overdue**.
  Setup and Edit schedule now write a local clock time (the Google Drive check
  too), and saving the schedule repairs one an earlier version wrote. Until it
  is saved, the dashboard works out the times that schedule really runs at,
  shows them, and says how to keep it at the same time all year.
- **The nightly Google Drive check finds a missing or incomplete file in
  minutes.** The check used to read every file of the backup on this PC, about
  an hour for 60 GB, before it compared anything with Google Drive, so a file
  that was missing or incomplete there showed up only at the very end. It now
  compares the list of files in Google Drive (names and sizes) with the backup
  on this PC first and stops at once if they differ. The slow comparison of
  the contents runs only when the two lists match.
- With the backups overdue or paused, a pending change review now says why the
  **Confirm these changes** button is there.
- **The nightly Google Drive check says why it stopped, and copes with a late
  start.** A check that stopped left no trace of why. Each check that stops
  now leaves a short record of when it stopped, what it was doing, why in
  plain words and what to do. When the PC was off or asleep at 03:00, Windows
  starts the check at the next sign-in, together with the backup it missed.
  The check then waits for Google Drive for desktop, the internet connection
  and that backup, instead of failing or making the backup give up until the
  next night. Each step that runs Restic, rclone or Python has a time limit
  sized for your backups, and one that hangs is stopped together with
  everything it started. Before anything slow, the check now refuses an
  rclone older than 1.65.0, which can't report the checksums it compares. It
  keeps only its five newest work folders (and the one with the latest
  proof), and it deletes its working copy of the encrypted rclone settings
  after each run. Its proof no longer claims that its Google sign-in can only
  read.
- **Confirm these changes works.** After a backup that found far more changes
  than usual, confirming them always failed with "ACL inheritance is not
  protected". The review asked for one exact form of permissions on the
  backup's record of that run, but the backup writes that record with the
  permissions of its folder, where only Administrators and Windows can make
  changes. The review now accepts either, as long as nobody else can change the
  record or its folder.
- **Changing the backup location works.** Every move stopped at its first check
  and put everything back, because Windows PowerShell handed the backup service
  the command that unlocks the backup cut in pieces at the space in "Program
  Files". The move now starts the backup service with correctly quoted words
  and only the few Windows settings it needs, so nothing left in your own
  environment can change where it reads its password from, and it runs
  Windows' permissions tool only if Microsoft itself signed it. Once a move is
  complete, Rewindle's record of the backup location names the new folder too,
  so later backups can still compare their changes with earlier ones and the
  Google Drive check can be set up there. While a move runs, the dashboard now
  says "Moving your backup location" instead of "Backups paused: moving the
  backup location didn't finish", and it offers **Repair interrupted move**
  only once the move has really stopped, also after the dashboard was closed
  and opened again during the move.
- **Setup remembers where your backups are when you install Rewindle again,
  and a failed install no longer blocks the next one.** Only the Setup window
  that had just removed Rewindle knew where its backups were. After removing
  Rewindle from Installed apps, or closing Setup between the two halves of a
  reinstall, Setup proposed a new folder, started a second, empty backup there
  that needed room for a full copy, and rewrote the recovery key to name it.
  The installer now reads where the backups are from the records Rewindle
  keeps after an uninstall (`kept_repository` in the plan), Setup and the
  console installer suggest that folder, and Backup location says what
  choosing another place means, with a button to go back to the earlier
  backups. And when an install failed at its last checks, the dashboard it had
  just started kept the program folder in use: the rollback deleted the list
  of installed files but not the folder, still said it had undone its changes,
  and from then on Setup could neither install nor remove Rewindle. The
  rollback now stops the dashboard and the backup program first, removes that
  list last and checks that the folder is gone; if something is still in use,
  it says so and asks you to restart the PC and choose Reinstall or repair in
  Setup.
- **The weekly deep check really happens, a folder named Coverage is backed up,
  and a failed backup names the right cause.** About once a week a backup also
  reads back a sample of the saved data, but only a backup that ran on a Sunday
  did it, so a PC that was off on Sundays, or a schedule without Sunday, never
  had it. It now runs on the first backup on or after the seventh day since the
  last check that passed, whatever the weekday; it counts only once it passes,
  and the recovery readiness check says how long ago that was. The default
  exclusion list left out every folder named coverage, venv or .cache, in any
  letter case, so a Coverage folder of insurance papers was never backed up. It
  now leaves out only what developer tools write inside such folders, and it no
  longer suggests editing the installed list, which made restores and repairs
  refuse to run; it changes only with an update. A full backup drive, a
  different drive at the backup drive's letter and a protected folder's drive
  that doesn't answer now each get their own explanation and next step. Before,
  the first two said to reconnect the backup drive and the third blamed the
  backup drive.
- **Protection is neither too calm nor too loud.** A backup missed while the
  PC was off, asleep or signed out no longer turns the page red the moment
  you sign in: Windows starts such a backup by itself, so Protection says
  **Catching up** in a neutral color and asks for nothing. If the backup has
  not started 45 minutes after you sign in or wake the PC, it is **Backup
  overdue** again, with **Back up now**. An off-site copy whose nightly
  check has not worked for two days (or that has shown a check as running for
  that long) no longer says there is nothing to do: the card warns, says to
  leave the PC on and signed in overnight, and what to do if that does not
  help. A backup cut short by a sign-out or shutdown is shown as interrupted;
  before, it could show as still running for up to a day, with **Back up
  now**, folder changes and restores turned off. Setting the PC's clock back
  no longer pauses the status checks, the notices or the wait after **Back up
  now** for as long as the clock went back. And when a sign-out or shutdown is
  cancelled, Rewindle is still running in the notification area; before, it
  had already quit.
- **Dashboard buttons and lists behave.** "See what happened" under a failed
  backup stayed greyed out until a run was picked in Activity; it now opens that
  run's details at once. A double-click on Back up now, Stop backing up, Add
  folder, Restore now and the other buttons that ask for something sent the
  request twice, so a second confirmation opened or a red "wait" message stayed
  on screen. Each of them now stays off until its first press has been answered,
  and Rewindle never starts a second folder change while one is waiting for
  Windows approval. When the backup status can't be read, Protection no longer
  adds "No verified backup yet" under it. "Last 7 days" and the other ranges in
  Activity move on at midnight instead of turning into fixed dates. Restore
  lists the newest 50 backups, with **Show older backups** for the rest, so a
  long backup history no longer slows the window down; the search still looks
  through all of them. Review restore and Restore now check the restore folder
  without freezing the window while a sleeping drive wakes up, and the restore
  still starts only if that check passes.
- **Restoring a file or folder with square brackets in its name works.**
  Choosing something like `Photos [2020]` or `Notes[1].txt` restored nothing,
  or a different item with a similar name (`Photos 2`, `Notes1.txt`), and the
  restore still said it was complete and verified, because the backup service
  reads `[` in a name as the start of a pattern. Rewindle now hands over every
  chosen name exactly as it is written. After the restore it also looks for
  each item you chose in the folder you restored to; if one is not there, the
  restore ends as incomplete and says what to try next, instead of reporting
  success. However many restores you run, **Check recovery readiness** still
  finds your last restore drill.
- **A folder that holds WSL links can be backed up.** The backup service can't
  store the links, pipes and devices that WSL (Windows Subsystem for Linux)
  keeps on a Windows drive, so a protected folder with any of them, such as a
  project checked out from inside WSL, made every backup end as incomplete.
  With no complete backup, Restore and clean-up of old backups refused to run.
  Each backup now finds these items while it checks your folders and leaves
  exactly those out, so it completes and is verified; Windows links and
  junctions are backed up as before, and nothing needs to be added to the
  exclusion list. An item is left in when it can't be named exactly (for
  example, another item next to it has the same name in other letter case), or
  when there are more than 1,000 of them; for those, the backup behaves as it
  did before. If WSL puts a real file or folder where one of them was while
  the backup runs, that backup ends as incomplete rather than miss it quietly.

### Security

- **Steps that run with administrator rights load PowerShell modules only from
  Windows.** Windows PowerShell looks in your Documents folder first, where any
  program you run could put a module that answers to the name of a built-in
  command and so runs with those rights. Setup's elevated step, the nightly
  Google Drive check, its password helper and its task installer now limit
  PowerShell to Windows' own modules before they run any command, and the
  backup service's other elevated steps now do it first too. The Google Drive
  check's password helper changed, so registering that check again needs
  `-ProvisionAssets`.
- **Nothing that runs as administrator is built in your own temporary folder
  any more.** The installer, the uninstaller and moving the backup location
  compiled small Windows helpers in your temporary folder and then loaded them
  as administrator, so another program running as you could have swapped them
  in between. They are now made in memory. The installer also downloads
  Microsoft's WebView2 installer into a folder only administrators can change
  and keeps it locked from its signature check until it has finished, and the
  rest of the install keeps its temporary files in such a folder too.
- **Protected tasks no longer take backup settings from your account's
  environment variables.** The scheduled backup, restores, the repair helpers,
  the nightly Google Drive check and Setup run with administrator rights, but
  Windows gives them the user's own environment variables, which any program
  the user runs can change without asking. A Restic or rclone setting planted
  there (a password command, a password or repository file, a pack size, a
  replacement for the Google Drive connection) could run a program with
  administrator rights, check the wrong account or make every backup fail.
  Every Python, Restic and rclone process they start now gets a short fixed
  list of variables taken from Windows itself, the Google Drive check keeps its
  read-only access and My Drive root in the connection itself, and Restic keeps
  its temporary files in Rewindle's protected data folder instead of the user's
  temp folder.
- **A restore or a move of the backup location can no longer be steered into
  Windows or program folders.** The restore checked the folder you chose and
  then wrote into it with administrator rights, but a program running as you
  could swap that folder for a link in between, so the restored files landed
  in Windows or Program Files instead. The chosen folder now stays open for the
  whole restore, so it cannot be moved, and the files go into a hidden folder
  inside it that only Windows and administrators can change, then move into
  your folder with its usual permissions. A folder inside Windows, Program
  Files or ProgramData is refused outright, with a suggestion of where to
  restore instead. Moving the backup location had the same gap: the folders
  it copies into, next to the new location, now stay open the same way until
  they get their final names, and only the backup's own files are copied, so
  nothing else in the old folder (a Google Drive folder, for example) comes
  along with administrator rights.
- **Setup and the installer are stricter about what they trust.** A Windows
  tool, or Microsoft's WebView2 installer, must now be signed by Microsoft
  itself: the signer is exactly Microsoft Corporation, through Microsoft's own
  root certificates. Before, any valid signature with "Microsoft" anywhere in
  the signer's name passed. Setup looks for the DLLs it loads by name only in
  Windows' System32 folder, so a file left next to it in Downloads is never
  loaded in their place. And the installer no longer uses a
  `C:\ProgramData\ResticBackuper` folder that Administrators don't own, since
  any account can create one there: it says so and asks for the folder to be
  moved away, and it creates that folder already owned by Administrators.
- **A program running without administrator rights can no longer stop your
  backups.** Every backup and every protected change first takes a lock file
  in the backup service's folder. That file could be read by your account, and
  reading was enough to hold the lock, so any program you ran could keep every
  backup from starting. Now only Administrators and Windows can open it. An
  older lock file is repaired the next time a backup or a protected change
  starts, even while a program holds it open, and Setup protects it again
  after it sets the folder's permissions.
  The dashboard now prepares every request for administrator approval, and
  checks every answer it gets back, with one shared set of checks. Two older
  copies had fallen behind the rest: one quoted line breaks loosely, and one
  accepted a restore answer with weaker permissions than the others allow.
  The GitHub workflows now run only actions pinned to an exact commit, and the
  release workflow publishes a signed record of how each download was built,
  which `gh attestation verify` checks. Releases are still not code-signed.

## [0.2.0-alpha.2] - 2026-10-08

### Added

- A machine-readable backend for setup programs, specified in
  `docs/setup-contract.md`:
  - `Install-ResticBackuper.ps1 -PlanOnly -PlanOutput <file>` validates the
    choices with the same functions a real install uses, changes nothing, needs
    no elevation and writes one JSON document: errors and warnings with stable
    codes and plain-language messages, the resolved configuration, defaults,
    and a description of the PC (drives with an eligibility verdict and a
    recommended backup drive, Windows and .NET versions, WebView2, Google Drive,
    an existing installation, the standard folders).
  - `-Unattended -ExpectedUserSid <sid> -ProgressPath <file>` on the installer
    and the uninstaller append one JSON line per phase and always end with a
    result line, including on failure. The installer reports whether the user
    can read the recovery key, and its new verification phase checks the
    finished installation.
- Tests: a hermetic suite for plan mode, the progress feed and the decision
  functions (`tests/Test-InstallPlan.ps1`), static checks that tie the scripts to
  the contract (`tests/test_setup_contract.py`), and an end-to-end CI test that
  really installs and uninstalls on the hosted runner
  (`tests/Test-InstallerContract.ps1`).
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
  `install-failure`, `uac-declined`, `key-unreadable`, `goes-online-only`), and
  `npm run build:setup-demo` makes a static copy. The sample is not part of the
  setup program; the build checks the bundle for it.
- `tests\Test-SetupHost.ps1` checks the setup program's logic without starting
  it or the installer, `tests\Test-SetupWindow.ps1` opens the real window against
  fakes and takes a screenshot of every page, and CI runs the first.

### Changed

- `-Schedule` is checked in the script body instead of by a parameter attribute,
  so a plan can report a bad time; a real install still checks it first. A
  network repository path is now refused before any probe reaches the network.
- `build\Build-Release.ps1` builds the setup program with
  `installer\setup\build.ps1`. The ZIP still carries `Install.cmd` for console
  installs. The WebView2 SDK pin and the deterministic ZIP helper moved to
  `build\RewindleWebView2.ps1` and `build\RewindleZip.ps1`, shared by the
  dashboard and setup builds.
- A reinstall over the state an uninstall kept continues the same backup plan,
  which the engine requires. When it uses another backup location, the kept
  recovery key is rewritten to name it once the reinstall has succeeded
  (`initialize_repository.py --commit-recovery-key`); a reinstall that fails
  leaves the key as it was.
- The uninstaller removes a leftover Installed apps entry whose program folder
  is already gone, and keeps, with a warning, a Start menu shortcut or Installed
  apps entry it can't prove is Rewindle's. Setup explains that a new install
  won't run over such an entry.
- README and release notes show the setup wizard (`docs/images/setup/`).

### Security

- Setup runs as the person who started it. Only the installer and the
  uninstaller run elevated, and a script from Setup's own bundle runs from a
  copy staged in an administrator-only folder and checked against the SHA-256
  hashes Setup took when it unpacked the bundle.
- The elevated installer's progress file is owned by Administrators and only
  they and SYSTEM can change it; Setup trusts no other file, and a success
  report from an installer that exits with an error is a failure.
- Setup holds Microsoft's WebView2 bootstrapper and its own WebView2 libraries
  open from the moment it checks them until they are used, runs and loads them
  by their resolved paths, keeps its temporary folder out of the DLL search
  order, and serves its own pages from memory instead of from disk.

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

[Unreleased]: https://github.com/50sotero/rewindle/compare/v0.2.0-alpha.2...HEAD
[0.2.0-alpha.2]: https://github.com/50sotero/rewindle/compare/v0.2.0-alpha.1...v0.2.0-alpha.2
[0.2.0-alpha.1]: https://github.com/50sotero/rewindle/releases/tag/v0.2.0-alpha.1
