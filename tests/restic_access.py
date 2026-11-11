"""How Restic 0.19.1 treats --insecure-no-password, for the fake Restic programs in the tests.

Every fake that stands in for Restic when backups may have no password applies these rules first, in this order, to a
command that opens the backups (measured with the pinned Restic on throwaway repositories):

1. --insecure-no-password next to a password source (--password-command, --password-file, --new-password-file, or a
   non-empty RESTIC_PASSWORD, RESTIC_PASSWORD_FILE or RESTIC_PASSWORD_COMMAND): exit 1 with CONFLICT. (The real Restic
   runs a password command before it refuses; a fake never needs to.)
2. Backups without a password, opened without the flag: exit 1 with EMPTY_NOT_ALLOWED (with stdin closed; with an open
   stdin the real Restic waits for a password instead, which is why every caller closes it).
3. Backups with a password, opened with the flag: exit 12 with WRONG_PASSWORD.

Anything else is up to the fake.
"""

from __future__ import annotations

from typing import Mapping, Sequence

NO_PASSWORD_FLAG = "--insecure-no-password"
PASSWORD_SOURCE_OPTIONS = ("--password-command", "--password-file", "--new-password-file")
PASSWORD_SOURCE_VARIABLES = ("RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND")

CONFLICT = (
    "Fatal: --insecure-no-password must not be specified together with providing a password via a cli option or "
    "environment variable"
)
EMPTY_NOT_ALLOWED = (
    "Fatal: an empty password is not allowed by default. Pass the flag `--insecure-no-password` to restic to disable "
    "this check"
)
WRONG_PASSWORD = "Fatal: wrong password or no key found"


def has_password_source(command: Sequence[str], environment: Mapping[str, str] | None) -> bool:
    for argument in command:
        for option in PASSWORD_SOURCE_OPTIONS:
            if argument == option or argument.startswith(option + "="):
                return True
    return any((environment or {}).get(name) for name in PASSWORD_SOURCE_VARIABLES)


def restic_access_result(
    command: Sequence[str], environment: Mapping[str, str] | None, access: str = "password"
) -> tuple[int, str] | None:
    """(exit code, stderr) when Restic would refuse to open backups made with `access`; None when it would open them."""
    if access not in ("password", "no_password"):
        raise ValueError(f"unknown access for the fake: {access!r}")
    flag = NO_PASSWORD_FLAG in command
    if flag and has_password_source(command, environment):
        return 1, CONFLICT
    if access == "no_password" and not flag:
        return 1, EMPTY_NOT_ALLOWED
    if access == "password" and flag:
        return 12, WRONG_PASSWORD
    return None
