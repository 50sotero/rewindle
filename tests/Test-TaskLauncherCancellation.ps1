$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourcePath = Join-Path $project 'src\task_launcher\Program.cs'
$buildPath = Join-Path $project 'src\task_launcher\build.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw

$requiredFragments = @(
    'Local\\ResticBackuper.Cancel.',
    'O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)',
    'RESTICBACKUPER_CANCEL_EVENT_NAME',
    'RESTICBACKUPER_CANCEL_CHANNEL_ID',
    'RESTICBACKUPER_CANCEL_CHANNEL_FINGERPRINT',
    'RESTICBACKUPER_LAUNCHER_PID',
    'RESTICBACKUPER_LAUNCHER_START_FILETIME',
    'CreateNoWindow | CreateSuspended | CreateUnicodeEnvironment',
    'JobObjectLimitKillOnJobClose',
    'MsgWaitForMultipleObjectsEx',
    'if (message == WmClose)',
    'SetEvent(activeCancellationEvent)',
    'return IntPtr.Zero;',
    'byte[] random = new byte[32];',
    'generator.GetBytes(random);'
)
foreach ($fragment in $requiredFragments) {
    if (-not $source.Contains($fragment)) {
        throw "Task launcher cancellation contract is missing: $fragment"
    }
}
if ($source.Contains('Environment.SetEnvironmentVariable')) {
    throw 'Cancellation identity must be passed in a child-only environment block.'
}
if ($source -notmatch 'WmClose[\s\S]+SetEvent\(activeCancellationEvent\)[\s\S]+return IntPtr.Zero') {
    throw 'WM_CLOSE must set the event without destroying the supervisor window.'
}

$buildResult = & $buildPath | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $buildResult.executable -PathType Leaf)) {
    throw 'Task launcher build did not produce an executable.'
}
if ($buildResult.bytes -le 0 -or $buildResult.sha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Task launcher build metadata is invalid.'
}

$assembly = [Reflection.Assembly]::LoadFile($buildResult.executable)
$programType = $assembly.GetType(
    'ResticBackuper.TaskLauncher.Program',
    $true,
    $false
)
$binding = [Reflection.BindingFlags]'Static,NonPublic'
$activeEvent = $programType.GetField('activeCancellationEvent', $binding)
$windowProcedure = $programType.GetMethod('CancellationWindowProcedure', $binding)
if ($null -eq $activeEvent -or $null -eq $windowProcedure) {
    throw 'The native WM_CLOSE cancellation contract could not be reflected.'
}
$fixtureEvent = [Threading.EventWaitHandle]::new(
    $false,
    [Threading.EventResetMode]::ManualReset
)
try {
    $activeEvent.SetValue($null, $fixtureEvent.SafeWaitHandle.DangerousGetHandle())
    $returnValue = $windowProcedure.Invoke(
        $null,
        @([IntPtr]::Zero, [uint32]0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    )
    if ([IntPtr]$returnValue -ne [IntPtr]::Zero) {
        throw 'WM_CLOSE was not consumed by the task launcher.'
    }
    if (-not $fixtureEvent.WaitOne(0)) {
        throw 'WM_CLOSE did not set the cooperative cancellation event.'
    }
}
finally {
    $activeEvent.SetValue($null, [IntPtr]::Zero)
    $fixtureEvent.Dispose()
}

# The elevated Python child gets an allow-listed environment. Settings planted
# in this process (as a user could plant them in HKCU\Environment) must not
# reach it; every Windows value comes from the Windows API.
$system = [Environment]::SystemDirectory
$windows = Split-Path -Parent $system
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$planted = [ordered]@{
    RESTIC_PASSWORD_COMMAND = 'C:\planted\evil.cmd'
    RESTIC_PASSWORD_FILE = 'C:\planted\password.txt'
    RESTIC_REPOSITORY_FILE = 'C:\planted\repository.txt'
    RCLONE_CONFIG_PLANTED_TYPE = 'sftp'
    RCLONE_CONFIG_PLANTED_SSH = 'C:\planted\evil.cmd'
    PYTHONPATH = 'C:\planted'
    COR_ENABLE_PROFILING = '1'
    COR_PROFILER = '{00000000-0000-0000-0000-000000000000}'
    GODEBUG = 'planted=1'
    HTTPS_PROXY = 'http://planted.invalid:8080'
    PATH = 'C:\planted'
    TEMP = 'C:\planted'
    TMP = 'C:\planted'
    SystemRoot = 'C:\planted'
    windir = 'C:\planted'
    ComSpec = 'C:\planted\cmd.exe'
    LOCALAPPDATA = 'C:\planted\AppData\Local'
    PROCESSOR_ARCHITECTURE = 'planted'
}
$channelType = $programType.GetNestedType('CancellationChannel', [Reflection.BindingFlags]'NonPublic')
$channelConstructor = $channelType.GetConstructor(
    [Reflection.BindingFlags]'Instance,NonPublic',
    $null,
    [Type[]]@([IntPtr], [string], [string], [string]),
    $null
)
$buildEnvironment = $programType.GetMethod('BuildChildEnvironment', $binding)
if ($null -eq $channelConstructor -or $null -eq $buildEnvironment) {
    throw 'The task launcher child environment could not be reflected.'
}
$fixtureChannelId = 'ab' * 32
$fixtureEventName = 'Local\ResticBackuper.Cancel.' + $fixtureChannelId
$fixtureChannel = $channelConstructor.Invoke(
    @([IntPtr]::Zero, $fixtureChannelId, $fixtureEventName, ('cd' * 32))
)
$saved = @{}
$block = [IntPtr]::Zero
$child = [ordered]@{}
try {
    foreach ($name in $planted.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $planted[$name], 'Process')
    }
    $block = [IntPtr]$buildEnvironment.Invoke(
        $null,
        @($fixtureChannel, [uint32]4321, '1234567890')
    )
}
finally {
    foreach ($name in $planted.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
}
try {
    $offset = 0
    while ($true) {
        $entry = [Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]::Add($block, $offset))
        if ([string]::IsNullOrEmpty($entry)) {
            break
        }
        $separator = $entry.IndexOf('=')
        $child[$entry.Substring(0, $separator)] = $entry.Substring($separator + 1)
        $offset += ($entry.Length + 1) * 2
    }
}
finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($block)
}

$expected = [ordered]@{
    ComSpec = (Join-Path $system 'cmd.exe')
    LOCALAPPDATA = $localAppData
    NUMBER_OF_PROCESSORS = [string][Environment]::ProcessorCount
    OS = 'Windows_NT'
    PATH = (@($system, $windows, (Join-Path $system 'Wbem'), (Join-Path $system 'WindowsPowerShell\v1.0')) -join ';')
    PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
    RESTICBACKUPER_CANCEL_CHANNEL_FINGERPRINT = ('cd' * 32)
    RESTICBACKUPER_CANCEL_CHANNEL_ID = $fixtureChannelId
    RESTICBACKUPER_CANCEL_EVENT_NAME = $fixtureEventName
    RESTICBACKUPER_LAUNCHER_PID = '4321'
    RESTICBACKUPER_LAUNCHER_START_FILETIME = '1234567890'
    SystemDrive = $windows.Substring(0, 2)
    SystemRoot = $windows
    windir = $windows
}
$actualNames = @($child.Keys | Sort-Object)
$expectedNames = @($expected.Keys | Sort-Object)
if (($actualNames -join ',') -ne ($expectedNames -join ',')) {
    throw ('The task launcher child environment names are wrong: ' + ($actualNames -join ', '))
}
foreach ($name in $expected.Keys) {
    if ($child[$name] -cne $expected[$name]) {
        throw "The task launcher child environment has the wrong $name value: $($child[$name])"
    }
}

# The Google Drive check task starts the check's Windows PowerShell through the launcher too, so it never has a window.
# Its environment is Windows' own as well: nothing planted reaches it, and it gets no cancellation identity.
$buildCheckEnvironment = $programType.GetMethod('BuildGoogleDriveCheckEnvironment', $binding)
$buildCheckCommandLine = $programType.GetMethod('BuildGoogleDriveCheckCommandLine', $binding)
$isRepositoryId = $programType.GetMethod('IsRepositoryId', $binding)
if ($null -eq $buildCheckEnvironment -or $null -eq $buildCheckCommandLine -or $null -eq $isRepositoryId) {
    throw 'The task launcher has no Google Drive check mode.'
}
$saved = @{}
$block = [IntPtr]::Zero
$checkChild = [ordered]@{}
try {
    foreach ($name in $planted.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $planted[$name], 'Process')
    }
    $block = [IntPtr]$buildCheckEnvironment.Invoke($null, @())
}
finally {
    foreach ($name in $planted.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
}
try {
    $offset = 0
    while ($true) {
        $entry = [Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]::Add($block, $offset))
        if ([string]::IsNullOrEmpty($entry)) {
            break
        }
        $separator = $entry.IndexOf('=')
        $checkChild[$entry.Substring(0, $separator)] = $entry.Substring($separator + 1)
        $offset += ($entry.Length + 1) * 2
    }
}
finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($block)
}
$checkExpected = [ordered]@{
    ComSpec = (Join-Path $system 'cmd.exe')
    NUMBER_OF_PROCESSORS = [string][Environment]::ProcessorCount
    OS = 'Windows_NT'
    PATH = (@($system, $windows, (Join-Path $system 'Wbem'), (Join-Path $system 'WindowsPowerShell\v1.0')) -join ';')
    PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
    PSModulePath = (Join-Path $system 'WindowsPowerShell\v1.0\Modules')
    SystemDrive = $windows.Substring(0, 2)
    SystemRoot = $windows
    TEMP = (Join-Path $windows 'Temp')
    TMP = (Join-Path $windows 'Temp')
    windir = $windows
}
$actualNames = @($checkChild.Keys | Sort-Object)
$expectedNames = @($checkExpected.Keys | Sort-Object)
if (($actualNames -join ',') -ne ($expectedNames -join ',')) {
    throw ('The Google Drive check environment names are wrong: ' + ($actualNames -join ', '))
}
foreach ($name in $checkExpected.Keys) {
    if ($checkChild[$name] -cne $checkExpected[$name]) {
        throw "The Google Drive check environment has the wrong $name value: $($checkChild[$name])"
    }
}

$fixtureId = '0123456789abcdef' * 4
$commandLine = [string]$buildCheckCommandLine.Invoke(
    $null,
    @(
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        'C:\Program Files\ResticBackuper\verify_my_drive_cloud_repository.ps1',
        'C:\Program Files\ResticBackuper\backup-config.json',
        'C:\ProgramData\ResticBackuperCloudVerification',
        $fixtureId
    )
)
$expectedCommandLine = (
    '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive ' +
    '-ExecutionPolicy Bypass -File "C:\Program Files\ResticBackuper\verify_my_drive_cloud_repository.ps1" ' +
    '-ConfigPath "C:\Program Files\ResticBackuper\backup-config.json" ' +
    '-CloudVerificationRoot "C:\ProgramData\ResticBackuperCloudVerification" -ExpectedRepositoryId ' + $fixtureId
)
if ($commandLine -cne $expectedCommandLine) {
    throw "The Google Drive check command line is wrong: $commandLine"
}
foreach ($case in @(
    @($fixtureId, $true),
    @($fixtureId.ToUpperInvariant(), $false),
    @($fixtureId.Substring(1), $false),
    @(($fixtureId + '0'), $false),
    @(($fixtureId.Substring(1) + '"'), $false),
    @(($fixtureId.Substring(1) + 'g'), $false),
    @('', $false)
)) {
    if ([bool]$isRepositoryId.Invoke($null, @([string]$case[0])) -ne [bool]$case[1]) {
        throw "The launcher judged the repository ID '$($case[0])' wrongly."
    }
}
$refused = $false
try {
    [void]$buildCheckCommandLine.Invoke($null, @('a', 'b', 'c', 'd', ($fixtureId.Substring(1) + ' ')))
}
catch {
    $inner = $_.Exception
    while ($null -ne $inner -and $inner -isnot [ArgumentException]) {
        $inner = $inner.InnerException
    }
    $refused = $null -ne $inner
}
if (-not $refused) {
    throw 'The launcher built a Google Drive check command line around an invalid repository ID.'
}

# The built launcher itself, started without a window. Outside Program Files it stops at its runtime check (65), which
# it reaches only with arguments it accepts; anything else stops it at once (64).
function Invoke-Launcher {
    param([string[]]$Arguments)

    $info = [Diagnostics.ProcessStartInfo]::new($buildResult.executable)
    $info.Arguments = ($Arguments -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw 'The task launcher did not exit.'
        }
        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}
foreach ($case in @(
    @(@(), 65),
    @(@('--google-drive-check', '--expected-repository-id', $fixtureId), 65),
    @(@('--google-drive-check', '--expected-repository-id', $fixtureId.ToUpperInvariant()), 64),
    @(@('--google-drive-check', '--expected-repository-id'), 64),
    @(@('--expected-repository-id', $fixtureId, '--google-drive-check'), 64),
    @(@('--google-drive-check', '--expected-repository-id', $fixtureId, '--scheduled'), 64),
    @(@('--GOOGLE-DRIVE-CHECK', '--expected-repository-id', $fixtureId), 64)
)) {
    $exitCode = Invoke-Launcher -Arguments ([string[]]$case[0])
    if ($exitCode -ne [int]$case[1]) {
        throw "The task launcher exited with $exitCode, not $($case[1]), for arguments: $($case[0] -join ' ')"
    }
}

# The whole start of a check, from a stand-in program folder: Windows PowerShell runs the stand-in verifier there, with
# the check's arguments and the allow-listed environment, and its exit code becomes the launcher's.
$runCheck = $programType.GetMethod('RunGoogleDriveCheck', $binding)
if ($null -eq $runCheck) {
    throw 'The task launcher cannot start a Google Drive check.'
}
# An error on the way ends in an exit code, never an exception: the launcher has no window, and an exception left
# unhandled could show an error window.
$guardedExit = [int]$runCheck.Invoke($null, [object[]]@('C:\no|such folder', [string]$fixtureId))
if ($guardedExit -ne 64) {
    throw "The launcher returned $guardedExit, not 64, for a program folder it cannot name."
}
$runCheckStart = $source.IndexOf('private static int RunGoogleDriveCheck(')
$runCheckEnd = $source.IndexOf('private static string BuildGoogleDriveCheckCommandLine(')
if ($runCheckStart -lt 0 -or $runCheckEnd -le $runCheckStart -or
    $source.Substring($runCheckStart, $runCheckEnd - $runCheckStart) -notmatch
        'catch \(ArgumentException\)[\s\S]+catch \(Exception\)\s*\{[^}]*return 74;') {
    throw 'Any other error starting a Google Drive check must end in exit code 74.'
}
# The program folder's name has a space, as Program Files does.
$standInRuntime = Join-Path ([IO.Path]::GetTempPath()) ('rewindle launcher check ' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($standInRuntime)
try {
    [IO.File]::WriteAllText((Join-Path $standInRuntime 'backup-config.json'), '{}')
    [IO.File]::WriteAllText(
        (Join-Path $standInRuntime 'verify_my_drive_cloud_repository.ps1'),
        @'
param([string]$ConfigPath, [string]$CloudVerificationRoot, [string]$ExpectedRepositoryId)
# A program the check leaves running, without a window: the launcher must end it with the check.
$childInfo = [Diagnostics.ProcessStartInfo]::new(
    (Join-Path ([Environment]::SystemDirectory) 'ping.exe'),
    '-n 120 127.0.0.1')
$childInfo.UseShellExecute = $false
$childInfo.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($childInfo)
$seen = [ordered]@{
    config = $ConfigPath
    root = $CloudVerificationRoot
    id = $ExpectedRepositoryId
    directory = [Environment]::CurrentDirectory
    temp = [string]$env:TEMP
    planted = [string]$env:RESTIC_PASSWORD_COMMAND + [string]$env:PYTHONPATH + [string]$env:RCLONE_CONFIG_PLANTED_TYPE
    cancel = [string]$env:RESTICBACKUPER_CANCEL_EVENT_NAME
    child = [string]$child.Id
    child_started = [string]$child.StartTime.ToFileTimeUtc()
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'seen.json'), ($seen | ConvertTo-Json -Compress))
exit 7
'@
    )
    $plantedForCheck = [ordered]@{
        RESTIC_PASSWORD_COMMAND = 'C:\planted\evil.cmd'
        PYTHONPATH = 'C:\planted'
        RCLONE_CONFIG_PLANTED_TYPE = 'sftp'
        TEMP = 'C:\planted'
        TMP = 'C:\planted'
    }
    $saved = @{}
    try {
        foreach ($name in $plantedForCheck.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $plantedForCheck[$name], 'Process')
        }
        $checkExit = [int]$runCheck.Invoke($null, [object[]]@([string]$standInRuntime, [string]$fixtureId))
    }
    finally {
        foreach ($name in $plantedForCheck.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
    if ($checkExit -ne 7) {
        throw "The launcher returned $checkExit, not the check's own exit code 7."
    }
    $seen = [IO.File]::ReadAllText((Join-Path $standInRuntime 'seen.json')) | ConvertFrom-Json
    $expectedSeen = [ordered]@{
        config = (Join-Path $standInRuntime 'backup-config.json')
        root = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ResticBackuperCloudVerification')
        id = $fixtureId
        directory = $standInRuntime
        temp = (Join-Path $windows 'Temp')
        planted = ''
        cancel = ''
    }
    foreach ($name in $expectedSeen.Keys) {
        if ([string]$seen.$name -cne [string]$expectedSeen[$name]) {
            throw "The check started with the wrong $name : $($seen.$name)"
        }
    }

    # The program the check left running ended with it.
    $leftover = Get-Process -Id ([int]$seen.child) -ErrorAction SilentlyContinue
    if ($null -ne $leftover) {
        try {
            $outlived = $false
            try {
                # Only the process the check started counts: by now its ID may name another one.
                $outlived = [string]$leftover.StartTime.ToFileTimeUtc() -ceq [string]$seen.child_started -and
                    -not $leftover.WaitForExit(10000)
            }
            catch {
                # It ended while it was being looked at.
            }
            if ($outlived) {
                $leftover.Kill()
                throw 'A program the Google Drive check started outlived it: the launcher did not end it.'
            }
        }
        finally {
            $leftover.Dispose()
        }
    }
}
finally {
    Remove-Item -LiteralPath $standInRuntime -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    passed = $true
    wm_close_runtime_signal = 'passed'
    child_environment = 'allow-listed'
    google_drive_check_environment = 'allow-listed'
    google_drive_check_arguments = 'checked'
    google_drive_check_leftovers = 'ended with the check'
    executable = $buildResult.executable
    bytes = $buildResult.bytes
    sha256 = $buildResult.sha256
} | ConvertTo-Json -Depth 3
