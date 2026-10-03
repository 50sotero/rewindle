$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scheduleSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\TaskSchedule.cs') -Raw -Encoding UTF8
$scheduleSource = "using System.Security.AccessControl;`r`nusing System.Web.Script.Serialization;`r`n" + $scheduleSource
$controllerSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\BackupCancellationController.cs') -Raw -Encoding UTF8
$controllerSource = $controllerSource -replace '^(using [^\r\n]+;\r?\n)+\r?\n', ''
function Join-DashboardSources {
    param([string[]]$Parts)
    $usingPattern = '(?m)^using\s+[^;]+;\s*\r?\n'
    $usings = @($Parts | ForEach-Object {
        [regex]::Matches($_, $usingPattern) | ForEach-Object { $_.Value.Trim() }
    } | Sort-Object -Unique)
    $bodies = @($Parts | ForEach-Object { [regex]::Replace($_, $usingPattern, '') })
    return ($usings -join [Environment]::NewLine) + [Environment]::NewLine + ($bodies -join [Environment]::NewLine)
}
$engineProfileSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\EngineProfile.cs') -Raw -Encoding UTF8
$harness = @'
namespace ResticBackuper.Dashboard
{
    public static class BackupCancellationFixtureHarness
    {
        public static string Status(string json, string expectedRunId)
        {
            BackupCancellationController.ActiveBackupStatus status;
            bool alreadyFinished;
            string error;
            bool valid = BackupCancellationController.TryValidateStatusDocument(
                json,
                expectedRunId,
                out status,
                out alreadyFinished,
                out error);
            if (!valid)
            {
                return "ERROR|" + error;
            }
            if (alreadyFinished)
            {
                return "FINISHED";
            }
            return "ACTIVE|" + status.RunId + "|" +
                status.WrapperPid.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" +
                status.WrapperStartFileTime + "|" +
                status.LauncherPid.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" +
                status.LauncherStartFileTime + "|" + status.State;
        }

        public static string Result(
            string json,
            string nonce,
            string digest,
            string sid,
            string runId,
            int exitCode)
        {
            BackupCancellationController.ValidatedCancellationResult result;
            string error;
            bool valid = BackupCancellationController.TryValidateResultDocument(
                json,
                nonce,
                digest,
                sid,
                runId,
                exitCode,
                out result,
                out error);
            if (!valid)
            {
                return "ERROR|" + error;
            }
            return "OK|" + (result.Ok ? "1" : "0") + "|" +
                (result.Requested ? "1" : "0") + "|" +
                (result.AlreadyFinished ? "1" : "0") + "|" +
                (result.ErrorMessage ?? "");
        }

        public static string Digest(
            string sid,
            string runId,
            int wrapperPid,
            string fingerprint,
            string nonce)
        {
            return BackupCancellationController.ComputeRequestDigest(
                sid,
                runId,
                wrapperPid,
                fingerprint,
                nonce);
        }
    }
}
'@
Add-Type -TypeDefinition ((Join-DashboardSources @($engineProfileSource, $scheduleSource, $controllerSource)) + [Environment]::NewLine + $harness) `
    -ReferencedAssemblies @(
        'System.dll',
        'System.Core.dll',
        'System.Xml.dll',
        'System.Web.Extensions.dll'
    )

$script:tests = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $script:tests++
    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}
function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    $script:tests++
    if ($Actual -notmatch $Pattern) {
        throw "$Message Got '$Actual'."
    }
}
function Assert-SourceContains {
    param([string]$Marker, [string]$Message)
    $script:tests++
    if (-not $controllerSource.Contains($Marker)) {
        throw "$Message Missing source marker '$Marker'."
    }
}
function Assert-SourceExcludes {
    param([string]$Marker, [string]$Message)
    $script:tests++
    if ($controllerSource.IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$Message Found forbidden source marker '$Marker'."
    }
}

$runId = '20260720T224500-ab12cd34'
$otherRunId = '20260720T224600-de56fa78'
$sid = 'S-1-5-21-111-222-333-1001'
$nonce = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$digest = '123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0'
$fingerprint = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
$channelId = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
$channelEventName = 'Local\ResticBackuper.Cancel.' + $channelId
$channelAlgorithm = [Security.Cryptography.SHA256]::Create()
try {
    $channelFingerprintText = [BitConverter]::ToString(
        $channelAlgorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($channelEventName)))
    $channelFingerprint = $channelFingerprintText.Replace('-', '').ToLowerInvariant()
}
finally {
    $channelAlgorithm.Dispose()
}

function New-StatusJson {
    param(
        [string]$RunId = $runId,
        [object]$Schema = 1,
        [string]$State = 'backing_up',
        [object]$WrapperPid = 4321,
        [object]$WrapperStartFileTime = '133000000000000000',
        [object]$LauncherPid = 1234,
        [object]$LauncherStartFileTime = '132999999999000000',
        [string]$CancelChannelId = $channelId,
        [string]$CancelChannelFingerprint = $channelFingerprint,
        [object]$FinishedUtc = $null,
        [object]$ExitCode = $null,
        [switch]$OmitFinished,
        [switch]$OmitExitCode
    )
    $document = [ordered]@{
        schema_version = $Schema
        run_id = $RunId
        state = $State
        wrapper_pid = $WrapperPid
        wrapper_start_filetime = $WrapperStartFileTime
        launcher_pid = $LauncherPid
        launcher_start_filetime = $LauncherStartFileTime
        cancel_channel_id = $CancelChannelId
        cancel_channel_fingerprint = $CancelChannelFingerprint
        cancel_requested_utc = $null
        cancel_signal_sent_utc = $null
        cancel_outcome = $null
    }
    if (-not $OmitFinished) { $document.finished_utc = $FinishedUtc }
    if (-not $OmitExitCode) { $document.exit_code = $ExitCode }
    return $document | ConvertTo-Json -Compress
}

function Parse-Status([string]$Json) {
    return [ResticBackuper.Dashboard.BackupCancellationFixtureHarness]::Status($Json, $runId)
}

Assert-Equal "ACTIVE|$runId|4321|133000000000000000|1234|132999999999000000|backing_up" (Parse-Status (New-StatusJson)) 'A current active status must preserve exact process FILETIME strings.'
foreach ($state in @('starting', 'verifying_snapshot', 'checking_repository', 'restoring_canary', 'checking_data_subset', 'cancelling')) {
    Assert-Match '^ACTIVE\|' (Parse-Status (New-StatusJson -State $state)) "Active state '$state' must be accepted."
}
Assert-Equal 'FINISHED' (Parse-Status (New-StatusJson -RunId $otherRunId)) 'A different current run means the reviewed run already finished.'
foreach ($state in @('success', 'success_unchanged', 'failed', 'partial', 'cancelled', 'cancel_failed')) {
    Assert-Equal 'FINISHED' (Parse-Status (New-StatusJson -State $state -FinishedUtc '2026-07-20T22:50:00Z' -ExitCode 0)) "Terminal state '$state' must be reported as finished."
}
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperPid 0)) 'A zero wrapper PID must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperPid '4321')) 'A string wrapper PID must fail strict JSON typing.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperPid 4.5)) 'A fractional wrapper PID must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperStartFileTime '0')) 'A zero wrapper start identity must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperStartFileTime 133000000000000000)) 'A numeric wrapper FILETIME must fail strict string typing.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperStartFileTime '0133000000000000000')) 'A wrapper FILETIME with leading zeroes must fail canonical parsing.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -WrapperStartFileTime '18446744073709551616')) 'A wrapper FILETIME beyond UInt64 must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -LauncherPid 0)) 'A zero launcher PID must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -LauncherStartFileTime '0')) 'A zero launcher start identity must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -LauncherStartFileTime 132999999999000000)) 'A numeric launcher FILETIME must fail strict string typing.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -CancelChannelId 'not-a-channel')) 'A noncanonical cancellation channel ID must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -CancelChannelFingerprint ('f' * 64))) 'A cancellation channel fingerprint mismatch must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -Schema '1')) 'A string schema version must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -State 'mystery')) 'An unknown status state must fail closed.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -FinishedUtc '2026-07-20T22:50:00Z')) 'An active state with a finish time must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -ExitCode 0)) 'An active state with an exit code must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -OmitFinished)) 'Missing finish metadata must fail.'
Assert-Match '^ERROR\|' (Parse-Status (New-StatusJson -OmitExitCode)) 'Missing exit metadata must fail.'
Assert-Match '^ERROR\|' (Parse-Status '{') 'Malformed status JSON must fail.'
Assert-Match '^ERROR\|' (Parse-Status ('x' * (4 * 1024 * 1024 + 1))) 'Oversized status JSON must fail before parsing.'

function New-ResultJson {
    param(
        [bool]$Ok = $true,
        [bool]$Requested = $true,
        [bool]$AlreadyFinished = $false,
        [AllowNull()][object]$ErrorText = $null,
        [string]$RequestNonce = $nonce,
        [string]$RequestDigest = $digest,
        [string]$RequestSid = $sid,
        [string]$Action = 'cancel',
        [string]$RunId = $runId
    )
    return ([ordered]@{
        schema_version = 1
        request_nonce = $RequestNonce
        request_digest = $RequestDigest
        request_user_sid = $RequestSid
        action = $Action
        run_id = $RunId
        ok = $Ok
        requested = $Requested
        already_finished = $AlreadyFinished
        error = $ErrorText
    } | ConvertTo-Json -Compress)
}

function Parse-Result([string]$Json, [int]$ExitCode) {
    return [ResticBackuper.Dashboard.BackupCancellationFixtureHarness]::Result(
        $Json, $nonce, $digest, $sid, $runId, $ExitCode)
}

Assert-Equal 'OK|1|1|0|' (Parse-Result (New-ResultJson) 0) 'A bound accepted cancellation must validate.'
Assert-Equal 'OK|1|0|1|' (Parse-Result (New-ResultJson -Requested $false -AlreadyFinished $true) 0) 'A bound already-finished result must validate.'
Assert-Equal 'OK|0|0|0|manager failed' (Parse-Result (New-ResultJson -Ok $false -Requested $false -ErrorText 'manager failed') 9) 'A bound failure must validate as an error result.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -RequestNonce ('f' * 64)) 0) 'A nonce mismatch must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -RequestDigest ('f' * 64)) 0) 'A digest mismatch must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -RequestSid 'S-1-5-18') 0) 'A SID mismatch must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -Action 'start') 0) 'An action mismatch must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -RunId $otherRunId) 0) 'A run ID mismatch must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson) 7) 'Success with a nonzero exit must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -Ok $false -Requested $false -ErrorText 'failed') 0) 'Failure with a zero exit must fail.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -Requested $false -AlreadyFinished $false) 0) 'Success must choose exactly one successful outcome.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -AlreadyFinished $true) 0) 'Success cannot be both requested and already finished.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -Ok $false -AlreadyFinished $true -Requested $false -ErrorText 'failed') 9) 'Failure cannot claim an already-finished success.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -ErrorText 'unexpected') 0) 'Success cannot carry an error.'
Assert-Match '^ERROR\|' (Parse-Result (New-ResultJson -Ok $false -Requested $false -ErrorText $null) 9) 'Failure must carry an error.'
$missingErrorResult = (New-ResultJson).Replace(',"error":null', '')
Assert-Match '^ERROR\|' (Parse-Result $missingErrorResult 0) 'The result error field must be present even when null.'
Assert-Match '^ERROR\|' (Parse-Result ('x' * 65537) 0) 'Oversized result JSON must fail before parsing.'

$expectedPayload = @(
    'ResticBackuper.BackupControlRequest.v1',
    $sid,
    'cancel',
    $runId,
    '4321',
    $fingerprint,
    $nonce
) -join "`n"
$algorithm = [Security.Cryptography.SHA256]::Create()
try {
    $expectedDigestText = [BitConverter]::ToString(
        $algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($expectedPayload)))
    $expectedDigest = $expectedDigestText.Replace('-', '').ToLowerInvariant()
}
finally {
    $algorithm.Dispose()
}
$actualDigest = [ResticBackuper.Dashboard.BackupCancellationFixtureHarness]::Digest(
    $sid, $runId, 4321, $fingerprint, $nonce)
Assert-Equal $expectedDigest $actualDigest 'The cancellation digest must match the protected manager contract exactly.'

foreach ($marker in @(
    'public static BackupCancellationResult RequestCancel(string expectedRunId)',
    'TaskScheduleReader.ReadInstalled()',
    'task.State != BackupTaskState.Running',
    'string.Equals(userSid, task.UserSid',
    'get { return EngineProfile.Current.BackupManagerFileName; }',
    'private const string ResultDirectoryName = "BackupManagerResults"',
    'private const string StatusFileName = "status.json"',
    'new UTF8Encoding(false, true)',
    'stream.Length <= 0 || stream.Length > MaximumStatusBytes',
    'HasProtectedResultAcl(stream.GetAccessControl(), userSid)',
    'startInfo.Verb = "runas"',
    '"-Action"',
    '"Cancel"',
    '"-ExpectedWrapperPid"',
    '"-ExpectedTaskFingerprint"',
    '"-ExpectedUserSid"',
    '"-RequestNonce"'
)) {
    Assert-SourceContains $marker "Cancellation controller security contract is incomplete."
}
foreach ($forbidden in @(
    '/End',
    'Stop-ScheduledTask',
    'TerminateProcess',
    'restic.exe',
    'backup.py',
    'dry_run.py',
    'Process.GetProcessById',
    'process.Kill()'
)) {
    Assert-SourceExcludes $forbidden 'Cancellation client must never stop a backup or task directly.'
}

[pscustomobject]@{
    ok = $true
    tests = $script:tests
    fixture_documents_only = $true
    live_task_queried = $false
    uac_started = $false
    backup_started_or_stopped = $false
} | ConvertTo-Json


