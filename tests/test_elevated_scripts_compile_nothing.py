"""Static checks that no elevated script compiles code, and that the installer runs a program it downloaded only from a folder
that only administrators can change, held open from its signature check until it has exited.

The installer, the uninstaller and the managers and helpers in src run elevated with the account's own %TEMP%, which the
account's unelevated programs can change. Compiling C# there (Add-Type runs csc.exe on files it writes to %TEMP% and then
loads the assembly it built) would let such a program swap what the elevated script loads, so the scripts emit their
P/Invoke calls in memory instead. The behaviour is exercised by tests/Test-InstallPlan.ps1 (the installer's native calls
leave nothing in a watched %TEMP%; a held file can't be changed, deleted or renamed) and tests/Test-ManageRepository.ps1.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / "installer" / "Install-ResticBackuper.ps1"
UNINSTALLER = PROJECT / "installer" / "Uninstall-ResticBackuper.ps1"
BOOTSTRAP = PROJECT / "installer" / "setup" / "ElevatedBootstrap.cs"
ELEVATED_SCRIPTS = sorted([*(PROJECT / "src").glob("*.ps1"), *(PROJECT / "installer").glob("*.ps1")])

# Loading a framework assembly by name compiles nothing.
ASSEMBLY_ONLY = re.compile(r"^\s*Add-Type -AssemblyName [A-Za-z][\w.]*(?:, [A-Za-z][\w.]*)*\s*$")
COMPILERS = re.compile(
    r"CSharpCodeProvider|VBCodeProvider|CodeDomProvider|CompileAssemblyFrom|Microsoft\.CSharp|New-WebServiceProxy"
    r"|\[(?:System\.)?Reflection\.Assembly\]::(?:Load|LoadFrom|LoadFile|UnsafeLoadFrom)\(",
    re.I,
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code_lines(path: Path) -> list[tuple[int, str]]:
    """Every line that is not a whole-line comment, with its number."""
    return [
        (number, line)
        for number, line in enumerate(read(path).splitlines(), 1)
        if not line.lstrip().startswith("#")
    ]


def functions(text: str) -> dict[str, str]:
    """Top-level PowerShell functions: `function Name {` at column 0 to the next `}` at column 0."""
    text = re.sub(r"@'\n.*?\n'@", "@'\n'@", text, flags=re.S)
    return {
        match.group(1): match.group(2)
        for match in re.finditer(r"^function ([A-Za-z][\w-]*) \{\n(.*?)^\}$", text, re.S | re.M)
    }


class NoElevatedScriptCompilesCodeTests(unittest.TestCase):
    def test_the_elevated_scripts_are_the_ones_expected(self) -> None:
        names = {path.name for path in ELEVATED_SCRIPTS}
        for name in (
            "Install-ResticBackuper.ps1", "Uninstall-ResticBackuper.ps1", "Manage-Backup.ps1", "Manage-Repository.ps1",
            "Manage-Restore.ps1", "Manage-Schedule.ps1", "Manage-Sources.ps1", "install_google_drive_sync_task.ps1",
            "verify_my_drive_cloud_repository.ps1",
        ):
            self.assertIn(name, names)

    def test_add_type_only_loads_framework_assemblies(self) -> None:
        problems = [
            f"{path.relative_to(PROJECT)}:{number}: {line.strip()}"
            for path in ELEVATED_SCRIPTS
            for number, line in code_lines(path)
            if re.search(r"\bAdd-Type\b", line, re.I) and not ASSEMBLY_ONLY.match(line)
        ]
        self.assertEqual([], problems, "an elevated script compiles code; emit the P/Invoke calls with Reflection.Emit instead")

    def test_no_other_compiler_or_assembly_file_is_used(self) -> None:
        problems = [
            f"{path.relative_to(PROJECT)}:{number}: {line.strip()}"
            for path in ELEVATED_SCRIPTS
            for number, line in code_lines(path)
            if COMPILERS.search(line)
        ]
        self.assertEqual([], problems)

    def test_native_calls_are_emitted_in_memory_and_never_saved(self) -> None:
        emitting = set()
        for path in ELEVATED_SCRIPTS:
            for _, line in code_lines(path):
                if "DefineDynamicAssembly(" in line:
                    emitting.add(path.name)
                    self.assertIn("[Reflection.Emit.AssemblyBuilderAccess]::Run)", line, f"{path.name} may only run what it emits")
                self.assertNotRegex(line, r"AssemblyBuilderAccess\]::(?:RunAndSave|Save)\b")
        for name in ("Install-ResticBackuper.ps1", "Uninstall-ResticBackuper.ps1", "Manage-Repository.ps1", "Manage-Restore.ps1",
                     "install_google_drive_sync_task.ps1"):
            self.assertIn(name, emitting)

    def test_emitted_types_are_used_through_the_returned_type_never_by_name(self) -> None:
        # A type resolved by name could be one that something else defined first; each helper returns the type it emitted.
        for path in (INSTALLER, UNINSTALLER, PROJECT / "src" / "Manage-Repository.ps1"):
            text = read(path)
            for name in ("ResticBackuperSetup.NativePath", "ResticBackuperInstaller.NativeVolume", "ResticBackuperInstaller.NativeDisk",
                         "RepositoryRelocation.NativeVolume"):
                self.assertNotIn(f"[{name}]", text, path.name)
                self.assertNotIn(f"'{name}' -as [type]", text, path.name)

    def test_the_installers_calls_keep_set_last_error(self) -> None:
        # The disk lookup retries on ERROR_MORE_DATA and a failed volume lookup reports Windows' own error, which needs it.
        installer = functions(read(INSTALLER))["Get-InstallerNativeMethods"]
        self.assertIn("$dllImport.GetField('SetLastError')", installer)
        self.assertIn("[object[]]@($true, ", installer)
        manager = functions(read(PROJECT / "src" / "Manage-Repository.ps1"))["Get-RepositoryNativeMethods"]
        self.assertIn("$dllImport.GetField('SetLastError')", manager)
        self.assertIn("[object[]]@($true, ", manager)


class DownloadedProgramTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = read(INSTALLER)
        cls.defined = functions(cls.text)

    def test_the_webview2_bootstrapper_is_downloaded_into_a_folder_only_administrators_can_change(self) -> None:
        body = self.defined["Ensure-WebView2Runtime"]
        for forbidden in ("GetTempPath", "$env:TEMP", "$env:TMP", "Start-Process", "Assert-MicrosoftSignedExecutable"):
            self.assertNotIn(forbidden, body)
        folder = body.index("$folder = New-AdministratorsOnlyFolder")
        target = body.index("$bootstrapper = Join-Path $folder ")
        download = body.index("Invoke-WebRequest -UseBasicParsing -Uri $webView2BootstrapperUri -OutFile $bootstrapper")
        run = body.index("Invoke-HeldExecutable -Path $bootstrapper ")
        self.assertLess(folder, target)
        self.assertLess(target, download)
        self.assertLess(download, run)
        self.assertIn("-Code 'webview2_installer_untrusted'", body[run:])
        self.assertIn("Remove-Item -LiteralPath $folder -Recurse -Force", body[body.index("finally {"):])

    def test_the_program_is_held_from_before_its_check_until_it_has_exited(self) -> None:
        body = self.defined["Invoke-HeldExecutable"]
        hold = body.index("$held = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)")
        guarded = body.index("try {")
        check = body.index("Assert-MicrosoftSignedExecutable -Path $Path -Code $Code")
        start = body.index("Start-Process -FilePath $Path ")
        release = body.index("finally {")
        self.assertLess(hold, guarded)
        self.assertLess(guarded, check)
        self.assertLess(check, start)
        self.assertLess(start, release)
        self.assertIn("-Wait", body[start:release])
        self.assertIn("$held.Dispose()", body[release:])
        self.assertNotRegex(body, r"FileShare\]::(?:ReadWrite|Delete|Write)")

    def test_the_protected_folder_is_made_with_its_access_list_in_place(self) -> None:
        security = self.defined["New-AdministratorsOnlyFolderSecurity"]
        self.assertIn("SecurityIdentifier]::new('S-1-5-32-544')", security)
        self.assertIn("$security.SetOwner($administrators)", security)
        self.assertIn("$security.SetAccessRuleProtection($true, $false)", security)
        self.assertIn("SecurityIdentifier]::new('S-1-5-18')", security)
        self.assertIn("'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'", security)
        folder = self.defined["New-AdministratorsOnlyFolder"]
        self.assertIn("[Environment+SpecialFolder]::CommonApplicationData", folder)
        self.assertLess(folder.index("if (Test-Path -LiteralPath $path)"), folder.index("[IO.Directory]::CreateDirectory($path, (New-AdministratorsOnlyFolderSecurity))"))
        for check in ("[IO.FileAttributes]::ReparsePoint", "AreAccessRulesProtected", ".Value -ne 'S-1-5-32-544'"):
            self.assertIn(check, folder)
        # The Setup bootstrap's name pattern, so its clean-up of folders an interrupted run left covers these too.
        prefix = re.search(r'StagingPrefix = "([^"]+)"', read(BOOTSTRAP)).group(1)
        self.assertIn(f"('{prefix}' + [Guid]::NewGuid().ToString('N'))", folder)

    def test_the_elevated_install_keeps_its_temporary_files_in_a_protected_folder(self) -> None:
        use = self.defined["Use-ProtectedTemporaryFolder"]
        self.assertIn("$folder = New-AdministratorsOnlyFolder", use)
        self.assertIn("$env:TEMP = $folder", use)
        self.assertIn("$env:TMP = $folder", use)
        preflight = self.defined["Invoke-InstallPreflight"]
        self.assertLess(preflight.index("Invoke-SelfElevation"), preflight.index("Use-ProtectedTemporaryFolder"))
        # The progress feed is checked against the account's own temporary folder, so it is opened first.
        main = self.text.split("$preflightSucceeded = $false", 1)[1]
        self.assertLess(main.index("Open-ProgressFeed -Path $ProgressPath"), main.index("Invoke-InstallPreflight"))
        finals = re.findall(r"^finally \{\n(.*?)^\}$", main, re.S | re.M)
        self.assertEqual(2, len(finals))
        for block in finals:
            self.assertIn("Remove-ProtectedTemporaryFolder", block)

    def test_none_of_this_is_reachable_from_plan_mode(self) -> None:
        reachable: set[str] = set()
        pending = ["Invoke-PlanMode"]
        while pending:
            name = pending.pop()
            if name in reachable:
                continue
            reachable.add(name)
            for other in self.defined:
                if other not in reachable and re.search(rf"(?<![\w-]){re.escape(other)}(?![\w-])", self.defined[name]):
                    pending.append(other)
        for name in ("New-AdministratorsOnlyFolder", "Use-ProtectedTemporaryFolder", "Remove-ProtectedTemporaryFolder", "Invoke-HeldExecutable"):
            self.assertNotIn(name, reachable)
        # The native helpers are reachable (plan mode reads the drives) and change nothing.
        for name in ("Get-FeedNativeMethods", "Get-InstallerNativeMethods"):
            self.assertIn(name, reachable)


if __name__ == "__main__":
    unittest.main()
