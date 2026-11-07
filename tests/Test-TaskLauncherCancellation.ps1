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

[pscustomobject]@{
    passed = $true
    wm_close_runtime_signal = 'passed'
    child_environment = 'allow-listed'
    executable = $buildResult.executable
    bytes = $buildResult.bytes
    sha256 = $buildResult.sha256
} | ConvertTo-Json -Depth 3
