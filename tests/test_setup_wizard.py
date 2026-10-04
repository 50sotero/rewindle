"""Source checks for Rewindle Setup: the wizard (web), its desktop host (C#) and the build that joins them.

They read files and run nothing: no setup program, installer or backup is started. The host's logic is exercised by
tests/Test-SetupHost.ps1, and the real window by tests/Test-SetupWindow.ps1 (a developer tool, not run here).
"""

from __future__ import annotations

import json
from pathlib import Path
import re
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
        for name in ("fresh", "no-second-drive", "drivefs", "existing-install", "legacy-installed", "unsupported-os", "plan-errors", "install-failure", "uac-declined", "key-unreadable", "goes-online-only"):
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


if __name__ == "__main__":
    unittest.main()
