$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scheduleSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\TaskSchedule.cs') -Raw -Encoding UTF8
$scheduleSource = "using System.Security.AccessControl;`r`nusing System.Web.Script.Serialization;`r`n" + $scheduleSource
$launcherSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\ScheduleManagerLauncher.cs') -Raw -Encoding UTF8
$launcherSource = $launcherSource -replace '^(using [^\r\n]+;\r?\n)+\r?\n', ''
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
    public static class ScheduleResultFixtureHarness
    {
        public static string Validate(
            string json,
            string nonce,
            string digest,
            string sid,
            string baseline,
            int exitCode)
        {
            ScheduleChangeRequest request;
            string requestError;
            if (!ScheduleChangeRequest.TryCreate(
                "SelectedDays",
                "04:30",
                new[] { "Fri", "Sun", "Mon" },
                true,
                true,
                false,
                false,
                true,
                out request,
                out requestError))
            {
                return "HARNESS_ERROR|" + requestError;
            }
            ScheduleManagerLauncher.ValidatedScheduleResult result;
            string error;
            bool valid = ScheduleManagerLauncher.TryValidateResultDocument(
                json,
                nonce,
                digest,
                sid,
                baseline,
                request,
                exitCode,
                out result,
                out error);
            if (!valid)
            {
                return "ERROR|" + error;
            }
            return "OK|" + (result.Ok ? "1" : "0") + "|" +
                (result.Changed ? "1" : "0") + "|" +
                (result.RollbackPerformed ? "1" : "0") + "|" +
                (result.RollbackVerified ? "1" : "0") + "|" +
                (result.InstalledFingerprint ?? "") + "|" +
                (result.ErrorMessage ?? "");
        }
    }
}
'@
Add-Type -TypeDefinition ((Join-DashboardSources @($engineProfileSource, $scheduleSource, $launcherSource)) + [Environment]::NewLine + $harness) `
    -ReferencedAssemblies @(
        'System.dll',
        'System.Core.dll',
        'System.Xml.dll',
        'System.Web.Extensions.dll'
    )

$script:tests = 0
function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    $script:tests++
    if ($Actual -notmatch $Pattern) {
        throw "$Message Got '$Actual'."
    }
}
function Assert-NotMatch {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    $script:tests++
    if ($Actual -match $Pattern) {
        throw "$Message Got an unexpected match in the source."
    }
}

$nonce = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$digest = '123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0'
$baseline = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
$installed = '1111111111111111111111111111111111111111111111111111111111111111'
$sid = 'S-1-5-21-111-222-333-1001'

Assert-Match 'if \(desired\.Cadence == BackupScheduleCadence\.SelectedDays\)' $launcherSource 'Only selected-days requests should emit the Days argument.'
Assert-Match 'arguments\.Add\("-Days"\)' $launcherSource 'Selected-days requests must emit their canonical day CSV.'
Assert-NotMatch '"-Time",\s*desired\.TimeArgument,\s*"-Days"' $launcherSource 'Daily requests must omit the empty Days argument for Windows PowerShell -File binding.'

function New-ResultJson {
    param(
        [bool]$Ok = $true,
        [bool]$Changed = $true,
        [bool]$RollbackPerformed = $false,
        [bool]$RollbackVerified = $false,
        [bool]$BackupStarted = $false,
        [object]$Schedule = [ordered]@{
            cadence = 'SelectedDays'
            time = '04:30'
            days = @('Sun', 'Mon', 'Fri')
            enabled = $true
            start_when_available = $true
            wake_to_run = $false
            allow_start_on_batteries = $false
            stop_if_going_on_batteries = $true
        },
        [AllowNull()][string]$InstalledFingerprint = $installed,
        [AllowNull()][string]$ErrorText = $null,
        [string]$RequestNonce = $nonce,
        [string]$RequestDigest = $digest,
        [string]$RequestSid = $sid,
        [string]$ExpectedFingerprint = $baseline,
        [string]$Action = 'apply'
    )
    return ([ordered]@{
        schema_version = 1
        request_nonce = $RequestNonce
        request_digest = $RequestDigest
        request_user_sid = $RequestSid
        action = $Action
        expected_current_fingerprint = $ExpectedFingerprint
        ok = $Ok
        changed = $Changed
        rollback_performed = $RollbackPerformed
        rollback_verified = $RollbackVerified
        backup_started = $BackupStarted
        installed_fingerprint = $InstalledFingerprint
        error = $ErrorText
        schedule = $Schedule
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Validate([string]$Json, [int]$ExitCode) {
    return [ResticBackuper.Dashboard.ScheduleResultFixtureHarness]::Validate(
        $Json, $nonce, $digest, $sid, $baseline, $ExitCode)
}

$success = Validate (New-ResultJson) 0
Assert-Match ('^OK\|1\|1\|0\|0\|' + $installed + '\|$') $success 'A bound successful result must validate.'

$unchanged = Validate (New-ResultJson -Changed $false) 0
Assert-Match '^OK\|1\|0\|' $unchanged 'A verified no-op result must validate.'

$failure = Validate (New-ResultJson -Ok $false -Changed $false -Schedule $null -InstalledFingerprint $baseline -ErrorText 'Task is running') 9
Assert-Match ('^OK\|0\|0\|0\|0\|' + $baseline + '\|Task is running$') $failure 'A bound failure with a nonzero exit must validate as failure.'

Assert-Match '^ERROR\|' (Validate (New-ResultJson -RequestNonce ('f' * 64)) 0) 'A nonce mismatch must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -RequestDigest ('f' * 64)) 0) 'A digest mismatch must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -RequestSid 'S-1-5-18') 0) 'A SID mismatch must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -ExpectedFingerprint ('f' * 64)) 0) 'A baseline mismatch must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -Action 'remove') 0) 'An action mismatch must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -BackupStarted $true) 0) 'Any reported backup start must fail closed.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson) 7) 'Success with a nonzero exit must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -Ok $false -Schedule $null -ErrorText 'failed') 0) 'Failure with a zero exit must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -Ok $false -Schedule $null -RollbackPerformed $true -RollbackVerified $false -ErrorText 'failed') 7) 'An unverified rollback must fail.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -InstalledFingerprint ('A' * 64)) 0) 'The installed fingerprint must be lowercase hex.'
Assert-Match '^ERROR\|' (Validate (New-ResultJson -Schedule $null) 0) 'A successful result must include its exact schedule.'

$wrongSchedule = [ordered]@{
    cadence = 'SelectedDays'
    time = '04:30'
    days = @('Sun', 'Mon', 'Fri')
    enabled = $true
    start_when_available = $true
    wake_to_run = $true
    allow_start_on_batteries = $false
    stop_if_going_on_batteries = $true
}
Assert-Match '^ERROR\|' (Validate (New-ResultJson -Schedule $wrongSchedule) 0) 'A result schedule differing from the request must fail.'
Assert-Match '^ERROR\|' (Validate ('x' * 65537) 0) 'Oversized result content must fail before parsing.'

[pscustomobject]@{
    ok = $true
    tests = $script:tests
    result_parser_only = $true
    uac_started = $false
    live_task_queried = $false
    production_task_started = $false
} | ConvertTo-Json
