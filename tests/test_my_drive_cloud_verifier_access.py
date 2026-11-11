"""The nightly Google Drive check, for backups made with a password and for backups made without one.

A backup without a password is opened by Restic only with --insecure-no-password, on every command; Restic refuses the
flag next to any password setting (and runs a password command before it refuses), and, given no flag and an open
standard input, waits for a password. So the check (src/verify_my_drive_cloud_repository.ps1) puts the flag on all four of
its Restic runs, gives its Restic children no RESTIC_PASSWORD* setting, does not look for the saved password or the program
that reads it, and closes the standard input of every child it starts. A configuration without "repository_access"
(every one written before the choice existed, the owner's included) is a backup with a password and behaves as before.

The probes run the check's own functions in Windows PowerShell 5.1 under StrictMode, as the check does.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from restic_access import (  # noqa: E402
    CONFLICT,
    EMPTY_NOT_ALLOWED,
    PASSWORD_SOURCE_VARIABLES,
    WRONG_PASSWORD,
    restic_access_result,
)

PROJECT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
SCRIPT = (PROJECT / "src" / "verify_my_drive_cloud_repository.ps1").read_text(encoding="utf-8")
TELEMETRY = (PROJECT / "src" / "dashboard" / "Telemetry.cs").read_text(encoding="utf-8")

# The reader as the design contract gives it (design.md section 3): the same text is in every PowerShell script that
# reads the field, and a test elsewhere compares the copies.
DESIGN_READER = """function Get-RepositoryAccess {
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

PROBE_HEADER = "\n".join(
    [
        "Set-StrictMode -Version Latest",
        "$ErrorActionPreference = 'Stop'",
        "$script:checkStep = 'checking_setup'",
        "$script:checkFailureDetail = $null",
        "$script:failureRecordTarget = $null",
        "",
    ]
)
NATIVE_FUNCTIONS = (
    "ConvertTo-NativeArgument",
    "Get-RemainingMilliseconds",
    "Get-NativeProcessTree",
    "Stop-ExactProcess",
    "Stop-NativeProcessTree",
    "Format-PlainDuration",
    "Get-CheckStepLabel",
    "New-CheckFailureDetail",
    "Stop-Check",
    "Invoke-NativeToFiles",
)
FLAG = "--insecure-no-password"


def powershell_function(text: str, name: str) -> str:
    start = text.index(f"function {name} {{")
    return text[start : text.index("\n}\n", start) + 3]


def powershell_functions(text: str, *names: str) -> str:
    return "\n".join(powershell_function(text, name) for name in names)


def ps_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def windows_powershell() -> str:
    system = os.environ.get("SystemRoot", r"C:\Windows")
    return os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def run_windows_powershell(
    probe: str, *, arguments: tuple[str, ...] = (), open_standard_input: bool = False, timeout: float = 180
) -> subprocess.CompletedProcess:
    """Runs the probe script in Windows PowerShell 5.1 with no window.

    With open_standard_input the probe's own standard input is a pipe that stays open until the probe has finished, as the
    standard input of the nightly task is (or a console's is): a child that inherits it can wait on it.
    """
    with tempfile.TemporaryDirectory(prefix="rewindle-verifier-access-", ignore_cleanup_errors=True) as temp:
        script = Path(temp) / "probe.ps1"
        script.write_text(probe, encoding="ascii", newline="\n")
        command = [
            windows_powershell(),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            *arguments,
        ]
        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        if not open_standard_input:
            return subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
                creationflags=creation,
            )
        out_path = Path(temp) / "stdout.txt"
        err_path = Path(temp) / "stderr.txt"
        with out_path.open("wb") as out, err_path.open("wb") as err:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=out, stderr=err, creationflags=creation)
            try:
                process.wait(timeout=timeout)
            finally:
                if process.poll() is None:
                    process.kill()
                if process.stdin is not None:
                    process.stdin.close()
        return subprocess.CompletedProcess(
            command,
            process.returncode,
            out_path.read_text(encoding="utf-8", errors="replace"),
            err_path.read_text(encoding="utf-8", errors="replace"),
        )


def run_probe_json(test: unittest.TestCase, probe: str, **options) -> dict:
    completed = run_windows_powershell(probe, **options)
    test.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
    return json.loads(completed.stdout.strip().splitlines()[-1])


def native_launches(text: str) -> list[str]:
    """Each Invoke-RequiredNative / Invoke-NativeToFiles call of the script."""
    lines = text.splitlines()
    launches = []
    for index, line in enumerate(lines):
        if not re.match(r"^\s*(?:\$\w+ = )?Invoke-(?:RequiredNative|NativeToFiles) `$", line):
            continue
        depth = 0
        block = []
        for current in lines[index:]:
            block.append(current)
            depth += current.count("(") - current.count(")")
            if depth <= 0 and not current.rstrip().endswith("`"):
                break
        launches.append("\n".join(block))
    return launches


def offsite_filter_words() -> list[str]:
    """The words Telemetry.CleanOffsiteDetail hides a whole sentence for, read from the dashboard's own source."""
    start = TELEMETRY.index("private static string CleanOffsiteDetail(string value)")
    body = TELEMETRY[start : TELEMETRY.index("\n        }\n", start)]
    return re.findall(r'IndexOf\("([^"]+)", StringComparison\.OrdinalIgnoreCase\)', body)


def hidden_by_offsite_filter(text: str) -> bool:
    return any(word.lower() in text.lower() for word in offsite_filter_words())


class RepositoryAccessReaderTests(unittest.TestCase):
    def test_the_reader_is_the_designs_text_byte_for_byte(self):
        self.assertEqual(DESIGN_READER, powershell_function(SCRIPT, "Get-RepositoryAccess"))

    def test_the_field_is_never_read_with_dotted_access(self):
        # Under StrictMode Latest, $config.repository_access throws on every configuration written before the choice.
        self.assertNotRegex(SCRIPT, r"\$\w+\.repository_access")

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_configuration_without_the_field_is_a_backup_with_a_password_and_junk_is_refused(self):
        cases = {
            "owner_shaped": '{"repository": "x", "secret_file": "y"}',
            "password": '{"repository_access": "password"}',
            "no_password": '{"repository_access": "no_password"}',
            "capitalised": '{"repository_access": "Password"}',
            "upper_case": '{"repository_access": "NO_PASSWORD"}',
            "empty": '{"repository_access": ""}',
            "null": '{"repository_access": null}',
            "number": '{"repository_access": 5}',
            "boolean": '{"repository_access": true}',
            "array": '{"repository_access": ["password"]}',
            "spaced": '{"repository_access": "no password"}',
        }
        lines = [PROBE_HEADER, powershell_function(SCRIPT, "Get-RepositoryAccess"), "$result = [ordered]@{}"]
        for name, document in cases.items():
            lines.append(
                f"try {{ $result.{name} = Get-RepositoryAccess -Configuration (ConvertFrom-Json {ps_literal(document)}) }} "
                f"catch {{ $result.{name} = 'refused: ' + $_.Exception.Message }}"
            )
        lines += ["[Console]::Out.Write(($result | ConvertTo-Json -Compress))", ""]
        result = run_probe_json(self, "\n".join(lines))
        self.assertEqual("password", result["owner_shaped"])
        self.assertEqual("password", result["password"])
        self.assertEqual("no_password", result["no_password"])
        for name in ("capitalised", "upper_case", "empty", "null", "number", "boolean", "array", "spaced"):
            with self.subTest(name):
                self.assertEqual("refused: unsupported repository_access", result[name])

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_check_refuses_an_unsupported_value_and_reads_the_others(self):
        # The real script, run as -ValidateOnly (no native step) against configurations that hold every property it
        # requires. A refused value stops it at once, in words that hold none of the words the dashboard hides; the others
        # get past the reader and stop at the first thing this folder lacks (the My Drive folder).
        base = {
            "repository": r"C:\fixture\Google Drive\My Drive\Backups\repo",
            "repository_storage_mode": "google_drivefs_stream",
            "drivefs_my_drive_root": r"C:\fixture\Google Drive\My Drive",
            "restic_executable": r"C:\fixture\restic.exe",
            "python_executable": r"C:\fixture\python.exe",
            "secret_file": r"C:\fixture\repository-password.dpapi.json",
            "state_directory": r"C:\fixture\state",
            "canary_file": r"C:\fixture\canary.txt",
            "plan_id": "10000000-0000-4000-8000-000000000042",
            "config_generation": 1,
        }
        outcomes = {}
        for label, extra in (
            ("absent", {}),
            ("password", {"repository_access": "password"}),
            ("no_password", {"repository_access": "no_password"}),
            ("upper_case", {"repository_access": "NO_PASSWORD"}),
            ("junk", {"repository_access": "none"}),
        ):
            with tempfile.TemporaryDirectory(prefix="rewindle-verifier-config-", ignore_cleanup_errors=True) as temp:
                configuration = Path(temp) / "backup-config.json"
                configuration.write_text(json.dumps({**base, **extra}), encoding="utf-8")
                probe = "\n".join(
                    [
                        "$ErrorActionPreference = 'Stop'",
                        f"& {ps_literal(str(PROJECT / 'src' / 'verify_my_drive_cloud_repository.ps1'))} "
                        f"-ConfigPath {ps_literal(str(configuration))} "
                        f"-CloudVerificationRoot {ps_literal(str(Path(temp) / 'cloud-verification'))} -ValidateOnly",
                        "",
                    ]
                )
                completed = run_windows_powershell(probe)
                outcomes[label] = completed.stderr
                self.assertNotEqual(0, completed.returncode, label)
        for label in ("upper_case", "junk"):
            with self.subTest(label):
                self.assertIn("unsupported repository_access", outcomes[label])
                self.assertFalse(hidden_by_offsite_filter("unsupported repository_access"))
        for label in ("absent", "password", "no_password"):
            with self.subTest(label):
                self.assertNotIn("unsupported repository_access", outcomes[label])
                self.assertIn("Required verification directory not found", outcomes[label])

    def test_the_access_is_read_before_any_file_it_decides_about_is_looked_for(self):
        storage = SCRIPT.index("if ([string]$config.repository_storage_mode -cne 'google_drivefs_stream') {")
        read = SCRIPT.index("$repositoryAccess = Get-RepositoryAccess -Configuration $config")
        validate_only = SCRIPT.index("if ($ValidateOnly) {")
        required = SCRIPT.index("foreach ($requiredFile in @(")
        first_run = SCRIPT.index("Invoke-RequiredNative `\n        -Executable $resticExecutable")
        self.assertLess(storage, read)
        self.assertLess(read, required)
        self.assertLess(required, validate_only)
        self.assertLess(validate_only, first_run)
        # secret_file stays a property every configuration must have, in both modes: the paths are kept in every config.
        self.assertIn("    'secret_file',\n", SCRIPT[: SCRIPT.index("$repositoryAccess = ")])


class ResticCommandLineTests(unittest.TestCase):
    REPOSITORY = r"C:\Drive\My Drive\Backups\repo"
    OPTIONS = ["-o", "rclone.program=C:/Cloud/rclone.exe", "-o", "rclone.timeout=2m"]

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_flag_is_in_the_command_line_of_a_backup_without_a_password_exactly_once(self):
        options = "@(" + ", ".join(ps_literal(item) for item in self.OPTIONS) + ")"
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_function(SCRIPT, "Get-ResticCommonArguments"),
                "$result = [ordered]@{}",
                f"$repository = {ps_literal(self.REPOSITORY)}",
                f"$options = {options}",
                "$result.password = @(Get-ResticCommonArguments -Access 'password' -Repository $repository)",
                "$result.password_options = @(Get-ResticCommonArguments -Access 'password' -Repository $repository "
                "-Options $options)",
                "$result.no_password = @(Get-ResticCommonArguments -Access 'no_password' -Repository $repository)",
                "$result.no_password_options = @(Get-ResticCommonArguments -Access 'no_password' "
                "-Repository $repository -Options $options)",
                "foreach ($bad in @('No_Password', 'PASSWORD', 'none', ' password')) {",
                "    try { $null = Get-ResticCommonArguments -Access $bad -Repository $repository; "
                "$result['bad ' + $bad] = 'accepted' }",
                "    catch { $result['bad ' + $bad] = 'refused: ' + $_.Exception.Message }",
                "}",
                "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        # A backup with a password: the command line is what it always was (Restic reads its password command from the
        # environment).
        self.assertEqual(["--repo", self.REPOSITORY, "--no-lock", "--no-cache"], result["password"])
        self.assertEqual(
            ["--repo", self.REPOSITORY, "--no-lock", "--no-cache", *self.OPTIONS], result["password_options"]
        )
        # A backup without one: the same, and the flag once, right after the repository.
        self.assertEqual(["--repo", self.REPOSITORY, FLAG, "--no-lock", "--no-cache"], result["no_password"])
        self.assertEqual(
            ["--repo", self.REPOSITORY, FLAG, "--no-lock", "--no-cache", *self.OPTIONS], result["no_password_options"]
        )
        self.assertEqual(1, result["no_password_options"].count(FLAG))
        self.assertNotIn(FLAG, result["password_options"])
        for bad in ("No_Password", "PASSWORD", "none", " password"):
            with self.subTest(bad):
                self.assertEqual("refused: unsupported repository_access", result["bad " + bad])

    def test_all_four_restic_runs_take_their_command_line_from_that_function(self):
        runs = [launch for launch in native_launches(SCRIPT) if "-Executable $resticExecutable" in launch]
        self.assertEqual(4, len(runs))
        local, *cloud = runs
        self.assertIn("'Local Restic repository authentication'", local)
        self.assertIn("Get-ResticCommonArguments -Access $repositoryAccess -Repository $localRepositoryFull", local)
        self.assertEqual(3, len(cloud))
        for launch in cloud:
            with self.subTest(launch=launch.splitlines()[0]):
                self.assertIn("$resticCloudCommon", launch)
        self.assertEqual(
            ["cat", "snapshots", "restore"],
            [re.search(r"@\(\s*'(cat|snapshots|restore)'", launch).group(1) for launch in cloud],
        )
        common = SCRIPT[SCRIPT.index("    $resticCloudCommon = @(") :]
        common = common[: common.index("\n    )\n")]
        self.assertIn("Get-ResticCommonArguments `", common)
        self.assertIn("-Access $repositoryAccess `", common)
        self.assertIn("-Repository $remoteRepository `", common)
        # No run writes its own repository option, and only the function names the flag.
        self.assertEqual(1, SCRIPT.count("'--repo'"))
        self.assertEqual(1, SCRIPT.count("'" + FLAG + "'"))
        self.assertIn("'" + FLAG + "'", powershell_function(SCRIPT, "Get-ResticCommonArguments"))

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_two_command_lines_the_script_builds_come_out_as_they_always_did_plus_the_flag(self):
        # The script's own statements, run for a backup with a password and one without: the local `cat config` line and
        # the options shared by the three runs against Google Drive.
        local = next(
            launch for launch in native_launches(SCRIPT) if "-Executable $resticExecutable" in launch and "$localRepositoryFull" in launch
        )
        local_expression = local[local.index("-Arguments ") + len("-Arguments ") :]
        local_expression = local_expression[: local_expression.index(" `\n        -StdoutPath")]
        common = SCRIPT[SCRIPT.index("    $resticCloudCommon = @(") :]
        common = common[: common.index("\n    )\n") + len("\n    )\n")]
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_function(SCRIPT, "Get-ResticCommonArguments"),
                "$localRepositoryFull = 'C:\\Drive\\My Drive\\repo'",
                "$remoteRepository = 'rclone:Remote,scope=drive.readonly,root_folder_id=root:Backups/repo'",
                "$rcloneProgram = 'C:/Cloud/rclone.exe'",
                "$result = [ordered]@{}",
                "foreach ($repositoryAccess in @('password', 'no_password')) {",
                "    $localArguments = " + local_expression,
                common.replace("\n    ", "\n"),
                "    $result[$repositoryAccess] = [ordered]@{ local = @($localArguments); cloud = @($resticCloudCommon) }",
                "}",
                "[Console]::Out.Write(($result | ConvertTo-Json -Depth 4 -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        local_before = ["--repo", r"C:\Drive\My Drive\repo", "--no-lock", "--no-cache", "cat", "config"]
        cloud_before = [
            "--repo",
            "rclone:Remote,scope=drive.readonly,root_folder_id=root:Backups/repo",
            "--no-lock",
            "--no-cache",
            "-o",
            "rclone.program=C:/Cloud/rclone.exe",
            "-o",
            "rclone.timeout=2m",
        ]
        self.assertEqual({"local": local_before, "cloud": cloud_before}, result["password"])
        self.assertEqual(
            {"local": [*local_before[:2], FLAG, *local_before[2:]], "cloud": [*cloud_before[:2], FLAG, *cloud_before[2:]]},
            result["no_password"],
        )

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_command_lines_and_settings_the_check_builds_open_the_backup_they_were_built_for(self):
        # Applies the three rules Restic 0.19.1 measured to what the check's own functions build (tests/restic_access.py).
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_functions(
                    SCRIPT, "Get-ResticCommonArguments", "New-ResticPasswordCommand", "Get-CloudEnvironmentSettings"
                ),
                "$result = [ordered]@{}",
                "$common = @{ RcloneConfig = 'C:\\Run\\rclone.conf'; RclonePasswordCommand = 'rclone-password-command'; "
                "RcloneCacheDirectory = 'C:\\Run\\cache' }",
                "$command = New-ResticPasswordCommand -Access 'password' -pythonExecutable 'C:\\P\\python.exe' "
                "-secretStore 'C:\\P\\secret_store.py' -secretFile 'C:\\S\\secret.json'",
                "foreach ($access in @('password', 'no_password')) {",
                "    $settings = if ($access -ceq 'password') { Get-CloudEnvironmentSettings -Access $access @common "
                "-ResticPasswordCommand $command } else { Get-CloudEnvironmentSettings -Access $access @common }",
                "    $result[$access] = [ordered]@{",
                "        arguments = @(Get-ResticCommonArguments -Access $access -Repository 'C:\\Drive\\repo') + @('cat', 'config')",
                "        settings = $settings",
                "    }",
                "}",
                "[Console]::Out.Write(($result | ConvertTo-Json -Depth 4 -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        for access in ("password", "no_password"):
            with self.subTest(access):
                built = result[access]
                # The child gets the fixed environment (no RESTIC_*) plus these settings.
                self.assertIsNone(restic_access_result(built["arguments"], built["settings"], access))
        other = {"password": "no_password", "no_password": "password"}
        for access, wrong in other.items():
            with self.subTest(wrong_backup=access):
                built = result[access]
                refused = restic_access_result(built["arguments"], built["settings"], wrong)
                self.assertEqual((12, WRONG_PASSWORD) if access == "no_password" else (1, EMPTY_NOT_ALLOWED), refused)
        # The two together are what Restic refuses: the flag next to a password command.
        conflict = restic_access_result(
            result["no_password"]["arguments"], result["password"]["settings"], "no_password"
        )
        self.assertEqual((1, CONFLICT), conflict)


class CloudEnvironmentTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_only_a_backup_with_a_password_gets_a_restic_password_command(self):
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_function(SCRIPT, "Get-CloudEnvironmentSettings"),
                "$result = [ordered]@{}",
                "$common = @{ RcloneConfig = 'C:\\Run\\rclone-readonly.conf'; RclonePasswordCommand = 'rclone-command'; "
                "RcloneCacheDirectory = 'C:\\Run\\cache' }",
                "$result.password = Get-CloudEnvironmentSettings -Access 'password' @common "
                "-ResticPasswordCommand 'restic-command'",
                "$result.no_password = Get-CloudEnvironmentSettings -Access 'no_password' @common",
                "$result.no_password_empty = Get-CloudEnvironmentSettings -Access 'no_password' @common "
                "-ResticPasswordCommand ''",
                "function Try-Settings { param([scriptblock]$Action) try { $null = & $Action; 'accepted' } "
                "catch { 'refused: ' + $_.Exception.Message } }",
                "$result.no_password_with_command = Try-Settings { Get-CloudEnvironmentSettings -Access 'no_password' "
                "@common -ResticPasswordCommand 'restic-command' }",
                "$result.password_without_command = Try-Settings { Get-CloudEnvironmentSettings -Access 'password' "
                "@common }",
                "$result.password_blank_command = Try-Settings { Get-CloudEnvironmentSettings -Access 'password' "
                "@common -ResticPasswordCommand '   ' }",
                "$result.unsupported = Try-Settings { Get-CloudEnvironmentSettings -Access 'No_Password' @common }",
                "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        fixed = ["RCLONE_CONFIG", "RCLONE_PASSWORD_COMMAND", "RCLONE_ASK_PASSWORD", "RCLONE_CACHE_DIR"]
        # A backup with a password: what it always got, in the same order.
        self.assertEqual([*fixed, "RESTIC_PASSWORD_COMMAND"], list(result["password"]))
        self.assertEqual("restic-command", result["password"]["RESTIC_PASSWORD_COMMAND"])
        self.assertEqual(r"C:\Run\rclone-readonly.conf", result["password"]["RCLONE_CONFIG"])
        self.assertEqual("false", result["password"]["RCLONE_ASK_PASSWORD"])
        # A backup without one: the same rclone settings and nothing that names a Restic password.
        self.assertEqual(fixed, list(result["no_password"]))
        self.assertEqual(fixed, list(result["no_password_empty"]))
        for name in result["no_password"]:
            self.assertNotIn(name, PASSWORD_SOURCE_VARIABLES)
        for key in ("no_password_with_command", "password_without_command", "password_blank_command", "unsupported"):
            with self.subTest(key):
                self.assertTrue(result[key].startswith("refused: "), result[key])
        self.assertEqual("refused: unsupported repository_access", result["unsupported"])

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_password_command_is_built_for_a_backup_with_a_password_only(self):
        values = {
            "pythonExecutable": r"C:\Program Files\ResticBackuper\Python\python.exe",
            "secretStore": r"C:\Program Files\ResticBackuper\secret_store.py",
            "secretFile": r"C:\ProgramData\ResticBackuper\repository-password.dpapi.json",
        }
        arguments = " ".join(f"-{name} {ps_literal(value)}" for name, value in values.items())
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_function(SCRIPT, "New-ResticPasswordCommand"),
                "$result = [ordered]@{}",
                f"$result.password = New-ResticPasswordCommand -Access 'password' {arguments}",
                f"try {{ $result.no_password = New-ResticPasswordCommand -Access 'no_password' {arguments} }} "
                "catch { $result.no_password = 'refused' }",
                f"try {{ $result.unsupported = New-ResticPasswordCommand -Access 'x' {arguments} }} "
                "catch { $result.unsupported = 'refused' }",
                "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        self.assertEqual(
            '"{pythonExecutable}" -I -S -B "{secretStore}" reveal --secret-file "{secretFile}"'.format(**values),
            result["password"],
        )
        self.assertEqual("refused", result["no_password"])
        self.assertEqual("refused", result["unsupported"])

    def test_the_command_is_built_inside_the_branch_for_a_backup_with_a_password(self):
        body = SCRIPT[SCRIPT.index("$runLock = $null") :]
        assignments = re.findall(r"(?m)^\s*\$resticPasswordCommand = (.*)$", body)
        self.assertEqual(["''", "New-ResticPasswordCommand `"], assignments)
        branch = body.index("    if ($repositoryAccess -ceq 'password') {\n        $resticPasswordCommand = New-ResticPasswordCommand")
        self.assertLess(body.index("    $resticPasswordCommand = ''"), branch)
        self.assertLess(branch, body.index("$cloudEnvironment = New-NativeChildEnvironment"))
        # The Restic password setting is made in one place, and only for a backup with a password.
        self.assertEqual(1, len(re.findall(r"RESTIC_PASSWORD_COMMAND'?\]?\s*=", SCRIPT)))
        self.assertIn(
            "$settings['RESTIC_PASSWORD_COMMAND'] = $ResticPasswordCommand",
            powershell_function(SCRIPT, "Get-CloudEnvironmentSettings"),
        )
        self.assertIn(
            "-Settings (Get-CloudEnvironmentSettings `\n            -Access $repositoryAccess `", body
        )
        # The statement is where the existing test extracts it from.
        self.assertIn("\n    $resticPasswordCommand = (\n", SCRIPT)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_backup_without_a_password_does_not_need_the_saved_password_or_its_program(self):
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_function(SCRIPT, "Get-PasswordFilePaths"),
                "$result = [ordered]@{}",
                "$files = @{ SecretFile = 'C:\\State\\secret.json'; SecretStore = 'C:\\P\\secret_store.py' }",
                "$result.password = @(Get-PasswordFilePaths -Access 'password' @files)",
                "$result.no_password = @(Get-PasswordFilePaths -Access 'no_password' @files)",
                "try { $null = Get-PasswordFilePaths -Access 'PASSWORD' @files; $result.unsupported = 'accepted' } "
                "catch { $result.unsupported = 'refused' }",
                "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        self.assertEqual([r"C:\State\secret.json", r"C:\P\secret_store.py"], result["password"])
        self.assertEqual([], result["no_password"])
        self.assertEqual("refused", result["unsupported"])
        # The check's own list of required files holds neither; they come from the function, for the mode.
        required = SCRIPT[SCRIPT.index("foreach ($requiredFile in @(") :]
        required = required[: required.index(")) {")]
        self.assertNotIn("$secretFile", required)
        self.assertNotIn("$secretStore", required)
        self.assertIn(
            "foreach ($passwordFile in @(Get-PasswordFilePaths `\n    -Access $repositoryAccess `\n"
            "    -SecretFile $secretFile `\n    -SecretStore $secretStore)) {\n    Assert-NormalFile -Path $passwordFile",
            SCRIPT,
        )


class StandardInputTests(unittest.TestCase):
    """Restic waits for a password on an open standard input when a no-password backup is opened without the flag."""

    def test_every_native_child_has_its_standard_input_closed_right_after_it_starts(self):
        native = powershell_function(SCRIPT, "Invoke-NativeToFiles")
        self.assertIn("$start.RedirectStandardInput = $true", native)
        started = native.index("if (-not $process.Start()) {")
        closed = native.index("$process.StandardInput.Close()")
        copying = native.index("$process.StandardOutput.BaseStream.CopyToAsync($stdout)")
        self.assertLess(started, closed)
        self.assertLess(closed, copying)
        # Every native step goes through it.
        self.assertEqual(1, SCRIPT.count("[System.Diagnostics.Process]::new()"))
        self.assertNotIn("Start-Process", SCRIPT)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_child_does_not_inherit_the_standard_input_of_the_check(self):
        with tempfile.TemporaryDirectory(prefix="rewindle-verifier-stdin-", ignore_cleanup_errors=True) as temp:
            reader = Path(temp) / "read_standard_input.py"
            reader.write_text("import sys\nsys.stdout.write('stdin=' + repr(sys.stdin.read()))\n", encoding="ascii")
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(SCRIPT, *NATIVE_FUNCTIONS),
                    "$system = " + ps_literal(os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32")),
                    "$environment = @{ SystemRoot = " + ps_literal(os.environ.get("SystemRoot", r"C:\Windows"))
                    + "; PATH = $system }",
                    "$result = [ordered]@{}",
                    "try {",
                    "    $result.exit = Invoke-NativeToFiles -Executable " + ps_literal(sys.executable)
                    + " -Arguments @('-I', " + ps_literal(str(reader)) + ") -StdoutPath "
                    + ps_literal(str(Path(temp) / "out.txt")) + " -StderrPath "
                    + ps_literal(str(Path(temp) / "err.txt")) + " -Environment $environment -TimeoutSeconds 20",
                    "    $result.outcome = 'finished'",
                    "}",
                    "catch { $result.outcome = 'stopped: ' + $script:checkFailureDetail.reason_code }",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe, open_standard_input=True)
            self.assertEqual("finished", result["outcome"])
            self.assertEqual(0, result["exit"])
            self.assertEqual("stdin=''", (Path(temp) / "out.txt").read_text(encoding="utf-8"))

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_missed_flag_fails_at_once_and_never_waits_for_a_password(self):
        # A stand-in for Restic with the rules measured on 0.19.1 (tests/restic_access.py). With no flag on a
        # no-password backup it waits on an open standard input, as the real one does, and stops when it is closed.
        with tempfile.TemporaryDirectory(prefix="rewindle-verifier-fake-restic-", ignore_cleanup_errors=True) as temp:
            root = Path(temp)
            fake = root / "fake_restic.py"
            fake.write_text(
                "\n".join(
                    [
                        "import os, sys",
                        "from pathlib import Path",
                        f"sys.path.insert(0, {str(TESTS)!r})",
                        "from restic_access import EMPTY_NOT_ALLOWED, restic_access_result",
                        "command = sys.argv[1:]",
                        "access = (Path(command[command.index('--repo') + 1]) / 'access').read_text().strip()",
                        "refusal = restic_access_result(command, os.environ, access)",
                        "if refusal is not None:",
                        "    code, message = refusal",
                        "    if message == EMPTY_NOT_ALLOWED:",
                        "        sys.stdin.read()",
                        "    sys.stderr.write(message + '\\n')",
                        "    sys.exit(code)",
                        "sys.stdout.write('{\"id\": \"' + 'ab' * 32 + '\"}')",
                        "",
                    ]
                ),
                encoding="ascii",
            )
            for name in ("password", "no_password"):
                folder = root / name
                folder.mkdir()
                (folder / "access").write_text(name, encoding="ascii")
            scenarios = [
                # name, the backup, how the command line is built, how the settings are built
                ("no_password_ok", "no_password", "no_password", "no_password"),
                ("password_ok", "password", "password", "password"),
                ("flag_missing", "no_password", "password", "no_password"),
                ("flag_on_a_password_backup", "password", "no_password", "no_password"),
                ("flag_next_to_a_password_command", "no_password", "no_password", "password"),
            ]
            lines = [
                PROBE_HEADER,
                powershell_functions(
                    SCRIPT,
                    *NATIVE_FUNCTIONS,
                    "New-NativeChildEnvironment",
                    "Get-ResticCommonArguments",
                    "Get-CloudEnvironmentSettings",
                ),
                "$temporary = " + ps_literal(str(root)),
                "$common = @{ RcloneConfig = 'C:\\Run\\rclone.conf'; RclonePasswordCommand = 'rclone-command'; "
                "RcloneCacheDirectory = 'C:\\Run\\cache' }",
                "$result = [ordered]@{}",
            ]
            for name, backup, command_line, settings in scenarios:
                repository = root / backup
                with_command = " -ResticPasswordCommand 'restic-command'" if settings == "password" else ""
                lines += [
                    "$arguments = @(" + ps_literal(str(fake)) + ") + @(Get-ResticCommonArguments -Access "
                    + ps_literal(command_line) + " -Repository " + ps_literal(str(repository)) + ") + @('cat', 'config')",
                    "$environment = New-NativeChildEnvironment -TemporaryDirectory $temporary -Settings "
                    "(Get-CloudEnvironmentSettings -Access " + ps_literal(settings) + " @common" + with_command + ")",
                    "$watch = [Diagnostics.Stopwatch]::StartNew()",
                    "try {",
                    "    $exit = Invoke-NativeToFiles -Executable " + ps_literal(sys.executable)
                    + " -Arguments (@('-I') + $arguments) -StdoutPath " + ps_literal(str(root / f"{name}.out"))
                    + " -StderrPath " + ps_literal(str(root / f"{name}.err"))
                    + " -Environment $environment -TimeoutSeconds 20",
                    f"    $result.{name} = [ordered]@{{ outcome = 'exit'; exit = $exit }}",
                    "}",
                    f"catch {{ $result.{name} = [ordered]@{{ outcome = 'stopped'; exit = $null }} }}",
                    f"$result.{name}.seconds = $watch.Elapsed.TotalSeconds",
                ]
            lines += ["[Console]::Out.Write(($result | ConvertTo-Json -Compress))", ""]
            result = run_probe_json(self, "\n".join(lines), open_standard_input=True)
            self.assertEqual({"outcome": "exit", "exit": 0}, {k: result["no_password_ok"][k] for k in ("outcome", "exit")})
            self.assertEqual({"outcome": "exit", "exit": 0}, {k: result["password_ok"][k] for k in ("outcome", "exit")})
            for name, code, message in (
                ("flag_missing", 1, EMPTY_NOT_ALLOWED),
                ("flag_on_a_password_backup", 12, WRONG_PASSWORD),
                ("flag_next_to_a_password_command", 1, CONFLICT),
            ):
                with self.subTest(name):
                    self.assertEqual("exit", result[name]["outcome"], "the run waited instead of failing")
                    self.assertEqual(code, result[name]["exit"])
                    self.assertLess(result[name]["seconds"], 15)
                    self.assertIn(message, (root / f"{name}.err").read_text(encoding="utf-8"))
            self.assertIn('"id"', (root / "no_password_ok.out").read_text(encoding="utf-8"))


class NoPasswordTextsTests(unittest.TestCase):
    """Telemetry.CleanOffsiteDetail hides a whole sentence that holds password, dpapi, RESTIC_ or "recovery key"."""

    def test_the_dashboards_filter_is_the_one_these_tests_apply(self):
        self.assertCountEqual(["password", "dpapi", "RESTIC_", "recovery key"], offsite_filter_words())
        self.assertTrue(hidden_by_offsite_filter("Rewindle couldn't use its saved password."))
        self.assertFalse(hidden_by_offsite_filter("Rewindle couldn't open your backup in the Google Drive folder."))

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_nothing_the_check_says_about_why_it_stopped_is_hidden(self):
        steps = sorted(set(re.findall(r"Set-CheckStep '([a-z_]+)'", SCRIPT)) | {"checking_setup", "unknown_step"})
        inventory = powershell_function(SCRIPT, "Get-InventoryFailureDetail")
        categories = sorted(set(re.findall(r"^        '([a-z_]+)' \{", inventory, re.M)))
        self.assertGreaterEqual(len(categories), 5)
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_functions(
                    SCRIPT,
                    "Get-CheckStepLabel",
                    "New-CheckFailureDetail",
                    "Get-CheckFailureDescription",
                    "Format-FileCount",
                    "Get-InventoryFailureDetail",
                ),
                "$texts = New-Object System.Collections.Generic.List[string]",
                "foreach ($step in @(" + ", ".join(ps_literal(step) for step in steps) + ")) {",
                "    $detail = Get-CheckFailureDescription -Step $step -Detail $null",
                "    $texts.Add([string]$detail.reason); $texts.Add([string]$detail.next_step)",
                "    $texts.Add((Get-CheckStepLabel -Step $step))",
                "}",
                "foreach ($category in @(" + ", ".join(ps_literal(item) for item in categories) + ")) {",
                "    foreach ($count in @(1, 2, 1234)) {",
                "        $detail = Get-InventoryFailureDetail -Category $category -Count $count",
                "        if ($null -ne $detail) { $texts.Add([string]$detail.reason); $texts.Add([string]$detail.next_step) }",
                "    }",
                "}",
                # Every sentence in the script (a string of several words), whichever way it reaches the person: a reason
                # or next step given to Stop-Check, or an error message. Names, paths and settings have no spaces.
                "$tokens = $null; $errors = $null",
                "$ast = [Management.Automation.Language.Parser]::ParseFile("
                + ps_literal(str(PROJECT / "src" / "verify_my_drive_cloud_repository.ps1"))
                + ", [ref]$tokens, [ref]$errors)",
                "$sentences = New-Object System.Collections.Generic.List[string]",
                "foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] "
                "-or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {",
                "    $value = [string]$node.Value",
                "    if ($value -match '\\s') { $sentences.Add($value) }",
                "}",
                "[Console]::Out.Write(([ordered]@{ errors = $errors.Count; texts = @($texts); sentences = @($sentences) } "
                "| ConvertTo-Json -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        self.assertEqual(0, result["errors"])
        # The scan covers the words the access choice added.
        self.assertIn("unsupported repository_access", result["sentences"])
        self.assertGreater(len(result["texts"]), 30)
        self.assertGreater(len(result["sentences"]), 30)
        for text in result["texts"]:
            with self.subTest(text=text):
                self.assertFalse(hidden_by_offsite_filter(text))
        # The format strings of the two commands hold paths and options, not words for a person.
        for sentence in result["sentences"]:
            with self.subTest(sentence=sentence):
                self.assertFalse(hidden_by_offsite_filter(sentence))


if __name__ == "__main__":
    unittest.main()
