# ResticBackuper recovery

This directory is a recovery aid for the configured Restic repository. It
contains Restic, the guarded restore wrapper, the generated configuration, and
checksums. It intentionally does **not** contain the repository password.

Keep a separate copy of `ResticBackuper-RecoveryKey.txt` in a password manager,
on removable media, or printed in a secure place. CurrentUser DPAPI alone will
not survive loss of the Windows profile.

## Same-machine restore

If the installed runtime and DPAPI credential are still available:

```powershell
& 'C:\Program Files\ResticBackuper\Python\python.exe' -I .\restore.py --list
& 'C:\Program Files\ResticBackuper\Python\python.exe' -I .\restore.py `
  --snapshot latest `
  --source 'C:\Users\you\Documents' `
  --target 'X:\Restored-Documents'
```

`--source` must exactly match a source listed by the configuration. It restores
that source without recreating absolute-path ancestors and their ACLs. Repeat
the command for other configured sources. The target must be absent or empty,
must not overlap a source or repository, and must not be inside Windows,
Program Files or ProgramData. While the restore runs, the files go into a
hidden folder inside the target and move into the target when it finishes.

To restore only some items, add `--include` for each one. With `--source`,
give its path inside that source, starting with `/`:
`--include '/Taxes [2024]/return.pdf'` restores
`C:\Users\you\Documents\Taxes [2024]\return.pdf`. Without `--source`, give its
whole path in the backup, starting with the drive letter:
`/C/Users/you/Documents/Taxes [2024]/return.pdf`. `restore.py` takes each name
exactly as written (a `[` needs no escaping here, unlike with Restic below),
refuses `*`, `?` and Windows-style paths, and reports the restore as incomplete
if an item you named is not in the target afterwards.

If a restore is interrupted (for example by a power cut), that hidden folder,
named `.rewindle-restore-` followed by 16 letters and digits, can stay behind
in the target, and only administrators can open it. To delete it, open a
Command Prompt as an administrator and run (with your folder's names):

```bat
rmdir /s /q "X:\Restored-Documents\.rewindle-restore-0123456789abcdef"
```

`rmdir /s` removes links inside the folder without following them. Then
restore again into a new or empty folder.

A restored file that has more than one name (a hard link) keeps the hidden
folder's administrator-only permissions, because its other name might be
outside the restore. An administrator can give it the target's usual
permissions with `icacls "<file>" /reset`.

## A backup drive that is full

Backups stop while the drive that holds the repository has less free space
than `minimum_free_gib` in the configuration. Make room by removing other
files from that drive, or move the repository to a bigger drive with Change
location in the dashboard. Never delete, move or edit anything inside the
repository folder to make room: every file in it can be part of every
backup. The next scheduled backup runs once there is room.

## Recovery-key restore

When only this bundle, the repository, and the offline recovery key remain:

```powershell
.\restic.exe --repo 'X:\Path\To\Repository' snapshots
.\restic.exe --repo 'X:\Path\To\Repository' restore `
  'latest:/C/Users/you/Documents' `
  --target 'X:\Restored-Documents' --overwrite never --verify
```

The source selector uses forward slashes and begins with the drive letter, as
shown above. Restic prompts for the password. Copy only the value on the `Password:` line
from the offline recovery-key file. Do not place it in command-line arguments,
scripts, logs, or screenshots.

To restore only part of that folder, add `--include` for each item with its
path inside the folder: `--include '/Taxes [[]2024]/return.pdf'` restores
`Taxes [2024]\return.pdf`. Restic reads `[` as the start of a pattern, so write
every `[` in a name as `[[]`. An include that matches nothing restores nothing
and still ends without an error, so check the target afterwards.

## Finding a file

If you know a file's name but not which backup or folder holds it, Restic can
look through every backup without changing anything:

```powershell
.\restic.exe --repo 'X:\Path\To\Repository' find --long --ignore-case '*budget*'
```

Restic asks for the password, as above. For each backup that holds a matching
file or folder it prints a line with the backup's short ID and time, then one
line for each match. With `--long`, as here, each of those lines ends with the
item's size in bytes, the date and time it last changed, and its path inside the
backup; without `--long` Restic prints only the paths. Add `--snapshot` with an
ID from the `snapshots` list to look in one backup only. The pattern is matched
against every part of a path, so a short one also lists everything inside
folders whose names match; type more of the name to narrow it down. In a
pattern `[` starts a set of characters, so for a name with `[` in it put `?` in
its place: `'*Taxes ?2024]*'` finds `Taxes [2024]`. Then restore the path
Restic printed as shown above, writing each `[` as `[[]` in `--include`.

Restores never need to modify or delete the repository. Prefer a new empty
target on a different path, inspect the restored files, and only then decide
how to put individual files back into service.

## If clean-up of old backups was on

When someone turned on clean-up of old backups, it removed only backups on a
list they confirmed. Those backups can't be restored, and `find` no longer
finds what only they held; `snapshots` lists the ones that are left, which
include the last backup of each recent day, week and month that was kept. A
clean-up that was interrupted (for example by a power cut) may have removed
only part of its list, or not yet freed the space; that does not affect
restoring what is left.

If Restic says the repository is locked, a clean-up may have stopped part-way.
Add `--no-lock` to `snapshots`, `find` and `restore`: all three only read, and
the option lets them run without touching the lock. Do not run `forget`,
`prune` or `unlock` while you are recovering files.
