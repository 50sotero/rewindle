"""Static checks that keep the installer's machine-readable backend, its contract and its tests in step.

The behaviour itself is exercised by tests/Test-InstallPlan.ps1 (hermetic) and tests/Test-InstallerContract.ps1 (a real
install, hosted CI runner only). These checks need no PowerShell: they read the scripts, docs/setup-contract.md and ci.yml.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / "installer" / "Install-ResticBackuper.ps1"
UNINSTALLER = PROJECT / "installer" / "Uninstall-ResticBackuper.ps1"
CONTRACT = PROJECT / "docs" / "setup-contract.md"
CI = PROJECT / ".github" / "workflows" / "ci.yml"
CONTRACT_TEST = PROJECT / "tests" / "Test-InstallerContract.ps1"

REGION = re.compile(r"# region progress-feed.*?# endregion progress-feed", re.S)


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
            "Get-KeptRepository",
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
        self.assertEqual(["rewindle", "legacy_personal_edition", "kept_repository"], list(plan["environment"]["existing_install"]))
        phase, result = documents[1], documents[2]
        self.assertEqual(["schema", "seq", "time", "type", "phase", "state", "title", "detail"], list(phase))
        self.assertEqual(
            ["schema", "seq", "time", "type", "ok", "error", "install_root", "recovery_key_path", "recovery_key_readable_by_user",
             "dashboard_executable", "version", "warnings"],
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
        for name in ("install_root", "recovery_key_path", "recovery_key_readable_by_user", "dashboard_executable", "version", "warnings"):
            self.assertIn(name, self.contract)
            self.assertIn(f"{name} = ", self.installer)
        for name in ("operation", "removed", "kept", "state_root", "cloud_verification_root"):
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
        self.assertEqual(["rewindle", "legacy_personal_edition", "kept_repository"], re.findall(r"^\s+(\w+) = ", existing, re.M))
        reader = defined["Get-KeptRepository"]
        # It reads the three records, needs the stored password, never throws and never raises a finding.
        for name in ("'repository.json'", "'last-success.json'", "'status.json'", "$secretFile"):
            self.assertIn(name, reader)
        self.assertTrue(reader.lstrip().startswith("try {"))
        for finding in ("Stop-InstallValidation", "New-InstallFinding", "Add-PlanFinding", "throw"):
            self.assertNotIn(finding, reader)
        self.assertIn("`environment.existing_install.kept_repository`", self.contract)
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
