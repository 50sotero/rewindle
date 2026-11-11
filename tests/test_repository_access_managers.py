"""Backups with or without a password in the two protected managers: Manage-Repository.ps1 and Manage-Sources.ps1.

tests/Test-ManageRepository.ps1 and tests/Test-ManageSourcesDriveFs.ps1 never run on CI, so what Manage-Repository.ps1 does
is proven here as well: static checks of the script, and small Windows PowerShell 5.1 probes that read functions out of it
and run them (Invoke-ResticCapture against a stand-in Restic that follows tests/restic_access.py).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(Path(__file__).resolve().parent))

from restic_access import CONFLICT, EMPTY_NOT_ALLOWED, WRONG_PASSWORD  # noqa: E402


REPOSITORY_MANAGER = SOURCE / "Manage-Repository.ps1"
SOURCES_MANAGER = SOURCE / "Manage-Sources.ps1"
REPOSITORY_TEXT = REPOSITORY_MANAGER.read_text(encoding="utf-8")
SOURCES_TEXT = SOURCES_MANAGER.read_text(encoding="utf-8")

# The reader every throwing PowerShell script carries, character for character (design section 3).
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


def powershell_function(text: str, name: str) -> str:
    start = text.index(f"\nfunction {name} {{\n") + 1
    return text[start : text.index("\n}\n", start) + 3]


def stored_copy(path: Path) -> bytes:
    """The file as git stores it (its staged copy, the same as HEAD on a clean checkout).

    A checkout with core.autocrlf=true, like the CI runner's, writes CR LF to the working copy, so the line endings a file is
    committed with can only be read from git.
    """
    relative = path.relative_to(PROJECT).as_posix()
    completed = subprocess.run(["git", "cat-file", "blob", f":{relative}"], cwd=PROJECT, capture_output=True, timeout=30, check=False)
    if completed.returncode != 0:
        raise AssertionError(f"git has no stored copy of {relative}: " + completed.stderr.decode("utf-8", "replace").strip())
    return completed.stdout


def block_without(text: str, header: str) -> tuple[str, list[str]]:
    """`text` with every block that starts with the exact `header` line end removed, and those blocks."""
    removed: list[str] = []
    while True:
        start = text.find(header)
        if start < 0:
            return text, removed
        depth = 0
        index = text.index("{", start)
        for index in range(index, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    break
        removed.append(text[start : index + 1])
        text = text[:start] + text[index + 1 :]


def windows_powershell() -> str:
    system = os.environ.get("SystemRoot", r"C:\Windows")
    return os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def run_windows_powershell(
    script: str, extra_environment: dict[str, str], *, hold_stdin_open: bool = False
) -> subprocess.CompletedProcess:
    """Runs `script` in Windows PowerShell 5.1 with no window and the module path pinned to Windows' own folder.

    With hold_stdin_open the probe's own standard input is an open pipe nobody writes to until it has finished, so a child
    that inherits it (instead of getting its own, closed) can be told from one that does not.
    """
    system = os.environ.get("SystemRoot", r"C:\Windows")
    environment = dict(os.environ)
    environment["PSModulePath"] = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "Modules")
    environment.update(extra_environment)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    with tempfile.TemporaryDirectory(prefix="rewindle-managers-probe-", ignore_cleanup_errors=True) as temp:
        script_path = Path(temp) / "probe.ps1"
        script_path.write_text(script, encoding="ascii", newline="\n")
        out_path = Path(temp) / "out.txt"
        err_path = Path(temp) / "err.txt"
        command = [
            windows_powershell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(script_path),
        ]
        with out_path.open("wb") as out, err_path.open("wb") as err:
            process = subprocess.Popen(
                command, stdin=subprocess.PIPE if hold_stdin_open else subprocess.DEVNULL, stdout=out, stderr=err,
                creationflags=flags, env=environment,
            )
            try:
                process.wait(timeout=240)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            finally:
                if process.stdin is not None:
                    process.stdin.close()
        return subprocess.CompletedProcess(
            command, process.returncode,
            out_path.read_text(encoding="utf-8", errors="replace"), err_path.read_text(encoding="utf-8", errors="replace"),
        )


def last_json_line(test: unittest.TestCase, completed: subprocess.CompletedProcess) -> object:
    test.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    test.assertTrue(lines, "the probe printed nothing: " + completed.stderr)
    return json.loads(lines[-1])


FUNCTION_LOADER = """
$ast = [Management.Automation.Language.Parser]::ParseFile($env:RW_MANAGER, [ref]$null, [ref]$null)
$wanted = @($env:RW_FUNCTIONS -split ',')
$found = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $wanted })
if ($found.Count -ne $wanted.Count) { throw "functions found: $(@($found | ForEach-Object { $_.Name }) -join ', ')" }
foreach ($definition in $found) { . ([scriptblock]::Create($definition.Extent.Text)) }
"""

# A stand-in Restic that follows tests/restic_access.py: the flag next to a password source is refused, backups without a
# password need the flag, backups with a password refuse it. It logs what it was given, and whether its standard input was
# closed (an open pipe nobody writes to is where the real Restic waits for a password).
FAKE_RESTIC = r"""
using System;
using System.Collections;
using System.IO;
using System.Text;
using System.Threading;
public static class FakeRestic {
  static int standardInputByte;
  static bool StandardInputIsOpen() {
    Thread reader = new Thread(delegate() {
      try { standardInputByte = Console.In.Read(); } catch (Exception) { standardInputByte = -1; }
    });
    reader.IsBackground = true;
    reader.Start();
    return !reader.Join(1500);
  }
  public static int Main(string[] args) {
    string directory = AppDomain.CurrentDomain.BaseDirectory;
    string accessFile = Path.Combine(directory, "fake-access.txt");
    string access = File.Exists(accessFile) ? File.ReadAllText(accessFile).Trim() : "password";
    bool open = StandardInputIsOpen();
    bool flag = false;
    bool source = false;
    StringBuilder log = new StringBuilder();
    foreach (string argument in args) {
      log.Append("ARG:" + argument + "\n");
      if (argument == "--insecure-no-password") flag = true;
      if (argument == "--password-command" || argument == "--password-file" || argument == "--new-password-file") source = true;
    }
    foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
      string name = ((string)entry.Key).ToUpperInvariant();
      string value = (string)entry.Value;
      if (name.StartsWith("RESTIC_") || name.StartsWith("RCLONE_")) log.Append("ENV:" + name + "\n");
      if ((name == "RESTIC_PASSWORD" || name == "RESTIC_PASSWORD_FILE" || name == "RESTIC_PASSWORD_COMMAND") && value.Length > 0) source = true;
    }
    log.Append("STDIN:" + (open ? "open" : "closed") + "\nEND\n");
    File.AppendAllText(Path.Combine(directory, "fake-restic.log"), log.ToString());
    if (flag && source) { Console.Error.WriteLine("@@CONFLICT@@"); return 1; }
    if (access == "no_password" && !flag) {
      if (open) { Console.Error.WriteLine("waited for a password on a standard input that stayed open"); return 93; }
      Console.Error.WriteLine("@@EMPTY@@");
      return 1;
    }
    if (access == "password" && flag) { Console.Error.WriteLine("@@WRONG@@"); return 12; }
    Console.WriteLine("{\"id\":\"" + new string('a', 64) + "\"}");
    return 0;
  }
}
""".replace("@@CONFLICT@@", CONFLICT).replace("@@EMPTY@@", EMPTY_NOT_ALLOWED).replace("@@WRONG@@", WRONG_PASSWORD)

RESTIC_PROBE = (
    "Set-StrictMode -Version Latest\n$ErrorActionPreference = 'Stop'\n"
    + FUNCTION_LOADER
    + r"""
$work = $env:RW_WORK
$installRoot = Join-Path $work 'ProgramFiles\ResticBackuper'
$stateRoot = Join-Path $work 'ProgramData\ResticBackuper'
foreach ($directory in @((Join-Path $installRoot 'Python'), $stateRoot)) { [void][IO.Directory]::CreateDirectory($directory) }
$source = @'
""" + FAKE_RESTIC + r"""
'@
$restic = Join-Path $installRoot 'restic.exe'
Add-Type -TypeDefinition $source -OutputAssembly $restic -OutputType ConsoleApplication
$log = Join-Path $installRoot 'fake-restic.log'
$accessFile = Join-Path $installRoot 'fake-access.txt'
$repository = Join-Path $work 'Repository'

function New-Validated {
    param([object]$Configuration)
    return [pscustomobject]@{
        ResticExecutable = $restic
        PythonExecutable = Join-Path $installRoot 'Python\python.exe'
        SecretFile = Join-Path $stateRoot 'repository-password.dpapi.json'
        RepositoryAccess = Get-RepositoryAccess -Configuration $Configuration
    }
}

function Invoke-Case {
    param([string]$Name, [object]$Validated, [string]$Backups)
    [IO.File]::WriteAllText($accessFile, $Backups)
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
    $case = [ordered]@{ name = $Name; output = $null; error = $null }
    try { $case.output = [string](Invoke-ResticCapture -Validated $Validated -Repository $repository -CommandArguments @('cat', 'config')) }
    catch { $case.error = $_.Exception.Message }
    $case.log = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
    return [pscustomobject]$case
}

$older = New-Validated -Configuration ([pscustomobject]@{ plan_id = 'an older install, without the key' })
$explicit = New-Validated -Configuration ([pscustomobject]@{ repository_access = 'password' })
$without = New-Validated -Configuration ([pscustomobject]@{ repository_access = 'no_password' })
$results = [Collections.Generic.List[object]]::new()
$results.Add((Invoke-Case -Name 'older_shape' -Validated $older -Backups 'password'))
$results.Add((Invoke-Case -Name 'password' -Validated $explicit -Backups 'password'))
$results.Add((Invoke-Case -Name 'no_password' -Validated $without -Backups 'no_password'))
# A password in the person's own environment never reaches Restic, so it cannot meet the flag there.
$env:RESTIC_PASSWORD = 'a password that must never be handed on'
$env:RESTIC_PASSWORD_FILE = 'Z:\elsewhere\password.txt'
$results.Add((Invoke-Case -Name 'no_password_with_a_password_in_the_environment' -Validated $without -Backups 'no_password'))
Remove-Item Env:\RESTIC_PASSWORD
Remove-Item Env:\RESTIC_PASSWORD_FILE
$results.Add((Invoke-Case -Name 'no_password_but_the_backups_have_one' -Validated $without -Backups 'password'))
$results.Add((Invoke-Case -Name 'password_but_the_backups_have_none' -Validated $explicit -Backups 'no_password'))
$refusal = try { ConvertTo-PasswordCommand -Validated $without; 'built' } catch { $_.Exception.Message }
$unsupported = [ordered]@{}
foreach ($value in @('Password', 'NO_PASSWORD', 'no-password', '', ' password', 5, $true)) {
    $unsupported[[string]$value] = try { Get-RepositoryAccess -Configuration ([pscustomobject]@{ repository_access = $value }); 'accepted' } catch { $_.Exception.Message }
}
$unsupported['<null>'] = try { Get-RepositoryAccess -Configuration ([pscustomobject]@{ repository_access = $null }); 'accepted' } catch { $_.Exception.Message }
[ordered]@{
    install_root = $installRoot
    state_root = $stateRoot
    repository = $repository
    cases = @($results)
    password_command_refusal = $refusal
    unsupported = $unsupported
    older_reads = Get-RepositoryAccess -Configuration ([pscustomobject]@{ plan_id = 'older' })
} | ConvertTo-Json -Depth 6 -Compress
"""
)

SOURCES_PROBE = (
    "Set-StrictMode -Version Latest\n$ErrorActionPreference = 'Stop'\n"
    + FUNCTION_LOADER
    + r"""
function New-Document {
    param([object]$Spec)
    if ($Spec.PSObject.Properties['absent']) { return [pscustomobject]@{ plan_id = 'a document without the key' } }
    return [pscustomobject]@{ plan_id = 'a document with the key'; repository_access = $Spec.value }
}
$results = [Collections.Generic.List[object]]::new()
# Windows PowerShell 5.1 hands a JSON array over as one object, so it is read into a variable and walked.
$cases = ConvertFrom-Json -InputObject $env:RW_CASES
foreach ($case in $cases) {
    $live = New-Document -Spec $case.live
    $outcome = try {
        if ($env:RW_STYLE -eq 'sources') {
            Assert-RecoveryRepositoryAccess -Configuration (New-Document -Spec $case.config) -Manifest (New-Document -Spec $case.manifest) `
                -Validated ([pscustomobject]@{ Json = $live })
        }
        else {
            Assert-RecoveryRepositoryAccess -Expected $live -Configuration (New-Document -Spec $case.config) -Manifest (New-Document -Spec $case.manifest)
        }
        'ok'
    } catch { $_.Exception.Message }
    $results.Add([pscustomobject]@{ id = $case.id; outcome = $outcome })
}
ConvertTo-Json -InputObject @($results) -Depth 4 -Compress
"""
)


def absent() -> dict:
    return {"absent": True}


def value(content: object) -> dict:
    return {"value": content}


class StaticManagerTests(unittest.TestCase):
    def test_both_managers_read_the_mode_with_the_contract_function_character_for_character(self) -> None:
        for name, text in (("Manage-Repository.ps1", REPOSITORY_TEXT), ("Manage-Sources.ps1", SOURCES_TEXT)):
            with self.subTest(script=name):
                self.assertEqual(GET_REPOSITORY_ACCESS, powershell_function(text, "Get-RepositoryAccess"))
                self.assertEqual(1, text.count("function Get-RepositoryAccess {"))

    def test_nothing_else_reads_the_field_by_dotted_access_or_with_a_case_blind_comparison(self) -> None:
        for name, text in (("Manage-Repository.ps1", REPOSITORY_TEXT), ("Manage-Sources.ps1", SOURCES_TEXT)):
            with self.subTest(script=name):
                # Dotted access throws under StrictMode on every older configuration; -eq ignores case.
                self.assertNotRegex(text, r"\.repository_access\b")
                self.assertEqual(1, text.count("Properties['repository_access']"))
                self.assertNotRegex(text, r"-i?(?:eq|ne|in|notin)\s+@?\(?'(?:no_)?password'")

    def test_the_scripts_stay_plain_ascii_with_lf_line_endings(self) -> None:
        for path in (
            REPOSITORY_MANAGER, SOURCES_MANAGER,
            PROJECT / "tests" / "Test-ManageRepository.ps1", PROJECT / "tests" / "Test-ManageSources.ps1",
            PROJECT / "tests" / "Test-ManageSourcesDriveFs.ps1",
        ):
            with self.subTest(file=path.name):
                data = stored_copy(path)
                data.decode("ascii")
                self.assertIn(b"\n", data)
                self.assertNotIn(b"\r", data)

    def test_the_move_reads_the_mode_once_and_checks_the_secret_and_the_recovery_key_only_for_a_password(self) -> None:
        validated = powershell_function(REPOSITORY_TEXT, "Get-ValidatedConfiguration")
        self.assertIn("    $access = Get-RepositoryAccess -Configuration $configuration\n", validated)
        self.assertEqual(1, validated.count("Get-RepositoryAccess"))
        self.assertIn("RepositoryAccess = $access", validated)
        # The unsupported value is refused before any path or file is looked at.
        self.assertLess(validated.index("Get-RepositoryAccess"), validated.index("Get-CanonicalLocalPath"))
        rest, only_password = block_without(validated, "if ($access -ceq 'password') {")
        self.assertEqual(3, len(only_password), only_password)
        joined = "\n".join(only_password)
        self.assertIn("(Join-Path $installRoot 'secret_store.py'), $secretFile", joined)
        self.assertIn("@($secretFile, 'DPAPI secret file')", joined)
        self.assertIn("@([string]$configuration.recovery_key_file, 'Recovery key')", joined)
        # Nothing outside those blocks needs a saved secret, its helper or a recovery key to exist or sit on NTFS.
        self.assertNotIn("secret_store.py", rest)
        self.assertNotIn("@($secretFile, 'DPAPI secret file')", rest)
        self.assertNotIn("'Recovery key'", rest)
        self.assertNotRegex(rest, r"Assert-(?:NormalFile|NtfsProtectedPath)[^\n]*\$secretFile")
        # The checked path of a saved secret is part of every configuration, so it stays compared in both modes.
        self.assertIn("@($secretFile, (Join-Path $stateRoot 'repository-password.dpapi.json'), 'DPAPI secret file')", rest)

    def test_only_the_credential_helper_builds_the_password_command_and_it_refuses_a_backup_without_one(self) -> None:
        self.assertEqual(1, REPOSITORY_TEXT.count("ConvertTo-PasswordCommand -Validated"))
        helper = powershell_function(REPOSITORY_TEXT, "Get-ResticCredentialArguments")
        self.assertIn("ConvertTo-PasswordCommand -Validated $Validated", helper)
        self.assertLess(
            helper.index("if ($Validated.RepositoryAccess -ceq 'no_password') { return @('--insecure-no-password') }"),
            helper.index("'--password-command'"),
        )
        command = powershell_function(REPOSITORY_TEXT, "ConvertTo-PasswordCommand")
        self.assertLess(command.index("if ($Validated.RepositoryAccess -cne 'password') {"), command.index("secret_store.py"))
        self.assertLess(command.index("throw '"), command.index("secret_store.py"))
        capture = powershell_function(REPOSITORY_TEXT, "Invoke-ResticCapture")
        self.assertNotIn("--password-command", capture)
        self.assertNotIn("ConvertTo-PasswordCommand", capture)
        self.assertIn(
            "$arguments = @('--repo', $Repository) + @(Get-ResticCredentialArguments -Validated $Validated) + @(\n"
            "        '--cache-dir', $cache, '--retry-lock', '0s'\n"
            "    ) + $CommandArguments\n",
            capture,
        )

    def test_restic_gets_its_own_closed_standard_input_in_both_modes(self) -> None:
        capture = powershell_function(REPOSITORY_TEXT, "Invoke-ResticCapture")
        self.assertEqual(1, capture.count("$start.RedirectStandardInput = $true"))
        start = capture.index("if (-not $process.Start())")
        self.assertLess(capture.index("$start.RedirectStandardInput = $true"), start)
        after_start = capture[start:]
        self.assertLess(after_start.index("$process.StandardInput.Close()"), after_start.index("ReadToEndAsync"))
        # Nothing between Start and the close can fail in a way that skips it, and nothing else spawns Restic.
        between = after_start[: after_start.index("$process.StandardInput.Close()")]
        self.assertEqual(1, between.count("\n") - between.count("# "), between)
        self.assertEqual(1, REPOSITORY_TEXT.count("[Diagnostics.Process]::new()"))

    def test_the_bundle_and_the_published_configuration_keep_the_mode(self) -> None:
        bundle = powershell_function(REPOSITORY_TEXT, "Get-ValidatedRecoveryBundle")
        self.assertIn(
            "        Assert-RecoveryRepositoryAccess -Expected $ExpectedPlan.Json -Configuration $bundleConfig -Manifest $manifest\n",
            bundle,
        )
        check = powershell_function(REPOSITORY_TEXT, "Assert-RecoveryRepositoryAccess")
        self.assertIn("$expectedAccess = Get-RepositoryAccess -Configuration $Expected", check)
        self.assertIn("(Get-RepositoryAccess -Configuration $Configuration) -cne $expectedAccess", check)
        self.assertIn("(Get-RepositoryAccess -Configuration $Manifest) -cne $expectedAccess", check)
        self.assertIn("throw 'Recovery repository_access is not synchronized with the protected configuration.'", check)
        published = powershell_function(REPOSITORY_TEXT, "Assert-PublishedConfiguration")
        self.assertIn(
            "(Get-RepositoryAccess -Configuration $published) -cne (Get-RepositoryAccess -Configuration $ExpectedPlan.Json)",
            published,
        )
        # A move writes the mode nowhere: the configuration, the recovery copy, its manifest and the record are rewritten
        # from their own bytes, so a key the move does not know about is kept.
        self.assertNotIn("Set-JsonProperty -Object $liveJson -Name 'repository_access'", REPOSITORY_TEXT)
        self.assertEqual(0, REPOSITORY_TEXT.count("'repository_access' -Value"))

    def test_the_copy_progress_line_names_backups_not_an_encrypted_repository(self) -> None:
        self.assertEqual(2, REPOSITORY_TEXT.count("'Copying your backups and the recovery tools.'"))
        self.assertNotIn("encrypted repository", REPOSITORY_TEXT)

    def test_the_source_manager_compares_the_mode_of_the_bundle_with_the_live_configuration(self) -> None:
        bundle = powershell_function(SOURCES_TEXT, "Get-ValidatedRecoveryBundle")
        self.assertLess(
            bundle.index("Assert-RecoveryStorageBinding -Configuration $recoveryConfig -Validated $Validated"),
            bundle.index("Assert-RecoveryRepositoryAccess -Configuration $recoveryConfig -Manifest $manifest -Validated $Validated"),
        )
        check = powershell_function(SOURCES_TEXT, "Assert-RecoveryRepositoryAccess")
        self.assertIn("$expected = Get-RepositoryAccess -Configuration $Validated.Json", check)
        self.assertIn("(Get-RepositoryAccess -Configuration $Configuration) -cne $expected", check)
        self.assertIn("(Get-RepositoryAccess -Configuration $Manifest) -cne $expected", check)
        self.assertIn("throw 'Recovery repository_access is not synchronized with the protected configuration.'", check)
        # The mode is never written by this manager: the transition check refuses any change to a field it does not own.
        self.assertNotIn("'repository_access' -Value", SOURCES_TEXT)

    def test_the_local_suite_fake_follows_the_shared_restic_messages(self) -> None:
        suite = (PROJECT / "tests" / "Test-ManageRepository.ps1").read_text(encoding="utf-8")
        for message in (CONFLICT, EMPTY_NOT_ALLOWED, WRONG_PASSWORD):
            with self.subTest(message=message):
                self.assertIn(message, suite)
        for rule in ('access == "no_password" && !noPasswordFlag', 'access == "password" && noPasswordFlag', "noPasswordFlag && passwordSource"):
            self.assertIn(rule, suite)


class ResticSpawnProbeTests(unittest.TestCase):
    """Invoke-ResticCapture, read out of Manage-Repository.ps1 and run against a stand-in Restic."""

    @classmethod
    def setUpClass(cls) -> None:
        with tempfile.TemporaryDirectory(prefix="rewindle-managers-restic-", ignore_cleanup_errors=True) as work:
            completed = run_windows_powershell(
                RESTIC_PROBE,
                {
                    "RW_MANAGER": str(REPOSITORY_MANAGER),
                    "RW_WORK": work,
                    "RW_FUNCTIONS": ",".join((
                        "Get-RepositoryAccess", "ConvertTo-PasswordCommand", "ConvertTo-WindowsArgument",
                        "Set-AllowListedChildEnvironment", "Assert-NormalDirectoryChain",
                        "Get-ResticCredentialArguments", "Invoke-ResticCapture",
                    )),
                },
                hold_stdin_open=True,
            )
        cls.report = last_json_line(cls(), completed)
        cls.cases = {case["name"]: case for case in cls.report["cases"]}

    @staticmethod
    def parse_log(text: str) -> list[dict]:
        calls: list[dict] = []
        current: dict = {"args": [], "env": [], "stdin": None}
        for line in text.splitlines():
            if line.startswith("ARG:"):
                current["args"].append(line[4:])
            elif line.startswith("ENV:"):
                current["env"].append(line[4:])
            elif line.startswith("STDIN:"):
                current["stdin"] = line[6:]
            elif line == "END":
                calls.append(current)
                current = {"args": [], "env": [], "stdin": None}
        return calls

    def password_command(self) -> str:
        install = self.report["install_root"]
        state = self.report["state_root"]
        words = [
            install.replace("\\", "/") + "/Python/python.exe", "-I", "-S", "-B", install.replace("\\", "/") + "/secret_store.py",
            "reveal", "--secret-file", state.replace("\\", "/") + "/repository-password.dpapi.json",
        ]
        return " ".join('"' + word.replace('"', '\\"') + '"' for word in words)

    def expected_arguments(self, credential: list[str]) -> list[str]:
        cache = self.report["state_root"] + "\\cache"
        return ["--repo", self.report["repository"], *credential, "--cache-dir", cache, "--retry-lock", "0s", "cat", "config"]

    def only_call(self, name: str) -> dict:
        calls = self.parse_log(self.cases[name]["log"])
        self.assertEqual(1, len(calls), self.cases[name])
        return calls[0]

    def test_an_older_configuration_is_opened_exactly_as_before(self) -> None:
        # No repository_access key: the saved-password command, in the argument order Restic has always been given.
        self.assertEqual("password", self.report["older_reads"])
        case = self.cases["older_shape"]
        self.assertIsNone(case["error"], case)
        self.assertEqual(self.expected_arguments(["--password-command", self.password_command()]), self.only_call("older_shape")["args"])
        self.assertEqual(self.cases["older_shape"]["log"], self.cases["password"]["log"])

    def test_a_backup_without_a_password_is_opened_with_the_flag_alone(self) -> None:
        case = self.cases["no_password"]
        self.assertIsNone(case["error"], case)
        self.assertEqual(self.expected_arguments(["--insecure-no-password"]), self.only_call("no_password")["args"])
        self.assertNotIn("--password-command", self.only_call("no_password")["args"])
        self.assertIn('"id"', case["output"])

    def test_a_password_in_the_persons_environment_never_reaches_restic(self) -> None:
        name = "no_password_with_a_password_in_the_environment"
        self.assertIsNone(self.cases[name]["error"], self.cases[name])
        self.assertEqual([], self.only_call(name)["env"])

    def test_restic_never_gets_the_managers_own_standard_input_in_either_mode(self) -> None:
        # The probe's own standard input was an open pipe the whole time.
        for name in ("older_shape", "password", "no_password", "no_password_with_a_password_in_the_environment",
                     "no_password_but_the_backups_have_one", "password_but_the_backups_have_none"):
            with self.subTest(case=name):
                self.assertEqual("closed", self.only_call(name)["stdin"])

    def test_the_flag_that_does_not_match_the_backups_stops_the_move_with_restics_own_answer(self) -> None:
        wrong = self.cases["no_password_but_the_backups_have_one"]
        self.assertIsNone(wrong["output"])
        self.assertIn("exit code 12", wrong["error"])
        self.assertIn(WRONG_PASSWORD, wrong["error"])
        empty = self.cases["password_but_the_backups_have_none"]
        self.assertIsNone(empty["output"])
        self.assertIn("exit code 1:", empty["error"])
        self.assertIn(EMPTY_NOT_ALLOWED, empty["error"])
        self.assertNotIn("waited for a password", empty["error"])

    def test_no_command_that_reveals_the_saved_secret_is_built_for_a_backup_without_a_password(self) -> None:
        self.assertEqual("This backup opens without a key, so there is no key command to build.", self.report["password_command_refusal"])
        for text in self.cases["no_password"]["log"], self.cases["no_password_but_the_backups_have_one"]["log"]:
            self.assertNotIn("password-command", text)
            self.assertNotIn("secret_store", text)

    def test_the_conflict_the_flag_would_meet_in_a_password_source_is_the_shared_one(self) -> None:
        # The stand-in follows tests/restic_access.py; this ties its refusal of flag plus password source to it.
        self.assertIn("RESTIC_PASSWORD", CONFLICT.upper() + "RESTIC_PASSWORD")
        self.assertTrue(CONFLICT.startswith("Fatal: --insecure-no-password must not be specified together with"))

    def test_an_unsupported_mode_is_refused_by_name_and_the_older_shape_reads_as_password(self) -> None:
        for given, outcome in self.report["unsupported"].items():
            with self.subTest(value=given):
                self.assertEqual("unsupported repository_access", outcome)
        self.assertEqual({"Password", "NO_PASSWORD", "no-password", "", " password", "5", "True", "<null>"}, set(self.report["unsupported"]))


class BundleModeProbe:
    """Assert-RecoveryRepositoryAccess, read out of a manager and run on the three documents it compares."""

    MANAGER: Path
    STYLE: str
    MISMATCH = "Recovery repository_access is not synchronized with the protected configuration."
    UNSUPPORTED = "unsupported repository_access"

    @classmethod
    def setUpClass(cls) -> None:
        cls.expectations: dict[str, str] = {}
        cases = []

        def add(identifier: str, live: dict, config: dict, manifest: dict, expected: str) -> None:
            cases.append({"id": identifier, "live": live, "config": config, "manifest": manifest})
            cls.expectations[identifier] = expected

        add("older install: the key in none of the three", absent(), absent(), absent(), "ok")
        add("a missing key counts as password in the recovery copy", absent(), value("password"), absent(), "ok")
        add("... and in the live configuration", value("password"), absent(), value("password"), "ok")
        add("... and in the manifest", value("password"), value("password"), absent(), "ok")
        add("no_password in all three", value("no_password"), value("no_password"), value("no_password"), "ok")
        add("recovery copy without the key beside no_password", value("no_password"), absent(), value("no_password"), cls.MISMATCH)
        add("manifest without the key beside no_password", value("no_password"), value("no_password"), absent(), cls.MISMATCH)
        add("recovery copy says password beside no_password", value("no_password"), value("password"), value("no_password"), cls.MISMATCH)
        add("recovery copy says no_password beside an older configuration", absent(), value("no_password"), absent(), cls.MISMATCH)
        add("manifest says no_password beside password", value("password"), value("password"), value("no_password"), cls.MISMATCH)
        for given in ("NO_PASSWORD", "Password", "no-password", "", None, 5, True):
            label = repr(given)
            add(f"unsupported {label} in the live configuration", value(given), absent(), absent(), cls.UNSUPPORTED)
            add(f"unsupported {label} in the recovery copy", absent(), value(given), absent(), cls.UNSUPPORTED)
            add(f"unsupported {label} in the manifest", absent(), absent(), value(given), cls.UNSUPPORTED)
        completed = run_windows_powershell(
            SOURCES_PROBE,
            {
                "RW_MANAGER": str(cls.MANAGER),
                "RW_STYLE": cls.STYLE,
                "RW_FUNCTIONS": "Get-RepositoryAccess,Assert-RecoveryRepositoryAccess",
                "RW_CASES": json.dumps(cases),
            },
        )
        cls.outcomes = {row["id"]: row["outcome"] for row in last_json_line(cls(), completed)}

    def test_every_combination_of_the_three_documents_is_decided_as_the_contract_says(self) -> None:
        self.assertEqual(set(self.expectations), set(self.outcomes))
        for identifier, expected in self.expectations.items():
            with self.subTest(case=identifier):
                self.assertEqual(expected, self.outcomes[identifier])


class SourceManagerBundleModeTests(BundleModeProbe, unittest.TestCase):
    MANAGER = SOURCES_MANAGER
    STYLE = "sources"


class RepositoryManagerBundleModeTests(BundleModeProbe, unittest.TestCase):
    MANAGER = REPOSITORY_MANAGER
    STYLE = "repository"


if __name__ == "__main__":
    unittest.main()
