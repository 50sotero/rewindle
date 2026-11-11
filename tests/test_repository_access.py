"""Backups with or without a password: the engine's one rule for how Restic opens them (restic_common)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import restic_common
from restic_access import CONFLICT, EMPTY_NOT_ALLOWED, WRONG_PASSWORD, restic_access_result


SANITIZED_WORDS = ("password", "dpapi", "restic_")


def write_config(root: Path, **extra) -> Path:
    """A minimal valid backup-config.json (as tests/test_core.py writes it), plus `extra` keys."""
    source = root / "source"
    source.mkdir(exist_ok=True)
    restic = root / "restic.exe"
    restic.write_bytes(b"test fixture; not an executable")
    excludes = root / "excludes.txt"
    excludes.write_text("**/__pycache__\n", encoding="utf-8")
    canary = root / "canary.txt"
    canary.write_text("ResticBackuper test canary\n", encoding="utf-8")
    config = {
        "schema_version": 1,
        "plan_id": "11111111-1111-4111-8111-111111111111",
        "config_generation": 1,
        "repository": str(root / "repository"),
        "repository_volume_serial": "00000000",
        "restic_executable": str(restic),
        "recovery_tools_directory": str(root / "recovery-tools"),
        "python_executable": sys.executable,
        "state_directory": str(root / "state"),
        "secret_file": str(root / "state" / "password.test.json"),
        "recovery_key_file": str(root / "recovery.test.txt"),
        "exclude_file": str(excludes),
        "canary_file": str(canary),
        "hostname": "RESTICBACKUPER-TEST",
        "scheduled_tag": "scheduled-test",
        "cloud_placeholder_policy": "strict",
        "sources": [str(source)],
        "source_identities": {str(source): {"expected_volume_serial": "00000000"}},
    }
    config.update(extra)
    path = root / "backup-config.test.json"
    path.write_text(json.dumps(config), encoding="utf-8")
    return path


class RepositoryAccessRuleTests(unittest.TestCase):
    def test_absent_means_password(self) -> None:
        self.assertEqual("password", restic_common.repository_access({}))

    def test_the_two_values_are_accepted_exactly(self) -> None:
        self.assertEqual("password", restic_common.repository_access({"repository_access": "password"}))
        self.assertEqual("no_password", restic_common.repository_access({"repository_access": "no_password"}))

    def test_anything_else_is_refused_and_never_defaulted(self) -> None:
        for value in ("Password", "NO_PASSWORD", "no-password", "none", "", " password", None, 0, 5, True, [], {}):
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as caught:
                    restic_common.repository_access({"repository_access": value})
                # Rewindle's log filters hide a whole message that contains one of these words.
                for word in SANITIZED_WORDS:
                    self.assertNotIn(word, str(caught.exception).lower().replace("repository_access", ""))

    def test_load_config_records_the_access_and_defaults_an_old_configuration(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            old = restic_common.load_config(write_config(root), require_repository=False)
            self.assertEqual("password", old["repository_access"])
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            chosen = restic_common.load_config(
                write_config(root, repository_access="no_password"), require_repository=False
            )
            self.assertEqual("no_password", chosen["repository_access"])

    def test_load_config_refuses_an_unsupported_access(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            with self.assertRaises(ValueError):
                restic_common.load_config(write_config(root, repository_access="nopassword"), require_repository=False)


class ResticArgumentTests(unittest.TestCase):
    def config(self, root: Path, access: str | None) -> dict:
        config = {
            "restic_executable": str(root / "restic.exe"),
            "repository": str(root / "repository"),
            "state_directory": str(root / "state"),
            "python_executable": sys.executable,
            "secret_file": str(root / "state" / "password.test.json"),
        }
        if access is not None:
            config["repository_access"] = access
        return config

    def test_password_mode_command_is_unchanged(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            for access in (None, "password"):
                with self.subTest(access=access):
                    config = self.config(root, access)
                    command = restic_common.restic_base(config, json_output=True)
                    self.assertEqual(
                        [
                            config["restic_executable"],
                            "--repo",
                            config["repository"],
                            "--password-command",
                            restic_common.password_command(config),
                            "--cache-dir",
                            str(root / "state" / "cache"),
                            "--retry-lock",
                            "5m",
                            "--json",
                        ],
                        command,
                    )
                    self.assertNotIn(restic_common.NO_PASSWORD_FLAG, command)

    def test_no_password_mode_has_the_flag_and_no_password_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            config = self.config(root, "no_password")
            command = restic_common.restic_base(config)
            self.assertEqual(
                [
                    config["restic_executable"],
                    "--repo",
                    config["repository"],
                    "--insecure-no-password",
                    "--cache-dir",
                    str(root / "state" / "cache"),
                    "--retry-lock",
                    "5m",
                ],
                command,
            )
            self.assertEqual(["--insecure-no-password"], restic_common.restic_credential_arguments(config))
            self.assertIsNone(restic_access_result(command, restic_common.restic_child_environment(command), "no_password"))

    def test_no_reveal_command_is_ever_built_without_a_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            with self.assertRaises(RuntimeError):
                restic_common.password_command(self.config(root, "no_password"))
            with self.assertRaises(ValueError):
                restic_common.restic_base(self.config(root, "bogus"))

    def test_the_child_environment_refuses_a_password_source_next_to_the_flag(self) -> None:
        flag = restic_common.NO_PASSWORD_FLAG
        with self.assertRaises(ValueError):
            restic_common.restic_child_environment(["restic.exe", flag, "snapshots"], password="secret")
        for source in (
            ["--password-command", "reveal"],
            ["--password-command=reveal"],
            ["--password-file", "key.txt"],
            ["--password-file=key.txt"],
            ["--new-password-file", "new.txt"],
        ):
            with self.subTest(source=source):
                with self.assertRaises(ValueError) as caught:
                    restic_common.restic_child_environment(["restic.exe", "--repo", "R", flag, *source, "snapshots"])
                for word in ("dpapi", "restic_"):
                    self.assertNotIn(word, str(caught.exception).lower())
        environment = restic_common.restic_child_environment(["restic.exe", "--repo", "R", flag, "snapshots"])
        self.assertFalse([name for name in environment if name.upper().startswith("RESTIC_")])
        # Password mode keeps working as before.
        restic_common.restic_child_environment(["restic.exe", "--password-command", "reveal", "snapshots"])
        self.assertEqual(
            "secret",
            restic_common.restic_child_environment(["restic.exe", "--repo", "R", "snapshots"], password="secret")[
                "RESTIC_PASSWORD"
            ],
        )

    def test_mismatch_failure_has_its_own_code(self) -> None:
        self.assertEqual("repository_access_mismatch", restic_common.RepositoryAccessMismatch.failure_code)
        self.assertTrue(issubclass(restic_common.RepositoryAccessMismatch, restic_common.EngineFailure))


class FakeRun:
    def __init__(self, returncode: int | None = 0, error: BaseException | None = None) -> None:
        self.returncode = returncode
        self.error = error
        self.calls: list[tuple[list[str], dict]] = []

    def __call__(self, command, **options):
        self.calls.append((list(command), options))
        if self.error is not None:
            raise self.error
        return subprocess.CompletedProcess(command, self.returncode, b'{"version":2}', b"Fatal: something restic said")


class AccessProbeTests(unittest.TestCase):
    def probe(self, repository: Path, runner: FakeRun) -> str:
        return restic_common.probe_repository_access("C:/fake/restic.exe", repository, runner=runner, timeout_seconds=7)

    def test_exit_codes_map_to_access(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text) / "repository"
            repository.mkdir()
            self.assertEqual("no_password", self.probe(repository, FakeRun(0)))
            self.assertEqual("password", self.probe(repository, FakeRun(12)))
            self.assertEqual("missing", self.probe(repository, FakeRun(10)))
            for code in (1, 2, 3, 11, 130, -1):
                with self.subTest(code=code):
                    self.assertEqual("unknown", self.probe(repository, FakeRun(code)))
            # Restic saying "no repository" next to a config file means the location can't be read properly (a Google
            # Drive folder still syncing, say), never that there are no backups.
            (repository / "config").write_bytes(b"x")
            self.assertEqual("unknown", self.probe(repository, FakeRun(10)))

    def test_a_config_check_that_fails_after_exit_10_is_unknown_not_missing(self) -> None:
        # Restic says "no repository", and then the config file can't be checked (access denied, say): that is not
        # proof that there are no backups, so the answer is "unknown", never "missing".
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text) / "repository"
            repository.mkdir()
            real_exists = Path.exists
            for error in (PermissionError(13, "Access is denied"), OSError(5, "Input/output error")):
                with self.subTest(error=type(error).__name__):

                    def exists(path, *arguments, **options):
                        if path.name == "config":
                            raise error
                        return real_exists(path, *arguments, **options)

                    with mock.patch.object(Path, "exists", exists):
                        self.assertEqual("unknown", self.probe(repository, FakeRun(10)))
            # Without the error the same answer is "missing", so the patch above is what made it "unknown".
            self.assertEqual("missing", self.probe(repository, FakeRun(10)))

    def test_a_default_call_is_given_the_long_time_limit(self) -> None:
        # Google Drive may have to download the key files before Restic can answer, so the limit is generous.
        self.assertGreaterEqual(restic_common.ACCESS_PROBE_TIMEOUT_SECONDS, 120)
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            runner = FakeRun(0)
            restic_common.probe_repository_access("C:/fake/restic.exe", Path(root_text), runner=runner)
            self.assertEqual(restic_common.ACCESS_PROBE_TIMEOUT_SECONDS, runner.calls[0][1]["timeout"])

    def test_time_out_and_start_failure_are_unknown(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text)
            self.assertEqual(
                "unknown", self.probe(repository, FakeRun(error=subprocess.TimeoutExpired(["restic"], 7)))
            )
            self.assertEqual("unknown", self.probe(repository, FakeRun(error=FileNotFoundError("restic.exe"))))

    def test_the_probe_reads_only_and_never_gives_a_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text)
            runner = FakeRun(0)
            self.probe(repository, runner)
            command, options = runner.calls[0]
            self.assertEqual(
                [
                    "C:/fake/restic.exe",
                    "--repo",
                    str(repository),
                    "--insecure-no-password",
                    "--no-lock",
                    "--no-cache",
                    "cat",
                    "config",
                ],
                command,
            )
            self.assertIs(subprocess.DEVNULL, options["stdin"])
            self.assertEqual(7, options["timeout"])
            self.assertFalse(options["shell"])
            self.assertFalse([name for name in options["env"] if name.upper().startswith("RESTIC_")])
            self.assertIsNone(restic_access_result(command, options["env"], "no_password"))


GET_REPOSITORY_ACCESS = """function Get-RepositoryAccess {
    # How Restic opens these backups (backup-config.json "repository_access"): 'password' (also when the key is absent,
    # as in every configuration written before the choice existed) or 'no_password'. Anything else is refused.
    param([Parameter(Mandatory = $true)] [object]$Configuration)
    $property = $Configuration.PSObject.Properties['repository_access']
    if ($null -eq $property) { return 'password' }
    $value = $property.Value
    if ($value -isnot [string] -or $value -cnotin @('password', 'no_password')) {
        throw 'unsupported repository_access'
    }
    return [string]$value
}
"""

GET_RECORDED_REPOSITORY_ACCESS = """function Get-RecordedRepositoryAccess {
    # The access a configuration or state record names: 'password' (also when the key is absent), 'no_password', or
    # $null when it names anything else. Callers treat $null as "can't tell".
    param([object]$Record)
    if ($null -eq $Record) { return $null }
    $property = $Record.PSObject.Properties['repository_access']
    if ($null -eq $property) { return 'password' }
    $value = $property.Value
    if ($value -is [string] -and $value -cin @('password', 'no_password')) { return [string]$value }
    return $null
}
"""

# Every PowerShell script that opens backups reads the mode with the one throwing reader; the installer and the
# uninstaller, which must never stop on a record they can't use, with the non-failing one.
THROWING_READERS = (
    "src/Manage-Repository.ps1",
    "src/Manage-Restore.ps1",
    "src/Manage-Sources.ps1",
    "src/verify_my_drive_cloud_repository.ps1",
)
RECORD_READERS = (
    "installer/Install-ResticBackuper.ps1",
    "installer/Uninstall-ResticBackuper.ps1",
)

# Files that give Restic a password and need not know the mode, with the reason. Every other file under src\ or
# installer\ that mentions a password source must also handle backups without a password.
PASSWORD_SOURCE_ALLOWED = {
    "src/secret_store.py": "the DPAPI helper itself; it starts no Restic process",
    "src/dashboard/RunDetailsWindow.cs": "a log filter that hides such words; it starts no Restic process",
    "src/sync_repository_to_google_drive.ps1": "retired, never shipped (build\\Build-Release.ps1 leaves it out)",
}


# What a file that gives Restic a password must contain to show it knows backups without one: the mode's value or
# Restic's flag, a reader of the mode, or the shared refusal (recovery_health.refuse_when_backups_have_no_key).
HANDLES_BACKUPS_WITHOUT_A_PASSWORD = (
    "no_password",
    "insecure-no-password",
    "NO_PASSWORD_FLAG",
    "repository_access(",
    "refuse_when_backups_have_no_key(",
    "Get-RepositoryAccess",
    "Get-RecordedRepositoryAccess",
)

# What counts as giving Restic a password, and where the sweep looks.
PASSWORD_SOURCES = ("--password-command", "RESTIC_PASSWORD", "--password-file")
SWEPT_ROOTS = ("src", "installer")
SWEPT_SUFFIXES = (".py", ".ps1", ".cs", ".ts", ".tsx", ".cmd")
SKIPPED_FOLDERS = ("node_modules", "dist", "obj", "__pycache__", "vendor")
PRINT_COUNTS_OPTION = "--print-password-source-counts"

# How many times each file under src\ or installer\ mentions a password source (every occurrence of
# PASSWORD_SOURCES, comments included; allowed files too). A file that already knows the mode still passes the marker
# check above when someone adds a call that builds its own password source, so the sweep also pins the number of
# mentions per file. A new site, or a removed one, fails the sweep until the new site has been checked (it must follow
# the mode: no password source next to --insecure-no-password) and the count here is updated. Print the current counts
# with:  python tests\test_repository_access.py --print-password-source-counts
PASSWORD_SOURCE_COUNTS = {
    "src/credential_repair.py": 4,
    "src/dashboard/RunDetailsWindow.cs": 1,
    "src/key_rotation.py": 7,
    "src/Manage-Repository.ps1": 1,
    "src/Manage-Restore.ps1": 1,
    "src/recovery_health.py": 6,
    "src/restic_common.py": 10,
    "src/restore.py": 12,
    "src/secret_store.py": 1,
    "src/sync_repository_to_google_drive.ps1": 6,
    "src/verify_my_drive_cloud_repository.ps1": 3,
}


def swept_files(project: Path):
    """Every source file under src\\ and installer\\ of `project` that the sweep reads, as a sorted list of paths."""
    found = []
    for root in SWEPT_ROOTS:
        for path in sorted((project / root).rglob("*")):
            if not path.is_file() or path.suffix.lower() not in SWEPT_SUFFIXES:
                continue
            if any(part in SKIPPED_FOLDERS for part in path.relative_to(project).parts):
                continue
            found.append(path)
    return found


def password_source_counts(project: Path) -> dict[str, int]:
    """For each swept file of `project` that mentions a password source: how many times it does."""
    counts = {}
    for path in swept_files(project):
        text = path.read_text(encoding="utf-8", errors="replace")
        count = sum(text.count(source) for source in PASSWORD_SOURCES)
        if count:
            counts[path.relative_to(project).as_posix()] = count
    return counts


def password_source_problems(project: Path) -> list[str]:
    """What is wrong with the password sources of `project`'s tree; an empty list when the sweep passes."""
    counts = password_source_counts(project)
    if not counts:
        return ["the sweep found no file that gives Restic a password, so it is looking in the wrong place"]
    problems = []
    for relative, count in counts.items():
        if relative not in PASSWORD_SOURCE_ALLOWED:
            text = (project / relative).read_text(encoding="utf-8", errors="replace")
            if not any(marker in text for marker in HANDLES_BACKUPS_WITHOUT_A_PASSWORD):
                problems.append(f"{relative} gives Restic a password but never mentions backups without one")
        pinned = PASSWORD_SOURCE_COUNTS.get(relative)
        if pinned is None:
            problems.append(
                f"{relative} mentions a password source {count} times and is not in PASSWORD_SOURCE_COUNTS. Check the "
                f"site follows the mode (backups without a password get no password source), then add the count."
            )
        elif pinned != count:
            problems.append(
                f"{relative} mentions a password source {count} times; PASSWORD_SOURCE_COUNTS pins {pinned}. A site was "
                f"added or removed: check it follows the mode (backups without a password get no password source), "
                f"then update the count."
            )
    for relative, pinned in PASSWORD_SOURCE_COUNTS.items():
        if relative not in counts:
            problems.append(
                f"{relative} no longer mentions a password source but PASSWORD_SOURCE_COUNTS pins {pinned}. Check that "
                f"the site it had was removed on purpose, then update the count."
            )
    return problems


def text_of(relative: str) -> str:
    return (PROJECT / relative).read_text(encoding="utf-8")


def windows_powershell() -> str:
    system = os.environ.get("SystemRoot", r"C:\Windows")
    return os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def run_windows_powershell(script: str) -> subprocess.CompletedProcess:
    """Run a script in Windows PowerShell 5.1 (as the managers run), with its own module path and no window."""
    environment = dict(os.environ)
    system = os.environ.get("SystemRoot", r"C:\Windows")
    environment["PSModulePath"] = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "Modules")
    with tempfile.TemporaryDirectory(prefix="repository-access-ps-") as folder:
        path = Path(folder) / "probe.ps1"
        path.write_text(script, encoding="utf-8-sig")
        return subprocess.run(
            [windows_powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(path)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
            env=environment,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )


class CopiesOfTheRuleTests(unittest.TestCase):
    """Every copy of the rule, in every language, accepts the same two values and defaults the same way."""

    def test_powershell_copies_are_the_design_text(self) -> None:
        for relative in THROWING_READERS:
            with self.subTest(file=relative):
                text = text_of(relative)
                self.assertEqual(1, text.count("function Get-RepositoryAccess {"))
                self.assertIn(GET_REPOSITORY_ACCESS, text)
        for relative in RECORD_READERS:
            with self.subTest(file=relative):
                text = text_of(relative)
                self.assertEqual(1, text.count("function Get-RecordedRepositoryAccess {"))
                self.assertIn(GET_RECORDED_REPOSITORY_ACCESS, text)

    @unittest.skipUnless(os.name == "nt", "needs Windows PowerShell")
    def test_powershell_readers_behave_like_the_python_rule(self) -> None:
        cases = [
            ("absent", "[pscustomobject]@{}"),
            ("password", "[pscustomobject]@{ repository_access = 'password' }"),
            ("no_password", "[pscustomobject]@{ repository_access = 'no_password' }"),
            ("capitalised", "[pscustomobject]@{ repository_access = 'Password' }"),
            ("upper-case", "[pscustomobject]@{ repository_access = 'NO_PASSWORD' }"),
            ("empty", "[pscustomobject]@{ repository_access = '' }"),
            ("null", "[pscustomobject]@{ repository_access = $null }"),
            ("number", "[pscustomobject]@{ repository_access = 5 }"),
            ("json-absent", "('{\"schema_version\": 1}' | ConvertFrom-Json)"),
            ("json-no_password", "('{\"repository_access\": \"no_password\"}' | ConvertFrom-Json)"),
        ]
        # PowerShell's [ordered] keys ignore case, so no two labels may differ only in case.
        self.assertEqual(len(cases), len({name.lower() for name, _ in cases}))
        lines = [
            "Set-StrictMode -Version Latest",
            "$ErrorActionPreference = 'Stop'",
            GET_REPOSITORY_ACCESS,
            GET_RECORDED_REPOSITORY_ACCESS,
            "$results = [ordered]@{}",
        ]
        for name, expression in cases:
            lines.append(
                f"$record = {expression}\n"
                f"try {{ $strict = Get-RepositoryAccess -Configuration $record }} catch {{ $strict = 'refused: ' + $_.Exception.Message }}\n"
                f"$recorded = Get-RecordedRepositoryAccess -Record $record\n"
                f"$results['{name}'] = [ordered]@{{ strict = $strict; recorded = $recorded }}"
            )
        lines.append("$results['no-record'] = [ordered]@{ strict = $null; recorded = (Get-RecordedRepositoryAccess -Record $null) }")
        lines.append("$results | ConvertTo-Json -Depth 3 -Compress")
        result = run_windows_powershell("\n".join(lines) + "\n")
        self.assertEqual(0, result.returncode, result.stderr)
        observed = json.loads(result.stdout)
        refused = "refused: unsupported repository_access"
        expected = {
            "absent": ("password", "password"),
            "password": ("password", "password"),
            "no_password": ("no_password", "no_password"),
            "capitalised": (refused, None),
            "upper-case": (refused, None),
            "empty": (refused, None),
            "null": (refused, None),
            "number": (refused, None),
            "json-absent": ("password", "password"),
            "json-no_password": ("no_password", "no_password"),
        }
        for name, (strict, recorded) in expected.items():
            with self.subTest(case=name):
                self.assertEqual(strict, observed[name]["strict"])
                self.assertEqual(recorded, observed[name]["recorded"])
        self.assertIsNone(observed["no-record"]["recorded"])
        # And the Python rule agrees on every value both can express.
        for value, outcome in (("password", "password"), ("no_password", "no_password")):
            self.assertEqual(outcome, restic_common.repository_access({"repository_access": value}))
        for value in ("Password", "NO_PASSWORD", "", None, 5):
            with self.assertRaises(ValueError):
                restic_common.repository_access({"repository_access": value})

    def test_python_copies_match_the_engine(self) -> None:
        import recovery_health
        import refresh_recovery_tools
        import restore

        for module in (restore, refresh_recovery_tools):
            with self.subTest(module=module.__name__):
                self.assertEqual(restic_common.REPOSITORY_ACCESS_VALUES, tuple(module.REPOSITORY_ACCESS_VALUES))
                self.assertEqual(restic_common.DEFAULT_REPOSITORY_ACCESS, module.DEFAULT_REPOSITORY_ACCESS)
                for value in (None, "password", "no_password", "Password", "", 5, "none"):
                    config = {} if value is None else {"repository_access": value}
                    try:
                        expected = restic_common.repository_access(config)
                    except ValueError as error:
                        with self.assertRaises(ValueError) as caught:
                            module.repository_access(config)
                        self.assertEqual(str(error), str(caught.exception))
                    else:
                        self.assertEqual(expected, module.repository_access(config))
        self.assertEqual(restic_common.NO_PASSWORD_FLAG, restore.NO_PASSWORD_FLAG)
        # recovery_health reads the mode through the engine and never builds a reveal for backups without a password.
        self.assertIs(restic_common.repository_access, recovery_health.repository_access)
        with self.assertRaises(RuntimeError):
            recovery_health.password_command({"repository_access": "no_password"}, SOURCE)


class PasswordSourceSweepTests(unittest.TestCase):
    """Search the tree, don't trust a list: a file that gives Restic a password must also know backups without one."""

    def test_every_file_with_a_password_source_handles_backups_without_one_and_keeps_its_count(self) -> None:
        problems = password_source_problems(PROJECT)
        self.assertEqual(
            [],
            problems,
            "\n".join(problems) + f"\nThe current counts print with: python tests\\test_repository_access.py {PRINT_COUNTS_OPTION}",
        )
        self.assertNotIn(
            "sync_repository_to_google_drive.ps1",
            (PROJECT / "build" / "Build-Release.ps1").read_text(encoding="utf-8"),
            "the retired script is allowed only because it is not shipped",
        )


class PasswordSourceSweepOnACopyTests(unittest.TestCase):
    """The sweep is a function over a folder, so these run it on a copy of the swept files with one change made."""

    def setUp(self) -> None:
        self.fresh_copy()

    def fresh_copy(self) -> None:
        holder = tempfile.TemporaryDirectory(prefix="resticbackuper-sweep-")
        self.addCleanup(holder.cleanup)
        self.copy = Path(holder.name)
        for path in swept_files(PROJECT):
            target = self.copy / path.relative_to(PROJECT)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())

    def edit(self, relative: str, change) -> None:
        path = self.copy / relative
        path.write_text(change(path.read_text(encoding="utf-8")), encoding="utf-8", newline="")

    def test_the_copy_passes_when_nothing_changed(self) -> None:
        self.assertEqual([], password_source_problems(self.copy))
        self.assertEqual(password_source_counts(PROJECT), password_source_counts(self.copy))

    def test_one_extra_unguarded_password_command_in_a_file_that_knows_the_mode_fails(self) -> None:
        relative = "src/restore.py"
        text = (self.copy / relative).read_text(encoding="utf-8")
        # The per-file marker check alone would let this file through: it already mentions the mode.
        self.assertTrue(any(marker in text for marker in HANDLES_BACKUPS_WITHOUT_A_PASSWORD))
        self.assertIn("no_password", text)
        self.edit(relative, lambda text: text + '\n\ndef unguarded_site(restic):\n    return [restic, "--password-command", "reveal"]\n')
        problems = password_source_problems(self.copy)
        self.assertEqual(1, len(problems), problems)
        self.assertIn(relative, problems[0])
        self.assertIn(f"{PASSWORD_SOURCE_COUNTS[relative] + 1} times", problems[0])
        self.assertIn(f"pins {PASSWORD_SOURCE_COUNTS[relative]}", problems[0])
        # The message says what to do about it.
        self.assertIn("check it follows the mode", problems[0])
        self.assertIn("update the count", problems[0])

    def test_an_extra_environment_password_or_password_file_fails_too(self) -> None:
        for source in ('environment["RESTIC_PASSWORD"] = secret', '"--password-file", key_file'):
            with self.subTest(source=source):
                self.fresh_copy()
                self.edit("src/key_rotation.py", lambda text: text + f"\nunguarded = {source}\n")
                problems = password_source_problems(self.copy)
                self.assertEqual(1, len(problems), problems)
                self.assertIn("src/key_rotation.py", problems[0])
                self.assertIn("update the count", problems[0])

    def test_a_removed_password_source_fails(self) -> None:
        relative = "src/restic_common.py"
        self.edit(relative, lambda text: text.replace("--password-command", "--password-source", 1))
        problems = password_source_problems(self.copy)
        self.assertEqual(1, len(problems), problems)
        self.assertIn(relative, problems[0])
        self.assertIn(f"{PASSWORD_SOURCE_COUNTS[relative] - 1} times", problems[0])
        self.assertIn("update the count", problems[0])

    def test_a_pinned_file_that_loses_every_password_source_fails(self) -> None:
        relative = "src/Manage-Restore.ps1"

        def without_password_sources(text: str) -> str:
            for source in PASSWORD_SOURCES:
                text = text.replace(source, "no-source")
            return text

        self.edit(relative, without_password_sources)
        problems = password_source_problems(self.copy)
        self.assertEqual(1, len(problems), problems)
        self.assertIn(relative, problems[0])
        self.assertIn("no longer mentions a password source", problems[0])

    def test_a_new_file_with_a_password_source_fails_even_when_it_knows_the_mode(self) -> None:
        guarded = self.copy / "src" / "new_helper.py"
        guarded.write_text('if access == "no_password":\n    pass\ncommand = ["--password-command", "reveal"]\n', encoding="utf-8")
        problems = password_source_problems(self.copy)
        self.assertEqual(1, len(problems), problems)
        self.assertIn("src/new_helper.py", problems[0])
        self.assertIn("not in PASSWORD_SOURCE_COUNTS", problems[0])
        # And one that never mentions the mode fails the marker check as well as the count.
        guarded.write_text('command = ["--password-command", "reveal"]\n', encoding="utf-8")
        problems = password_source_problems(self.copy)
        self.assertEqual(2, len(problems), problems)
        self.assertTrue(any("never mentions backups without one" in problem for problem in problems))

    def test_an_allowed_file_is_still_counted(self) -> None:
        relative = "src/secret_store.py"
        self.assertIn(relative, PASSWORD_SOURCE_ALLOWED)
        self.edit(relative, lambda text: text + '\nextra = "--password-command"\n')
        problems = password_source_problems(self.copy)
        self.assertEqual(1, len(problems), problems)
        self.assertIn(relative, problems[0])

    def test_folders_that_hold_other_peoples_code_are_not_swept(self) -> None:
        for folder in ("node_modules", "dist", "vendor"):
            target = self.copy / "src" / "dashboard" / folder / "package.ts"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('const x = "--password-command";\n', encoding="utf-8")
        self.assertEqual([], password_source_problems(self.copy))


class FakeContractTests(unittest.TestCase):
    """The shared fake rules (tests/restic_access.py) match what Restic 0.19.1 does."""

    def test_rules(self) -> None:
        flag = "--insecure-no-password"
        self.assertEqual((1, CONFLICT), restic_access_result(["restic", flag, "--password-command", "x"], {}, "no_password"))
        self.assertEqual((1, CONFLICT), restic_access_result(["restic", flag], {"RESTIC_PASSWORD": "x"}, "no_password"))
        self.assertIsNone(restic_access_result(["restic", flag], {"RESTIC_PASSWORD": ""}, "no_password"))
        self.assertEqual((1, EMPTY_NOT_ALLOWED), restic_access_result(["restic", "snapshots"], {}, "no_password"))
        self.assertEqual((12, WRONG_PASSWORD), restic_access_result(["restic", flag, "snapshots"], {}, "password"))
        self.assertIsNone(restic_access_result(["restic", "--password-command", "x"], {}, "password"))


if __name__ == "__main__":
    if PRINT_COUNTS_OPTION in sys.argv[1:]:
        print("PASSWORD_SOURCE_COUNTS = {")
        for name, number in password_source_counts(PROJECT).items():
            print(f'    "{name}": {number},')
        print("}")
    else:
        unittest.main()
