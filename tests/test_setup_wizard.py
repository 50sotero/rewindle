"""Source checks for Rewindle Setup: the wizard (web), its desktop host (C#) and the build that joins them.

They read files and run nothing: no setup program, installer or backup is started. The host's logic is exercised by
tests/Test-SetupHost.ps1, and the real window by tests/Test-SetupWindow.ps1 (a developer tool, not run here).
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
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
            "-PlanOnly", "-PlanOutput", "-Repository", "-RepositoryStorageMode", "-DriveFsMyDriveRoot", "-SourceList", "-Schedule",
            "-DisableVss", "-Unattended", "-ExpectedUserSid", "-ProgressPath", "-StartBackup",
        ):
            with self.subTest(flag=flag):
                self.assertIn(f'"{flag}"', self.contract)

    def test_parameters_the_installer_already_has_are_the_ones_the_host_passes(self) -> None:
        param_block = self.installer[: self.installer.index("Set-StrictMode")]
        for name in ("Repository", "RepositoryStorageMode", "DriveFsMyDriveRoot", "SourceList", "Schedule", "DisableVss", "StartBackup", "Unattended", "ExpectedUserSid"):
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
        for name in ("fresh", "no-second-drive", "drivefs", "existing-install", "legacy-installed", "unsupported-os", "plan-errors", "install-failure", "uac-declined", "key-unreadable", "goes-online-only", "kept-backups"):
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
        # The wait for the installer's last answer on the location page is what keeps Next off while it checks.
        self.assertRegex(self.app, r"next\('schedule', !choices\?\.repository \|\| errors \|\| checking\)")

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


if __name__ == "__main__":
    unittest.main()
