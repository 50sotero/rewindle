#requires -Version 5.1

# Elevated PowerShell launchers start rclone, Restic and Python with an allow-listed environment, never with their own.
# An elevated process's environment comes from the user's profile (HKCU\Environment included), which the user can change
# without approval, so these checks plant Restic, rclone and Windows settings in this process and look at what a child
# really receives. Covered here: the 03:00 Google Drive check (verify_my_drive_cloud_repository.ps1), including the
# real rclone password helper under that environment and the read-only rclone connection string, and the installer's
# repository set-up (Install-ResticBackuper.ps1). Manage-Restore.ps1 is covered end to end by Test-ManageRestore.ps1.
# Nothing here is installed or elevated: the functions are extracted from the sources and run against a fake child.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$verifierSource = Join-Path $projectRoot 'src\verify_my_drive_cloud_repository.ps1'
$passwordHelperSource = Join-Path $projectRoot 'src\reveal-rclone-config-password.ps1'
$installerSource = Join-Path $projectRoot 'installer\Install-ResticBackuper.ps1'
$system = [Environment]::SystemDirectory
$windows = [IO.Directory]::GetParent($system).FullName
$powershell = Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$encoding = [Text.UTF8Encoding]::new($false)
$script:assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)

    $script:assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-FailsClosed {
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Parameter(Mandatory)] [string]$Message
    )

    $script:assertions++
    $failure = $null
    try {
        [void](& $Action)
    }
    catch {
        $failure = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($failure)) {
        throw "Assertion failed: $Message"
    }
}

function Get-SourceFunctions {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string[]]$Names
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        throw "$Path did not parse."
    }
    $definitions = @(
        $ast.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $Names
            },
            $true
        )
    )
    $found = @($definitions | ForEach-Object { $_.Name })
    $missing = @($Names | Where-Object { $_ -notin $found })
    if ($missing.Count -ne 0 -or $definitions.Count -ne $Names.Count) {
        throw ("These functions could not be extracted exactly from ${Path}: " + ($missing -join ', '))
    }
    return (@($definitions | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine)
}

. ([scriptblock]::Create((Get-SourceFunctions -Path $verifierSource -Names @(
    'ConvertTo-NativeArgument',
    'New-NativeChildEnvironment',
    'Get-ReadOnlyRemoteSpec',
    'Invoke-NativeToFiles'
))))
. ([scriptblock]::Create((Get-SourceFunctions -Path $installerSource -Names @(
    'Quote-ProcessArgument',
    'New-PythonChildEnvironment',
    'Invoke-ProtectedPython'
))))

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('rewindle-child-env-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
[void][IO.Directory]::CreateDirectory($fixtureRoot)

# A stand-in for rclone, Restic and Python: it records its working folder, its arguments and its whole environment.
$fakeRecord = Join-Path $fixtureRoot 'fake-native-record.txt'
$fakeNative = Join-Path $fixtureRoot 'fake-native.exe'
$fakeSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class FakeNative {
  public static int Main(string[] args) {
    List<string> lines = new List<string>();
    lines.Add("CWD\t" + Environment.CurrentDirectory);
    foreach (string argument in args) lines.Add("ARG\t" + argument);
    IDictionary variables = Environment.GetEnvironmentVariables();
    List<string> names = new List<string>();
    foreach (DictionaryEntry item in variables) names.Add((string)item.Key);
    names.Sort(StringComparer.Ordinal);
    foreach (string name in names) lines.Add("ENV\t" + name + "=" + (string)variables[name]);
    File.WriteAllLines(@"__FAKE_RECORD__", lines.ToArray(), new UTF8Encoding(false));
    return args.Length > 0 && args[args.Length - 1] == "exit-seven" ? 7 : 0;
  }
}
'@
Add-Type -TypeDefinition $fakeSource.Replace('__FAKE_RECORD__', $fakeRecord) -OutputAssembly $fakeNative -OutputType ConsoleApplication

function Read-FakeRecord {
    $record = [pscustomobject]@{
        WorkingDirectory = $null
        Arguments = [Collections.Generic.List[string]]::new()
        Environment = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    }
    foreach ($line in [IO.File]::ReadAllLines($fakeRecord, $encoding)) {
        $tab = $line.IndexOf("`t")
        $kind = $line.Substring(0, $tab)
        $value = $line.Substring($tab + 1)
        if ($kind -ceq 'CWD') {
            $record.WorkingDirectory = $value
        }
        elseif ($kind -ceq 'ARG') {
            $record.Arguments.Add($value)
        }
        else {
            $separator = $value.IndexOf('=')
            $record.Environment[$value.Substring(0, $separator)] = $value.Substring($separator + 1)
        }
    }
    [IO.File]::Delete($fakeRecord)
    return $record
}

function Assert-ExactEnvironment {
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$Actual,
        [Parameter(Mandatory)] [Collections.IDictionary]$Expected,
        [Parameter(Mandatory)] [string]$Label
    )

    $actualNames = [string[]]@($Actual.Keys)
    $expectedNames = [string[]]@($Expected.Keys)
    [Array]::Sort($actualNames, [StringComparer]::Ordinal)
    [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
    Assert-True (($actualNames -join ', ') -ceq ($expectedNames -join ', ')) (
        "$Label gets exactly the allowed names; it got: " + ($actualNames -join ', '))
    foreach ($name in $expectedNames) {
        Assert-True ([string]$Actual[$name] -ceq [string]$Expected[$name]) "$Label gets $name = $($Expected[$name])"
    }
}

# What a user could plant in their own environment: a replacement rclone backend that runs a program, another account's
# token, a wider scope, Restic password and repository files, .NET, Go, Python and proxy settings, and Windows values
# pointing at a folder of their choice.
$planted = [ordered]@{
    RCLONE_CONFIG_RESTICBACKUPERGOOGLEREADONLY_TYPE = 'sftp'
    RCLONE_CONFIG_RESTICBACKUPERGOOGLEREADONLY_SSH = 'C:\planted\evil.cmd'
    RCLONE_CONFIG_RESTICBACKUPERGOOGLEREADONLY_TOKEN = '{"access_token":"planted"}'
    RCLONE_DRIVE_TOKEN = '{"access_token":"planted"}'
    RCLONE_DRIVE_SCOPE = 'drive'
    RCLONE_DRIVE_ROOT_FOLDER_ID = 'planted-folder'
    RCLONE_CONFIG = 'C:\planted\rclone.conf'
    RCLONE_LOG_FILE = 'C:\planted\rclone.log'
    RESTIC_PASSWORD_COMMAND = 'C:\planted\evil.cmd'
    RESTIC_PASSWORD_FILE = 'C:\planted\password.txt'
    RESTIC_REPOSITORY_FILE = 'C:\planted\repository.txt'
    COR_ENABLE_PROFILING = '0'
    COR_PROFILER = '{00000000-0000-0000-0000-000000000000}'
    GODEBUG = 'planted=1'
    HTTPS_PROXY = 'http://planted.invalid:8080'
    PYTHONPATH = 'C:\planted'
    XDG_CONFIG_HOME = 'C:\planted'
    PATH = 'C:\planted'
    TEMP = 'C:\planted'
    TMP = 'C:\planted'
    SystemRoot = 'C:\planted'
    windir = 'C:\planted'
    ComSpec = 'C:\planted\cmd.exe'
    PSModulePath = 'C:\planted\Modules'
    LOCALAPPDATA = 'C:\planted\AppData\Local'
    PROCESSOR_ARCHITECTURE = 'planted'
}

function Invoke-WithPlantedEnvironment {
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Collections.IDictionary]$Override = @{}
    )

    $values = [ordered]@{}
    foreach ($name in $planted.Keys) { $values[$name] = $planted[$name] }
    foreach ($name in $Override.Keys) { $values[$name] = $Override[$name] }
    $saved = @{}
    try {
        foreach ($name in $values.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process')
        }
        return (& $Action)
    }
    finally {
        foreach ($name in $values.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

$windowsValues = [ordered]@{
    SystemRoot = $windows
    windir = $windows
    SystemDrive = [IO.Path]::GetPathRoot($windows).TrimEnd('\')
    ComSpec = (Join-Path $system 'cmd.exe')
    PATH = (@($system, $windows, (Join-Path $system 'Wbem'), (Join-Path $system 'WindowsPowerShell\v1.0')) -join ';')
    PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
    OS = 'Windows_NT'
    NUMBER_OF_PROCESSORS = [string][Environment]::ProcessorCount
}

try {
    # The 03:00 Google Drive check: Restic and rclone get the Windows values, Windows' own module folder, the run's
    # protected temporary folder and the settings the verifier chose, nothing else.
    $runFolder = Join-Path $fixtureRoot 'runs\run-1'
    $temporary = Join-Path $runFolder 'temp'
    [void][IO.Directory]::CreateDirectory($temporary)
    $settings = [ordered]@{
        RCLONE_CONFIG = (Join-Path $runFolder 'rclone-readonly.conf')
        RCLONE_PASSWORD_COMMAND = '"C:\fixture\powershell.exe" -NoProfile -File "C:\fixture\reveal.ps1"'
        RCLONE_ASK_PASSWORD = 'false'
        RCLONE_CACHE_DIR = (Join-Path $runFolder 'rclone-cache')
        RESTIC_PASSWORD_COMMAND = '"C:\fixture\python.exe" -I -S -B "C:\fixture\secret_store.py" reveal'
    }
    $cloudExpected = [ordered]@{}
    foreach ($name in $windowsValues.Keys) { $cloudExpected[$name] = $windowsValues[$name] }
    $cloudExpected['PSModulePath'] = Join-Path $system 'WindowsPowerShell\v1.0\Modules'
    $cloudExpected['TEMP'] = $temporary
    $cloudExpected['TMP'] = $temporary
    $helperExpected = [ordered]@{}
    foreach ($name in $cloudExpected.Keys) { $helperExpected[$name] = $cloudExpected[$name] }
    foreach ($name in $settings.Keys) { $cloudExpected[$name] = $settings[$name] }

    # One run of each launcher before anything is planted: Windows PowerShell finds .NET assemblies through SystemRoot
    # the first time it meets a type, so a planted SystemRoot would otherwise break this test process, not the launcher.
    [void](Invoke-NativeToFiles `
        -Executable $fakeNative `
        -Arguments @('warm-up') `
        -StdoutPath (Join-Path $runFolder 'warm-up.stdout.txt') `
        -StderrPath (Join-Path $runFolder 'warm-up.stderr.txt') `
        -Environment (New-NativeChildEnvironment -TemporaryDirectory $temporary -Settings $settings))
    [void](Get-ReadOnlyRemoteSpec -RemoteName 'ResticBackuperGoogleReadOnly' -RootFolderId 'root')
    [void](Invoke-ProtectedPython -Python $fakeNative -WorkingDirectory $fixtureRoot -Arguments @('warm-up'))
    [IO.File]::Delete($fakeRecord)

    $cloudPath = 'ResticBackups/Personal copy'
    $lsjsonExit = Invoke-WithPlantedEnvironment {
        $environment = New-NativeChildEnvironment -TemporaryDirectory $temporary -Settings $settings
        $remote = Get-ReadOnlyRemoteSpec -RemoteName 'ResticBackuperGoogleReadOnly' -RootFolderId 'root'
        Invoke-NativeToFiles `
            -Executable $fakeNative `
            -Arguments @('lsjson', ($remote + ':' + $cloudPath), '--recursive') `
            -StdoutPath (Join-Path $runFolder 'lsjson.stdout.json') `
            -StderrPath (Join-Path $runFolder 'lsjson.stderr.log') `
            -Environment $environment
    }
    Assert-True ($lsjsonExit -eq 0) 'the fake rclone ran'
    $record = Read-FakeRecord
    Assert-ExactEnvironment -Actual $record.Environment -Expected $cloudExpected -Label 'rclone and Restic'
    Assert-True (
        ($record.Arguments -join '|') -ceq
            ('lsjson|ResticBackuperGoogleReadOnly,scope=drive.readonly,root_folder_id=root:' + $cloudPath + '|--recursive')
    ) 'rclone gets the read-only scope and the My Drive root in its connection string'
    Assert-True ($record.WorkingDirectory.TrimEnd('\') -ceq $fixtureRoot.TrimEnd('\')) 'the child runs in its own folder'

    $helperExit = Invoke-WithPlantedEnvironment {
        $environment = New-NativeChildEnvironment -TemporaryDirectory $temporary
        Invoke-NativeToFiles `
            -Executable $fakeNative `
            -Arguments @('-I', '-S', '-B', 'C:\fixture\verify_cloud_repository_inventory.py') `
            -StdoutPath (Join-Path $runFolder 'inventory.stdout.json') `
            -StderrPath (Join-Path $runFolder 'inventory.stderr.log') `
            -Environment $environment
    }
    Assert-True ($helperExit -eq 0) 'the fake inventory helper ran'
    Assert-ExactEnvironment -Actual (Read-FakeRecord).Environment -Expected $helperExpected -Label 'the inventory helper'

    $architectures = Invoke-WithPlantedEnvironment -Override @{ PROCESSOR_ARCHITECTURE = 'ARM64' } {
        (New-NativeChildEnvironment -TemporaryDirectory $temporary)['PROCESSOR_ARCHITECTURE']
    }
    Assert-True ([string]$architectures -ceq 'ARM64') 'a real processor architecture is passed on'
    Assert-FailsClosed { New-NativeChildEnvironment -TemporaryDirectory $temporary -Settings @{ PATH = 'C:\planted' } } (
        'only rclone and Restic settings can be added')

    # The real password helper still decrypts the rclone configuration password with only these variables, as rclone
    # starts it.
    $assets = Join-Path $fixtureRoot 'assets'
    [void][IO.Directory]::CreateDirectory($assets)
    $helper = Join-Path $assets 'reveal-rclone-config-password.ps1'
    [IO.File]::Copy($passwordHelperSource, $helper)
    $credentialPath = Join-Path $assets 'rclone-config-password.clixml'
    $fixturePassword = 'fixture-rclone-password-' + [Guid]::NewGuid().ToString('N')
    [Management.Automation.PSCredential]::new(
        'rclone-config',
        (ConvertTo-SecureString -String $fixturePassword -AsPlainText -Force)
    ) | Export-Clixml -LiteralPath $credentialPath
    $revealStdout = Join-Path $runFolder 'reveal.stdout.txt'
    $revealStderr = Join-Path $runFolder 'reveal.stderr.txt'
    $revealExit = Invoke-WithPlantedEnvironment {
        $environment = New-NativeChildEnvironment -TemporaryDirectory $temporary -Settings $settings
        Invoke-NativeToFiles `
            -Executable $powershell `
            -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $helper, '-CredentialPath', $credentialPath
            ) `
            -StdoutPath $revealStdout `
            -StderrPath $revealStderr `
            -Environment $environment
    }
    Assert-True ($revealExit -eq 0) ('the rclone password helper runs with the allow-listed environment: ' +
        [IO.File]::ReadAllText($revealStderr))
    Assert-True ([IO.File]::ReadAllText($revealStdout).TrimEnd("`r", "`n") -ceq $fixturePassword) (
        'the rclone password helper still decrypts its password')

    foreach ($badId in @('', 'root,scope=drive', 'root:other', "ro'ot", 'ro"ot', 'a=b', "root`n", 'root folder')) {
        Assert-FailsClosed { Get-ReadOnlyRemoteSpec -RemoteName 'ResticBackuperGoogleReadOnly' -RootFolderId $badId } (
            "a root folder ID that could change the connection string is refused: $badId")
    }
    foreach ($badName in @('', 'Remote,scope=drive', 'Remote:x', "Remote`n", 'Remote name')) {
        Assert-FailsClosed { Get-ReadOnlyRemoteSpec -RemoteName $badName -RootFolderId 'root' } (
            "a remote name that could change the connection string is refused: $badName")
    }

    # The installer's repository set-up: Python gets the Windows values and the user's local application-data folder as
    # Windows reports it, nothing else, and runs in the install folder.
    $installFolder = Join-Path $fixtureRoot 'Program Files\Rewindle fixture'
    [void][IO.Directory]::CreateDirectory($installFolder)
    $pythonExpected = [ordered]@{}
    foreach ($name in $windowsValues.Keys) { $pythonExpected[$name] = $windowsValues[$name] }
    $pythonExpected['LOCALAPPDATA'] = $localAppData
    $pythonArguments = @('-I', '-S', '-B', (Join-Path $installFolder 'initialize_repository.py'), '--config',
        (Join-Path $installFolder 'backup-config.json'), 'C:\trailing backslash\')
    $pythonExit = Invoke-WithPlantedEnvironment {
        Invoke-ProtectedPython -Python $fakeNative -WorkingDirectory $installFolder -Arguments $pythonArguments
    }
    Assert-True ($pythonExit -eq 0) 'the fake installer Python ran'
    $record = Read-FakeRecord
    Assert-ExactEnvironment -Actual $record.Environment -Expected $pythonExpected -Label 'the installer Python'
    Assert-True (($record.Arguments -join '|') -ceq ($pythonArguments -join '|')) 'the installer Python gets its arguments'
    Assert-True ($record.WorkingDirectory.TrimEnd('\') -ceq $installFolder) 'the installer Python runs in the install folder'
    $failedExit = Invoke-ProtectedPython -Python $fakeNative -WorkingDirectory $installFolder -Arguments @('-I', 'exit-seven')
    Assert-True ($failedExit -eq 7) 'the installer sees the exit code of its Python'
    [IO.File]::Delete($fakeRecord)
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}

[pscustomobject]@{
    passed = $true
    assertions = $script:assertions
    covered = 'verifier rclone, Restic and helper children; rclone password helper; installer Python'
} | ConvertTo-Json -Compress
