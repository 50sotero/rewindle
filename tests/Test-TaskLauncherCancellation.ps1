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

[pscustomobject]@{
    passed = $true
    wm_close_runtime_signal = 'passed'
    executable = $buildResult.executable
    bytes = $buildResult.bytes
    sha256 = $buildResult.sha256
} | ConvertTo-Json -Depth 3
