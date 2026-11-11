"""Static checks that keep the installer's machine-readable backend, its contract and its tests in step.

The behaviour itself is exercised by tests/Test-InstallPlan.ps1 (hermetic) and tests/Test-InstallerContract.ps1 (a real
install, hosted CI runner only). These checks need no PowerShell: they read the scripts, docs/setup-contract.md and ci.yml.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / "installer" / "Install-ResticBackuper.ps1"
UNINSTALLER = PROJECT / "installer" / "Uninstall-ResticBackuper.ps1"
CONTRACT = PROJECT / "docs" / "setup-contract.md"
CI = PROJECT / ".github" / "workflows" / "ci.yml"
CONTRACT_TEST = PROJECT / "tests" / "Test-InstallerContract.ps1"

REGION = re.compile(r"# region progress-feed.*?# endregion progress-feed", re.S)
OWNED_PROCESSES = re.compile(r"# region owned-processes.*?# endregion owned-processes", re.S)
MAINTENANCE = PROJECT / "src" / "dashboard" / "web" / "src" / "setup" / "screens" / "Maintenance.tsx"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def functions(text: str) -> dict[str, str]:
    """Top-level PowerShell functions: `function Name {` at column 0 to the next `}` at column 0."""
    # The C# inside an Add-Type here-string has lines that start with a closing brace; drop those bodies first.
    text = re.sub(r"@'\n.*?\n'@", "@'\n'@", text, flags=re.S)
    found: dict[str, str] = {}
    for match in re.finditer(r"^function ([A-Za-z][\w-]*) \{\n(.*?)^\}$", text, re.S | re.M):
        found[match.group(1)] = match.group(2)
    return found


def script_codes(text: str) -> set[str]:
    """Every identifier a script uses as a finding, failure or warning code."""
    codes: set[str] = set()
    for pattern in (
        r"-Code '([a-z0-9_]+)'",
        r"\[string\]\$Code = '([a-z0-9_]+)'",
        r"(?:NotAbsolute|Invalid)Code '([a-z0-9_]+)'",
        r"@\('([a-z0-9_]+_failed)'",
        r"\bcode = '([a-z0-9_]+)'",
        r"\$code = '([a-z0-9_]+)'",
        r"\{ '([a-z0-9_]+_(?:not_local|drive_unavailable|volume_unavailable))' \}",
    ):
        codes.update(re.findall(pattern, text))
    return codes


def contract_code_tables(text: str) -> set[str]:
    """First-column codes of every table in the contract whose header is `Code | ...`."""
    codes: set[str] = set()
    inside = False
    for line in text.splitlines():
        if line.startswith("|"):
            cells = [cell.strip() for cell in line.strip("|").split("|")]
            if cells and cells[0] == "Code":
                inside = True
                continue
            if inside:
                match = re.fullmatch(r"`([a-z0-9_]+)`", cells[0])
                if match:
                    codes.add(match.group(1))
        else:
            inside = False
    return codes


class ProgressFeedTests(unittest.TestCase):
    def test_the_progress_feed_region_is_identical_in_both_scripts(self) -> None:
        installer = REGION.search(read(INSTALLER))
        uninstaller = REGION.search(read(UNINSTALLER))
        self.assertIsNotNone(installer)
        self.assertIsNotNone(uninstaller)
        self.assertEqual(installer.group(0), uninstaller.group(0), "re-copy the region between the two scripts")

    def test_both_scripts_declare_the_documented_parameters(self) -> None:
        installer = read(INSTALLER)
        uninstaller = read(UNINSTALLER)
        for name in ("PlanOnly", "PlanOutput", "ProgressPath", "ExpectedUserSid", "Unattended"):
            self.assertRegex(installer, rf"\${name}\b", name)
        for name in ("ProgressPath", "ExpectedUserSid", "Unattended"):
            self.assertRegex(uninstaller, rf"\${name}\b", name)
        contract = read(CONTRACT)
        for text in ("-PlanOnly", "-PlanOutput", "-ProgressPath", "-ExpectedUserSid", "Rewindle.InstallPlan.v1", "Rewindle.InstallProgress.v1"):
            self.assertIn(text, contract)
        for text in (installer, uninstaller):
            self.assertIn("Rewindle.InstallProgress.v1", text)
        self.assertIn("Rewindle.InstallPlan.v1", installer)

    def test_the_schedule_is_still_validated_before_anything_else(self) -> None:
        installer = read(INSTALLER)
        self.assertNotIn("[ValidatePattern(", installer.split("Set-StrictMode", 1)[0])
        preflight = functions(installer)["Invoke-InstallPreflight"]
        self.assertLess(preflight.index("Assert-ScheduleValue"), preflight.index("Assert-MicrosoftSignedExecutable"))
        self.assertLess(preflight.index("Assert-ScheduleValue"), preflight.index("Invoke-SelfElevation"))
        self.assertIn(r"^([01]\d|2[0-3]):[0-5]\d$", functions(installer)["Assert-ScheduleValue"])

    def test_parameter_combinations_are_refused_before_anything_runs(self) -> None:
        installer = read(INSTALLER)
        head = installer.split("function Get-InstallerRoots", 1)[0]
        for refusal in (
            "-PlanOnly cannot be combined with -ProgressPath.",
            "-PlanOutput requires -PlanOnly.",
            "-ProgressPath requires -Unattended.",
        ):
            self.assertIn(refusal, head)
        self.assertIn("-ProgressPath requires -Unattended.", read(UNINSTALLER).split("function ", 1)[0])
        self.assertIn("REWINDLE_SETUP_TEST_ROOTS is a test hook that only -PlanOnly honors.", installer)


class PlanModeCannotChangeTheMachineTests(unittest.TestCase):
    """The call graph from Invoke-PlanMode reaches no function that creates, writes, installs or registers anything."""

    INSTALL_ONLY = (
        "Set-ProtectedDirectory",
        "Assert-DriveFsProviderTransaction",
        "New-RuntimeManifest",
        "Ensure-WebView2Runtime",
        "Invoke-SelfElevation",
        "Open-ProgressFeed",
        "Write-Utf8NoBom",
        "Invoke-InstallPreflight",
        "Invoke-WebView2Phase",
        # Asks the installed program about the backups (and starts it); the question asks the person. Neither may run in a plan.
        "Invoke-RepositoryAccessDetection",
        "Invoke-ProtectedPython",
        "Invoke-RepositoryAccessQuestion",
        "Read-RepositoryAccessChoice",
    )
    MUTATING = (
        r"\bNew-Item\b", r"\bSet-Acl\b", r"\bRemove-Item\b", r"\bCopy-Item\b", r"\bMove-Item\b", r"\bRename-Item\b",
        r"\bRegister-ScheduledTask\b", r"\bUnregister-ScheduledTask\b", r"\bStart-ScheduledTask\b", r"\bStop-ScheduledTask\b",
        r"\bStart-Process\b", r"\bStop-Process\b", r"\bNew-ItemProperty\b", r"\bSet-ItemProperty\b", r"\bRemove-ItemProperty\b",
        r"\bInvoke-WebRequest\b", r"\bInvoke-RestMethod\b", r"\bSet-Content\b", r"\bAdd-Content\b", r"\bOut-File\b",
        r"\bExport-Clixml\b", r"WriteAllText", r"WriteAllBytes", r"\]::Move\(", r"\]::Delete\(", r"\]::Copy\(", r"&\s*\$icacls\b",
        r"New-Object -ComObject", r"\bPush-Location\b", r"\bSet-Location\b",
    )

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = read(INSTALLER)
        cls.defined = functions(cls.text)
        reachable: set[str] = set()
        pending = ["Invoke-PlanMode"]
        while pending:
            name = pending.pop()
            if name in reachable:
                continue
            reachable.add(name)
            body = cls.defined[name]
            for other in cls.defined:
                if other not in reachable and re.search(rf"(?<![\w-]){re.escape(other)}(?![\w-])", body):
                    pending.append(other)
        cls.reachable = reachable

    def test_the_graph_is_not_trivially_small(self) -> None:
        for name in (
            "Resolve-RepositorySelection", "Resolve-SourceSelection", "Assert-RepositoryTarget", "Get-PlanVolumes", "Write-PlanDocument",
            "Get-KeptRepository", "Resolve-RepositoryAccess", "Get-ExistingRepositoryAccess", "Get-RecordedRepositoryAccess",
        ):
            self.assertIn(name, self.reachable)

    def test_no_install_only_function_is_reachable(self) -> None:
        for name in self.INSTALL_ONLY:
            self.assertNotIn(name, self.reachable, f"{name} must not be reachable from plan mode")

    def test_reachable_functions_call_no_state_changing_command(self) -> None:
        for name in sorted(self.reachable):
            body = self.defined[name]
            for pattern in self.MUTATING:
                if re.search(pattern, body):
                    self.fail(f"{name} (reachable from plan mode) uses {pattern}")

    def test_the_plan_file_is_the_only_file_plan_mode_creates(self) -> None:
        creators = [name for name in self.reachable if "CreateNew" in self.defined[name]]
        self.assertEqual(["Write-PlanDocument"], creators)

    def test_prompts_are_skipped_in_plan_mode(self) -> None:
        for name in sorted(self.reachable):
            body = self.defined[name]
            if "Read-Host" in body:
                self.assertIn("$PlanOnly", body[: body.index("Read-Host")], f"{name} asks a question before checking -PlanOnly")

    def test_install_code_runs_only_after_plan_mode_has_exited(self) -> None:
        marker = self.text.index("if ($PlanOnly) {\n    try {")
        self.assertIn("[void](Invoke-PlanMode)\n        exit 0", self.text[marker : marker + 400])
        for name in ("Start-InstallPhase", "Invoke-InstallPreflight", "Assert-InstallationVerified"):
            self.assertGreater(self.text.index(f"function {name} "), marker, f"{name} is defined after plan mode exits")
        self.assertGreater(self.text.index("Register-ScheduledTask -TaskName $backupTaskName"), marker)
        self.assertGreater(self.text.index("Set-ProtectedDirectory -Path $installRoot"), marker)

    def test_the_machine_roots_hook_is_refused_by_a_real_install(self) -> None:
        roots = self.defined["Get-InstallerRoots"]
        self.assertLess(roots.index("if (-not $PlanOnly)"), roots.index("ConvertFrom-Json"))


class ContractMatchesTheScriptsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = read(CONTRACT)
        cls.installer = read(INSTALLER)
        cls.uninstaller = read(UNINSTALLER)

    def test_every_code_a_script_can_emit_is_documented(self) -> None:
        documented = set(re.findall(r"`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)`", self.contract))
        used = script_codes(self.installer) | script_codes(self.uninstaller)
        self.assertGreater(len(used), 70)
        self.assertEqual([], sorted(used - documented), "codes used by a script but missing from docs/setup-contract.md")

    def test_every_code_in_a_contract_table_exists_in_a_script(self) -> None:
        documented = contract_code_tables(self.contract)
        used = script_codes(self.installer) | script_codes(self.uninstaller)
        self.assertGreater(len(documented), 70)
        self.assertEqual([], sorted(documented - used), "codes documented in a table but not used by any script")

    def test_ineligible_reasons_match(self) -> None:
        in_code = set(re.findall(r"\$reason = '([a-z_]+)'", self.installer))
        section = self.contract.split("| Reason | Meaning |", 1)[1].split("\n\n", 1)[0]
        in_doc = set(re.findall(r"^\| `([a-z_]+)` \|", section, re.M))
        self.assertEqual(in_code, in_doc)

    def test_install_phases_match_the_contract_in_order(self) -> None:
        titles = re.search(r"\$installPhaseTitles = @\{\n(.*?)\n\}", self.installer, re.S).group(1)
        in_code = re.findall(r"^\s+([a-z0-9_]+) = '([^']*)'$", titles, re.M)
        section = self.contract.split("### 3.3 Phases", 1)[1].split("\n### ", 1)[0]
        in_doc = re.findall(r"^\| \d+ \| `([a-z0-9_]+)` \| ([^|]+?) \|", section, re.M)
        self.assertEqual(12, len(in_code))
        self.assertEqual(in_code, in_doc)
        main = self.installer.split("$preflightSucceeded = $false", 1)[1]
        in_flow = []
        for phase in re.findall(r"(?:Start|Skip)-InstallPhase '([a-z0-9_]+)'", main):
            if phase not in in_flow:
                in_flow.append(phase)
        self.assertEqual([phase for phase, _ in in_code][2:], in_flow)

    def test_uninstall_phases_match_the_contract_in_order(self) -> None:
        titles = re.search(r"\$uninstallPhaseTitles = @\{\n(.*?)\n\}", self.uninstaller, re.S).group(1)
        in_code = re.findall(r"^\s+([a-z0-9_]+) = '([^']*)'$", titles, re.M)
        section = self.contract.split("## 4. Uninstall", 1)[1].split("\n## ", 1)[0]
        in_doc = re.findall(r"^\| \d+ \| `([a-z0-9_]+)` \| ([^|]+?) \|", section, re.M)
        self.assertEqual(7, len(in_code))
        self.assertEqual(in_code, in_doc)
        main = self.uninstaller.split("$progressOpened = $false", 1)[1]
        in_flow = []
        for phase in re.findall(r"(?:Start|Skip)-UninstallPhase '([a-z0-9_]+)'", main):
            if phase not in in_flow:
                in_flow.append(phase)
        self.assertEqual([phase for phase, _ in in_code], in_flow)

    def test_the_json_examples_in_the_contract_are_json(self) -> None:
        blocks = re.findall(r"```json\n(.*?)```", self.contract, re.S)
        self.assertGreaterEqual(len(blocks), 3)
        documents = [json.loads(block) for block in blocks]
        plan = documents[0]
        self.assertEqual("Rewindle.InstallPlan.v1", plan["schema"])
        self.assertEqual(["schema", "ok", "errors", "warnings", "resolved", "defaults", "environment"], list(plan))
        self.assertEqual(
            ["root", "label", "filesystem", "drive_type", "size_bytes", "free_bytes", "is_system", "same_physical_disk_as_system",
             "eligible", "ineligible_reason", "ineligible_message", "recommended"],
            list(plan["environment"]["volumes"][0]),
        )
        self.assertEqual(
            ["rewindle", "legacy_personal_edition", "kept_repository", "kept_repository_access"],
            list(plan["environment"]["existing_install"]),
        )
        self.assertEqual(
            ["repository", "storage_mode", "repository_access", "existing_repository_access", "drivefs_my_drive_root", "sources",
             "canary_source", "schedule", "vss", "minimum_free_bytes", "estimated_source_bytes"],
            list(plan["resolved"]),
        )
        phase, result = documents[1], documents[2]
        self.assertEqual(["schema", "seq", "time", "type", "phase", "state", "title", "detail"], list(phase))
        self.assertEqual(
            ["schema", "seq", "time", "type", "ok", "error", "install_root", "recovery_key_path", "recovery_key_readable_by_user",
             "dashboard_executable", "version", "repository_access", "warnings"],
            list(result),
        )

    def test_the_progress_lines_are_built_in_the_documented_order(self) -> None:
        region = REGION.search(self.installer).group(0)
        envelope = re.search(r"\$line = \[ordered\]@\{\n\s+schema = '([^']+)'\n\s+seq = [^\n]+\n\s+time = ", region)
        self.assertEqual("Rewindle.InstallProgress.v1", envelope.group(1))
        phase = re.search(r"Write-FeedLine \(\[ordered\]@\{\n(.*?)\n\s+\}\)", region, re.S).group(1)
        self.assertEqual(["type", "phase", "state", "title", "detail"], re.findall(r"^\s+(\w+) = ", phase, re.M))
        result = re.search(r"\$line = \[ordered\]@\{\n\s+type = 'result'\n\s+ok = \$Ok\n\s+error = \$ErrorInfo\n", region)
        self.assertIsNotNone(result)

    def test_the_result_properties_are_documented(self) -> None:
        for name in (
            "install_root", "recovery_key_path", "recovery_key_readable_by_user", "dashboard_executable", "version",
            "repository_access", "warnings",
        ):
            self.assertIn(name, self.contract)
            self.assertIn(f"{name} = ", self.installer)
        for name in ("operation", "removed", "kept", "state_root", "cloud_verification_root", "repository_access"):
            self.assertIn(name, self.contract)
            self.assertIn(f"{name} = ", self.uninstaller)

    def test_existing_console_texts_are_kept(self) -> None:
        for text in (
            "A repository path is required; no safe non-system default was found.",
            "The repository is on the Windows system volume. This does not protect against failure or loss of that volume; a separate physical drive is strongly recommended.",
            "Installation cancelled before any product files were created.",
            "INSTALLATION FAILED:",
            "Rewindle installed successfully.",
            "-Repository is required with -Unattended.",
            "-SourceList is required with -Unattended.",
            "Approve elevation with the same Windows account.",
        ):
            self.assertIn(text, self.installer)
        for text in ("app components were removed.", "Preserved backup state:", "Uninstall cancelled before any changes were made."):
            self.assertIn(text, self.uninstaller)

    def test_the_kept_backup_location_is_reported_and_never_a_finding(self) -> None:
        # A reinstall after a separate uninstall is told where the earlier backups are, from the state folder the uninstall kept.
        defined = functions(self.installer)
        plan = defined["Invoke-PlanMode"]
        self.assertIn("$keptRepository = Get-KeptRepository\n", plan)
        self.assertNotRegex(plan, r"Get-PlanEnvironmentPart[^\n]*Get-KeptRepository")
        existing = re.search(r"existing_install = \[ordered\]@\{\n(.*?)\n\s+\}", plan, re.S).group(1)
        self.assertEqual(
            ["rewindle", "legacy_personal_edition", "kept_repository", "kept_repository_access"],
            re.findall(r"^\s+(\w+) = ", existing, re.M),
        )
        reader = defined["Get-KeptRepository"]
        # It reads the three records, needs the stored password, never throws and never raises a finding.
        for name in ("'repository.json'", "'last-success.json'", "'status.json'", "$secretFile"):
            self.assertIn(name, reader)
        # A completed move of the backup location rewrites repository.json and stamps relocated_utc, which counts too.
        self.assertIn("@('repository.json', @('initialized_utc', 'updated_utc', 'relocated_utc'))", reader)
        self.assertIn("-Name 'relocated_utc'", read(PROJECT / "src" / "Manage-Repository.ps1"))
        self.assertTrue(reader.lstrip().startswith("try {"))
        for finding in ("Stop-InstallValidation", "New-InstallFinding", "Add-PlanFinding", "throw"):
            self.assertNotIn(finding, reader)
        self.assertIn("`environment.existing_install.kept_repository`", self.contract)
        self.assertIn("`environment.existing_install.kept_repository_access`", self.contract)
        self.assertIn("**A reinstall.**", self.contract.split("## 6. Notes for the wizard", 1)[1])

    def test_the_console_suggests_the_kept_backup_location(self) -> None:
        prompt = functions(self.installer)["Get-RepositoryInput"]
        unattended = prompt.index("if ($Unattended)")
        self.assertLess(prompt.index("if ($PlanOnly)"), prompt.index("Get-KeptRepository"))
        self.assertLess(unattended, prompt.index("Get-KeptRepository"))
        self.assertLess(prompt.index("Get-KeptRepository"), prompt.index("Get-DefaultRepository"))
        self.assertLess(prompt.index("Get-KeptRepository"), prompt.index("Read-Host"))

    def test_the_wizard_facing_deviations_are_written_down(self) -> None:
        section = self.contract.split("## 7. Deviations and additions", 1)[1]
        for text in ("canary", "permissions", "-Schedule", "verification"):
            self.assertIn(text, section)


class MicrosoftSignerTests(unittest.TestCase):
    """Windows' own tools and the WebView2 installer must be signed by Microsoft itself, not by a name that contains it."""

    ROOTS = {"3B1EFD3A66EA28B16697394703A72CA340A05BD5", "8F43288AD272F3103B6FB1428485EA3014C0BCFE"}
    # The repository manager runs System32's icacls.exe as administrator when it moves the backup location.
    MANAGER = PROJECT / "src" / "Manage-Repository.ps1"
    # A comparison that is true when "Microsoft" merely appears in a name, against a literal that holds the word: PowerShell's
    # -like and -match in each case and negated form, .NET's Contains, IndexOf, StartsWith, EndsWith and Regex.IsMatch, and
    # Python's `in`.
    SUBSTRING = re.compile(
        r"""-[ci]?(?:not)?(?:like|match)\s+@?["'][^"'\n]*microsoft"""
        r"""|(?:\.|::)(?:Contains|IndexOf|StartsWith|EndsWith|IsMatch)\s*\([^)"'\n]*@?["'][^"'\n]*microsoft"""
        r"""|["'][^"'\n]*microsoft[^"'\n]*["']\s+(?:not\s+)?in\b""",
        re.I,
    )
    # Folders the builds fill; nothing in them is a source script.
    GENERATED = {"node_modules", "dist", "build-output", "bin", "obj", ".packages", "__pycache__"}

    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = functions(read(INSTALLER))
        cls.uninstaller = functions(read(UNINSTALLER))
        cls.manager = functions(read(cls.MANAGER))

    def test_no_script_accepts_a_signer_name_that_merely_contains_microsoft(self) -> None:
        for path, defined in ((INSTALLER, self.installer), (UNINSTALLER, self.uninstaller)):
            with self.subTest(script=path.name):
                self.assertNotRegex(read(path), r"(?i)-(?:not)?like\s+'\*Microsoft\*'")
                check = defined["Assert-MicrosoftSignedExecutable"]
                self.assertLess(check.index("Get-AuthenticodeSignerFacts -Path $Path"), check.index("Get-MicrosoftSignerProblem"))
                self.assertNotIn("Get-AuthenticodeSignature", check)

    def test_no_script_under_src_or_installer_accepts_a_signer_by_a_microsoft_substring(self) -> None:
        # The pattern sees each form such a check has taken here, so a pass below means something.
        for old in (
            "$signature.SignerCertificate.Subject -notlike '*Microsoft*'",
            'subject.IndexOf("Microsoft Corporation", StringComparison.OrdinalIgnoreCase) >= 0',
            "[regex]::IsMatch($subject, 'Microsoft')",
            '"Microsoft" in signer',
        ):
            with self.subTest(pattern=old):
                self.assertRegex(old, self.SUBSTRING)
        scanned, found = set(), []
        for folder in ("src", "installer"):
            for root, directories, files in os.walk(PROJECT / folder):
                directories[:] = [name for name in directories if name not in self.GENERATED]
                for name in files:
                    if not name.lower().endswith((".ps1", ".psm1", ".cs", ".py")):
                        continue
                    path = Path(root) / name
                    relative = path.relative_to(PROJECT).as_posix()
                    scanned.add(relative)
                    for number, line in enumerate(read(path).splitlines(), 1):
                        if self.SUBSTRING.search(line):
                            found.append(f"{relative}:{number}: {line.strip()}")
        for expected in ("src/Manage-Repository.ps1", "installer/Install-ResticBackuper.ps1", "installer/setup/WebViewRuntime.cs"):
            self.assertIn(expected, scanned)
        self.assertEqual([], found, "check the signer with Get-MicrosoftSignerProblem (Setup: MicrosoftSignerProblem)")

    def test_the_installer_the_uninstaller_and_the_repository_manager_apply_the_same_rule(self) -> None:
        for copy, defined in (("uninstaller", self.uninstaller), ("repository manager", self.manager)):
            for name in ("Get-MicrosoftSignerProblem", "Get-AuthenticodeSignerFacts"):
                with self.subTest(copy=copy, function=name):
                    self.assertTrue(name in defined, f"the {copy} has no {name}")
                    self.assertEqual(self.installer[name], defined[name])

    def test_the_repository_manager_checks_icacls_with_the_rule(self) -> None:
        trusted = self.manager["Get-TrustedIcacls"]
        self.assertNotIn("Get-AuthenticodeSignature", trusted)
        self.assertIn("Get-AuthenticodeSignerFacts -Path $icacls", trusted)
        self.assertIn("Get-MicrosoftSignerProblem", trusted)
        self.assertLess(trusted.index("Get-AuthenticodeSignerFacts -Path $icacls"), trusted.index("Get-MicrosoftSignerProblem"))
        for caller in ("Set-ProtectedTreeAcl", "Set-RepositoryRecordBytes"):
            with self.subTest(caller=caller):
                self.assertIn("$icacls = Get-TrustedIcacls\n", self.manager[caller])
        # Nothing else in the manager finds icacls.exe or reads a signature its own way.
        text = read(self.MANAGER)
        self.assertEqual(1, text.count("'icacls.exe'"))
        self.assertEqual(1, len(re.findall(r"\bGet-AuthenticodeSignature\b", text)))

    def test_only_microsofts_own_roots_and_its_exact_name_are_trusted(self) -> None:
        rule = self.installer["Get-MicrosoftSignerProblem"]
        roots = re.search(r"\$microsoftRoots = @\((.*?)\n    \)", rule, re.S)
        self.assertIsNotNone(roots)
        self.assertEqual(self.ROOTS, set(re.findall(r"'([0-9A-F]{40})'", roots.group(1))))
        self.assertIn("$organizations[0] -cne 'O=Microsoft Corporation'", rule)
        self.assertIn("$Status -cne 'Valid'", rule)
        # Rewindle Setup checks the WebView2 installer it downloads against the same roots.
        runtime = read(PROJECT / "installer" / "setup" / "WebViewRuntime.cs")
        block = re.search(r"MicrosoftRootThumbprints =\s*\{(.*?)\};", runtime, re.S)
        self.assertIsNotNone(block)
        self.assertEqual(self.ROOTS, set(re.findall(r'"([0-9A-F]{40})"', block.group(1))))

    def test_the_signer_check_adds_no_compiled_code(self) -> None:
        for name in ("Get-MicrosoftSignerProblem", "Get-AuthenticodeSignerFacts", "Assert-MicrosoftSignedExecutable"):
            with self.subTest(function=name):
                self.assertNotIn("Add-Type", self.installer[name])


class StateFolderOwnerTests(unittest.TestCase):
    """Any account can create C:\\ProgramData\\ResticBackuper; one that Administrators or SYSTEM don't own is never used."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = read(INSTALLER)
        cls.defined = functions(cls.text)

    def test_only_administrators_and_system_may_own_it(self) -> None:
        check = self.defined["Test-TrustedStateOwner"]
        self.assertEqual(["S-1-5-18", "S-1-5-32-544"], sorted(re.findall(r"'(S-1-[0-9-]+)'", check)))

    def test_nothing_is_read_from_the_folder_before_its_owner_is_checked(self) -> None:
        body = self.defined["Get-PreservedPlanIdentity"]
        statements = [line.strip() for line in body.splitlines() if line.strip() and not line.strip().startswith("#")]
        self.assertEqual("Assert-StateFolderOwner", statements[0])

    def test_the_kept_backup_location_is_read_only_from_a_folder_they_own(self) -> None:
        # Get-KeptRepository reads a reinstall's suggested backup location from the same folder. It never raises a finding, so
        # it checks the folder itself, and an owner it can't read counts as one Administrators and SYSTEM don't have.
        reader = self.defined["Get-KeptRepository"]
        owner = reader.index("if (-not (Test-TrustedStateOwner -OwnerSid (Get-FeedOwnerSid -Path $stateRoot))) { return $null }")
        self.assertLess(reader.index("[IO.FileAttributes]::ReparsePoint) { return $null }"), owner)
        for later in ("Test-Path -LiteralPath $secretFile", "Join-Path $stateRoot $record[0]", "ReadAllText"):
            with self.subTest(later=later):
                self.assertLess(owner, reader.index(later))

    def test_plan_mode_reports_it_whatever_backup_location_is_chosen(self) -> None:
        plan = self.defined["Invoke-PlanMode"]
        stage = plan.index("[void](Invoke-PlanStage { Assert-StateFolderOwner })")
        self.assertLess(stage, plan.index("Resolve-RepositorySelection"))

    def test_the_install_checks_it_before_it_resolves_anything(self) -> None:
        preflight = self.defined["Invoke-InstallPreflight"]
        check = preflight.index("Assert-StateFolderOwner")
        self.assertGreater(check, preflight.index("expected_user_mismatch"))
        for later in ("Assert-Payload", "Resolve-RepositorySelection", "Resolve-ProtectedBindings"):
            with self.subTest(later=later):
                self.assertLess(check, preflight.index(later))

    def test_the_install_creates_the_folder_owned_by_administrators_and_checks_one_it_finds(self) -> None:
        canary = self.text.split("Start-InstallPhase 'canary'", 1)[1].split("Complete-InstallPhase 'canary'", 1)[0]
        creation = canary.index("[IO.Directory]::CreateDirectory($stateRoot, (New-ProtectedDirectorySecurity -UserSid $currentSid))")
        self.assertNotIn("New-Item -ItemType Directory -Path $stateRoot", canary)
        self.assertLess(creation, canary.index("Assert-StateFolderOwner"))
        self.assertLess(canary.index("Assert-StateFolderOwner"), canary.index("$canarySource"))
        security = self.defined["New-ProtectedDirectorySecurity"]
        self.assertIn("$acl.SetOwner($administrators)", security)
        self.assertIn("$acl.SetAccessRuleProtection($true, $false)", security)
        self.assertIn("New-ProtectedDirectorySecurity -UserSid $UserSid", self.defined["Set-ProtectedDirectory"])


class ContinuedGenerationTests(unittest.TestCase):
    """A reinstall over kept state keeps the configuration generation only for the same backup scope, so its first backup
    finds the one before it instead of reading every file again. Test-InstallPlan.ps1 runs Get-ContinuedConfigGeneration
    itself; these check what the install hands it."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = read(INSTALLER)
        cls.defined = functions(cls.text)
        cls.payload = cls.text.split("Start-InstallPhase 'payload'", 1)[1].split("Complete-InstallPhase 'payload'", 1)[0]

    def test_a_new_plan_starts_at_one_and_a_kept_plan_asks_which_generation(self) -> None:
        self.assertIn("        config_generation = 1\n", self.payload)
        self.assertNotIn("config_generation + 1", self.payload)
        # The block of its own, not the plan_id line's inline "$(if ($null -ne $preservedPlan) {".
        kept = self.payload.index("\n    if ($null -ne $preservedPlan) {\n")
        call = self.payload.index(
            "$configuration['config_generation'] = Get-ContinuedConfigGeneration -PreservedPlan $preservedPlan"
        )
        self.assertEqual(-1, self.payload.find("\n    }\n", kept, call), "the call is inside that block")
        # Every field it compares is set first, and the file is written with its answer.
        for earlier in ("source_identities = $sourceIdentities", "$configuration['drivefs_cache_directory']"):
            with self.subTest(earlier=earlier):
                self.assertLess(self.payload.index(earlier), call)
        self.assertLess(call, self.payload.index("Write-Utf8NoBom -Path $configPath"))

    def test_it_compares_the_installed_exclusion_list_and_a_reused_repository(self) -> None:
        call = self.payload.split("Get-ContinuedConfigGeneration -PreservedPlan $preservedPlan", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("-RepositoryKept $repositoryPreviouslyInitialized", call)
        self.assertLess(
            self.payload.index("Assert-TreeMatchesManifest -Root $installRoot"),
            self.payload.index("Get-ContinuedConfigGeneration"),
        )
        # Hashed as backup.py hashes it for exclude_file_sha256, inside the try: a list it can't read means the next generation.
        body = self.defined["Get-ContinuedConfigGeneration"]
        hashing = body.index(
            "(Get-FileHash -LiteralPath ([string]$Configuration['exclude_file']) -Algorithm SHA256 -ErrorAction Stop)"
            ".Hash.ToLowerInvariant()"
        )
        self.assertLess(body.index("    try {\n"), hashing)

    def test_the_latest_verified_backup_comes_with_the_kept_plan(self) -> None:
        body = self.defined["Get-PreservedPlanIdentity"]
        self.assertIn("if ($name -eq 'last-success.json') { $lastSuccess = $document }", body)
        self.assertIn("last_success = $lastSuccess", body)

    def test_anything_it_cannot_read_starts_the_next_generation(self) -> None:
        body = self.defined["Get-ContinuedConfigGeneration"]
        self.assertIn("$next = $highest + 1", body)
        self.assertTrue(body.rstrip().endswith("catch {\n        return $next\n    }"))
        # It never answers lower than the highest generation on record, which the engine would refuse.
        returned = set(re.findall(r"return (\$\w+)", body))
        self.assertEqual({"$next", "$highest"}, returned)


class FailedInstallRollbackTests(unittest.TestCase):
    """A late failure stops what the install started before it removes the program folder, removes runtime-manifest.json last,
    and says Setup undid its changes only when the folder is gone. Test-InstallPlan.ps1 runs the helpers themselves."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = read(INSTALLER)
        cls.defined = functions(cls.installer)
        main = cls.installer.split("$preflightSucceeded = $false", 1)[1]
        cls.rollback = main.rsplit("\ncatch {\n", 1)[1].split("\nfinally {\n", 1)[0]

    def test_the_owned_processes_region_is_identical_in_both_scripts(self) -> None:
        installer = OWNED_PROCESSES.search(self.installer)
        uninstaller = OWNED_PROCESSES.search(read(UNINSTALLER))
        self.assertIsNotNone(installer)
        self.assertIsNotNone(uninstaller)
        self.assertEqual(installer.group(0), uninstaller.group(0), "re-copy the region between the two scripts")
        self.assertIn("function Stop-OwnedProcesses {", installer.group(0))

    def test_the_rollback_helpers_are_install_only(self) -> None:
        marker = self.installer.index("if ($PlanOnly) {\n    try {")
        for name in ("Stop-OwnedProcesses", "Stop-InstalledPrograms", "Remove-RuntimeContent", "Remove-InstalledRuntime"):
            self.assertGreater(self.installer.index(f"function {name} "), marker, f"{name} is defined after plan mode exits")

    def test_the_started_programs_are_stopped_while_their_tasks_are_still_registered(self) -> None:
        stop = self.rollback.index("Stop-InstalledPrograms -TaskName $startedTasks")
        for later in (
            "Unregister-ScheduledTask -TaskName $dashboardTaskName",
            "Unregister-ScheduledTask -TaskName $backupTaskName",
            "Remove-InstalledRuntime -Root $installRoot",
        ):
            self.assertLess(stop, self.rollback.index(later), later)
        for task in ("$startedTasks += $dashboardTaskName", "$startedTasks += $backupTaskName"):
            self.assertLess(self.rollback.index(task), stop)
        body = self.defined["Stop-InstalledPrograms"]
        self.assertIn("'ResticBackuperDashboard', 'ResticBackuperTaskLauncher'", body)
        # Through Task Scheduler first, waiting until the task stops, and only then the processes; and it never throws.
        self.assertLess(body.index("Stop-ScheduledTask"), body.index("Start-Sleep"))
        self.assertLess(body.index("Start-Sleep"), body.index("Stop-OwnedProcesses"))
        self.assertNotIn("throw", body)

    def test_the_program_folder_is_removed_with_runtime_manifest_last_and_checked(self) -> None:
        # No more Remove-Item -Recurse -ErrorAction SilentlyContinue of the program folder, which deleted the manifest and
        # left the files in use without saying so.
        self.assertNotRegex(self.rollback, r"Remove-Item[^\n]*(\$installRoot|\$resolved)")
        self.assertIn("$leftover = Remove-InstalledRuntime -Root $installRoot", self.rollback)
        self.assertIn("Write-InstallFailure -ErrorRecord $caught -RolledBack $true -Leftover $leftover", self.rollback)
        remove = self.defined["Remove-InstalledRuntime"]
        delete_manifest = remove.index("[IO.File]::Delete($manifestPath)")
        self.assertLess(remove.index("Remove-RuntimeContent -Directory $resolved -Keep $manifestPath"), delete_manifest)
        self.assertIn("if ($left.Count -eq 0) {", remove[:delete_manifest])
        self.assertIn("Join-Path $programFilesRoot $productName", remove)
        self.assertIn("New-RuntimeManifest -Root $resolved", remove)
        self.assertNotIn("-Recurse", remove)
        content = self.defined["Remove-RuntimeContent"]
        self.assertLess(content.index("ReparsePoint"), content.index("$entry.Delete()"))

    def test_the_leftover_message_names_a_choice_setup_really_offers(self) -> None:
        failure = self.defined["Write-InstallFailure"]
        undid = failure.index("' Setup undid its changes.")
        self.assertIn("if ($RolledBack -and $Leftover) {", failure[:undid])
        self.assertIn("elseif ($RolledBack) {", failure[:undid])
        left = re.search(r'\$message \+= "( Setup undid its other changes[^"]*)"', failure).group(1)
        for word in ("restic", "repository", "snapshot", "engine", "canary"):
            self.assertNotIn(word, left.lower())
        self.assertIn("Restart your PC, then run Setup again and choose Reinstall or repair", left)
        self.assertIn("<strong>Reinstall or repair", read(MAINTENANCE))
        section = self.contract_section()
        for text in ("runtime-manifest.json", "stops the dashboard", "Reinstall or repair"):
            self.assertIn(text, section)

    @staticmethod
    def contract_section() -> str:
        section = read(CONTRACT).split("### 3.5 Failure semantics", 1)[1].split("\n### ", 1)[0]
        return " ".join(section.split())


# The non-failing reader that both scripts carry, character for character (design section 3).
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

NO_PASSWORD_WARNING = (
    "Anyone who can open the backup folder can restore every backed-up file, including saved sign-ins. "
    "That includes the folder in Google Drive or on a lost USB drive."
)


def powershell_function(text: str, name: str) -> str:
    start = text.index(f"\nfunction {name} {{\n") + 1
    return text[start : text.index("\n}\n", start) + 3]


class OptionalPasswordInstallerTests(unittest.TestCase):
    """Backups with a password (the default) or without one: what the installer and its plan do about the choice.
    tests/Test-InstallPlan.ps1 runs the helpers themselves; these pin where each piece sits in the scripts."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.installer = read(INSTALLER)
        cls.defined = functions(cls.installer)
        cls.marker = cls.installer.index("if ($PlanOnly) {\n    try {")
        cls.main = cls.installer.split("$preflightSucceeded = $false", 1)[1]
        cls.payload = cls.main.split("Start-InstallPhase 'payload'", 1)[1].split("Complete-InstallPhase 'payload'", 1)[0]
        cls.initialization = cls.main.split("Start-InstallPhase 'canary'", 1)[1].split("Start-InstallPhase 'permissions'", 1)[0]
        cls.catch = cls.main.rsplit("\ncatch {\n", 1)[1].split("\nfinally {\n", 1)[0]

    # --- the parameter ---

    def test_the_non_failing_reader_is_the_same_in_the_installer_and_the_uninstaller(self) -> None:
        installer = powershell_function(self.installer, "Get-RecordedRepositoryAccess")
        uninstaller = powershell_function(read(UNINSTALLER), "Get-RecordedRepositoryAccess")
        self.assertEqual(installer, uninstaller)
        self.assertEqual(GET_RECORDED_REPOSITORY_ACCESS, installer)

    def test_the_resolved_mode_never_shares_a_name_with_the_parameter(self) -> None:
        # PowerShell variable names ignore case, so a script variable called repositoryAccess is the parameter itself, whose
        # value set refuses $null: the resolved mode (null while it is not known) lives in repositoryAccessMode.
        code = re.sub(r"(?m)^\s*#.*$", "", self.installer)
        self.assertEqual([], re.findall(r"(?i)\$(?:script|global|local|private):repositoryaccess(?![a-z])", code))
        self.assertIn("$script:repositoryAccessMode = ", code)

    def test_the_parameter_is_a_value_set_and_its_case_is_checked_in_a_plan_and_before_elevation(self) -> None:
        head = self.installer.split("Set-StrictMode", 1)[0]
        self.assertIn("[ValidateSet('password', 'no_password')]\n    [string]$RepositoryAccess,\n", head)
        check = self.defined["Assert-RepositoryAccessValue"]
        self.assertIn("if (-not $invocationParameters.ContainsKey('RepositoryAccess')) { return }", check)
        self.assertIn("$RepositoryAccess -cnotin @('password', 'no_password')", check)
        self.assertIn("-Code 'repository_access_invalid' -Field 'repository'", check)
        self.assertIn("Invoke-PlanStage -Field 'repository' { Assert-RepositoryAccessValue }", self.defined["Invoke-PlanMode"])
        preflight = self.defined["Invoke-InstallPreflight"]
        self.assertLess(preflight.index("Assert-ScheduleValue"), preflight.index("Assert-RepositoryAccessValue"))
        self.assertLess(preflight.index("Assert-RepositoryAccessValue"), preflight.index("Assert-MicrosoftSignedExecutable"))
        self.assertLess(preflight.index("Assert-RepositoryAccessValue"), preflight.index("Invoke-SelfElevation"))

    def test_self_elevation_forwards_the_parameter_only_when_it_was_given(self) -> None:
        body = self.defined["Invoke-SelfElevation"]
        forward = (
            "if ($invocationParameters.ContainsKey('RepositoryAccess')) {\n"
            "        $arguments += @('-RepositoryAccess', (Quote-ProcessArgument $RepositoryAccess))\n"
            "    }"
        )
        self.assertIn(forward, body)
        self.assertLess(body.index("'-RepositoryStorageMode', (Quote-ProcessArgument $RepositoryStorageMode),"), body.index(forward))
        self.assertLess(body.index(forward), body.index("if ($invocationParameters.ContainsKey('Repository')) {"))

    def test_the_script_variables_start_empty(self) -> None:
        head = self.installer.split("function New-InstallFinding", 1)[0]
        for name in ("repositoryAccessMode", "existingRepositoryAccess", "repositoryAccessSource"):
            self.assertIn(f"$script:{name} = $null\n", head)

    # --- resolving it ---

    def test_the_choice_is_resolved_after_the_backup_folder_and_before_the_sources(self) -> None:
        preflight = self.defined["Invoke-InstallPreflight"]
        self.assertLess(preflight.index("Resolve-RepositorySelection"), preflight.index("Resolve-RepositoryAccess"))
        self.assertLess(preflight.index("Resolve-RepositoryAccess"), preflight.index("Resolve-SourceSelection"))
        plan = self.defined["Invoke-PlanMode"]
        stage = "if ($repositoryOk) {\n        [void](Invoke-PlanStage -Field 'repository' { Resolve-RepositoryAccess })\n    }"
        self.assertIn(stage, plan)
        self.assertLess(plan.index("{ Resolve-RepositorySelection }"), plan.index(stage))
        self.assertLess(plan.index(stage), plan.index("{ Resolve-SourceSelection }"))

    def test_the_plan_reports_the_choice_beside_the_storage_mode_and_the_kept_backups(self) -> None:
        plan = self.defined["Invoke-PlanMode"]
        self.assertIn(
            "            storage_mode = $RepositoryStorageMode\n"
            "            repository_access = $script:repositoryAccessMode\n"
            "            existing_repository_access = $script:existingRepositoryAccess\n",
            plan,
        )
        self.assertIn(
            "kept_repository = if ($null -ne $keptRepository) { $keptRepository.repository } else { $null }\n"
            "                kept_repository_access = if ($null -ne $keptRepository) { $keptRepository.repository_access } else { $null }\n",
            plan,
        )

    def test_the_kept_record_carries_its_access_and_needs_a_stored_password_only_for_a_password(self) -> None:
        reader = self.defined["Get-KeptRepository"]
        self.assertIn("$access = Get-RecordedRepositoryAccess -Record $document\n                if ($null -eq $access) { continue }", reader)
        self.assertIn("repository = [string]$document.repository; storage_mode = $mode; repository_access = $access", reader)
        # The stored password is asked for after the newest record is chosen, and only for a record of backups with a password.
        loop_end = reader.index("# Backups with a password can be carried on only")
        self.assertGreater(loop_end, reader.index("foreach ($record in @("))
        self.assertIn(
            "$kept.repository_access -ceq 'password' -and -not (Test-Path -LiteralPath $secretFile -PathType Leaf)", reader[loop_end:]
        )
        self.assertNotIn("$secretFile", reader[:loop_end])

    def test_the_recorded_access_comes_from_the_kept_record_then_the_recovery_tools_then_the_folder_itself(self) -> None:
        existing = self.defined["Get-ExistingRepositoryAccess"]
        self.assertLess(existing.index("if (-not $repositoryPreviouslyInitialized) { return $null }"), existing.index("Get-KeptRepository"))
        self.assertLess(existing.index("Get-KeptRepository"), existing.index("Get-RecoveryToolsRepositoryAccess"))
        self.assertTrue(existing.rstrip().endswith("return 'unknown'"))
        tools = self.defined["Get-RecoveryToolsRepositoryAccess"]
        for name in ("backup-config.json", "recovery-manifest.json", "Get-RecordedRepositoryAccess", "Test-SameFolderPath"):
            self.assertIn(name, tools)
        self.assertNotIn("throw", tools)

    def test_the_resolution_table_is_followed(self) -> None:
        decision = self.defined["Get-RepositoryAccessDecision"]
        for text in (
            "access = $Given; source = 'parameter'",
            "access = $Existing; source = 'recorded'",
            "access = $null; source = $null",
            "access = 'password'; source = 'default'",
        ):
            self.assertIn(text, decision)
        resolve = self.defined["Resolve-RepositoryAccess"]
        self.assertLess(resolve.index("Assert-RepositoryAccessValue"), resolve.index("Get-ExistingRepositoryAccess"))
        self.assertLess(resolve.index("Get-RepositoryAccessDecision"), resolve.index("Assert-NoPendingKeyChange"))

    def test_a_pending_key_change_only_stops_a_choice_of_no_password(self) -> None:
        check = self.defined["Assert-NoPendingKeyChange"]
        self.assertIn("if ($script:repositoryAccessMode -cne 'no_password') { return }", check)
        self.assertIn("'credential-rotation.journal.json'", check)
        self.assertIn("-Code 'repository_access_rotation_pending' -Field 'repository' -Path $stateRoot", check)

    def test_a_choice_that_contradicts_the_record_is_a_warning_only_when_it_was_given(self) -> None:
        warnings = self.defined["Get-InstallWarnings"]
        self.assertIn("if ($script:repositoryAccessSource -ceq 'parameter') {", warnings)
        self.assertIn("-Code 'repository_access_differs' -Field 'repository'", warnings)
        message = self.defined["Get-RepositoryAccessDifferenceMessage"]
        self.assertIn(
            "The backups in this location were made without a password. If they still open without one, Setup stops before "
            "changing anything. Choose no password to continue them, or choose another location.",
            message,
        )
        self.assertIn(
            "The backups in this location were made with a password. If they still need one, Setup stops before changing "
            "anything. Choose a password to continue them, or choose another location.",
            message,
        )

    # --- the console ---

    def test_the_console_question_comes_last_and_is_never_asked_in_a_plan(self) -> None:
        preflight = self.defined["Invoke-InstallPreflight"]
        order = [
            "Assert-RepositoryTarget", "Get-InstallationConflicts", "Invoke-RepositoryAccessQuestion", "Write-InstallSummary",
            "Read-Host 'Install this configuration? [y/N]'",
        ]
        positions = [preflight.index(name) for name in order]
        self.assertEqual(sorted(positions), positions)
        for name in ("Invoke-RepositoryAccessQuestion", "Read-RepositoryAccessChoice"):
            self.assertGreater(self.installer.index(f"function {name} "), self.marker, name)
        choice = self.defined["Read-RepositoryAccessChoice"]
        self.assertLess(choice.index("if ($PlanOnly -or $Unattended) { return $null }"), choice.index("Read-Host"))
        question = self.defined["Invoke-RepositoryAccessQuestion"]
        self.assertIn("if ($script:repositoryAccessSource -ceq 'default' -and -not $Unattended) {", question)

    def test_the_console_says_the_consequence_before_it_asks(self) -> None:
        warning = self.defined["Get-NoPasswordWarning"]
        self.assertIn(f"'{NO_PASSWORD_WARNING}'", warning)
        choice = self.defined["Read-RepositoryAccessChoice"]
        self.assertLess(choice.index("Get-NoPasswordWarning"), choice.index("Read-Host"))
        self.assertLess(choice.index("You can't change this later for these backups."), choice.index("Read-Host"))
        self.assertIn(
            "Make backups without a password? Type yes for no password, or press Enter to keep the password (recommended)", choice
        )
        self.assertIn("Please type yes or no, or press Enter.", choice)
        question = self.defined["Invoke-RepositoryAccessQuestion"]
        for text in (
            "These backups were made without a password, so Setup keeps them that way.",
            "These backups were made with a password, so Setup keeps them that way.",
            "Setup will check whether these backups have a password and keep them that way.",
        ):
            self.assertIn(text, question)

    def test_the_summary_says_which_kind_of_backups_these_are_before_the_confirmation(self) -> None:
        summary = self.defined["Write-InstallSummary"]
        self.assertIn("Write-Host '  Password   : yes (recommended)'", summary)
        self.assertIn("Write-Host '  Password   : none'\n        Write-Warning (Get-NoPasswordWarning)", summary)
        self.assertIn("Write-Host '  Password   : the same as the backups already in this location'", summary)

    # --- the install ---

    def test_the_program_paths_are_hoisted_and_the_detection_runs_before_the_configuration_is_written(self) -> None:
        for name in ("$python = Join-Path $installRoot 'Python\\python.exe'\n", "$initializer = Join-Path $installRoot 'initialize_repository.py'\n"):
            self.assertEqual(1, self.installer.count("    " + name), name)
        payload = self.payload
        tree = payload.index("Assert-TreeMatchesManifest -Root $installRoot")
        python = payload.index("    $python = Join-Path $installRoot 'Python\\python.exe'")
        initializer = payload.index("    $initializer = Join-Path $installRoot 'initialize_repository.py'")
        detection = payload.index("    if ($null -eq $script:repositoryAccessMode) {\n        Invoke-RepositoryAccessDetection\n    }")
        guard = payload.index("if ($script:repositoryAccessMode -cnotin @('password', 'no_password')) {\n        throw ")
        configuration = payload.index("$configuration = [ordered]@{")
        written = payload.index("Write-Utf8NoBom -Path $configPath")
        manifest = payload.index("New-RuntimeManifest -Root $installRoot")
        self.assertLess(tree, python)
        self.assertLess(python, initializer)
        self.assertLess(initializer, detection)
        self.assertLess(detection, guard)
        self.assertLess(guard, configuration)
        self.assertLess(configuration, written)
        self.assertLess(written, manifest)

    def test_the_detection_is_install_only_and_asks_the_installed_program_in_one_layout(self) -> None:
        self.assertGreater(self.installer.index("function Invoke-RepositoryAccessDetection "), self.marker)
        body = self.defined["Invoke-RepositoryAccessDetection"]
        self.assertIn(
            "    $accessExit = Invoke-ProtectedPython -Python $python -WorkingDirectory $installRoot `\n"
            "        -TemporaryDirectory $script:protectedTemporaryFolder `\n"
            "        -Arguments @('-I', '-S', '-B', $initializer, '--detect-access', '--repository', $repositoryPath, "
            "'--restic', (Join-Path $installRoot 'restic.exe'))\n",
            body,
        )
        self.assertIn("-Code 'repository_access_unreadable' -Field 'repository'", body)
        self.assertEqual(1, self.installer.count("Invoke-RepositoryAccessDetection\n    }"))
        mapping = self.defined["Get-RepositoryAccessFromDetectionExit"]
        for text in (
            "if ($ExitCode -eq 20) { return [pscustomobject]@{ access = 'no_password'; source = 'detected' } }",
            "if ($ExitCode -eq 21) { return [pscustomobject]@{ access = 'password'; source = 'detected' } }",
            "if ($ExitCode -eq 22) { return [pscustomobject]@{ access = 'password'; source = 'default' } }",
        ):
            self.assertIn(text, mapping)
        self.assertTrue(mapping.rstrip().endswith("return $null"))

    def test_the_configuration_names_the_access_right_after_the_storage_mode(self) -> None:
        self.assertIn(
            "        repository_storage_mode = $RepositoryStorageMode\n"
            "        repository_access = $script:repositoryAccessMode\n"
            "        repository_volume_serial = $volume.serial\n",
            self.payload,
        )

    def test_the_phases_skip_the_credential_for_backups_without_a_password(self) -> None:
        block = self.initialization
        skip = block.index("Skip-InstallPhase 'credential' 'No password: this backup opens without one.'")
        self.assertLess(block.index("if ($script:repositoryAccessMode -ceq 'no_password') {"), skip)
        self.assertLess(skip, block.index("Start-InstallPhase 'repository'"))
        self.assertLess(block.index("Start-InstallPhase 'repository'"), block.index("$initializerExit = Invoke-ProtectedPython"))
        self.assertIn("Complete-InstallPhase 'recovery_key' 'This backup has no password, so there is no recovery key.'", block)
        self.assertEqual(1, block.count("$initializerExit = Invoke-ProtectedPython"))
        # The phase titles of a backup without a password are the documented ones, and the other phases keep theirs.
        titles = re.search(r"\$noPasswordPhaseTitles = @\{\n(.*?)\n\}", self.installer, re.S).group(1)
        self.assertEqual(
            [("credential", "Choosing no password"), ("repository", "Creating the backup location"),
             ("recovery_key", "Saving the recovery tools")],
            re.findall(r"^\s+([a-z0-9_]+) = '([^']*)'$", titles, re.M),
        )
        title = self.defined["Get-InstallPhaseTitle"]
        self.assertIn("$script:repositoryAccessMode -ceq 'no_password' -and $noPasswordPhaseTitles.ContainsKey($Phase)", title)
        for name in ("Start", "Complete", "Skip"):
            self.assertIn("-Title (Get-InstallPhaseTitle -Phase $Phase)", self.defined[f"{name}-InstallPhase"])
        self.assertIn("-Title (Get-InstallPhaseTitle -Phase $phase)", self.defined["Write-InstallFailure"])

    def test_the_documented_titles_for_backups_without_a_password_are_the_ones_in_the_script(self) -> None:
        contract = read(CONTRACT)
        section = contract.split("### 3.3 Phases", 1)[1].split("\n### ", 1)[0]
        table = section.split("| Phase | Title for backups without a password |", 1)[1].split("\n\n", 1)[0]
        in_doc = re.findall(r"^\| `([a-z0-9_]+)` \| ([^|]+?) \|$", table, re.M)
        titles = re.search(r"\$noPasswordPhaseTitles = @\{\n(.*?)\n\}", self.installer, re.S).group(1)
        self.assertEqual(re.findall(r"^\s+([a-z0-9_]+) = '([^']*)'$", titles, re.M), in_doc)
        self.assertIn("No password: this backup opens without one.", section)
        self.assertIn("This backup has no password, so there is no recovery key.", section)

    def test_the_initializer_refusals_end_the_install_with_their_own_code(self) -> None:
        block = self.initialization
        mismatch = block.index("if ($initializerExit -eq 4 -or $initializerExit -eq 5) {")
        unreadable = block.index("if ($initializerExit -eq 6) {")
        unavailable = block.index("if ($initializerExit -eq 7) {")
        other = block.index("if ($initializerExit -ne 0) {")
        self.assertLess(mismatch, unreadable)
        self.assertLess(unreadable, unavailable)
        self.assertLess(unavailable, other)
        self.assertIn("-Code 'repository_access_mismatch' -Field 'repository'", block[mismatch:unreadable])
        self.assertIn("-Code 'repository_access_unreadable' -Field 'repository'", block[unreadable:unavailable])
        # Backups with a password that this PC has no saved password for: its own code and words, as a refusal (which no
        # catch-block inference about the phase can turn into something else).
        refusal = block[unavailable:other]
        self.assertIn("-Code 'repository_password_unavailable' -Field 'repository' -Path $repositoryPath", refusal)
        self.assertIn(
            "-Message (Get-RepositoryAccessRefusalMessage -ExitCode $initializerExit -Source $script:repositoryAccessSource)", refusal
        )
        self.assertNotIn("throw", refusal)
        self.assertIn('throw "Repository initialization failed with exit code $initializerExit."', block[other:])

    def test_the_refusal_messages_are_the_designed_ones_and_end_by_saying_nothing_was_touched(self) -> None:
        body = self.defined["Get-RepositoryAccessRefusalMessage"]
        self.assertIn("$ending = ' Setup undid its changes, and your backups were not touched.'", body)
        for text in (
            "The backups in this location are protected by a password, but you chose no password. To continue these backups, "
            "choose a password. To start without one, choose another location.$ending",
            "The backups in this location were made without a password, but you chose a password. To continue these backups, "
            "choose no password. To start with a password, choose another location.$ending",
            "These backups no longer match what Setup recorded for them, usually because they were changed outside Rewindle. "
            "Setup can't carry on with them here. Choose another location, or see Switching an existing backup in SECURITY.md "
            "on Rewindle's GitHub page.$ending",
            "Setup couldn't open the backups in this location to continue them. Check that the backup drive or Google Drive "
            "folder is connected and available, then try again. If they still can't be opened, they may be damaged: choose "
            "another location for new backups, and keep this folder until you've checked it.$ending",
            '"$(Get-PasswordUnavailableMessage)$ending"',
        ):
            self.assertIn(text, body)
        self.assertNotIn("Rewindle's guide", body)
        self.assertIn("if ($ExitCode -eq 7) {", body)
        # Backups with a password whose password this PC doesn't have: the one text of the plan, the preflight and the install.
        self.assertIn(
            "return \"The backups in this location have a password that Rewindle doesn't have on this PC, so Setup can't continue "
            "them. Choose another location for new backups. You can still restore files from these backups with their recovery "
            "key.\"",
            self.defined["Get-PasswordUnavailableMessage"],
        )

    def test_the_contract_quotes_the_refusal_texts_of_the_script(self) -> None:
        contract = read(CONTRACT)
        for text in (
            "These backups no longer match what Setup recorded for them, usually because they were changed outside Rewindle. "
            "Setup can't carry on with them here. Choose another location, or see Switching an existing backup in SECURITY.md "
            "on Rewindle's GitHub page.",
            "Setup couldn't open the backups in this location to continue them. Check that the backup drive or Google Drive "
            "folder is connected and available, then try again. If they still can't be opened, they may be damaged: choose "
            "another location for new backups, and keep this folder until you've checked it.",
            "The backups in this location have a password that Rewindle doesn't have on this PC, so Setup can't continue them. "
            "Choose another location for new backups. You can still restore files from these backups with their recovery key.",
            "Setup could not save the recovery tools.",
        ):
            self.assertIn(text, contract)
        self.assertNotIn("Rewindle's guide", contract)

    def test_backups_with_a_password_this_pc_does_not_have_are_refused_by_the_plan_and_the_preflight(self) -> None:
        check = self.defined["Assert-PasswordAvailable"]
        # A plan runs the check and says the words, so both are defined before plan mode exits (what is defined after it does
        # not exist in a plan, which would end as an internal error).
        for name in ("Assert-PasswordAvailable", "Get-PasswordUnavailableMessage"):
            self.assertLess(self.installer.index(f"function {name} "), self.marker, name)
        # Only a password chosen over backups recorded as having one, in a folder that holds backups, with no stored password.
        self.assertIn(
            "if ($script:repositoryAccessMode -cne 'password' -or $script:existingRepositoryAccess -cne 'password') { return }", check
        )
        self.assertIn("if (-not $repositoryPreviouslyInitialized) { return }", check)
        self.assertIn("if (Test-Path -LiteralPath $secretFile -PathType Leaf) { return }", check)
        self.assertIn("-Code 'repository_password_unavailable' -Field 'repository' -Path $repositoryPath", check)
        self.assertIn("-Message (Get-PasswordUnavailableMessage)", check)
        self.assertNotIn("Get-RepositoryAccessRefusalMessage", check)  # no "Setup undid its changes" before anything was started
        # It runs wherever the choice is resolved: a plan's repository stage and the install's preflight, after the decision.
        resolve = self.defined["Resolve-RepositoryAccess"]
        self.assertLess(resolve.index("Assert-NoPendingKeyChange"), resolve.index("Assert-PasswordAvailable"))
        self.assertIn("Invoke-PlanStage -Field 'repository' { Resolve-RepositoryAccess }", self.defined["Invoke-PlanMode"])
        preflight = self.defined["Invoke-InstallPreflight"]
        self.assertLess(preflight.index("Resolve-RepositoryAccess"), preflight.index("Resolve-ProtectedBindings"))
        self.assertLess(preflight.index("Invoke-SelfElevation"), preflight.index("Resolve-RepositoryAccess"))

    def test_the_catch_block_blames_a_phase_only_for_a_failure_nothing_named(self) -> None:
        self.assertIn(
            "    if ($null -eq (Get-InstallFinding -ErrorRecord $caught) -and\n"
            "        ($script:FeedCurrentPhase -ceq 'credential' -or ($script:repositoryAccessMode -ceq 'no_password' "
            "-and $script:FeedCurrentPhase -ceq 'repository'))) {\n"
            "        Set-InitializationFailurePhase\n    }",
            self.catch,
        )
        body = self.defined["Set-InitializationFailurePhase"]
        branch = body.split("if ($script:repositoryAccessMode -ceq 'no_password') {", 1)[1].split("\n    }\n", 1)[0]
        self.assertNotIn("$secretFile", branch)
        self.assertIn("Join-Path $repositoryPath 'config'", branch)
        self.assertIn("return", branch)
        self.assertLess(body.index("-ceq 'no_password'"), body.index("$secretFile"))

    def test_nothing_about_a_recovery_key_is_checked_or_reported_for_backups_without_a_password(self) -> None:
        bindings = self.defined["Resolve-ProtectedBindings"]
        guard = bindings.index("if ($script:repositoryAccessMode -cne 'no_password') {")
        self.assertLess(guard, bindings.index("Assert-NoReparsePath -Path $recoveryKey"))
        self.assertLess(guard, bindings.index("'recovery_key_path_unsafe'"))
        # A stale key is held against the install only for backups known to have a password.
        self.assertIn("if ($script:repositoryAccessMode -ceq 'password' -and -not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {", bindings)
        self.assertIn(
            "if ($script:repositoryAccessMode -ceq 'no_password' -and $protectedBinding[1] -cin @('DPAPI credential', 'Recovery key')) { continue }",
            bindings,
        )
        facts = self.defined["Get-RecoveryKeyFacts"]
        self.assertLess(facts.index("if ($script:repositoryAccessMode -ceq 'no_password') {"), facts.index("Test-Path -LiteralPath $recoveryKey"))
        verified = self.defined["Assert-InstallationVerified"]
        gate = verified.index("if ($script:repositoryAccessMode -cne 'no_password') {")
        self.assertLess(gate, verified.index("Test-Path -LiteralPath $secretFile"))
        self.assertLess(gate, verified.index("Test-Path -LiteralPath $recoveryKey"))
        # The commit of a kept key stays one call; the readability check and its warning are inside the mode check.
        self.assertEqual(1, self.installer.count("'--commit-recovery-key'"))
        verification = self.main.split("Start-InstallPhase 'verification'", 1)[1].split("Complete-InstallPhase 'verification'", 1)[0]
        mode = verification.index("if ($script:repositoryAccessMode -cne 'no_password') {")
        self.assertLess(mode, verification.index("Test-FileReadableByUser -Path $recoveryKey"))
        self.assertLess(mode, verification.index("recovery_key_not_readable_by_user"))
        self.assertLess(verification.index("'--commit-recovery-key'"), mode)

    def test_the_success_text_and_results_leave_out_the_key_for_backups_without_a_password(self) -> None:
        main = self.main
        self.assertIn(
            "Write-Host 'Rewindle installed successfully. This backup has no password, so there is no recovery key to keep.' "
            "-ForegroundColor Green",
            main,
        )
        self.assertIn("Write-Host \"Recovery key: $recoveryKey\" -ForegroundColor Yellow", main)
        self.assertIn("$resultRecoveryKey = if ($script:repositoryAccessMode -ceq 'no_password') { $null } else { $recoveryKey }", main)
        self.assertIn(
            "        repository_storage_mode = $RepositoryStorageMode\n        repository_access = $script:repositoryAccessMode\n"
            "        source_count = $configuredSources.Count",
            main,
        )
        self.assertIn("        recovery_key_file = $resultRecoveryKey\n", main)
        self.assertIn("        recovery_key_path = $resultRecoveryKey\n", main)
        # Every result the install writes carries the access right after the version and before the warnings.
        self.assertEqual(
            3,
            len(re.findall(r"version = \$(?:script:)?version\n\s+repository_access = \$script:repositoryAccessMode\n\s+warnings = ", self.installer)),
        )
        self.assertIn("-Description 'Verified incremental Restic backup supervised by ResticBackuper.'", main)
        self.assertNotIn("Verified encrypted", self.installer)

    def test_the_failure_tails_keep_their_wording_for_backups_with_a_password(self) -> None:
        failure = self.defined["Write-InstallFailure"]
        # Backups with a password: both tails exactly as before.
        self.assertIn(
            "Reinstall or repair, which removes them first. $keptTail\"", failure
        )
        self.assertIn("'Backups and the recovery key it had already created were kept.'", failure)
        self.assertIn("$message += ' Setup undid its changes. Backups and the recovery key it had already created were kept.'", failure)
        # Without a password, or when it is not known, there is no key to mention.
        self.assertIn("'Backups it had already created were kept.'", failure)
        self.assertIn("$message += ' Setup undid its changes. Backups it had already created were kept.'", failure)
        self.assertIn("elseif ($script:repositoryAccessMode -ceq 'password') { 'Backups and the recovery key", failure)
        # The refusals bring their own ending, and the repository phase's default is not about an encrypted place.
        self.assertIn(
            "$refusal = ($code -ceq 'repository_access_mismatch' -or $code -ceq 'repository_access_unreadable' "
            "-or $code -ceq 'repository_password_unavailable')",
            failure,
        )
        self.assertIn("if ($phase -ceq 'repository' -and $script:repositoryAccessMode -cne 'password') {", failure)
        self.assertIn("$message = 'Setup could not create the backup location.'", failure)
        # Nor does the recovery key phase name a key that backups without a password (or of an unknown kind) do not have; the
        # table keeps the words for backups with a password.
        self.assertIn("elseif ($phase -ceq 'recovery_key' -and $script:repositoryAccessMode -cne 'password') {", failure)
        self.assertIn("$message = 'Setup could not save the recovery tools.'", failure)
        self.assertIn("recovery_key = @('recovery_key_failed', 'Setup could not write your recovery key.')", self.installer)
        write_error = self.catch.split('Write-Error "INSTALLATION FAILED: ', 1)[0]
        self.assertIn("if ($script:repositoryAccessMode -ceq 'password') { 'Repository, recovery key, recovery tools, and ProgramData state' }", write_error)


class OptionalPasswordUninstallerTests(unittest.TestCase):
    """What an uninstall reports and says about backups with and without a password."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = read(UNINSTALLER)
        cls.defined = functions(cls.text)

    def test_the_kept_data_reports_the_access_and_a_key_only_for_backups_with_a_password(self) -> None:
        body = self.defined["Get-KeptData"]
        self.assertIn("        repository = $null\n        repository_access = $null\n        recovery_key = $null\n", body)
        self.assertIn("$kept['repository_access'] = Get-RecordedRepositoryAccess -Record $script:configuration", body)
        gate = body.index("if ($kept['repository_access'] -ceq 'password') {")
        self.assertLess(gate, body.index("$kept['recovery_key'] = [string]$script:configuration.recovery_key_file"))
        self.assertEqual(1, body.count("recovery_key_file"))

    def test_the_console_names_a_recovery_key_only_for_backups_with_a_password(self) -> None:
        main = self.text.split("$progressOpened = $false", 1)[1]
        for line in ('Write-Host "  Recovery key: $($configuration.recovery_key_file) (preserved)"',
                     'Write-Host "Preserved recovery key: $($configuration.recovery_key_file)"'):
            before = main[: main.index(line)]
            self.assertTrue(before.rstrip().endswith("if ($keptAccess -ceq 'password') {"), line)
        self.assertEqual(2, main.count("elseif ($keptAccess -ceq 'no_password') {"))
        self.assertEqual(1, main.count("Write-Host '  Backups have no password, so there is no recovery key.'"))
        self.assertEqual(1, main.count("Write-Host 'Backups have no password, so there is no recovery key.'"))

    @unittest.skipUnless(os.name == "nt", "runs Windows PowerShell 5.1")
    def test_the_kept_data_is_read_without_failing_from_every_shape_of_configuration(self) -> None:
        reader = powershell_function(self.text, "Get-RecordedRepositoryAccess")
        kept = powershell_function(self.text, "Get-KeptData")
        script = (
            "Set-StrictMode -Version Latest\n$ErrorActionPreference = 'Stop'\n"
            "$stateRoot = 'C:\\Fixture\\State'\n$cloudVerificationRoot = 'C:\\Fixture\\NoSuchFolder\\Cloud'\n"
            + reader + "\n" + kept + "\n"
            "function New-Shape {\n"
            "    param([bool]$Has, [object]$Access)\n"
            "    $fields = [ordered]@{ repository = 'D:\\Backups'; recovery_key_file = 'C:\\Users\\you\\key.txt'; "
            "recovery_tools_directory = 'D:\\RecoveryTools' }\n"
            "    if ($Has) { $fields['repository_access'] = $Access }\n"
            "    return [pscustomobject]$fields\n"
            "}\n"
            "$shapes = [ordered]@{ absent = (New-Shape $false $null); password = (New-Shape $true 'password'); "
            "no_password = (New-Shape $true 'no_password'); bogus = (New-Shape $true 'Password'); number = (New-Shape $true 7) }\n"
            "$results = [ordered]@{}\n"
            "foreach ($name in $shapes.Keys) {\n"
            "    $script:configuration = $shapes[$name]\n"
            "    $data = Get-KeptData\n"
            "    $results[$name] = [ordered]@{ access = $data['repository_access']; key = $data['recovery_key']; "
            "keys = @($data.Keys) -join ',' }\n"
            "}\n"
            "$script:configuration = $null\n$empty = Get-KeptData\n"
            "$results['no configuration'] = [ordered]@{ access = $empty['repository_access']; key = $empty['recovery_key']; "
            "keys = @($empty.Keys) -join ',' }\n"
            "$results | ConvertTo-Json -Depth 4 -Compress\n"
        )
        completed = run_windows_powershell(script)
        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
        results = json.loads([line for line in completed.stdout.splitlines() if line.strip()][-1])
        key = "C:\\Users\\you\\key.txt"
        self.assertEqual("password", results["absent"]["access"])
        self.assertEqual(key, results["absent"]["key"])
        self.assertEqual("password", results["password"]["access"])
        self.assertEqual(key, results["password"]["key"])
        self.assertEqual("no_password", results["no_password"]["access"])
        self.assertIsNone(results["no_password"]["key"])
        for shape in ("bogus", "number", "no configuration"):
            with self.subTest(shape=shape):
                self.assertIsNone(results[shape]["access"])
                self.assertIsNone(results[shape]["key"])
        self.assertEqual(
            "state_root,repository,repository_access,recovery_key,recovery_tools,cloud_verification_root", results["absent"]["keys"]
        )


def windows_powershell() -> str:
    system = os.environ.get("SystemRoot", r"C:\Windows")
    return os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def run_windows_powershell(script: str) -> "subprocess.CompletedProcess[str]":
    """Runs `script` in Windows PowerShell 5.1 with no window, standard input closed and the module path pinned."""
    system = os.environ.get("SystemRoot", r"C:\Windows")
    environment = dict(os.environ)
    environment["PSModulePath"] = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "Modules")
    with tempfile.TemporaryDirectory(prefix="rewindle-setup-contract-probe-", ignore_cleanup_errors=True) as temp:
        path = Path(temp) / "probe.ps1"
        path.write_text(script, encoding="ascii", newline="\n")
        return subprocess.run(
            [windows_powershell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(path)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=240, env=environment,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )


class ContinuousIntegrationTests(unittest.TestCase):
    def test_ci_runs_the_hermetic_plan_suite_and_the_real_install_test(self) -> None:
        ci = read(CI)
        self.assertIn(r".\tests\Test-InstallPlan.ps1", ci)
        self.assertIn(r".\tests\Test-InstallerContract.ps1 -AllowSystemInstall", ci)
        self.assertLess(ci.index("Test-InstallPlan.ps1"), ci.index("Test-InstallerContract.ps1"))
        # The real install needs the release the build step produces.
        self.assertLess(ci.index("Build-Release.ps1"), ci.index("Test-InstallerContract.ps1"))

    def test_the_real_install_test_refuses_to_run_outside_hosted_ci(self) -> None:
        text = read(CONTRACT_TEST)
        guard = text.index("GITHUB_ACTIONS")
        self.assertIn("[switch]$AllowSystemInstall", text)
        self.assertIn("-ne 'true'", text[guard : guard + 80])
        for dangerous in ("New-LocalUser", "Start-Process", "ExtractToDirectory", "Add-LocalGroupMember", "Install-ResticBackuper.ps1"):
            self.assertGreater(text.index(dangerous), guard, f"{dangerous} appears before the CI guard")
        self.assertIn("RUNNER_ENVIRONMENT", text)
        self.assertIn("github-hosted", text)

    def test_ci_checks_backups_without_a_password_with_the_pinned_restic(self) -> None:
        ci = read(CI)
        command = "python -m unittest -v tests.test_repository_access_restic"
        self.assertEqual(1, ci.count(command))
        self.assertTrue((PROJECT / "tests" / "test_repository_access_restic.py").is_file())
        step = ci[: ci.index(command) + len(command)].rsplit("      - name: ", 1)[1]
        self.assertTrue(step.startswith("Check backups without a password with the pinned Restic\n"), step)
        # Like the other pinned-restic steps: only after the release is built, even when an earlier check failed, and a
        # missing restic.exe fails the step instead of skipping the checks.
        self.assertIn("if: ${{ !cancelled() && steps.build.outcome == 'success' }}", step)
        self.assertIn('REWINDLE_REQUIRE_PINNED_RESTIC: "1"', step)
        self.assertIn("shell: pwsh", step)
        self.assertLess(ci.index("Build-Release.ps1"), ci.index(command))
        # It comes after the steps that need the release, so a failure in it hides no other check.
        self.assertLess(ci.index("python -m unittest -v tests.test_generation_parent"), ci.index(command))

    def test_the_real_install_test_covers_backups_without_a_password(self) -> None:
        text = read(CONTRACT_TEST)
        # The second cycle installs backups without a password; the first, which has the checks that run once, keeps its
        # password so the refusal of a switch is shown against real backups with one.
        self.assertIn("[switch]$NoPassword", text)
        cycle_one = re.search(r"Invoke-InstallCycle -Id 'cycle1'(?:[^\n]*`\n)*[^\n]*", text)
        cycle_two = re.search(r"Invoke-InstallCycle -Id 'cycle2'(?:[^\n]*`\n)*[^\n]*", text)
        self.assertIsNotNone(cycle_one)
        self.assertIsNotNone(cycle_two)
        self.assertIn("-Extras", cycle_one.group(0))
        self.assertNotIn("-NoPassword", cycle_one.group(0))
        self.assertIn("-NoPassword", cycle_two.group(0))
        self.assertIn("if ($NoPassword) { $arguments += @('-RepositoryAccess', 'no_password') }", text)
        # What the install feed and result say for backups without a password, and for a password.
        for expected in (
            "'skipped', 'Choosing no password', 'No password: this backup opens without one.'",
            "'Creating the backup location'",
            "'Saving the recovery tools', 'This backup has no password, so there is no recovery key.'",
            "'Creating the backup password and storing it for your account'",
            "'Creating the encrypted backup location'",
            "'Writing your recovery key'",
            "if ($NoPassword) { $skipped += 'credential' }",
            "Assert-Equal $access $result.repository_access",
            "Assert-Equal $access $configuration.repository_access",
            "Assert-Equal $access $recoveryManifest.repository_access",
            "Assert-Equal $access $uninstallResult.kept.repository_access",
            "'version', 'repository_access', 'warnings'",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, text)
        # How the installed program tells the two kinds of backups, and that nothing of the password is made, kept or lost.
        self.assertIn("--detect-access", text)
        for exit_code, meaning in ((20, "have no password"), (21, "have a password"), (22, "holds no backups")):
            with self.subTest(exit_code=exit_code):
                self.assertRegex(text, rf"Assert-Equal {exit_code} \(Get-DetectionExit -Folder [^\n]*{meaning}")
        self.assertIn("--insecure-no-password", text)
        self.assertIn("'--password-command' not in command", text)
        self.assertIn("$seededSecretHash", text)
        self.assertIn("$seededKeyHash", text)
        self.assertIn("an older stored password is exactly as it was", text)
        self.assertIn("an older recovery key is exactly as it was", text)

    def test_the_real_install_test_refuses_a_switch_and_reinstalls_without_a_choice(self) -> None:
        text = read(CONTRACT_TEST)
        refusal = text.index("-Name 'install-no-password-over-password'")
        block = text[refusal : text.index("# A reinstall over the state the uninstall kept", refusal)]
        # Asking for no password over backups with a password is refused in the repository phase with the code and the
        # words the contract documents, and the backups, the stored password and the key are exactly as they were.
        self.assertIn("$argumentsWithoutChoice + @('-RepositoryAccess', 'no_password')", block)
        self.assertIn("Assert-Equal 'repository_access_mismatch' $refusedResult.error.code", block)
        self.assertIn("'repository:failed'", block)
        self.assertIn("The backups in this location are protected by a password, but you chose no password.", block)
        self.assertIn("Setup undid its changes, and your backups were not touched.", block)
        for kept in ("Get-FolderFingerprint -Path $Repository", "$secretBefore", "$keyBefore"):
            self.assertIn(kept, block)
        self.assertIn("(-not (Test-Path -LiteralPath $installRoot))", block)
        # A reinstall with no choice given keeps backups without a password, known from the kept record and then from the
        # backups themselves (the kept state and the recovery tools are gone by then).
        rounds = text[text.index("$laterArguments = $argumentsWithoutChoice") :]
        rounds = rounds[: rounds.index("# Leave a clean machine for the next cycle")]
        self.assertIn("Name = 'recorded'; Wipe = $false; Detail = ' They have no password.'", rounds)
        self.assertIn("Name = 'detected'; Wipe = $true; Detail = ' They have no password, so Setup kept that.'", rounds)
        self.assertIn("Remove-Item -LiteralPath $stateRoot -Recurse -Force", rounds)
        self.assertIn("Remove-Item -LiteralPath $uninstallResult.kept.recovery_tools -Recurse -Force", rounds)
        self.assertIn("Assert-Equal 'no_password' $roundResult.repository_access", rounds)
        self.assertIn("Assert-Equal 'skipped' $roundCredential.state", rounds)
        self.assertIn("Your existing backups in this location were kept and reused.", rounds)
        self.assertNotIn("-RepositoryAccess", rounds)
        # The summary names both new checks, and the clean-up copes with a cycle that made no recovery key.
        self.assertIn("install_without_password = 'passed'", text)
        self.assertIn("existing_backups_never_switched = 'passed'", text)
        self.assertIn("if ($null -ne $result.recovery_key_path) { Remove-Item -LiteralPath $result.recovery_key_path -Force }", text)
        # The first cycle's password and key are brought back for the second, which must leave them exactly as they were.
        self.assertIn("$script:olderSecret = [IO.File]::ReadAllBytes(", text)
        self.assertIn("$script:olderKey = [IO.File]::ReadAllBytes($result.recovery_key_path)", text)

    def test_the_hermetic_suite_never_starts_an_install(self) -> None:
        text = read(PROJECT / "tests" / "Test-InstallPlan.ps1")
        for line in text.splitlines():
            if "-File" in line and "Install-ResticBackuper.ps1" in line:
                self.assertIn("'-PlanOnly'", line)
        self.assertNotIn("Uninstall-ResticBackuper.ps1", re.sub(r"#.*", "", text))
        self.assertNotIn("-Unattended", re.sub(r"#.*", "", text))
        self.assertNotIn("Register-ScheduledTask", text)


if __name__ == "__main__":
    unittest.main()
