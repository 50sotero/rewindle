"""Source checks for Rewindle Setup: the wizard (web), its desktop host (C#) and the build that joins them.

They read files and run nothing: no setup program, installer or backup is started. The host's logic is exercised by
tests/Test-SetupHost.ps1, and the real window by tests/Test-SetupWindow.ps1 (a developer tool, not run here).
"""

from __future__ import annotations

from html import unescape
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SETUP = PROJECT / "installer" / "setup"
WEB = PROJECT / "src" / "dashboard" / "web"
WIZARD = WEB / "src" / "setup"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class BridgeContractTests(unittest.TestCase):
    """The page and the host keep one list of commands and one list of events."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.bridge_ts = read(WIZARD / "bridge.ts")
        cls.protocol_cs = read(SETUP / "BridgeProtocol.cs")
        cls.mock = read(WIZARD / "mock" / "mockSetupBridge.ts")

    def page_commands(self) -> set[str]:
        union = re.search(r"export type SetupCommand =(.*?);", self.bridge_ts, re.S)
        self.assertIsNotNone(union)
        return set(re.findall(r"'(\w+)'", union.group(1)))

    def host_commands(self) -> set[str]:
        block = re.search(r"Commands =\s*\{(.*?)\};", self.protocol_cs, re.S)
        self.assertIsNotNone(block)
        return set(re.findall(r'"(\w+)"', block.group(1)))

    def test_the_page_and_the_host_name_the_same_commands(self) -> None:
        self.assertEqual(self.page_commands(), self.host_commands())

    def test_every_command_has_a_handler_in_the_host_and_in_the_sample(self) -> None:
        bridge = read(SETUP / "SetupBridge.cs")
        for command in self.host_commands():
            with self.subTest(command=command):
                self.assertIn(f'case "{command}":', bridge)
                self.assertIn(f"case '{command}':", self.mock)

    def test_the_page_only_asks_for_commands_it_may_use(self) -> None:
        used: set[str] = set()
        for path in WIZARD.rglob("*.ts*"):
            if "mock" in path.parts:
                continue
            used |= set(re.findall(r"""(?:request|requestRaw)(?:<[^>]*>)?\(\s*'(\w+)'""", read(path)))
        self.assertTrue(used, "no bridge requests were found in the wizard")
        self.assertLessEqual(used, self.page_commands())

    def test_events_the_host_sends_are_the_events_the_page_reads(self) -> None:
        union = re.search(r"export type HostEvent =(.*?);\s*\n\nexport", self.bridge_ts, re.S)
        self.assertIsNotNone(union)
        page_events = set(re.findall(r"event: '(\w+)'", union.group(1)))
        host = read(SETUP / "SetupBridge.cs") + read(SETUP / "SetupOperation.cs")
        host_events = set(re.findall(r'[Ee]mit\("(\w+)"', host))
        self.assertEqual(page_events, host_events)

    def test_the_protocol_version_matches(self) -> None:
        self.assertRegex(self.protocol_cs, r"Version = 1;")
        self.assertIn("protocol: 1", self.mock)

    def test_message_size_and_id_limits_are_enforced_before_a_command_runs(self) -> None:
        for marker in ("MaximumMessageLength", "IdPattern", "IsCommand(command)", "WebPolicy.IsAllowedUri(args.Source)"):
            with self.subTest(marker=marker):
                self.assertIn(marker, self.protocol_cs + read(SETUP / "SetupWindow.cs"))


class InstallerContractTests(unittest.TestCase):
    """The host builds the installer's command line from the contract's parameter names."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = read(SETUP / "InstallerContract.cs")
        cls.installer = read(PROJECT / "installer" / "Install-ResticBackuper.ps1")
        cls.uninstaller = read(PROJECT / "installer" / "Uninstall-ResticBackuper.ps1")

    def test_the_arguments_are_named_as_in_the_contract(self) -> None:
        for flag in (
            "-PlanOnly", "-PlanOutput", "-Repository", "-RepositoryStorageMode", "-DriveFsMyDriveRoot", "-RepositoryAccess", "-SourceList",
            "-Schedule", "-DisableVss", "-Unattended", "-ExpectedUserSid", "-ProgressPath", "-StartBackup",
        ):
            with self.subTest(flag=flag):
                self.assertIn(f'"{flag}"', self.contract)

    def test_parameters_the_installer_already_has_are_the_ones_the_host_passes(self) -> None:
        param_block = self.installer[: self.installer.index("Set-StrictMode")]
        for name in ("Repository", "RepositoryStorageMode", "DriveFsMyDriveRoot", "RepositoryAccess", "SourceList", "Schedule", "DisableVss", "StartBackup", "Unattended", "ExpectedUserSid"):
            with self.subTest(parameter=name):
                self.assertRegex(param_block, rf"\${name}\b")
        # The three parameters the contract adds are written by the installer's own change; when it has one it must have all three.
        added = [name for name in ("PlanOnly", "PlanOutput", "ProgressPath") if re.search(rf"\${name}\b", param_block)]
        self.assertIn(len(added), (0, 3), f"the installer has only some of the contract's new parameters: {added}")

    def test_the_schema_names_are_the_contracts(self) -> None:
        self.assertIn('"Rewindle.InstallPlan.v1"', self.contract)
        self.assertIn('"Rewindle.InstallProgress.v1"', self.contract)
        self.assertIn("'Rewindle.InstallPlan.v1'", read(WIZARD / "contract.ts"))
        self.assertIn("'Rewindle.InstallProgress.v1'", read(WIZARD / "contract.ts"))

    def test_the_phases_the_wizard_lists_are_the_contracts(self) -> None:
        contract_ts = read(WIZARD / "contract.ts")

        def table(name: str) -> list[str]:
            block = re.search(rf"export const {name}[^=]*=\s*\[(.*?)\n\];", contract_ts, re.S)
            self.assertIsNotNone(block, name)
            return re.findall(r"\{ id: '(\w+)', title:", block.group(1))

        # The order the installer emits them in (docs/setup-contract.md, section 3.3): the restore test file comes before the password and
        # the folders are locked last of the steps that write.
        self.assertEqual(
            ["preflight", "webview2", "payload", "canary", "credential", "repository", "recovery_key", "permissions", "tasks", "dashboard", "verification", "first_backup"],
            table("INSTALL_PHASES"),
        )
        self.assertEqual(
            ["preflight", "stop", "tasks", "program_files", "shortcut", "registration", "verification"],
            table("UNINSTALL_PHASES"),
        )

    def test_a_reinstall_stops_on_entries_the_uninstaller_kept(self) -> None:
        # The codes the wizard treats as "kept, so a new setup won't run" are the uninstaller's own.
        codes = re.search(r"KEPT_ENTRY_WARNINGS = \[([^\]]*)\]", read(WIZARD / "contract.ts")).group(1)
        uninstaller = read(PROJECT / "installer" / "Uninstall-ResticBackuper.ps1")
        for code in re.findall(r"'(\w+)'", codes):
            self.assertIn(f"-Code '{code}'", uninstaller)
        # The removal half of a reinstall looks at them before it clears the result and starts the steps again.
        wizard = read(WIZARD / "useWizard.ts")
        stop = wizard.index("if (reinstalling.current && keptEntriesOf(removal).length > 0)")
        self.assertLess(stop, wizard.index("void startRef.current(removal?.kept?.repository"))
        self.assertIn("setScreen('uninstalled')", wizard[stop:stop + 600])

    def test_install_scans_the_chosen_folders_once_more_first(self) -> None:
        # The installer's own last check doesn't look for online-only files, so Install (and Try again) scans the folders again
        # and starts the installer only when that scan found none.
        wizard = read(WIZARD / "useWizard.ts")
        self.assertIn("install: installAfterCheck,", wizard)
        check = wizard.index("const installAfterCheck = useCallback(")
        self.assertIn("actions.recheckFolders(selectedPaths(choices))", wizard[check:check + 400])
        wait = wizard.index("if (selectedTotal(choices, sizes).measuring) return;")
        found = wizard.index("if (onlineOnlyPaths(choices, sizes).length > 0)", wait)
        self.assertLess(found, wizard.index("void runOperation('install');", found))
        self.assertNotIn("install: () => runOperation('install')", wizard)

    def test_no_command_line_is_built_by_joining_text(self) -> None:
        for path in SETUP.glob("*.cs"):
            text = read(path)
            if path.name == "ElevatedBootstrap.cs":
                # The bootstrap's PowerShell body is checked on its own (test_the_bootstrap_runs_only_the_checked_command_line).
                text = re.sub(r'private const string Body =\s*@"(?:[^"]|"")*";', "", text)
            for match in re.finditer(r"\.Arguments\s*=\s*([^;]+);", text):
                with self.subTest(file=path.name, expression=match.group(1)[:60]):
                    expression = match.group(1)
                    # Arguments are only ever made by CommandLine.Join/Quote from an argument array, or are a fixed string.
                    self.assertTrue(
                        "CommandLine." in expression or re.fullmatch(r'\s*"[^"+]*"\s*', expression),
                        f"{path.name}: {expression}",
                    )

    def test_the_bootstrap_runs_only_the_checked_command_line(self) -> None:
        bootstrap = read(SETUP / "ElevatedBootstrap.cs")
        body = re.search(r'private const string Body =\s*@"((?:[^"]|"")*)";', bootstrap).group(1).replace('""', '"')
        # The argument file holds the script's own arguments as one command line made by CommandLine.Join, never other text.
        self.assertIn("CommandLine.Join(scriptArguments)", bootstrap)
        # The bootstrap's command line is a fixed prefix, the staged script and that file's text, read only after its hash matched,
        # and the script and manifest copies are checked before anything runs.
        arguments = re.findall(r"\$start\.Arguments = (.+)", body)
        self.assertEqual(
            ["'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"' + (Join-Path $stage $scriptPath) + '\" ' + "
             "[IO.File]::ReadAllText($argumentCopy, (New-Object System.Text.UTF8Encoding($false)))"],
            arguments,
        )
        self.assertLess(body.index("-cne $checks[$relative]"), body.index("$start.Arguments"))
        self.assertLess(body.index("(Get-Sha256 $argumentCopy) -cne $argumentHash"), body.index("$start.Arguments"))
        self.assertLess(body.index("CreateDirectory($candidate, $security)"), body.index("Copy-Staged (Join-Path $source"))
        self.assertIn("SetAccessRuleProtection($true, $false)", body)
        self.assertIn("ReparsePoint", body)

    def test_the_host_never_names_the_installer_script_from_the_page(self) -> None:
        bridge = read(SETUP / "SetupBridge.cs")
        self.assertNotIn("Json.String(request.Payload, \"script", bridge)
        self.assertIn("environment.InstallScriptPath", bridge)


class HostHardeningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window = read(SETUP / "SetupWindow.cs")
        cls.manifest = read(SETUP / "app.manifest")
        cls.assembly = read(SETUP / "AssemblyInfo.cs")

    def test_the_web_view_is_locked_down_like_the_dashboards(self) -> None:
        for marker in (
            "AreDevToolsEnabled = false",
            "AreDefaultContextMenusEnabled = false",
            "AreDefaultScriptDialogsEnabled = false",
            "AreBrowserAcceleratorKeysEnabled = false",
            "IsGeneralAutofillEnabled = false",
            "IsPasswordAutosaveEnabled = false",
            "NewWindowRequested",
            "DownloadStarting",
            "PermissionRequested",
            "LaunchingExternalUriScheme",
            "ServerCertificateErrorDetected",
            "AddWebResourceRequestedFilter(\"*\"",
            "WebPolicy.IsAllowedUri(args.Uri)",
            "AllowExternalDrop = false",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, self.window)

    def test_the_only_address_the_web_view_loads_is_the_virtual_host(self) -> None:
        self.assertEqual(1, len(re.findall(r"\.Navigate\(", self.window)))
        self.assertIn("core.Navigate(WebPolicy.PageAddress)", self.window)
        self.assertNotIn("DevToolsProtocol", self.window)
        for path in SETUP.glob("*.cs"):
            self.assertNotIn("OpenDevToolsWindow", read(path))

    def test_the_wizard_pages_are_served_from_memory(self) -> None:
        # No folder in the person's temporary folder is mapped to the origin the bridge trusts: every request is answered from
        # the copy read into memory from this program's own resources.
        self.assertNotIn("SetVirtualHostNameToFolderMapping", self.window)
        self.assertIn("workspace.Web.TryGet(new Uri(address).AbsolutePath, out content, out contentType)", self.window)
        workspace = read(SETUP / "SetupWorkspace.cs")
        self.assertIn("content = WebContent.Read(resource);", workspace)
        self.assertNotIn("SafeZip.Extract(resource, WebFolder)", workspace)
        self.assertIn("workspace.ReadWeb();", read(SETUP / "Program.cs"))

    def test_the_wizard_page_has_a_strict_content_security_policy(self) -> None:
        page = read(WEB / "setup.html")
        policy = re.search(r'Content-Security-Policy" content="([^"]+)"', page)
        self.assertIsNotNone(policy)
        for directive in ("default-src 'self'", "script-src 'self'", "connect-src 'self'", "object-src 'none'", "frame-src 'none'", "base-uri 'none'", "form-action 'none'"):
            self.assertIn(directive, policy.group(1))
        self.assertNotIn("unsafe-eval", policy.group(1))
        self.assertNotRegex(policy.group(1), r"https?:")

    def test_the_program_runs_as_the_user_and_is_per_monitor_dpi_aware(self) -> None:
        self.assertIn('requestedExecutionLevel level="asInvoker"', self.manifest)
        self.assertNotIn("requireAdministrator", self.manifest)
        self.assertIn("PerMonitorV2", self.manifest)
        self.assertIn("longPathAware", self.manifest)
        self.assertIn('assemblyIdentity version="0.0.0.0"', self.manifest)
        self.assertIn('TargetFramework(".NETFramework,Version=v4.8"', self.assembly)

    def test_only_the_window_file_needs_the_webview_libraries(self) -> None:
        """Program.Main sets up the assembly resolver before any code that names a WebView2 type is compiled."""
        for path in SETUP.glob("*.cs"):
            uses = "using Microsoft.Web.WebView2" in read(path)
            with self.subTest(file=path.name):
                if path.name == "SetupWindow.cs":
                    self.assertTrue(uses)
                else:
                    self.assertFalse(uses, f"{path.name} names a WebView2 type")
        program = read(SETUP / "Program.cs")
        self.assertLess(program.index("WebViewLibraries.Install"), program.index("RunWindow(workspace)"))
        self.assertIn("MethodImplOptions.NoInlining", program)

    def test_the_elevated_start_is_one_runas_with_a_hidden_window_and_no_shell_text(self) -> None:
        operation = read(SETUP / "SetupOperation.cs")
        self.assertEqual(1, len(re.findall(r'Verb = "runas"', operation)))
        self.assertIn("ProcessWindowStyle.Hidden", operation)
        # A script from the unpacked bundle is wrapped in the protected bootstrap; either way the line is CommandLine.Join's.
        self.assertIn("bundle == null ? powershellArguments : ElevatedBootstrap.Wrap(powershellArguments, bundle)", operation)
        self.assertIn("CommandLine.Join(arguments)", operation)
        self.assertIn("1223", operation)

    def test_the_microsoft_bootstrapper_is_checked_before_it_is_run(self) -> None:
        runtime = read(SETUP / "WebViewRuntime.cs")
        self.assertIn("https://go.microsoft.com/fwlink/p/?LinkId=2124703", runtime)
        self.assertIn("https://go.microsoft.com/fwlink/p/?LinkId=2124703", read(PROJECT / "installer" / "Install-ResticBackuper.ps1"))
        # Held open from the check to the run, and checked and run by its resolved path, so what runs is what was checked.
        hold = runtime.index("using (FileStream held = Hold(bootstrapper, out resolved))")
        check = runtime.index("IsSignedByMicrosoft(resolved, held.SafeFileHandle")
        self.assertLess(hold, check)
        self.assertLess(check, runtime.index("Run(resolved)"))
        self.assertNotIn("Run(bootstrapper)", runtime)
        self.assertIn("held = HeldFile.Open(path);", runtime)
        held = read(SETUP / "HeldFile.cs")
        self.assertIn("new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)", held)
        self.assertIn("GetFinalPathNameByHandle", held)
        self.assertIn("WinVerifyTrust", runtime)

    def test_the_webview_libraries_are_held_and_checked_before_they_are_loaded(self) -> None:
        workspace = read(SETUP / "SetupWorkspace.cs")
        hold = workspace.index("private void HoldLibrary(")
        body = workspace[hold:workspace.index("\n        }\n", workspace.index("catch\n", hold))]
        # Written, then held, then compared with this program's own copy through the held handle.
        self.assertLess(body.index("FileMode.CreateNew"), body.index("HeldFile.Open(destination)"))
        self.assertLess(body.index("HeldFile.Open(destination)"), body.index("sha.ComputeHash(held)"))
        self.assertIn("heldLibraries.Add(held)", body)
        self.assertNotIn("File.Copy(", workspace)
        # Loaded from the resolved folder, which is kept out of the DLL search order.
        for caller in (SETUP / "Program.cs", PROJECT / "tests" / "SetupWindowSmoke.cs"):
            self.assertIn("WebViewLibraries.Install(workspace.ResolvedLibraryFolder);", read(caller))
        libraries = read(SETUP / "WebViewLibraries.cs")
        self.assertIn("SetDllDirectory(string.Empty);", libraries)
        self.assertNotIn("SetDllDirectory(libraryFolder)", libraries)

    def test_the_bootstrapper_must_be_signed_by_microsoft_itself(self) -> None:
        runtime = read(SETUP / "WebViewRuntime.cs")
        # Not a name that merely contains "Microsoft": exactly one organization, exactly "Microsoft Corporation", and a valid
        # chain that ends at one of Microsoft's own roots (never Microsoft's root for other publishers).
        self.assertNotIn('IndexOf("Microsoft Corporation"', runtime)
        self.assertIn('string.Equals(organizations[0], "O=Microsoft Corporation", StringComparison.Ordinal)', runtime)
        roots = re.search(r"MicrosoftRootThumbprints =\s*\{(.*?)\};", runtime, re.S)
        self.assertIsNotNone(roots)
        self.assertEqual(
            {"3B1EFD3A66EA28B16697394703A72CA340A05BD5", "8F43288AD272F3103B6FB1428485EA3014C0BCFE"},
            set(re.findall(r'"([0-9A-F]{40})"', roots.group(1))),
        )
        check = runtime[runtime.index("internal static bool IsSignedByMicrosoft(string path, SafeFileHandle file"):]
        self.assertLess(check.index("VerifyTrust(path, file)"), check.index("problem = SignerProblem(signer, carried);"))

    def test_setup_limits_the_dll_search_order_before_anything_else(self) -> None:
        program = read(SETUP / "Program.cs")
        # Main restricts the order and hands over to Start, which is compiled only afterwards, so nothing Setup uses (WPF, the
        # message box, the log, the WebView2 libraries) can be loaded from the folder the program was started from.
        main = re.search(r"private static int Main\(string\[\] args\)\n        \{\n(.*?)\n        \}\n", program, re.S)
        self.assertIsNotNone(main)
        statements = [line.strip() for line in main.group(1).splitlines() if line.strip() and not line.strip().startswith("//")]
        self.assertEqual(
            ["bool dllSearchRestricted = DllSearch.RestrictToSystem32();", "return Start(args, dllSearchRestricted);"], statements
        )
        self.assertIn("[MethodImpl(MethodImplOptions.NoInlining)]\n        private static int Start(string[] args, bool dllSearchRestricted)", program)
        start = program[program.index("private static int Start(") :]
        for later in ("foreach (string argument in args)", "MessageBox.Show", "new Mutex", "SetupLog.Initialize", "WebViewLibraries.Install"):
            with self.subTest(later=later):
                self.assertIn(later, start)
        search = read(SETUP / "DllSearch.cs")
        self.assertIn("LoadLibrarySearchSystem32 = 0x00000800;", search)
        self.assertIn("SetDefaultDllDirectories(LoadLibrarySearchSystem32)", search)
        # Nothing that would put the program's own folder, or a folder of the person's, back into the order.
        for widening in ("0x00001000", "0x00000200", "0x00000400", "AddDllDirectory", "SetDllDirectory"):
            with self.subTest(widening=widening):
                self.assertNotIn(widening, search)
        smoke = read(PROJECT / "tests" / "SetupWindowSmoke.cs")
        self.assertLess(smoke.index("DllSearch.RestrictToSystem32();"), smoke.index("WebViewLibraries.Install("))

    def test_project_links_are_the_projects_own(self) -> None:
        links = read(SETUP / "ProjectLinks.cs")
        self.assertIn("https://github.com/50sotero/rewindle", links)
        self.assertEqual(
            "https://github.com/50sotero/rewindle",
            re.search(r"PROJECT_URL = '([^']+)'", read(WEB / "src" / "project.ts")).group(1),
        )
        self.assertNotRegex(links, r'"https?://(?!github\.com/50sotero/rewindle)')


class SampleDataTests(unittest.TestCase):
    """The sample bridge is for `npm run dev:setup` and the setup-demo build only, and the shipped bundle is checked for it."""

    def test_the_sample_is_imported_behind_a_build_time_guard_and_nowhere_else(self) -> None:
        main = read(WIZARD / "main.tsx")
        self.assertIn("import.meta.env.DEV || import.meta.env.MODE === 'setup-demo'", main)
        self.assertEqual(1, len(re.findall(r"import\('\./mock/mockSetupBridge'\)", main)))
        for path in WIZARD.rglob("*.ts*"):
            if "mock" in path.parts or path.name == "main.tsx":
                continue
            self.assertIsNone(re.search(r"from '[./]*mock/|import\('[./]*mock/", read(path)), f"{path.name} imports the sample")

    def test_the_build_checks_the_bundle_for_the_sample(self) -> None:
        build = read(SETUP / "build.ps1")
        self.assertIn("rewindle-setup-sample-bridge", build)
        self.assertIn("mockSetupBridge", build)
        self.assertIn("npm.cmd run build:setup", build)
        marker = re.search(r"SETUP_SAMPLE_MARKER = '([^']+)'", read(WIZARD / "mock" / "mockSetupBridge.ts"))
        self.assertIsNotNone(marker)
        self.assertIn(marker.group(1), build)

    def test_every_scenario_the_task_names_exists(self) -> None:
        scenarios = read(WIZARD / "mock" / "scenarios.ts")
        for name in (
            "fresh", "no-second-drive", "drivefs", "existing-install", "legacy-installed", "unsupported-os", "plan-errors", "install-failure",
            "uac-declined", "key-unreadable", "goes-online-only", "kept-backups",
            # The password choice: backups kept without a password, with a mode no record names, an installed copy without a password,
            # and an install the installer refuses because the backups there are not what was recorded.
            "kept-no-password", "kept-unknown-access", "existing-no-password", "access-mismatch",
        ):
            with self.subTest(scenario=name):
                self.assertIn(f"'{name}'", scenarios)

    def test_the_sample_uses_only_placeholder_paths(self) -> None:
        for path in (WIZARD / "mock").glob("*.ts"):
            found = re.search(r"(?i)[a-z]:\\+users\\+(?!you\b)(\w+)", read(path))
            self.assertIsNone(found, f"{path.name} has a profile path that is not the placeholder: {found and found.group(0)}")

    def test_the_wizard_is_its_own_vite_entry_and_never_part_of_the_dashboards(self) -> None:
        dashboard = read(WEB / "vite.config.ts")
        self.assertNotIn("setup", dashboard.lower())
        wizard = read(WEB / "vite.setup.config.ts")
        self.assertIn("setup.html", wizard)
        self.assertIn("outDir: '../build-output/setup-web'", wizard)
        self.assertNotIn("outDir: '../dist", wizard)
        package = json.loads(read(WEB / "package.json"))
        scripts = package["scripts"]
        self.assertIn("vite.setup.config.ts", scripts["dev:setup"])
        self.assertIn("127.0.0.1", scripts["dev:setup"] + wizard)
        self.assertIn("setup-demo", scripts["build:setup-demo"])
        self.assertNotIn("setup", scripts["build"])

    def test_the_release_build_refuses_wizard_files_in_the_dashboard_payload(self) -> None:
        release = read(PROJECT / "build" / "Build-Release.ps1")
        self.assertIn("web/(setup|rewindle-setup)", release)


class BuildIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.release = read(PROJECT / "build" / "Build-Release.ps1")
        cls.build = read(SETUP / "build.ps1")

    def test_the_release_still_produces_the_zip_and_the_setup_program(self) -> None:
        self.assertIn('"Rewindle-v$version-windows-x64.zip"', self.release)
        self.assertIn('"Rewindle-v$version-windows-x64-setup.exe"', self.release)
        self.assertIn("installer\\setup\\build.ps1", self.release)
        self.assertIn("-BundleArchive $artifactPath", self.release)
        self.assertIn("Assert-ReleaseBinaryVersion $setupArtifactPath", self.release)

    def test_the_zip_still_carries_the_console_installer(self) -> None:
        self.assertIn("'Install.cmd', 'Install-ResticBackuper.ps1'", self.release)
        self.assertTrue((PROJECT / "installer" / "Install.cmd").is_file())

    def test_the_old_bootstrapper_is_gone_and_every_host_source_is_compiled(self) -> None:
        self.assertFalse((PROJECT / "installer" / "RewindleSetup.cs").exists())
        self.assertIn("Get-ChildItem -LiteralPath $project -Filter '*.cs'", self.build)
        self.assertIn("/win32manifest:", self.build)
        self.assertIn("Write-RewindleVersionSource", self.build)
        self.assertIn("Write-RewindleVersionedManifest", self.build)

    def test_the_resources_the_build_embeds_are_the_ones_the_host_reads(self) -> None:
        workspace = read(SETUP / "SetupWorkspace.cs")
        for name in ("REWINDLE_BUNDLE", "REWINDLE_SETUP_WEB", "REWINDLE_WEBVIEW2_CORE", "REWINDLE_WEBVIEW2_WPF", "REWINDLE_WEBVIEW2_LOADER"):
            with self.subTest(resource=name):
                self.assertIn(name, workspace)
                self.assertIn(name, self.build)
        self.assertIn("REWINDLE_ICON", self.build)
        self.assertIn("REWINDLE_ICON", read(SETUP / "Program.cs"))

    def test_the_webview_sdk_is_pinned_once(self) -> None:
        shared = read(PROJECT / "build" / "RewindleWebView2.ps1")
        self.assertIn("1.0.4191.47", shared)
        self.assertNotIn("1.0.4191.47", read(PROJECT / "src" / "dashboard" / "build.ps1"))
        self.assertNotIn("1.0.4191.47", self.build)
        self.assertIn("Get-RewindleWebView2Sdk", read(PROJECT / "src" / "dashboard" / "build.ps1"))
        self.assertIn("Get-RewindleWebView2Sdk", self.build)

    def test_ci_runs_the_host_checks(self) -> None:
        ci = read(PROJECT / ".github" / "workflows" / "ci.yml")
        self.assertIn("Test-SetupHost.ps1", ci)


class KeptBackupLocationTests(unittest.TestCase):
    """A Setup started after a separate uninstall proposes the folder the earlier backups are in, and says what choosing another means."""

    # Runs contract.ts as it is (Node strips its types; it imports nothing) on plans that differ only in kept_repository.
    RUNNER = """
const contract = await import(process.argv[1]);
const cases = JSON.parse(process.argv[2]);
const plan = kept => ({ schema: 'Rewindle.InstallPlan.v1', ok: true, errors: [], warnings: [], resolved: {}, defaults: {},
  environment: { existing_install: kept === undefined ? { rewindle: null } : { rewindle: null, kept_repository: kept } } });
const report = {};
for (const [name, kept] of Object.entries(cases)) report[name] = contract.parsePlan(plan(kept)).environment.existingInstall.keptRepository;
report.missing = contract.parsePlan(plan(undefined)).environment.existingInstall.keptRepository;
console.log(JSON.stringify(report));
"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.wizard = read(WIZARD / "useWizard.ts")
        cls.location = read(WIZARD / "screens" / "Location.tsx")

    def test_the_plan_parser_reads_the_kept_location_and_nothing_else(self) -> None:
        node = shutil.which("node")
        if not node:
            self.skipTest("Node.js is unavailable")
        cases = {
            "local": "E:\\ResticBackups\\Personal",
            "cloud": "G:\\My Drive\\Rewindle\\Backups",
            "null": None,
            "empty": "",
            "relative": "Backups\\Rewindle",
            "network": "\\\\server\\share\\Backups",
            "root": "E:\\",
            "quote": 'E:\\Back"ups',
            "number": 42,
            "object": {"path": "E:\\Backups"},
        }
        completed = subprocess.run(
            [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", self.RUNNER,
             (WIZARD / "contract.ts").as_uri(), json.dumps(cases)],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            self.skipTest("this Node.js cannot run TypeScript files")
        self.assertEqual(0, completed.returncode, completed.stderr)
        report = json.loads(completed.stdout)
        self.assertEqual("E:\\ResticBackups\\Personal", report["local"])
        self.assertEqual("G:\\My Drive\\Rewindle\\Backups", report["cloud"])
        for name in ("null", "empty", "relative", "network", "root", "quote", "number", "object", "missing"):
            with self.subTest(case=name):
                self.assertIsNone(report[name])

    def test_the_wizard_starts_from_the_kept_location(self) -> None:
        start = self.wizard.index("const start = useCallback(async (preferredRepository?: string) => {")
        body = self.wizard[start:self.wizard.index("startRef.current = start;", start)]
        # The removal this session ran (read from the installed configuration) comes first, then what the installer found.
        kept = body.index("const kept = preferredRepository ?? plan.environment.existingInstall.keptRepository ?? undefined;")
        self.assertLess(kept, body.index("const initial = initialChoices(plan, kept);"))
        self.assertIn("setKeptRepository(kept ?? null);", body)
        self.assertNotIn("initialChoices(plan, preferredRepository)", body)
        # initialChoices, the way back and the Location page all decide "is it here?" in one place, Google Drive included.
        choices = self.wizard[self.wizard.index("function initialChoices("):self.wizard.index("function firstScreen(")]
        self.assertIn("keptPlace(plan, preferredRepository)", choices)
        place = self.wizard[self.wizard.index("export function keptPlace("):self.wizard.index("function initialDrive(")]
        self.assertIn("isWithin(kept, myDrive)", place)
        self.assertIn("volume.eligible && samePath(volume.root, driveRoot(kept))", place)
        back = self.wizard[self.wizard.index("chooseKeptRepository: () =>"):self.wizard.index("chooseDriveFs: () =>")]
        self.assertIn("keptPlace(base, keptRepository)", back)

    def test_choosing_another_place_is_warned_about_with_the_way_back(self) -> None:
        self.assertIn("const keptElsewhere = !!kept && !samePath(choices.repository, kept);", self.location)
        self.assertIn("const keptHere = !!kept && !!keptPlace(wizard.base!, kept);", self.location)
        self.assertIn("const keptMissing = keptElsewhere && !keptHere;", self.location)
        start = self.location.index("{keptElsewhere && keptHere && (")
        block = self.location[start:self.location.index("\n      )}", start)]
        self.assertIn("onClick={() => wizard.actions.chooseKeptRepository()}>Use my earlier backups</Button>", block)
        # What the person reads: the sentence before the button, without its markup.
        sentence = re.search(r"<span>(Your earlier backups are in .*?)</span>\s*<Button", block, re.S)
        self.assertIsNotNone(sentence)
        words = re.sub(r"<[^>]+>|\{[^}]*\}", " ", sentence.group(1))
        for phrase in ("starts a new backup from scratch", "room for a full copy", "won’t show your earlier backups", "They stay where they are."):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, words)
        for word in ("repositor", "snapshot", "restic", "engine"):
            with self.subTest(word=word):
                self.assertNotIn(word, words.lower())


class WizardWordingTests(unittest.TestCase):
    """What a first-time home user is told stays true to what the program does, and the real-window smoke test can still find its way."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.app = read(WIZARD / "SetupApp.tsx")
        cls.smoke = read(PROJECT / "tests" / "SetupWindowSmoke.cs")

    def test_the_smoke_test_still_finds_every_page_title_and_button_it_waits_for(self) -> None:
        # tests/SetupWindowSmoke.cs (run by Test-SetupWindow.ps1, a developer tool) drives the real window by these words.
        titles = " | ".join(re.findall(r"title: '([^']+)'", self.app))
        for part in re.findall(r"screen-title'\)\.textContent\.indexOf\('([^']+)'\)", self.smoke):
            with self.subTest(title=part):
                self.assertIn(part, titles)
        for label in set(re.findall(r'Click\(view, "([^"]+)"\)', self.smoke)):
            with self.subTest(button=label):
                self.assertIn(f"label: '{label}'", self.app)

    def test_the_wizard_never_shows_the_programs_internal_name(self) -> None:
        for path in WIZARD.rglob("*.ts*"):
            if "mock" in path.parts:
                continue
            code = re.sub(r"/\*.*?\*/|//[^\n]*", "", read(path), flags=re.S)
            with self.subTest(file=path.name):
                self.assertNotIn("ResticBackuper", code)

    def test_a_saved_recovery_key_copy_is_only_called_checked_because_the_host_checks_it(self) -> None:
        bridge = read(SETUP / "SetupBridge.cs")
        self.assertIn("written[index] != key[index]", bridge)
        self.assertIn("The copy didn’t match the original.", bridge)
        recovery = read(WIZARD / "screens" / "Recovery.tsx")
        self.assertIn("Saved and checked", recovery)
        # A copy on the Windows drive, or on the backup drive, doesn't survive losing this PC, and the page says so.
        self.assertIn("copyPlace(", recovery)
        self.assertIn("on this PC’s own drive, so it won’t help if this PC is lost", recovery)
        # Google Drive leaves choices.driveRoot empty, so the backups' drive comes from the repository path: a copy in that Drive
        # is with the backups, never "away", and is never ticked as safe on its own.
        self.assertIn("driveRoot(wizard.choices?.repository ?? '') || (wizard.choices?.driveRoot ?? '')", recovery)
        self.assertNotIn("const backupRoot = wizard.choices?.driveRoot ?? '';", recovery)
        self.assertIn("in the same Google Drive as your backups", recovery)

    def test_a_disabled_next_says_why_and_a_check_in_progress_says_so(self) -> None:
        for text in ("Fix the problem on this page to continue", "Enter a valid time to continue", "Checking this location…"):
            with self.subTest(text=text):
                self.assertIn(text, self.app)
        # The wait for the installer's last answer on the location page is what keeps Next off while it checks. Location is followed by
        # the Password page, which has its own wait for the same answer, and Schedule's way back leads to it.
        self.assertRegex(self.app, r"next\('password', !choices\?\.repository \|\| errors \|\| checking\)")
        self.assertRegex(self.app, r"(?s)case 'password': \{.*?back: back\('location'\), next: next\('schedule', kind === 'checking' \|\| kind === 'unavailable'\)", )
        self.assertIn("back: back('password'), next: next('review', invalid)", self.app)

    def test_enter_never_starts_the_installation(self) -> None:
        # The title takes the focus on every page, so Enter outside a control means Next; on Review Next is Install and its permission prompt.
        self.assertIn("&& screen !== 'review') {", self.app)
        self.assertIn("footer.next.variant === 'primary' && screen !== 'review'", self.app)

    def test_the_done_page_does_not_claim_protection_that_has_not_happened(self) -> None:
        done = read(WIZARD / "screens" / "Done.tsx")
        self.assertNotIn("is protecting", done)
        self.assertIn("nextRunDay(", done)
        # What "Skip for now" left undone, and an autostart the installer reported as failed, are both said here.
        self.assertIn("Your recovery key is still only on this PC.", done)
        self.assertIn("dashboard_autostart_failed", done)
        self.assertIn("<Done wizard={wizard} recovery={recovery} />", self.app)

    def test_the_installers_conflict_messages_say_what_to_remove_and_how_to_go_on(self) -> None:
        installer = read(PROJECT / "installer" / "Install-ResticBackuper.ps1")
        for code, how in (("start_menu_shortcut_exists", "Delete $startMenuShortcut"), ("task_name_in_use", "Open Task Scheduler")):
            with self.subTest(code=code):
                found = re.search(rf"-Code '{code}' -Field 'environment' `\s*-Message (\"[^\"]*\")", installer)
                self.assertIsNotNone(found)
                self.assertIn(how, found.group(1))
                self.assertIn("then try again", found.group(1))
        self.assertNotIn("Start menu item named ResticBackuper", installer)


OWNER_SENTENCE = (
    "Anyone who can open the backup folder can restore every backed-up file, including saved sign-ins. "
    "That includes the folder in Google Drive or on a lost USB drive."
)
BANNED_WORDS = ("repositor", "snapshot", "restic", "engine", "ResticBackuper")


def node_module(script: str, *arguments: str) -> dict:
    """Runs `script` as an ES module under Node (types stripped, as KeptBackupLocationTests does) and returns the JSON it prints."""
    node = shutil.which("node")
    if not node:
        raise unittest.SkipTest("Node.js is unavailable")
    completed = subprocess.run(
        [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", script, *arguments],
        capture_output=True, text=True, encoding="utf-8", timeout=90, check=False,
    )
    if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
        raise unittest.SkipTest("this Node.js cannot run TypeScript files")
    if completed.returncode != 0:
        raise AssertionError(completed.stderr)
    return json.loads(completed.stdout)


class PasswordChoiceContractTests(unittest.TestCase):
    """contract.ts reads the password facts the installer writes and decides, in functions that import nothing, what the wizard sends and shows."""

    PARSER = """
const contract = await import(process.argv[1]);
const planWith = (resolved, existing = { rewindle: null }) => contract.parsePlan({
  schema: 'Rewindle.InstallPlan.v1', ok: true, errors: [], warnings: [], defaults: {},
  resolved: { repository: 'E:\\\\Rewindle\\\\Backups', ...resolved }, environment: { existing_install: existing } });
const result = extra => contract.parseProgressLine({ schema: 'Rewindle.InstallProgress.v1', type: 'result', ok: true, error: null, ...extra }).result;
const values = ['password', 'no_password', 'unknown', null, 'bogus', 'No_Password', 'PASSWORD', 5, true, {}, ''];
const report = { access: {}, existing: {}, kept: {}, keptNoFolder: {}, result: {}, resultKept: {} };
for (const value of values) {
  const key = JSON.stringify(value);
  report.access[key] = planWith({ repository_access: value }).resolved.repositoryAccess;
  report.existing[key] = planWith({ existing_repository_access: value }).resolved.existingRepositoryAccess;
  report.kept[key] = planWith({}, { rewindle: null, kept_repository: 'E:\\\\ResticBackups\\\\Personal', kept_repository_access: value }).environment.existingInstall.keptRepositoryAccess;
  report.keptNoFolder[key] = planWith({}, { rewindle: null, kept_repository: null, kept_repository_access: value }).environment.existingInstall.keptRepositoryAccess;
  report.result[key] = result({ repository_access: value }).repositoryAccess;
  report.resultKept[key] = result({ kept: { repository: 'E:\\\\b', repository_access: value } }).kept.repositoryAccess;
}
report.absent = {
  access: planWith({}).resolved.repositoryAccess, existing: planWith({}).resolved.existingRepositoryAccess,
  kept: planWith({}, { rewindle: null, kept_repository: 'E:\\\\x' }).environment.existingInstall.keptRepositoryAccess,
  result: result({}).repositoryAccess, resultKept: result({ kept: { repository: 'E:\\\\b' } }).kept.repositoryAccess,
  keptWholeAbsent: result({}).kept,
};
console.log(JSON.stringify(report));
"""

    LOGIC = """
const contract = await import(process.argv[1]);
const R = 'E:\\\\Rewindle\\\\Backups';
const plan = (repository, existing, errors = []) => contract.parsePlan({
  schema: 'Rewindle.InstallPlan.v1', ok: errors.length === 0, errors, warnings: [], defaults: {},
  resolved: { repository, existing_repository_access: existing }, environment: { existing_install: { rewindle: null } } });
const out = {};
const send = (name, p, repository, pick) => { out[name] = contract.accessToSend(p, repository, pick) ?? null; };
send('new_no_password', plan(R, null), R, 'no_password');
send('new_password', plan(R, null), R, 'password');
send('spelled_differently', plan(R, null), 'e:/rewindle//backups/', 'no_password');
send('another_folder', plan(R, null), 'D:\\\\Backups', 'no_password');
send('plan_without_folder', plan(null, null), R, 'no_password');
send('recorded_password', plan(R, 'password'), R, 'no_password');
send('recorded_no_password', plan(R, 'no_password'), R, 'password');
send('unknown_mode', plan(R, 'unknown'), R, 'no_password');
send('no_plan', null, R, 'no_password');
send('no_pick', plan(R, null), R, null);
send('pick_not_a_mode', plan(R, null), R, 'bogus');
send('no_folder_chosen', plan(R, null), '', 'password');
const refused = [{ code: 'repository_drive_unavailable', field: 'repository', message: 'No such drive.', path: null, detail: null }];
const page = (name, p, repository, checking = false, failed = false) => { out['page_' + name] = contract.passwordPageFor(p, repository, checking, failed); };
page('choice', plan(R, null), R);
page('while_checking', plan(R, null), R, true);
page('plan_for_another_folder', plan(R, null), 'E:\\\\Elsewhere');
page('no_plan_yet', null, R);
page('refused_location', plan(null, null, refused), R);
page('request_failed', plan(R, null), 'E:\\\\Elsewhere', false, true);
page('kept_password', plan(R, 'password'), R);
page('kept_no_password', plan(R, 'no_password'), R);
page('kept_unknown', plan(R, 'unknown'), R);
const planned = (name, p, repository, pick) => { out['planned_' + name] = contract.plannedAccess(p, repository, pick); };
planned('new_no_password', plan(R, null), R, 'no_password');
planned('new_password', plan(R, null), R, 'password');
planned('recorded_wins', plan(R, 'no_password'), R, 'password');
planned('unknown_mode', plan(R, 'unknown'), R, 'no_password');
planned('plan_for_another_folder', plan(R, 'password'), 'E:\\\\Elsewhere', 'no_password');
planned('no_pick', plan(R, null), R, null);
const access = (name, resultAccess, credential, plannedMode) => {
  out['install_' + name] = contract.installAccess(resultAccess === undefined ? null : { repositoryAccess: resultAccess }, credential, plannedMode);
};
access('result_no_password', 'no_password', 'completed', 'password');
access('result_password_beats_a_skip', 'password', 'skipped', 'no_password');
access('skipped_credential', null, 'skipped', 'password');
access('done_credential_beats_the_plan', null, 'completed', 'no_password');
access('started_credential', null, 'started', 'no_password');
access('nothing_yet_planned', undefined, null, 'no_password');
access('nothing_yet_unknown', undefined, null, null);
access('result_without_the_field', null, null, null);
out.needed = { password: contract.recoveryNeededFor('password'), no_password: contract.recoveryNeededFor('no_password'), unknown: contract.recoveryNeededFor(null) };
out.words = {
  none: contract.keptWords(null), undefined: contract.keptWords(undefined), password: contract.keptWords('password'), no_password: contract.keptWords('no_password'),
  none_were: contract.keptWords(null, 'were'), undefined_were: contract.keptWords(undefined, 'were'),
  password_were: contract.keptWords('password', 'were'), no_password_were: contract.keptWords('no_password', 'were'),
};
out.noPasswordTitles = contract.NO_PASSWORD_PHASE_TITLES;
console.log(JSON.stringify(out));
"""

    # The rules about findings and refusals, in a script of their own: they are new, and the checks above read only what they read before.
    RULES = """
const contract = await import(process.argv[1]);
const R = 'E:\\\\Rewindle\\\\Backups';
const plan = (repository, existing, errors = []) => contract.parsePlan({
  schema: 'Rewindle.InstallPlan.v1', ok: errors.length === 0, errors, warnings: [], defaults: {},
  resolved: { repository, existing_repository_access: existing }, environment: { existing_install: { rewindle: null } } });
const out = {};
// The findings the installer raises only for backups with a password (a leftover recovery key), as the first page and Review read them.
const finding = (code, field = 'environment') => ({ code, field, message: 'About ' + code + '.', path: null, detail: null });
const keyErrors = [finding('recovery_key_stale'), finding('recovery_key_path_unsafe'), finding('task_name_in_use')];
const codes = found => found.errors.map(issue => issue.code);
const findings = (name, p, repository, pick) => {
  out['welcome_' + name] = codes(contract.welcomeIssues(p));
  out['install_' + name] = codes(contract.installIssues(p, repository, pick, ...contract.ISSUE_FIELDS));
  out['applies_' + name] = contract.passwordFindingsApply(p, repository, pick);
};
findings('new_password', plan(R, null, keyErrors), R, 'password');
findings('new_no_password', plan(R, null, keyErrors), R, 'no_password');
findings('new_nothing_picked', plan(R, null, keyErrors), R, null);
findings('kept_password_pick_none', plan(R, 'password', keyErrors), R, 'no_password');
findings('kept_none_pick_password', plan(R, 'no_password', keyErrors), R, 'password');
findings('kept_unknown_pick_none', plan(R, 'unknown', [finding('recovery_key_path_unsafe')]), R, 'no_password');
findings('plan_for_another_folder', plan(R, null, keyErrors), 'E:\\\\Elsewhere', 'no_password');
findings('no_plan_yet', null, R, 'no_password');
findings('other_findings_only', plan(R, null, [finding('task_name_in_use'), finding('source_not_found', 'sources'), finding('repository_password_unavailable', 'repository')]), R, 'no_password');
findings('key_code_about_another_field', plan(R, null, [finding('recovery_key_stale', 'repository')]), R, 'no_password');
// After an install, and the refusals whose next step is another location.
const op = (operation, outcome) => ({ operation, finished: outcome === undefined ? null : { outcome } });
out.changed = {
  install_failed: contract.locationMayHaveChanged(op('install', 'failed')),
  install_cancelled: contract.locationMayHaveChanged(op('install', 'cancelled')),
  install_succeeded: contract.locationMayHaveChanged(op('install', 'succeeded')),
  install_blocked: contract.locationMayHaveChanged(op('install', 'blocked')),
  install_running: contract.locationMayHaveChanged(op('install')),
  uninstall_failed: contract.locationMayHaveChanged(op('uninstall', 'failed')),
  none: contract.locationMayHaveChanged(null), undefined: contract.locationMayHaveChanged(undefined),
};
out.another = Object.fromEntries(
  ['repository_access_mismatch', 'repository_password_unavailable', 'repository_access_unreadable', 'recovery_key_failed', 'repository_initialization_failed', '', null, undefined]
    .map(code => [String(code), contract.leadsToAnotherLocation(code)]));
console.log(JSON.stringify(out));
"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.uri = (WIZARD / "contract.ts").as_uri()

    def test_every_password_field_is_read_as_one_of_the_two_modes_or_nothing(self) -> None:
        report = node_module(self.PARSER, self.uri)
        modes = {'"password"': "password", '"no_password"': "no_password"}
        for field in ("access", "kept", "result", "resultKept"):
            for key, value in report[field].items():
                with self.subTest(field=field, value=key):
                    self.assertEqual(modes.get(key), value)
        # Where the installer found backups already, a value it never sends is "a mode nobody recorded", never "no backups there"
        # (that would offer a choice the installer refuses). Missing or null is the only "no backups".
        for key, value in report["existing"].items():
            with self.subTest(field="existing", value=key):
                self.assertEqual({'"password"': "password", '"no_password"': "no_password", '"unknown"': "unknown", "null": None}.get(key, "unknown"), value)
        # The kept mode is only ever a fact about the kept folder.
        for key, value in report["keptNoFolder"].items():
            with self.subTest(field="keptNoFolder", value=key):
                self.assertIsNone(value)
        # An older installer's plan and result carry none of it: nothing is claimed either way.
        self.assertEqual(
            {"access": None, "existing": None, "kept": None, "result": None, "resultKept": None, "keptWholeAbsent": None}, report["absent"])

    def test_the_pick_is_sent_only_for_a_location_the_latest_plan_found_empty(self) -> None:
        out = node_module(self.LOGIC, self.uri)
        self.assertEqual("no_password", out["new_no_password"])
        self.assertEqual("password", out["new_password"])
        # The folder may be written differently by the page and the installer.
        self.assertEqual("no_password", out["spelled_differently"])
        for case in (
            "another_folder", "plan_without_folder", "recorded_password", "recorded_no_password", "unknown_mode", "no_plan", "no_pick",
            "pick_not_a_mode", "no_folder_chosen",
        ):
            with self.subTest(case=case):
                self.assertIsNone(out[case])

    def test_the_password_page_offers_the_choice_only_when_it_may(self) -> None:
        out = node_module(self.LOGIC, self.uri)
        self.assertEqual({"kind": "choice"}, out["page_choice"])
        # Waiting: an answer is on its way, there is none yet, or it is for another folder than the one chosen now.
        for case in ("page_while_checking", "page_plan_for_another_folder", "page_no_plan_yet"):
            with self.subTest(case=case):
                self.assertEqual({"kind": "checking"}, out[case])
        # An answer that will not come for this folder: the installer refused the location, or could not be asked.
        self.assertEqual({"kind": "unavailable"}, out["page_refused_location"])
        self.assertEqual({"kind": "unavailable"}, out["page_request_failed"])
        # Backups already there keep the kind they have, and nothing is offered.
        self.assertEqual({"kind": "kept", "access": "password"}, out["page_kept_password"])
        self.assertEqual({"kind": "kept", "access": "no_password"}, out["page_kept_no_password"])
        self.assertEqual({"kind": "kept", "access": "unknown"}, out["page_kept_unknown"])

    def test_what_the_backups_will_have_follows_the_record_then_the_pick(self) -> None:
        out = node_module(self.LOGIC, self.uri)
        self.assertEqual("no_password", out["planned_new_no_password"])
        self.assertEqual("password", out["planned_new_password"])
        self.assertEqual("no_password", out["planned_recorded_wins"])
        self.assertIsNone(out["planned_unknown_mode"])
        self.assertEqual("no_password", out["planned_plan_for_another_folder"])
        self.assertIsNone(out["planned_no_pick"])

    def test_the_recovery_step_is_skipped_only_for_backups_known_to_have_no_password(self) -> None:
        out = node_module(self.LOGIC, self.uri)
        self.assertEqual({"password": True, "no_password": False, "unknown": True}, out["needed"])
        # The installer's result decides; else what its credential step did; else what was chosen or recorded.
        self.assertEqual("no_password", out["install_result_no_password"])
        self.assertEqual("password", out["install_result_password_beats_a_skip"])
        self.assertEqual("no_password", out["install_skipped_credential"])
        self.assertEqual("password", out["install_done_credential_beats_the_plan"])
        self.assertEqual("password", out["install_started_credential"])
        self.assertEqual("no_password", out["install_nothing_yet_planned"])
        # Not known yet, or a result that says nothing (an older installer): the key page is still shown, never skipped.
        self.assertIsNone(out["install_nothing_yet_unknown"])
        self.assertIsNone(out["install_result_without_the_field"])

    def test_what_an_uninstall_keeps_is_worded_for_the_kind_of_backups(self) -> None:
        out = node_module(self.LOGIC, self.uri)
        words = out["words"]
        self.assertEqual("Your backups and recovery key are kept", words["password"])
        self.assertEqual("Your backups and recovery key were kept", words["password_were"])
        self.assertEqual("Your backups are kept", words["no_password"])
        self.assertEqual("Your backups were kept", words["no_password_were"])
        # When nothing says which kind the backups are (null, or not told at all), no recovery key is claimed: any there is is kept too.
        for case in ("none", "undefined"):
            with self.subTest(access=case):
                self.assertEqual("Your backups are kept, and so is any recovery key", words[case])
        for case in ("none_were", "undefined_were"):
            with self.subTest(access=case):
                self.assertEqual("Your backups were kept, and so was any recovery key", words[case])

    def test_a_leftover_recovery_key_counts_only_for_backups_that_have_a_password(self) -> None:
        out = node_module(self.RULES, self.uri)
        key, other = ["recovery_key_stale", "recovery_key_path_unsafe"], ["task_name_in_use"]
        # The first page never stops for them: they depend on the password, which is chosen later. Every other finding still does.
        for case in ("new_password", "new_no_password", "new_nothing_picked", "kept_password_pick_none", "kept_none_pick_password", "plan_for_another_folder"):
            with self.subTest(welcome=case):
                self.assertEqual(other, out["welcome_" + case])
        self.assertEqual([], out["welcome_kept_unknown_pick_none"])
        self.assertEqual([], out["welcome_no_plan_yet"])
        # Install counts them while the backups will have (or may have) a password: a new location with a password picked (or nothing
        # picked yet), backups that have one, backups whose kind is not known yet, and a plan that is not for this folder.
        for case in ("new_password", "new_nothing_picked", "kept_password_pick_none", "plan_for_another_folder"):
            with self.subTest(install=case):
                self.assertEqual(key + other, out["install_" + case])
                self.assertTrue(out["applies_" + case])
        self.assertEqual(["recovery_key_path_unsafe"], out["install_kept_unknown_pick_none"])
        self.assertTrue(out["applies_kept_unknown_pick_none"])
        # They do not count at all when the person picked no password for a new location, or the backups there are known to have none.
        for case in ("new_no_password", "kept_none_pick_password"):
            with self.subTest(install=case):
                self.assertEqual(other, out["install_" + case])
                self.assertFalse(out["applies_" + case])
        # Nothing else about this is the password's business: other findings, and these codes about another field, always count.
        self.assertEqual(["task_name_in_use", "source_not_found", "repository_password_unavailable"], out["install_other_findings_only"])
        self.assertEqual(["recovery_key_stale"], out["install_key_code_about_another_field"])
        self.assertEqual([], out["install_no_plan_yet"])

    def test_an_install_that_did_not_finish_is_what_makes_the_location_be_asked_about_again(self) -> None:
        out = node_module(self.RULES, self.uri)
        # An install that failed or was cancelled may have left the backups it made. One that finished, one still running, one that
        # was stopped before it began (blocked), an uninstall and no operation at all leave the location as it was.
        self.assertEqual(
            {"install_failed": True, "install_cancelled": True, "install_succeeded": False, "install_blocked": False, "install_running": False,
             "uninstall_failed": False, "none": False, "undefined": False}, out["changed"])

    def test_the_refusals_whose_next_step_is_another_location(self) -> None:
        out = node_module(self.RULES, self.uri)
        self.assertEqual(
            {"repository_access_mismatch": True, "repository_password_unavailable": True, "repository_access_unreadable": False, "recovery_key_failed": False,
             "repository_initialization_failed": False, "": False, "null": False, "undefined": False}, out["another"])

    def test_the_words_for_backups_without_a_password_are_a_table_of_their_own(self) -> None:
        out = node_module(self.LOGIC, self.uri)
        self.assertEqual(
            {"credential": "Choosing no password", "repository": "Creating the backup location", "recovery_key": "Saving the recovery tools"},
            out["noPasswordTitles"])
        # The installer's phases stay a literal list in the installer's order (test_the_phases_the_wizard_lists_are_the_contracts reads it).
        contract_ts = read(WIZARD / "contract.ts")
        self.assertIn("{ id: 'credential', title: 'Setting up encryption (no password to remember)', weight: 4 },", contract_ts)
        self.assertIn("{ id: 'recovery_key', title: 'Writing your recovery key', weight: 5 },", contract_ts)

    def test_the_helpers_are_pure_functions_of_the_contracts_own_types(self) -> None:
        # The Node runs above load contract.ts alone; a new import would break them, and accessToSend must stay testable that way.
        contract_ts = read(WIZARD / "contract.ts")
        self.assertIsNone(re.search(r"^import ", contract_ts, re.M))
        self.assertIn("export function accessToSend(plan: InstallPlan | null, repository: string, pick: RepositoryAccess | null | undefined): RepositoryAccess | undefined {", contract_ts)


class WizardStepsTests(unittest.TestCase):
    """The rail, the compact bar and "Step N of M" all count the same steps, from one function of whether there is a recovery key to save."""

    RUNNER = """
import { pathToFileURL } from 'node:url';
const module = await import(pathToFileURL(process.argv[1]).href);
const screens = steps => steps.map(step => step.screen);
const report = {};
for (const needed of [true, false]) {
  const steps = module.stepsFor(needed);
  report[needed] = {
    screens: screens(steps), labels: steps.map(step => step.label),
    numbers: Object.fromEntries(['welcome', 'folders', 'location', 'password', 'schedule', 'review', 'installing', 'recovery', 'done', 'maintenance'].map(screen => [screen, module.stepNumber(steps, screen) ?? null])),
  };
}
report.choice = module.CHOICE_STEPS;
console.log(JSON.stringify(report));
"""

    def test_steps_and_numbers_come_from_one_function(self) -> None:
        wizard = read(WIZARD / "useWizard.ts")
        # The block is self-contained (no imports), so it runs as it is: the Screen type, STEPS, CHOICE_STEPS, stepsFor and stepNumber.
        block = wizard[wizard.index("export type Screen ="):wizard.index("export interface FolderChoice")]
        with tempfile.TemporaryDirectory() as folder:
            module = Path(folder) / "steps.ts"
            module.write_text(block, encoding="utf-8")
            report = node_module(self.RUNNER, str(module))
        everything = ["welcome", "folders", "location", "password", "schedule", "review", "installing", "recovery", "done"]
        self.assertEqual(everything, report["true"]["screens"])
        # No recovery key to save: the step goes, and every number after it is still right.
        self.assertEqual([screen for screen in everything if screen != "recovery"], report["false"]["screens"])
        self.assertEqual(["Welcome", "Protected folders", "Backup location", "Password", "Automatic backups", "Review", "Install", "Recovery key", "Done"], report["true"]["labels"])
        self.assertEqual({"welcome": 1, "folders": 2, "location": 3, "password": 4, "schedule": 5, "review": 6, "installing": 7, "recovery": 8, "done": 9, "maintenance": None}, report["true"]["numbers"])
        self.assertEqual({"welcome": 1, "folders": 2, "location": 3, "password": 4, "schedule": 5, "review": 6, "installing": 7, "recovery": None, "done": 8, "maintenance": None}, report["false"]["numbers"])
        # The choices that can be revisited until Install, in order: Password sits between Location and Schedule.
        self.assertEqual(["welcome", "folders", "location", "password", "schedule", "review"], report["choice"])

    def test_the_shell_counts_the_steps_it_is_given_and_never_a_literal(self) -> None:
        app = read(WIZARD / "SetupApp.tsx")
        self.assertNotIn("of 8", app)
        self.assertNotIn("NUMBERED", app)
        self.assertIsNone(re.search(r"\bSTEPS\.", app))
        self.assertIn("const eyebrow = step ? `Step ${step} of ${wizard.steps.length}` : undefined;", app)
        self.assertIn("stepNumber(wizard.steps, wizard.screen)", app)
        self.assertIn("const steps = wizard.steps;", app)
        self.assertIn("{steps.map((step, index) => {", app)
        self.assertIn("{stepIndex + 1} of {steps.length}", app)
        wizard = read(WIZARD / "useWizard.ts")
        self.assertIn("const steps = useMemo(() => stepsFor(recoveryNeeded), [recoveryNeeded]);", wizard)
        self.assertIn("const recoveryNeeded = recoveryNeededFor(access);", wizard)

# ---- the pages as the person reads them -------------------------------------------------------------------------------------------
# The screens are bundled with esbuild (already in web/node_modules) and rendered to static HTML with react-dom/server around a wizard
# built from the real contract parsers and pure functions, so the words asserted below are the words on the page.

FOLDER = "E:\\Rewindle\\Backups"
OTHER_FOLDER = "E:\\Elsewhere"
RECOVERY_KEY = "C:\\Users\\you\\Documents\\Rewindle recovery key.txt"
NO_PASSWORD_DETAIL = "No password: this backup opens without one."
NO_KEY_DETAIL = "This backup has no password, so there is no recovery key."
# The installer's own sentences (docs/setup-contract.md). The refusals end with the installer's "undid its changes" sentence.
REFUSAL_ENDING = " Setup undid its changes, and your backups were not touched."
BACKUPS_CHANGED = (
    "These backups no longer match what Setup recorded for them, usually because they were changed outside Rewindle. "
    "Setup can’t carry on with them here. Choose another location, or see Switching an existing backup in SECURITY.md on Rewindle’s GitHub page."
)
BACKUPS_UNREADABLE = (
    "Setup couldn’t open the backups in this location to continue them. Check that the backup drive or Google Drive folder is connected and "
    "available, then try again. If they still can’t be opened, they may be damaged: choose another location for new backups, and keep this "
    "folder until you’ve checked it."
)
PASSWORD_UNAVAILABLE = (
    "The backups in this location have a password that Rewindle doesn’t have on this PC, so Setup can’t continue them. Choose another "
    "location for new backups. You can still restore files from these backups with their recovery key."
)
STALE_KEY = (
    "A recovery key from an earlier setup is still in your profile folder, but the password that goes with it is gone. "
    "Move that file somewhere safe, then run setup again."
)
UNSAFE_KEY = "Something other than a file is where Rewindle keeps the recovery key in your profile folder."
TASK_IN_USE = "A scheduled task already has Rewindle’s name. Open Task Scheduler and remove it, then try again."


def finding(code: str, message: str, field: str = "environment") -> dict:
    return {"code": code, "field": field, "message": message}


KEY_STALE = finding("recovery_key_stale", STALE_KEY)
KEY_UNSAFE = finding("recovery_key_path_unsafe", UNSAFE_KEY)
PC_PROBLEM = finding("task_name_in_use", TASK_IN_USE)


def plan_json(repository=FOLDER, existing=None, errors=None, kept=None, kept_access=None, installed=None) -> dict:
    """An installer plan (without its schema, which the page harness adds) for `repository`; `existing` is what it found there."""
    resolved = {
        "repository": repository, "storage_mode": "local_ntfs", "sources": ["C:\\Users\\you\\Documents"], "schedule": "02:00", "vss": True,
    }
    if existing is not None:
        resolved["existing_repository_access"] = existing
    existing_install = {"rewindle": installed}
    if kept is not None:
        existing_install["kept_repository"] = kept
    if kept_access is not None:
        existing_install["kept_repository_access"] = kept_access
    return {
        "ok": not errors, "errors": errors or [], "warnings": [], "defaults": {"schedule": "02:00"}, "resolved": resolved,
        "environment": {"version": "1.2.3", "existing_install": existing_install, "volumes": [], "known_folders": []},
    }


def result_json(**extra) -> dict:
    result = {
        "ok": True, "error": None, "install_root": "C:\\Program Files\\Rewindle", "recovery_key_path": RECOVERY_KEY,
        "recovery_key_readable_by_user": True, "warnings": [],
    }
    result.update(extra)
    return result


def phase(name: str, state: str, detail=None) -> dict:
    return {"phase": name, "state": state, "title": "", "detail": detail}


PASSWORD_PHASES = [phase("payload", "completed"), phase("credential", "completed"), phase("repository", "completed"), phase("recovery_key", "completed")]
NO_PASSWORD_PHASES = [
    phase("payload", "completed"), phase("credential", "skipped", NO_PASSWORD_DETAIL), phase("repository", "completed"),
    phase("recovery_key", "completed", NO_KEY_DETAIL),
]
SUCCEEDED = {"operation": "install", "outcome": "succeeded", "result": None, "message": "", "exitCode": 0}


def failed(operation: str = "install") -> dict:
    return {"operation": operation, "outcome": "failed", "result": None, "message": "The installer stopped.", "exitCode": 1}


def finished_install(phases: list, result: dict | None, **extra) -> dict:
    return {"kind": "install", "stage": "finished", "phases": phases, "result": result, "finished": SUCCEEDED, "startBackup": False, **extra}


def render_cases() -> dict:
    cases: dict[str, dict] = {}

    def page(name: str, screen: str, **spec) -> None:
        cases[name] = {"screen": screen, "repository": FOLDER, **spec}

    # The Password page and the Review row, in every state the installer's answer can leave them in.
    for screen, prefix in (("password", "pw_"), ("review", "rv_")):
        page(prefix + "choice", screen, plan=plan_json())
        page(prefix + "none", screen, plan=plan_json(), pick="no_password")
        page(prefix + "kept_password", screen, plan=plan_json(existing="password"), pick="no_password")
        page(prefix + "kept_none", screen, plan=plan_json(existing="no_password"), pick="password")
        page(prefix + "kept_unknown", screen, plan=plan_json(existing="unknown"))
        page(prefix + "checking", screen, plan=plan_json(), checking=True)
        page(prefix + "other_folder", screen, plan=plan_json(repository=OTHER_FOLDER))
        page(prefix + "no_plan_yet", screen)
        page(prefix + "refused", screen, plan=plan_json(repository=None, errors=[
            {"code": "repository_drive_unavailable", "field": "repository", "message": "That drive isn’t connected."}]))
        page(prefix + "request_failed", screen, failed=True)

    # A recovery key left in the profile folder: the installer raises these findings for backups with a password only, and a plan never
    # carries the pick, so the first page must not stop for them and Review counts them by the choice made by then.
    both = [KEY_STALE, KEY_UNSAFE]
    page("wl_key", "welcome", plan=plan_json(errors=both))
    page("wl_key_and_pc", "welcome", plan=plan_json(errors=both + [PC_PROBLEM]))
    page("rv_key_password", "review", plan=plan_json(errors=both))
    page("rv_key_none", "review", plan=plan_json(errors=both + [PC_PROBLEM]), pick="no_password")
    page("rv_key_kept_password", "review", plan=plan_json(existing="password", errors=both), pick="no_password")
    page("rv_key_kept_unknown", "review", plan=plan_json(existing="unknown", errors=[KEY_UNSAFE]), pick="no_password")
    # The installer's refusal of backups with a password this PC doesn't have, as a finding about the location.
    unavailable = [finding("repository_password_unavailable", PASSWORD_UNAVAILABLE, "repository")]
    page("loc_password_unavailable", "location", plan=plan_json(existing="password", errors=unavailable))
    page("rv_password_unavailable", "review", plan=plan_json(existing="password", errors=unavailable))

    # Done: the installer's result, what its credential step did, and what the person did about the key.
    def done(name: str, phases: list, result: dict | None, **spec) -> None:
        page(name, "done", operation=finished_install(phases, result), **spec)

    done("done_none", NO_PASSWORD_PHASES, result_json(repository_access="no_password", recovery_key_path=None, recovery_key_readable_by_user=None))
    done("done_none_stale_key", NO_PASSWORD_PHASES, result_json(repository_access="no_password"))
    done("done_none_by_credential", NO_PASSWORD_PHASES, result_json())
    done("done_password", PASSWORD_PHASES, result_json(repository_access="password"))
    done("done_password_no_key_reported", PASSWORD_PHASES, result_json(repository_access="password", recovery_key_path=None))
    done("done_older_installer", PASSWORD_PHASES, result_json())
    done("done_unknown_mode", [], result_json())
    done("done_saved", PASSWORD_PHASES, result_json(repository_access="password"), recovery={"savedTo": "F:\\Keys"})
    done("done_acknowledged", PASSWORD_PHASES, result_json(repository_access="password"), recovery={"acknowledged": True})

    # The install as it is listed while it runs and after it fails.
    page("op_none", "operation", operation=finished_install(NO_PASSWORD_PHASES, result_json(repository_access="no_password", recovery_key_path=None)))
    page("op_none_failed_choice", "operation", operation={
        "kind": "install", "stage": "finished", "access": "no_password", "startBackup": False, "result": None, "finished": failed(),
        "phases": [phase("payload", "completed"), phase("credential", "failed", "Could not choose.")]})
    page("op_password", "operation", operation=finished_install(PASSWORD_PHASES, result_json(repository_access="password")))
    page("op_unknown_yet", "operation", operation={
        "kind": "install", "stage": "running", "startBackup": False, "result": None, "finished": None, "phases": [phase("payload", "completed")]})
    page("op_skipped", "operation", operation=finished_install(
        PASSWORD_PHASES + [phase("dashboard", "skipped"), phase("first_backup", "skipped", "A first backup was not requested.")],
        result_json(repository_access="password"), startBackup=True))
    page("op_mismatch", "operation", operation={
        "kind": "install", "stage": "finished", "startBackup": False, "finished": failed(), "phases": [phase("payload", "completed"), phase("repository", "failed")],
        "result": result_json(ok=False, repository_access="password", error={"code": "repository_access_mismatch", "message": "The backups there have no password."})})
    for name, code, message in (
        ("op_password_unavailable", "repository_password_unavailable", PASSWORD_UNAVAILABLE),
        ("op_unreadable", "repository_access_unreadable", BACKUPS_UNREADABLE),
        ("op_changed", "repository_access_mismatch", BACKUPS_CHANGED),
    ):
        page(name, "operation", operation={
            "kind": "install", "stage": "finished", "startBackup": False, "finished": failed(), "phases": [phase("payload", "completed"), phase("repository", "failed")],
            "result": result_json(ok=False, repository_access="password", error={"code": code, "message": message + REFUSAL_ENDING})})
    page("op_failed", "operation", operation={
        "kind": "install", "stage": "finished", "startBackup": False, "finished": failed(), "phases": [phase("payload", "completed"), phase("repository", "failed")],
        "result": result_json(ok=False, error={"code": "disk_full", "message": "The drive is full."})})
    page("op_uninstall_failed", "operation", operation={
        "kind": "uninstall", "stage": "finished", "startBackup": False, "finished": failed("uninstall"), "phases": [],
        "result": result_json(ok=False, error={"code": "tasks_busy", "message": "A scheduled task is running."})})

    # What an uninstall keeps, by the kind of backups.
    installed = {"version": "1.2.3"}
    page("mt_none", "maintenance", plan=plan_json(installed=installed, kept="E:\\Rewindle\\Backups", kept_access="no_password"))
    page("mt_password", "maintenance", plan=plan_json(installed=installed, kept="E:\\Rewindle\\Backups", kept_access="password"))
    page("mt_not_told", "maintenance", plan=plan_json(installed=installed, kept="E:\\Rewindle\\Backups"))
    page("mt_no_folder", "maintenance", plan=plan_json(installed=installed, kept_access="no_password"))
    removed = {"install_root": True, "scheduled_tasks": ["Rewindle"], "start_menu_shortcut": True, "installed_apps_entry": True}

    def uninstalled(name: str, kept: dict | None) -> None:
        page(name, "uninstalled", operation={
            "kind": "uninstall", "stage": "finished", "startBackup": False, "finished": {**SUCCEEDED, "operation": "uninstall"}, "phases": [],
            "result": result_json(removed=removed, kept=kept, recovery_key_path=None)})

    uninstalled("un_none", {"state_root": "C:\\ProgramData\\Rewindle", "repository": FOLDER, "recovery_key": None, "recovery_tools": "E:\\Rewindle\\RecoveryTools", "repository_access": "no_password"})
    uninstalled("un_password", {"state_root": "C:\\ProgramData\\Rewindle", "repository": FOLDER, "recovery_key": RECOVERY_KEY, "recovery_tools": "E:\\Rewindle\\RecoveryTools", "repository_access": "password"})
    uninstalled("un_not_told", {"state_root": "C:\\ProgramData\\Rewindle", "repository": FOLDER, "recovery_key": RECOVERY_KEY, "recovery_tools": None})

    # What a plan request carries, with each pick.
    page("inputs_password", "inputs", plan=plan_json(), pick="password")
    page("inputs_none", "inputs", plan=plan_json(), pick="no_password")
    return cases


ENTRY = """
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { PLAN_SCHEMA, PROGRESS_SCHEMA, parsePlan, parseProgressLine, passwordPageFor, plannedAccess, recoveryNeededFor } from '__SETUP__/contract';
import { accessOfOperation, inputsOf, stepsFor } from '__SETUP__/useWizard';
import { Welcome } from '__SETUP__/screens/Welcome';
import { Location } from '__SETUP__/screens/Location';
import { Password } from '__SETUP__/screens/Password';
import { Review } from '__SETUP__/screens/Review';
import { Done } from '__SETUP__/screens/Done';
import { Maintenance } from '__SETUP__/screens/Maintenance';
import { Uninstalled } from '__SETUP__/screens/Blocked';
import { OperationView } from '__SETUP__/screens/Installing';

const noop = () => undefined;

// A wizard made the way useWizard makes its own: the plan is parsed by the real parser, and the page state, the mode and whether a
// recovery key is needed come from the real functions (the hook computes them from the same inputs).
function wizardFor(spec: any): any {
  const plan = spec.plan ? parsePlan({ schema: PLAN_SCHEMA, ...spec.plan }) : null;
  const choices = {
    folders: [{ path: 'C:/Users/you/Documents', key: 'Documents', selected: true, exists: true, custom: false }],
    storageMode: 'local_ntfs', driveRoot: 'E:/', repository: spec.repository ?? '', customRepository: false, schedule: '02:00', vss: true,
    startBackup: true, repositoryAccess: spec.pick ?? 'password',
  };
  const o = spec.operation;
  const parsed: any = o && o.result ? parseProgressLine({ schema: PROGRESS_SCHEMA, type: 'result', ...o.result }) : null;
  const operation: any = o ? {
    operation: o.kind ?? 'install', stage: o.stage ?? 'finished',
    phases: (o.phases ?? []).map((p: any, index: number) => ({ seq: index + 1, time: '', phase: p.phase, state: p.state, title: p.title ?? '', detail: p.detail ?? null })),
    lines: [], result: parsed ? parsed.result : null, finished: o.finished ?? null, cancelling: false, startBackup: !!o.startBackup, reinstall: false, access: o.access ?? null,
  } : null;
  // Review and Maintenance read the first plan (base) even when the latest one is not there yet.
  const base = plan ?? parsePlan({ schema: PLAN_SCHEMA, ok: true, errors: [], warnings: [], defaults: {}, resolved: {}, environment: { existing_install: { rewindle: null } } });
  const passwordPage = passwordPageFor(plan, choices.repository, !!spec.checking, !!spec.failed);
  const access = operation && operation.operation === 'install' ? accessOfOperation(operation) : plannedAccess(plan, choices.repository, choices.repositoryAccess);
  const recoveryNeeded = recoveryNeededFor(access);
  return {
    choices, base, host: { version: '1.2.3', locale: 'en-GB' }, theme: { reducedMotion: true }, sizes: {}, notice: null, refreshing: false, refreshNote: null, keptRepository: null,
    validation: { plan, checking: !!spec.checking, error: spec.failed ? 'The installer could not be asked.' : null },
    passwordPage, access, recoveryNeeded, steps: stepsFor(recoveryNeeded), operation,
    actions: { setRepositoryAccess: noop, setStartBackup: noop, refreshDrives: noop, chooseDrive: noop, chooseDriveFs: noop, chooseKeptRepository: noop, browseRepository: noop }, goTo: noop, request: () => Promise.resolve(undefined), openLink: noop,
  };
}

export function run(spec: any): string {
  const wizard = wizardFor(spec);
  const recovery: any = { savedTo: spec.recovery?.savedTo ?? null, acknowledged: !!spec.recovery?.acknowledged };
  switch (spec.screen) {
    case 'welcome': return renderToStaticMarkup(createElement(Welcome, { wizard }));
    case 'location': return renderToStaticMarkup(createElement(Location, { wizard }));
    case 'password': return renderToStaticMarkup(createElement(Password, { wizard }));
    case 'review': return renderToStaticMarkup(createElement(Review, { wizard }));
    case 'done': return renderToStaticMarkup(createElement(Done, { wizard, recovery }));
    case 'maintenance': return renderToStaticMarkup(createElement(Maintenance, { wizard, onReinstall: noop, onUninstall: noop, openDashboard: noop }));
    case 'uninstalled': return renderToStaticMarkup(createElement(Uninstalled, { wizard }));
    case 'operation': return renderToStaticMarkup(createElement(OperationView, { wizard, operation: wizard.operation }));
    case 'inputs': return JSON.stringify(inputsOf(wizard.choices, wizard.validation.plan));
    default: throw new Error('unknown screen ' + spec.screen);
  }
}
"""

BUILD = """
import { createRequire } from 'node:module';
const [web, entry, outfile] = process.argv.slice(2);
const esbuild = createRequire(web + '/package.json')('esbuild');
await esbuild.build({
  entryPoints: [entry], outfile, bundle: true, platform: 'node', format: 'cjs', logLevel: 'error',
  tsconfig: web + '/tsconfig.json', nodePaths: [web + '/node_modules'], define: { 'process.env.NODE_ENV': '"production"' },
});
"""

DRIVER = """
const bundle = require(process.argv[2]);
const specs = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
const out = {};
for (const [name, spec] of Object.entries(specs)) out[name] = bundle.run(spec);
process.stdout.write(JSON.stringify(out));
"""

VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class _ElementText(HTMLParser):
    """The text inside the one element with a given id."""

    def __init__(self, element_id: str) -> None:
        super().__init__()
        self.element_id, self.depth, self.chunks, self.found = element_id, 0, [], False

    def handle_starttag(self, tag, attrs):
        if self.depth:
            if tag not in VOID_TAGS:
                self.depth += 1
        elif not self.found and dict(attrs).get("id") == self.element_id:
            self.found, self.depth = True, 1

    def handle_startendtag(self, tag, attrs):
        pass

    def handle_endtag(self, tag):
        if self.depth:
            self.depth -= 1

    def handle_data(self, data):
        if self.depth:
            self.chunks.append(data)


def element_text(markup: str, element_id: str) -> str:
    parser = _ElementText(element_id)
    parser.feed(markup)
    return re.sub(r"\s+", " ", "".join(parser.chunks)).strip()


def visible(markup: str) -> str:
    """What a person reads: the page's text without its markup, entities decoded, white space collapsed."""
    return re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]*>", "", markup))).strip()


class RenderedPageTests(unittest.TestCase):
    """The pages for the password choice, rendered from the real screens: what is read, what a screen reader announces, what is left out."""

    pages: dict = {}

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        for needed in ("esbuild", "react-dom", "react", "lucide-react", "motion"):
            if not (WEB / "node_modules" / needed / "package.json").is_file():
                raise unittest.SkipTest(f"web/node_modules has no {needed} (npm ci has not been run)")
        folder = Path(tempfile.mkdtemp(prefix="setup-pages-")).resolve()
        cls.addClassCleanup(shutil.rmtree, folder, True)
        (folder / "entry.tsx").write_text(ENTRY.replace("__SETUP__", WIZARD.as_posix()), encoding="utf-8")
        (folder / "build.mjs").write_text(BUILD, encoding="utf-8")
        (folder / "driver.cjs").write_text(DRIVER, encoding="utf-8")
        (folder / "specs.json").write_text(json.dumps(render_cases()), encoding="utf-8")
        built = subprocess.run(
            [node, "--no-warnings", str(folder / "build.mjs"), WEB.as_posix(), (folder / "entry.tsx").as_posix(), (folder / "out.cjs").as_posix()],
            capture_output=True, text=True, encoding="utf-8", timeout=180, check=False)
        if built.returncode != 0:
            raise AssertionError("the screens did not bundle: " + built.stderr)
        ran = subprocess.run(
            [node, "--no-warnings", str(folder / "driver.cjs"), str(folder / "out.cjs"), str(folder / "specs.json")],
            capture_output=True, text=True, encoding="utf-8", timeout=120, check=False)
        if ran.returncode != 0:
            raise AssertionError("the screens did not render: " + ran.stderr)
        cls.pages = json.loads(ran.stdout)

    def text(self, name: str) -> str:
        return visible(self.pages[name])

    # ---- the Password page

    def test_the_owner_sentence_is_on_the_choice_page_whichever_option_is_picked(self) -> None:
        for name in ("pw_choice", "pw_none"):
            with self.subTest(page=name):
                self.assertIn(OWNER_SENTENCE, self.text(name))
        # It is the description of the no-password option itself, so a screen reader reads it with that option, and it is whole text on the page.
        none_card = element_text(self.pages["pw_choice"], "access-none-detail")
        self.assertIn(OWNER_SENTENCE, none_card)
        self.assertNotIn("Anyone who can open", element_text(self.pages["pw_choice"], "access-password-detail"))
        # Never behind a tooltip, a hover, a click or a hidden element.
        for name in ("pw_choice", "pw_none"):
            with self.subTest(page=name):
                self.assertNotRegex(self.pages[name], r"\stitle=")
                self.assertNotRegex(self.pages[name], r"\shidden[=\s>]")
                self.assertNotRegex(self.pages[name], r'aria-hidden="true"[^>]*>[^<]*Anyone who can open')

    def test_the_two_options_are_radio_cards_each_described_by_its_own_text(self) -> None:
        for name, checked in (("pw_choice", [True, False]), ("pw_none", [False, True])):
            with self.subTest(page=name):
                radios = re.findall(r"<input[^>]*>", self.pages[name])
                self.assertEqual(2, len(radios))
                for radio, id_, on in zip(radios, ("access-password-detail", "access-none-detail"), checked):
                    self.assertIn('type="radio"', radio)
                    self.assertIn('name="backup-password"', radio)
                    self.assertIn(f'aria-describedby="{id_}"', radio)
                    self.assertEqual(on, " checked" in radio, radio)
                    self.assertTrue(element_text(self.pages[name], id_), f"nothing is described by {id_}")
        self.assertIn('<fieldset class="drive-group" aria-labelledby="screen-title">', self.pages["pw_choice"])

    def test_a_password_is_the_recommended_option_and_picked_to_begin_with(self) -> None:
        html = self.pages["pw_choice"]
        first, second = html.split('<label', 2)[1:3]
        self.assertIn("Recommended", first)
        self.assertNotIn("Recommended", second)
        self.assertIn("Yes, protect them with a password", first)
        self.assertIn("recovery key", first)
        self.assertIn("No password", second)
        self.assertIn("There’s no recovery key to keep, and nothing to remember.", second)
        self.assertIn("You can’t change this later for these backups.", self.text("pw_choice"))

    def test_backups_that_are_already_there_keep_their_kind_and_are_not_offered_a_choice(self) -> None:
        for name in ("pw_kept_password", "pw_kept_none", "pw_kept_unknown"):
            with self.subTest(page=name):
                self.assertNotIn('type="radio"', self.pages[name])
                self.assertIn("Choose another location", self.text(name))
        self.assertIn("You’ll get a recovery key to keep at the end of Setup.", self.text("pw_kept_password"))
        self.assertNotIn(OWNER_SENTENCE, self.text("pw_kept_password"))
        # A kept backup without a password is as open as a new one: the same words, and what that means for the key.
        self.assertIn(OWNER_SENTENCE, self.text("pw_kept_none"))
        self.assertIn("There’s no recovery key to keep, and nothing to remember.", self.text("pw_kept_none"))
        # The pick made earlier (the other one) does not leak into what a kept backup is said to have.
        self.assertNotIn("recovery key to keep at the end", self.text("pw_kept_none"))

    def test_while_the_installer_has_not_answered_for_this_folder_nothing_is_offered(self) -> None:
        for name in ("pw_checking", "pw_other_folder", "pw_no_plan_yet"):
            with self.subTest(page=name):
                self.assertNotIn('type="radio"', self.pages[name])
                self.assertIn('role="status"', self.pages[name])
                self.assertIn("This takes a moment. Nothing is changed.", self.text(name))
                self.assertNotIn(OWNER_SENTENCE, self.text(name))
        for name in ("pw_refused", "pw_request_failed"):
            with self.subTest(page=name):
                self.assertNotIn('type="radio"', self.pages[name])
                self.assertIn("Go to Backup location", self.text(name))
                self.assertNotIn("This takes a moment", self.text(name))

    # ---- the Review row

    def test_review_says_what_was_chosen_about_the_password_and_where_to_change_it(self) -> None:
        def row(name: str) -> str:
            html = self.pages[name]
            body = html[html.index(">Password</h2>") + len(">Password</h2>"):]
            return visible(body[:body.index("</div></div>")])

        self.assertEqual("Yes. You’ll get a recovery key to keep.", row("rv_choice"))
        self.assertEqual("No password. Anyone who can open the backup folder can restore your files.", row("rv_none"))
        for name in ("rv_kept_password", "rv_kept_none", "rv_kept_unknown"):
            with self.subTest(page=name):
                self.assertEqual("Same as your existing backups", row(name))
        for name in ("rv_checking", "rv_other_folder", "rv_no_plan_yet"):
            with self.subTest(page=name):
                self.assertEqual("Checking this location…", row(name))
        for name in ("rv_refused", "rv_request_failed"):
            with self.subTest(page=name):
                self.assertEqual("Fix the backup location first.", row(name))
        # The row sits between the location and the schedule it is a step between, with its own edit button.
        html = self.pages["rv_choice"]
        self.assertLess(html.index(">Backup location</h2>"), html.index(">Password</h2>"))
        self.assertLess(html.index(">Password</h2>"), html.index(">Automatic backups</h2>"))
        self.assertIn('aria-label="Edit the password choice"', html)

    # ---- Done

    TILE = "Your recovery key is still only on this PC."
    QUIET = "Your backups have no password, so there is no recovery key to keep."

    def test_done_has_no_recovery_key_tile_for_backups_without_a_password(self) -> None:
        for name in ("done_none", "done_none_stale_key", "done_none_by_credential"):
            with self.subTest(page=name):
                self.assertNotIn(self.TILE, self.text(name))
                self.assertNotIn("Copy " + RECOVERY_KEY, self.text(name))
                self.assertIn(self.QUIET, self.text(name))
        self.assertIn('<li class="is-quiet">', self.pages["done_none"])

    def test_done_still_warns_about_an_unsaved_key_for_every_other_case(self) -> None:
        for name in ("done_password", "done_older_installer", "done_unknown_mode"):
            with self.subTest(page=name):
                self.assertIn(self.TILE, self.text(name))
                self.assertIn("Copy " + RECOVERY_KEY, self.text(name))
                self.assertNotIn(self.QUIET, self.text(name))
        # No key reported, or one saved or acknowledged on the Recovery page: nothing to warn about, and no claim of "no password" either.
        for name in ("done_password_no_key_reported", "done_saved", "done_acknowledged"):
            with self.subTest(page=name):
                self.assertNotIn(self.TILE, self.text(name))
                self.assertNotIn(self.QUIET, self.text(name))

    # ---- the install as it is listed

    def test_an_install_without_a_password_lists_no_password_step_and_its_own_words(self) -> None:
        text = self.text("op_none")
        self.assertNotIn("Setting up encryption", text)
        self.assertNotIn("Choosing no password", text)
        self.assertNotIn("Writing your recovery key", text)
        self.assertIn("Creating the backup location", text)
        self.assertIn("Saving the recovery tools", text)
        self.assertIn(NO_KEY_DETAIL, text)
        # A step that failed is always listed, and in these words for a backup without a password.
        failed_text = self.text("op_none_failed_choice")
        self.assertIn("Choosing no password", failed_text)
        self.assertIn("Could not choose.", failed_text)

    def test_an_install_with_a_password_lists_the_steps_it_always_did(self) -> None:
        for name in ("op_password", "op_unknown_yet"):
            text = self.text(name)
            with self.subTest(page=name):
                self.assertIn("Setting up encryption (no password to remember)", text)
                self.assertIn("Writing your recovery key", text)
                self.assertIn("Creating the backup location", text)
                self.assertNotIn("Choosing no password", text)
                self.assertNotIn("Saving the recovery tools", text)

    def test_a_skipped_step_says_why_or_that_it_was_not_needed(self) -> None:
        html = self.pages["op_skipped"]
        self.assertIn("A first backup was not requested.", visible(html))
        # The step without a reason has the short one, for those who see the page (it is not read out: the state is).
        self.assertRegex(html, r'<span class="phase-detail" aria-hidden="true">Not needed</span>')
        self.assertEqual(1, html.count(">Not needed<"))

    def test_a_failure_that_is_a_mismatch_leads_to_another_location_not_to_the_same_attempt(self) -> None:
        mismatch = self.text("op_mismatch")
        self.assertIn("The backups there have no password.", mismatch)
        self.assertIn("Choose Back to review, then change the backup location.", mismatch)
        self.assertNotIn("Choose Try again", mismatch)
        plain = self.text("op_failed")
        self.assertIn("Choose Try again, or Back to review to change your choices.", plain)
        self.assertNotIn("then change the backup location", plain)

    def test_backups_with_a_password_this_pc_does_not_have_lead_to_another_location_and_unreadable_ones_to_trying_again(self) -> None:
        for name, message in (("op_password_unavailable", PASSWORD_UNAVAILABLE), ("op_changed", BACKUPS_CHANGED)):
            with self.subTest(page=name):
                text = self.text(name)
                self.assertIn(message + REFUSAL_ENDING, text)
                self.assertIn("Choose Back to review, then change the backup location.", text)
                self.assertNotIn("Choose Try again", text)
        # Backups that could not be opened may only be out of reach for now: trying again is a first step, and the installer's own words
        # say when to give up on them. The page does not turn that into "change the location".
        unreadable = self.text("op_unreadable")
        self.assertIn(BACKUPS_UNREADABLE + REFUSAL_ENDING, unreadable)
        self.assertIn("Choose Try again, or Back to review to change your choices.", unreadable)
        self.assertNotIn("then change the backup location", unreadable)

    def test_the_installers_refusal_of_a_password_this_pc_does_not_have_is_shown_where_the_location_is_chosen(self) -> None:
        # A finding about the location, like any other: listed on Backup location and on Review as an error (which keeps Next and
        # Install from going on, see test_a_disabled_next_says_why_and_a_check_in_progress_says_so), with the installer's own sentence.
        for name in ("loc_password_unavailable", "rv_password_unavailable"):
            with self.subTest(page=name):
                self.assertIn(PASSWORD_UNAVAILABLE, self.text(name))
                self.assertRegex(self.pages[name], r'<div class="callout is-error">(?:<[^>]+>)*<span>The backups in this location have a password')

    # ---- a recovery key left in the profile folder

    def test_the_first_page_does_not_stop_for_a_recovery_key_left_behind_but_still_stops_for_the_rest(self) -> None:
        # The installer raises these findings for backups with a password only, and a plan never carries the pick: a person who will
        # choose no password on the fourth page must be able to get there.
        key_only = self.text("wl_key")
        for message in (STALE_KEY, UNSAFE_KEY):
            self.assertNotIn(message, key_only)
        self.assertNotIn("is-error", self.pages["wl_key"])
        self.assertNotIn("Check again", key_only)
        # A problem with the PC itself is still told here, with the way to ask the installer again.
        mixed = self.text("wl_key_and_pc")
        self.assertIn(TASK_IN_USE, mixed)
        self.assertIn("Check again", mixed)
        for message in (STALE_KEY, UNSAFE_KEY):
            self.assertNotIn(message, mixed)

    def test_review_lists_a_recovery_key_left_behind_only_when_the_backups_have_or_may_have_a_password(self) -> None:
        for name, messages in (
            ("rv_key_password", (STALE_KEY, UNSAFE_KEY)), ("rv_key_kept_password", (STALE_KEY, UNSAFE_KEY)), ("rv_key_kept_unknown", (UNSAFE_KEY,)),
        ):
            with self.subTest(page=name):
                for message in messages:
                    self.assertIn(message, self.text(name))
                    self.assertRegex(self.pages[name], r'<div class="callout is-error">(?:<[^>]+>)*<span>' + re.escape(message[:30]))
        self.assertNotIn(STALE_KEY, self.text("rv_key_kept_unknown"))
        # No password picked for a new location: they do not count, and the rest of the findings still do.
        none = self.text("rv_key_none")
        for message in (STALE_KEY, UNSAFE_KEY):
            self.assertNotIn(message, none)
        self.assertIn(TASK_IN_USE, none)

    def test_a_failed_uninstall_says_the_backups_were_not_touched(self) -> None:
        text = self.text("op_uninstall_failed")
        self.assertIn("A scheduled task is running.", text)
        self.assertIn("Your backups were not touched. Try again, or remove Rewindle from Settings › Apps › Installed apps.", text)

    # ---- what an uninstall keeps

    def test_maintenance_names_what_is_kept_for_the_kind_of_backups(self) -> None:
        none = self.text("mt_none")
        self.assertIn("Your backups are kept; your folders and schedule start from the suggestions.", none)
        self.assertIn("Remove the Rewindle app and its scheduled backups. Your backups are kept.", none)
        self.assertNotIn("recovery key", none)
        text = self.text("mt_password")
        self.assertIn("Your backups and recovery key are kept; your folders and schedule start from the suggestions.", text)
        self.assertIn("Remove the Rewindle app and its scheduled backups. Your backups and recovery key are kept.", text)
        # Nothing says which kind the backups are (no kept records, or none for a folder): no key is claimed, and any there is is kept too.
        for name in ("mt_not_told", "mt_no_folder"):
            with self.subTest(page=name):
                text = self.text(name)
                self.assertIn("Your backups are kept, and so is any recovery key; your folders and schedule start from the suggestions.", text)
                self.assertIn("Remove the Rewindle app and its scheduled backups. Your backups are kept, and so is any recovery key.", text)
                self.assertNotIn("Your backups and recovery key", text)

    def test_the_uninstalled_page_names_what_was_kept_for_the_kind_of_backups(self) -> None:
        none = self.text("un_none")
        self.assertIn("Your backups were kept. They have no password, so there is no recovery key to keep.", none)
        self.assertNotIn("Keep the recovery key", none)
        self.assertNotIn("Your recovery key" + RECOVERY_KEY, none)
        password = self.text("un_password")
        self.assertIn("Your backups and recovery key were kept. Keep the recovery key: you need it to restore anything from those backups.", password)
        self.assertNotIn("no recovery key to keep", password)
        self.assertIn(RECOVERY_KEY, password)
        # The uninstaller did not say which kind the backups are: no key is claimed in the first sentence.
        not_told = self.text("un_not_told")
        self.assertIn("Your backups were kept, and so was any recovery key.", not_told)
        self.assertNotIn("Your backups and recovery key", not_told)
        self.assertNotIn("no recovery key to keep", not_told)

    # ---- all of it

    def test_no_new_words_for_the_password_choice_use_the_programs_own_terms(self) -> None:
        for name, html in self.pages.items():
            if name.startswith("inputs_"):
                continue
            with self.subTest(page=name):
                found = re.findall(r"repositor\w*|snapshot\w*|restic\w*|engine\w*", visible(html), re.I)
                self.assertEqual([], found)

    def test_the_pick_never_reaches_a_plan_request(self) -> None:
        password, none = json.loads(self.pages["inputs_password"]), json.loads(self.pages["inputs_none"])
        self.assertEqual(password, none)
        self.assertEqual({"repository", "storageMode", "sources", "schedule", "vss"}, set(none))
        self.assertNotIn("ccess", self.pages["inputs_none"])
        self.assertNotIn("no_password", self.pages["inputs_none"])

# ---- the wizard's state, run for real ---------------------------------------------------------------------------------------------
# useWizard is bundled with a minimal hooks runtime in place of React (state, refs, memos and effects that run after a render when their
# dependencies changed) and driven against a scripted host in place of the desktop program, so what it asks the host, and when, is what
# the page would ask. Time is the script's: the checks of the choices wait for it, and the requests' own time-outs are never run.

HOOK_RUNTIME = """
let instance = null;
const sameDeps = (a, b) => !!a && !!b && a.length === b.length && a.every((value, index) => Object.is(value, b[index]));

function schedule(inst) {
  if (inst.scheduled) return;
  inst.scheduled = true;
  queueMicrotask(() => inst.render());
}

export function mount(component) {
  const inst = { slots: [], cursor: 0, scheduled: false, result: undefined, effects: [] };
  inst.render = () => {
    inst.scheduled = false;
    instance = inst; inst.cursor = 0; inst.effects = [];
    try { inst.result = component(); } finally { instance = null; }
    for (const slot of inst.effects) {
      if (slot.cleanup) slot.cleanup();
      slot.cleanup = slot.effect();
    }
  };
  inst.render();
  return inst;
}

function slotAt(make) {
  const inst = instance;
  const index = inst.cursor++;
  if (!(index in inst.slots)) inst.slots[index] = make(inst);
  return inst.slots[index];
}

export function useState(initial) {
  const slot = slotAt(inst => {
    const made = { value: typeof initial === 'function' ? initial() : initial };
    made.set = next => {
      const value = typeof next === 'function' ? next(made.value) : next;
      if (!Object.is(value, made.value)) { made.value = value; schedule(inst); }
    };
    return made;
  });
  return [slot.value, slot.set];
}

export const useRef = initial => slotAt(() => ({ current: initial }));

export function useMemo(factory, deps) {
  const slot = slotAt(() => ({ ready: false, deps: undefined, value: undefined }));
  if (!slot.ready || !sameDeps(slot.deps, deps)) { slot.value = factory(); slot.deps = deps; slot.ready = true; }
  return slot.value;
}

export const useCallback = (callback, deps) => useMemo(() => callback, deps);

export function useEffect(effect, deps) {
  const slot = slotAt(() => ({ ran: false, deps: undefined, cleanup: undefined, effect: undefined }));
  if (!slot.ran || !deps || !sameDeps(slot.deps, deps)) {
    slot.ran = true; slot.deps = deps; slot.effect = effect;
    instance.effects.push(slot);
  }
}
"""

HOOK_ENTRY = """
import { useWizard } from '__SETUP__/useWizard';
import { mount } from './runtime.js';

const E = 'E:\\\\Rewindle\\\\Backups';
const DOCS = 'C:\\\\Users\\\\you\\\\Documents';
const settle = async () => { for (let i = 0; i < 30; i++) await new Promise(resolve => setImmediate(resolve)); };

// One run: the person picks "No password" for an empty location and chooses Install; the installer ends as `outcome` (having made the
// backups first, unless it was cancelled before it began); the person goes back to Review, picks a password and chooses Install again.
export async function run(outcome: string) {
  const timers = new Map<number, { fn: () => void; ms: number }>();
  let timerId = 0;
  const requests: any[] = [];
  const installs: any[] = [];
  const host = { backups: null as string | null };
  let listener: any = null;
  const emit = (event: string, data: unknown) => listener({ data: { type: 'event', event, data } });
  const plan = (repository: string) => ({
    schema: 'Rewindle.InstallPlan.v1', ok: true, errors: [], warnings: [],
    resolved: {
      repository, storage_mode: 'local_ntfs', repository_access: host.backups ?? 'password', existing_repository_access: host.backups,
      sources: [DOCS], schedule: '02:00', vss: true,
    },
    defaults: { repository: E, storage_mode: 'local_ntfs', sources: [DOCS], schedule: '02:00' },
    environment: {
      version: '1.2.3', os: { caption: 'Windows', build: '1', x64: true, supported: true }, powershell: '5.1', dotnet_framework_48: true,
      elevated: false, webview2: '1', existing_install: { rewindle: null },
      volumes: [{ root: 'E:\\\\', label: 'Backup Drive', filesystem: 'NTFS', drive_type: 'removable', size_bytes: 1e12, free_bytes: 9e11, is_system: false,
        same_physical_disk_as_system: false, eligible: true, recommended: true }],
      drivefs: { detected: false }, known_folders: [{ key: 'Documents', path: DOCS, exists: true, default_selected: true }],
    },
  });
  const answer = async (message: any) => {
    switch (message.command) {
      case 'hello': return { protocol: 1, version: '1.2.3', dark: false, highContrast: false, reducedMotion: false, host: 'desktop' };
      case 'getPlan': return plan(message.payload?.inputs?.repository ?? E);
      case 'measureFolders':
        for (const path of message.payload.paths) {
          queueMicrotask(() => emit('measure', { request: message.payload.request, path, bytes: 1, files: 1, placeholderFiles: 0, placeholderBytes: 0, skippedFolders: 0, done: true, error: null }));
        }
        return { accepted: true };
      case 'cancelMeasure': return { cancelled: false };
      case 'install':
        installs.push(message.payload.choices);
        queueMicrotask(() => {
          if (outcome !== 'cancelled') host.backups = 'no_password';
          emit('operationFinished', { operation: 'install', outcome, result: null, message: 'The installer stopped.', exitCode: outcome === 'succeeded' ? 0 : 1 });
        });
        return { started: true };
      default: throw new Error('the scripted host does not know ' + message.command);
    }
  };
  const native = {
    addEventListener: (_type: string, next: any) => { listener = next; },
    removeEventListener: () => undefined,
    postMessage: (message: any) => {
      requests.push(message);
      void answer(message).then(
        result => listener({ data: { type: 'response', id: message.id, ok: true, result } }),
        error => listener({ data: { type: 'response', id: message.id, ok: false, error: { code: 'failed', message: String(error) } } }));
    },
  };
  (globalThis as any).window = {
    setTimeout: (fn: () => void, ms: number) => { timers.set(++timerId, { fn, ms }); return timerId; },
    clearTimeout: (id: number) => { timers.delete(id); },
    rewindleSetupNative: native,
  };
  // The wizard asks the installer about its choices a moment after the last change; the requests' time-outs (minutes) are not run.
  const letTheChecksRun = async () => {
    for (const [id, timer] of [...timers]) if (timer.ms < 1000) { timers.delete(id); timer.fn(); }
    await settle();
  };
  const plansAskedForTheFolder = () => requests.filter(request => request.command === 'getPlan' && request.payload?.inputs?.repository).length;

  const app: any = mount(() => useWizard());
  const wizard = () => app.result;
  await settle();
  await letTheChecksRun();
  const facts: any = { screen: wizard().screen, pageBefore: wizard().passwordPage };
  wizard().actions.setRepositoryAccess('no_password');
  await settle();
  facts.plansBefore = plansAskedForTheFolder();
  wizard().install();
  await settle();
  facts.firstSent = installs.length > 0 ? installs[0].repositoryAccess ?? null : 'no install was requested';
  await letTheChecksRun();
  facts.plansAfter = plansAskedForTheFolder();
  facts.pageAfter = wizard().passwordPage;
  facts.checkingAfter = wizard().validation.checking;
  wizard().clearOperation();
  wizard().goTo('review');
  wizard().actions.setRepositoryAccess('password');
  await settle();
  wizard().install();
  await settle();
  facts.secondSent = installs.length > 1 ? installs[1].repositoryAccess ?? null : 'no second install was requested';
  return facts;
}
"""

HOOK_BUILD = """
import { createRequire } from 'node:module';
const [web, entry, outfile, runtime] = process.argv.slice(2);
const esbuild = createRequire(web + '/package.json')('esbuild');
await esbuild.build({
  entryPoints: [entry], outfile, bundle: true, platform: 'node', format: 'cjs', logLevel: 'error',
  tsconfig: web + '/tsconfig.json', alias: { react: runtime },
});
"""

HOOK_DRIVER = """
(async () => {
  const out = {};
  for (const outcome of ['failed', 'cancelled', 'succeeded']) {
    delete require.cache[require.resolve(process.argv[2])];
    out[outcome] = await require(process.argv[2]).run(outcome);
  }
  process.stdout.write(JSON.stringify(out));
})().catch(error => { console.error(error); process.exit(1); });
"""


class WizardStateRunTests(unittest.TestCase):
    """What the wizard asks the installer after an install that did not finish, and what it then sends with the next one."""

    runs: dict = {}

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        if not (WEB / "node_modules" / "esbuild" / "package.json").is_file():
            raise unittest.SkipTest("web/node_modules has no esbuild (npm ci has not been run)")
        folder = Path(tempfile.mkdtemp(prefix="setup-state-")).resolve()
        cls.addClassCleanup(shutil.rmtree, folder, True)
        (folder / "runtime.js").write_text(HOOK_RUNTIME, encoding="utf-8")
        (folder / "entry.ts").write_text(HOOK_ENTRY.replace("__SETUP__", WIZARD.as_posix()), encoding="utf-8")
        (folder / "build.mjs").write_text(HOOK_BUILD, encoding="utf-8")
        (folder / "driver.cjs").write_text(HOOK_DRIVER, encoding="utf-8")
        built = subprocess.run(
            [node, "--no-warnings", str(folder / "build.mjs"), WEB.as_posix(), (folder / "entry.ts").as_posix(), (folder / "out.cjs").as_posix(),
             (folder / "runtime.js").as_posix()],
            capture_output=True, text=True, encoding="utf-8", timeout=180, check=False)
        if built.returncode != 0:
            raise AssertionError("the wizard's state did not bundle: " + built.stderr)
        ran = subprocess.run(
            [node, "--no-warnings", str(folder / "driver.cjs"), str(folder / "out.cjs")],
            capture_output=True, text=True, encoding="utf-8", timeout=120, check=False)
        if ran.returncode != 0:
            raise AssertionError("the wizard's state did not run: " + ran.stderr)
        cls.runs = json.loads(ran.stdout)

    def test_the_scripted_run_reaches_the_choice_before_anything_is_installed(self) -> None:
        # The harness itself: the wizard started, asked about the folder, and offered the choice; the pick went with the first install.
        for outcome, run in self.runs.items():
            with self.subTest(outcome=outcome):
                self.assertEqual("welcome", run["screen"])
                self.assertEqual({"kind": "choice"}, run["pageBefore"])
                self.assertEqual(1, run["plansBefore"])
                self.assertEqual("no_password", run["firstSent"])

    def test_an_install_that_failed_makes_the_wizard_ask_about_the_location_again(self) -> None:
        run = self.runs["failed"]
        # The backups it made are there now: the plan is asked for again, the Password page says what they have, and nothing is offered.
        self.assertEqual(2, run["plansAfter"])
        self.assertEqual({"kind": "kept", "access": "no_password"}, run["pageAfter"])
        self.assertFalse(run["checkingAfter"])
        # So a pick made afterwards (the other one) is not sent for backups that already exist.
        self.assertIsNone(run["secondSent"])

    def test_an_install_that_was_cancelled_makes_the_wizard_ask_again_too(self) -> None:
        run = self.runs["cancelled"]
        self.assertEqual(2, run["plansAfter"])
        # Nothing was made, so the location is still empty: the choice is still offered, and the new pick goes with the next install.
        self.assertEqual({"kind": "choice"}, run["pageAfter"])
        self.assertEqual("password", run["secondSent"])

    def test_an_install_that_finished_does_not_ask_again(self) -> None:
        self.assertEqual(1, self.runs["succeeded"]["plansAfter"])


class PasswordWiringTests(unittest.TestCase):
    """How the pick travels, what the shell says around the Password page, and what the host does with the choice (source checks)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.app = read(WIZARD / "SetupApp.tsx")
        cls.wizard = read(WIZARD / "useWizard.ts")
        cls.contract = read(WIZARD / "contract.ts")
        cls.mock = read(WIZARD / "mock" / "mockSetupBridge.ts")
        cls.scenarios = read(WIZARD / "mock" / "scenarios.ts")
        cls.contract_cs = read(SETUP / "InstallerContract.cs")
        cls.bridge_cs = read(SETUP / "SetupBridge.cs")

    # ---- the shell around the page

    def test_the_password_page_has_its_own_title_and_leads_in_the_persons_words(self) -> None:
        start = self.app.index("function passwordHeader(")
        header = self.app[start:self.app.index("\n}\n", start)]
        for title in (
            "Should your backups have a password?", "Your backups already have a password", "Your backups have no password",
            "Your existing backups", "This location can’t be used yet", "Checking this location…",
        ):
            with self.subTest(title=title):
                self.assertIn(f"title: '{title}'", header)
        self.assertIn("A password keeps your backups private, even if someone gets hold of the backup drive or your Google Drive.", header)
        self.assertIn("backups can’t switch from one to the other", header)
        for word in BANNED_WORDS:
            with self.subTest(word=word):
                self.assertNotIn(word.lower(), header.lower())
        self.assertIn("case 'password': return passwordHeader(wizard, eyebrow);", self.app)
        self.assertIn("case 'password': return <Password wizard={wizard} />;", self.app)
        self.assertIn("import { Password } from './screens/Password';", self.app)

    def test_the_page_and_the_leads_do_not_call_every_backup_encrypted(self) -> None:
        # Backups can now be made without a password, so the words that spoke of encryption as a given are gone from the shell.
        welcome = read(WIZARD / "screens" / "Welcome.tsx")
        for name, source in (("SetupApp.tsx", self.app), ("Welcome.tsx", welcome), ("Password.tsx", read(WIZARD / "screens" / "Password.tsx"))):
            with self.subTest(file=name):
                self.assertNotIn("encrypted", source)
        self.assertIn("protected by a password unless you choose otherwise", welcome)
        self.assertIn("The password choice can’t be changed later.", self.app)
        self.assertNotIn("encrypted", read(SETUP / "AssemblyInfo.cs"))

    def test_continue_after_the_install_goes_to_the_recovery_key_only_when_there_is_one(self) -> None:
        self.assertIn("onClick: () => wizard.goTo(wizard.recoveryNeeded ? 'recovery' : 'done')", self.app)
        self.assertIn("lead: wizard.recoveryNeeded ? 'One more step: save your recovery key.' : undefined", self.app)
        # Nothing goes to Recovery by another way.
        self.assertEqual(1, len(re.findall(r"goTo\([^)]*'recovery'", self.app)))
        self.assertIn("const recoveryNeeded = recoveryNeededFor(access);", self.wizard)

    def test_install_waits_for_the_installers_answer_about_the_location(self) -> None:
        start = self.app.index("case 'review': {")
        block = self.app[start:self.app.index("case 'installing':", start)]
        self.assertIn("const checking = wizard.validation.checking;", block)
        self.assertIn("disabled: problems || scanning || checking", block)
        self.assertRegex(block, r"hint: checking \? <><Spinner size=\{12\} /><span>Checking this location…</span></>")

    def test_the_first_page_and_install_read_the_findings_through_the_rules_in_the_contract(self) -> None:
        # contract.ts decides which findings count (test_a_leftover_recovery_key_counts_only_for_backups_that_have_a_password); the shell
        # and the two pages only ask it, so no page keeps a rule of its own.
        self.assertIn("const blocked = welcomeIssues(plan).errors.length > 0;", self.app)
        self.assertIn("const problems = installIssues(plan, choices!.repository, choices!.repositoryAccess, ...ISSUE_FIELDS).errors.length > 0", self.app)
        self.assertNotIn("plan?.errors.length", self.app)
        self.assertNotIn("issuesFor(plan, 'environment')", self.app)
        welcome = read(WIZARD / "screens" / "Welcome.tsx")
        self.assertIn("const environment = welcomeIssues(wizard.validation.plan);", welcome)
        self.assertNotIn("issuesFor(", welcome)
        review = read(WIZARD / "screens" / "Review.tsx")
        self.assertIn("const all = installIssues(plan, choices.repository, choices.repositoryAccess, ...ISSUE_FIELDS);", review)
        self.assertNotIn("issuesFor(", review)
        # The two codes are the installer's own, raised for the environment.
        installer = read(PROJECT / "installer" / "Install-ResticBackuper.ps1")
        for code in re.findall(r"'(\w+)'", re.search(r"PASSWORD_ONLY_CODES: readonly string\[\] = \[([^\]]*)\]", self.contract).group(1)):
            with self.subTest(code=code):
                self.assertIn(f"-Code '{code}' -Field 'environment'", installer)

    def test_a_failure_whose_next_step_is_another_location_is_decided_by_the_contract(self) -> None:
        installing = read(WIZARD / "screens" / "Installing.tsx")
        self.assertIn("const mismatch = leadsToAnotherLocation(operation.result?.error?.code);", installing)
        self.assertNotIn("=== 'repository_access_mismatch'", installing)
        codes = re.search(r"ANOTHER_LOCATION_CODES: readonly string\[\] = \[([^\]]*)\]", self.contract)
        self.assertIsNotNone(codes)
        self.assertEqual(["repository_access_mismatch", "repository_password_unavailable"], re.findall(r"'(\w+)'", codes.group(1)))

    def test_the_sample_host_refuses_changed_backups_in_the_installers_own_words(self) -> None:
        self.assertIn(BACKUPS_CHANGED + REFUSAL_ENDING, self.mock)
        self.assertNotIn("Rewindle’s guide", self.mock)

    def test_what_a_removal_keeps_is_named_by_the_kind_of_backups_in_the_dialogs_too(self) -> None:
        self.assertIn("const keptAccess = wizard.base?.environment.existingInstall.keptRepositoryAccess ?? null;", self.app)
        self.assertEqual(2, self.app.count("{keptWords(keptAccess)}"))
        self.assertNotIn("Your backups and recovery key are kept", self.app)
        self.assertNotIn("and recovery key", self.app)
        self.assertIn("accessOfOperation(operation)", self.app)

    # ---- the pick

    def test_the_pick_is_a_choice_that_starts_as_a_password_and_survives_a_change_of_location(self) -> None:
        self.assertIn("startBackup: true, repositoryAccess: 'password' };", self.wizard)
        self.assertIn("setRepositoryAccess: (repositoryAccess: RepositoryAccess) => update(current => ({ ...current, repositoryAccess })),", self.wizard)
        # Location changes spread the earlier choices, so the pick is kept; no other screen reads or writes it but the Password page.
        for path in (WIZARD / "screens" / "Location.tsx", WIZARD / "screens" / "Folders.tsx", WIZARD / "screens" / "Schedule.tsx"):
            with self.subTest(file=path.name):
                self.assertNotIn("repositoryAccess", read(path))

    def test_the_pick_is_never_part_of_a_plan_request(self) -> None:
        start = self.wizard.index("export function inputsOf(")
        body = self.wizard[start:self.wizard.index("\n}\n", start)]
        self.assertNotIn("ccess", body)
        inputs = re.search(r"export interface PlanInputs \{(.*?)\n\}", self.contract, re.S)
        self.assertIsNotNone(inputs)
        self.assertNotIn("ccess", inputs.group(1))
        # The plan requests are built from inputsOf (or from nothing) alone.
        for request in re.findall(r"bridge\.request\('getPlan', (\{.*?\})\)", self.wizard):
            with self.subTest(request=request):
                self.assertNotIn("ccess", request)

    def test_the_pick_goes_to_the_installer_only_at_install_through_accessToSend(self) -> None:
        start = self.wizard.index("const runOperation = useCallback(")
        body = self.wizard[start:self.wizard.index("  }, [base, choices, validation.plan]);", start)]
        self.assertEqual(1, self.wizard.count("accessToSend(validation.plan, choices.repository, choices.repositoryAccess)"))
        self.assertLess(body.index("accessToSend("), body.index("bridge.request('install'"))
        self.assertIn("choices: { ...inputsOf(choices, base), ...(repositoryAccess ? { repositoryAccess } : {}), startBackup: choices.startBackup },", body)
        self.assertIn("access: plannedAccess(validation.plan, choices.repository, choices.repositoryAccess)", body)
        # The uninstall request carries nothing of it.
        self.assertIn("await bridge.request('uninstall');", body)
        self.assertEqual(1, len(re.findall(r"\{ repositoryAccess \}", self.wizard)))

    def test_the_page_state_the_mode_and_the_steps_follow_the_same_facts(self) -> None:
        self.assertIn("() => passwordPageFor(validation.plan, choices?.repository ?? '', validation.checking, validation.error !== null),", self.wizard)
        self.assertIn("operation && operation.operation === 'install' ? accessOfOperation(operation) : plannedAccess(validation.plan, choices?.repository ?? '', choices?.repositoryAccess),", self.wizard)
        self.assertIn("const steps = useMemo(() => stepsFor(recoveryNeeded), [recoveryNeeded]);", self.wizard)
        for name in ("passwordPage,", "access,", "recoveryNeeded,", "steps,"):
            with self.subTest(returned=name):
                self.assertIn(f"\n    {name}\n", self.wizard)

    def test_phase_titles_for_backups_without_a_password_come_from_the_table_and_the_installers_list_is_untouched(self) -> None:
        self.assertIn("if (kind === 'install' && access === 'no_password' && Object.hasOwn(NO_PASSWORD_PHASE_TITLES, id)) return NO_PASSWORD_PHASE_TITLES[id];", self.wizard)
        self.assertIn(
            ".filter(phase => !(noPassword && phase.id === 'credential' && reported.get(phase.id)?.state !== 'failed'))", self.wizard)

    # ---- the mock host

    def test_the_sample_host_takes_the_pick_at_install_and_reports_what_the_installer_would(self) -> None:
        for marker in (
            "choices?.repositoryAccess", "The password choice is not valid.", "repository_access: ", "existing_repository_access: ",
            "kept_repository_access: ", "repository_access_mismatch", NO_PASSWORD_DETAIL, NO_KEY_DETAIL,
            "'Saving the recovery tools'",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, self.mock)
        # A plan request is answered from the folder alone; only an install is given a pick.
        self.assertIn("command === 'install'", self.mock)
        self.assertIn("kept_repository_access", self.mock)

    # ---- the host

    def test_the_host_puts_the_password_choice_after_the_drive_pair_and_before_the_folders_at_install_only(self) -> None:
        start = self.contract_cs.index("private static void AddChoices(")
        body = self.contract_cs[start:self.contract_cs.index("\n        }\n", start)]
        self.assertLess(body.index('"-DriveFsMyDriveRoot"'), body.index('"-RepositoryAccess"'))
        self.assertLess(body.index('"-RepositoryAccess"'), body.index('"-SourceList"'))
        self.assertIn("if (withAccess && inputs.RepositoryAccess != null)", body)
        self.assertRegex(self.contract_cs, r"AddChoices\(arguments, inputs, false\)")
        self.assertRegex(self.contract_cs, r"AddChoices\(arguments, inputs, true\)")
        self.assertEqual(1, len(re.findall(r"AddChoices\(arguments, inputs, true\)", self.contract_cs)))

    def test_the_host_accepts_only_the_two_modes_from_the_page(self) -> None:
        self.assertIn('public const string AccessPassword = "password";', self.contract_cs)
        self.assertIn('public const string AccessNone = "no_password";', self.contract_cs)
        self.assertIn('"The password choice is not valid."', self.contract_cs)
        self.assertIn('"repositoryAccess"', self.contract_cs)
        self.assertIn('Json.String(line.Fields, "repository_access", 32)', self.contract_cs)

    def test_no_recovery_key_is_copied_or_shown_for_backups_without_a_password(self) -> None:
        start = self.bridge_cs.index("private ProgressLine RecoveryKeyReport()")
        body = self.bridge_cs[start:self.bridge_cs.index("private const string UnreadableKeyMessage", start)]
        refusal = body.index("InstallerContract.AccessNone")
        # Before the check of the path: a stale key file from an earlier install must not be offered for these backups.
        self.assertLess(refusal, body.index("string.IsNullOrEmpty(reported.RecoveryKeyPath)"))
        self.assertLess(refusal, body.index("IsAcceptablePath"))
        self.assertIn("These backups have no password, so there is no recovery key to copy.", body)

    def test_the_host_tests_and_the_window_smoke_test_cover_the_password_choice(self) -> None:
        host_tests = read(PROJECT / "tests" / "SetupHostTests.cs")
        for marker in ('"-RepositoryAccess"', "no_password", "The password choice is not valid.", "no_recovery_key", "[string]$RepositoryAccess"):
            with self.subTest(marker=marker):
                self.assertIn(marker, host_tests)
        smoke = self.smoke_source()
        self.assertIn('mode == "no-password"', smoke)
        self.assertIn('scenario == "no-password"', smoke)
        self.assertIn("indexOf('have a password')", smoke)
        # The window waits for the owner's sentence (its first sentence, as the page prints it) before it clicks anything on the page.
        self.assertIn(OWNER_SENTENCE.split(". That")[0] + ".", smoke)

    def smoke_source(self) -> str:
        return read(PROJECT / "tests" / "SetupWindowSmoke.cs")

    # ---- styles

    def test_the_choice_cards_have_their_styles(self) -> None:
        css = read(WEB / "styles" / "setup.css")
        for selector in (".access-card {", ".access-card .radio-dot {", ".access-card .drive-meta {", ".access-warning {", ".done-facts li.is-quiet {"):
            with self.subTest(selector=selector):
                self.assertIn(selector, css)


if __name__ == "__main__":
    unittest.main()
