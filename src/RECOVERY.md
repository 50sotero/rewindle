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
the command for other configured sources. The target must be absent or empty
and must not overlap a source or repository.

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

Restores never need to modify or delete the repository. Prefer a new empty
target on a different path, inspect the restored files, and only then decide
how to put individual files back into service.
