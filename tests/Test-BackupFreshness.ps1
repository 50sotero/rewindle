$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$telemetrySource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\Telemetry.cs') -Raw -Encoding UTF8
$scheduleSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\TaskSchedule.cs') -Raw -Encoding UTF8
$freshnessSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\BackupFreshness.cs') -Raw -Encoding UTF8
$engineProfileSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\EngineProfile.cs') -Raw -Encoding UTF8
$atomicFileSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\AtomicFile.cs') -Raw -Encoding UTF8
$sourceConfigurationSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\SourceConfiguration.cs') -Raw -Encoding UTF8
$harness = @'
namespace ResticBackuper.Dashboard
{
    using System;
    using System.Collections.Generic;
    using System.Globalization;

    public static class BackupFreshnessFixtureHarness
    {
        public static string Evaluate(
            string cadence,
            string time,
            string days,
            bool enabled,
            int taskState,
            string lastVerifiedUtc,
            string nowLocal,
            string nowUtc,
            TimeZoneInfo timeZone,
            int graceMinutes)
        {
            BackupScheduleCadence parsedCadence = string.Equals(
                cadence,
                "Daily",
                StringComparison.OrdinalIgnoreCase)
                ? BackupScheduleCadence.Daily
                : BackupScheduleCadence.SelectedDays;
            TimeSpan parsedTime = TimeSpan.ParseExact(time, @"hh\:mm", CultureInfo.InvariantCulture);
            List<DayOfWeek> parsedDays = new List<DayOfWeek>();
            if (!string.IsNullOrEmpty(days))
            {
                foreach (string token in days.Split(','))
                {
                    DayOfWeek day;
                    if (!TaskScheduleCanonicalizer.TryParseDayToken(token, out day))
                    {
                        throw new ArgumentException("Invalid day token: " + token);
                    }
                    parsedDays.Add(day);
                }
            }
            DateTime? verified = string.IsNullOrEmpty(lastVerifiedUtc)
                ? (DateTime?)null
                : DateTime.Parse(
                    lastVerifiedUtc,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
            DateTime local = DateTime.SpecifyKind(
                DateTime.Parse(nowLocal, CultureInfo.InvariantCulture),
                DateTimeKind.Unspecified);
            DateTime utc = DateTime.Parse(
                nowUtc,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
            TaskSchedule schedule = new TaskSchedule(
                parsedCadence,
                parsedTime,
                parsedDays.ToArray(),
                enabled,
                true,
                true,
                true,
                false,
                true,
                "ResticBackuper",
                "S-1-5-21-test",
                "launcher.exe",
                "C:\\Program Files\\ResticBackuper",
                (BackupTaskState)taskState,
                null,
                "fixture");
            BackupFreshnessResult result = BackupFreshnessEvaluator.Evaluate(
                schedule,
                verified,
                local,
                utc,
                timeZone,
                TimeSpan.FromMinutes(graceMinutes));
            return result.State.ToString() + "|" +
                Format(result.LastVerifiedUtc) + "|" +
                Format(result.LatestDueLocal) + "|" +
                Format(result.LatestDueUtc) + "|" +
                Format(result.NextScheduledLocal) + "|" +
                result.StatusLabel + "|" + result.Detail;
        }

        // Moves every Windows folder an engine path is built from (the installed plan, the cloud proof, the dashboard's own
        // folder) under the fixture, so the telemetry reader below never looks at a real installation.
        public static void UseFixtureFolderRoots(string root)
        {
            EngineProfile.UseFolderRootsForTesting(root);
        }

        private static string Format(DateTime? value)
        {
            return value.HasValue
                ? value.Value.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture)
                : string.Empty;
        }
    }
}
'@

$sourceParts = @($engineProfileSource, $atomicFileSource, $sourceConfigurationSource, $telemetrySource, $scheduleSource, $freshnessSource)
$usingPattern = '(?m)^using\s+[^;]+;\s*\r?\n'
$allUsings = @($sourceParts | ForEach-Object {
    [regex]::Matches($_, $usingPattern) | ForEach-Object { $_.Value.Trim() }
} | Sort-Object -Unique)
$sourceBodies = @($sourceParts | ForEach-Object {
    [regex]::Replace($_, $usingPattern, '')
})
$combinedSource = ($allUsings -join [Environment]::NewLine) +
    [Environment]::NewLine + ($sourceBodies -join [Environment]::NewLine) +
    [Environment]::NewLine + $harness

Add-Type -TypeDefinition $combinedSource `
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
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:tests++
    if (-not $Condition) {
        throw $Message
    }
}
function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    $script:tests++
    if ($Actual -notmatch $Pattern) {
        throw "$Message Got '$Actual'."
    }
}

function Evaluate-Freshness {
    param(
        [string]$Cadence = 'Daily',
        [string]$Time = '02:00',
        [string]$Days = '',
        [bool]$Enabled = $true,
        [int]$TaskState = 3,
        [string]$LastVerifiedUtc = '',
        [string]$NowLocal,
        [string]$NowUtc,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Utc,
        [int]$GraceMinutes = 120
    )
    return [ResticBackuper.Dashboard.BackupFreshnessFixtureHarness]::Evaluate(
        $Cadence,
        $Time,
        $Days,
        $Enabled,
        $TaskState,
        $LastVerifiedUtc,
        $NowLocal,
        $NowUtc,
        $TimeZone,
        $GraceMinutes)
}

$dailyHealthy = Evaluate-Freshness `
    -LastVerifiedUtc '2026-07-21T02:30:00Z' `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T05:00:00Z'
Assert-Match '^Healthy\|' $dailyHealthy 'A verified daily occurrence must be healthy.'
Assert-Match '\|2026-07-22T02:00:00\|Healthy\|' $dailyHealthy 'Healthy output must expose the next local occurrence.'

$dailyOverdue = Evaluate-Freshness `
    -LastVerifiedUtc '2026-07-20T02:30:00Z' `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T05:00:00Z'
Assert-Match '^Overdue\|' $dailyOverdue 'An older daily success must become overdue after grace.'
Assert-Match '\|2026-07-21T02:00:00\|2026-07-21T02:00:00\|' $dailyOverdue 'Overdue output must bind the missed local and UTC occurrence.'

$withinGrace = Evaluate-Freshness `
    -LastVerifiedUtc '2026-07-20T02:30:00Z' `
    -NowLocal '2026-07-21T03:30:00' `
    -NowUtc '2026-07-21T03:30:00Z'
Assert-Match '^Healthy\|' $withinGrace 'A current occurrence must not be overdue before its grace period ends.'

$weeklyOverdue = Evaluate-Freshness `
    -Cadence 'SelectedDays' `
    -Days 'Mon,Fri' `
    -LastVerifiedUtc '2026-07-19T03:00:00Z' `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T05:00:00Z'
Assert-Match '^Overdue\|' $weeklyOverdue 'Selected weekdays must detect a missed Monday occurrence.'
Assert-Match '\|2026-07-20T02:00:00\|2026-07-20T02:00:00\|' $weeklyOverdue 'Weekly freshness must use the selected local weekday.'

$plusFourteen = [TimeZoneInfo]::CreateCustomTimeZone(
    'Freshness-UTC+14',
    [TimeSpan]::FromHours(14),
    'Freshness UTC+14',
    'Freshness UTC+14')
$localDateOverdue = Evaluate-Freshness `
    -Cadence 'SelectedDays' `
    -Time '00:30' `
    -Days 'Mon' `
    -LastVerifiedUtc '2026-07-19T00:00:00Z' `
    -NowLocal '2026-07-20T03:00:00' `
    -NowUtc '2026-07-19T13:00:00Z' `
    -TimeZone $plusFourteen
Assert-Match '^Overdue\|' $localDateOverdue 'Weekday evaluation must use the local date even when UTC is the prior date.'
Assert-Match '\|2026-07-20T00:30:00\|2026-07-19T10:30:00\|' $localDateOverdue 'Local calendar occurrence must convert to the correct UTC date.'

$transitionStart = [TimeZoneInfo+TransitionTime]::CreateFloatingDateRule(
    [DateTime]::new(1, 1, 1, 2, 0, 0),
    3,
    5,
    [DayOfWeek]::Sunday)
$transitionEnd = [TimeZoneInfo+TransitionTime]::CreateFloatingDateRule(
    [DateTime]::new(1, 1, 1, 3, 0, 0),
    10,
    5,
    [DayOfWeek]::Sunday)
$adjustment = [TimeZoneInfo+AdjustmentRule]::CreateAdjustmentRule(
    [DateTime]::new(2020, 1, 1),
    [DateTime]::new(2030, 12, 31),
    [TimeSpan]::FromHours(1),
    $transitionStart,
    $transitionEnd)
$dstZone = [TimeZoneInfo]::CreateCustomTimeZone(
    'Freshness-European-DST',
    [TimeSpan]::FromHours(1),
    'Freshness European DST',
    'Freshness Standard',
    'Freshness Daylight',
    [TimeZoneInfo+AdjustmentRule[]]@($adjustment))

$springForward = Evaluate-Freshness `
    -Time '02:30' `
    -LastVerifiedUtc '2026-03-28T02:00:00Z' `
    -NowLocal '2026-03-29T06:00:00' `
    -NowUtc '2026-03-29T04:00:00Z' `
    -TimeZone $dstZone
Assert-Match '^Overdue\|' $springForward 'A spring-forward day must still evaluate a local calendar occurrence.'
Assert-Match '\|2026-03-29T03:00:00\|2026-03-29T01:00:00\|' $springForward 'An invalid local trigger time must advance to the first valid minute.'

$fallBack = Evaluate-Freshness `
    -Cadence 'SelectedDays' `
    -Time '02:30' `
    -Days 'Sun' `
    -LastVerifiedUtc '2026-10-25T01:00:00Z' `
    -NowLocal '2026-10-25T05:00:00' `
    -NowUtc '2026-10-25T04:00:00Z' `
    -TimeZone $dstZone
# A slot in the hour that repeats when the clocks go back is due from its first occurrence, so a run at either pass covers
# it; a backup verified before the first pass still does not.
Assert-Match '^Healthy\|' $fallBack 'A run during the repeated hour covers the slot it repeats.'
Assert-Match '\|2026-10-25T02:30:00\|2026-10-25T00:30:00\|' $fallBack 'An ambiguous trigger is due from its first UTC occurrence.'
$fallBackMissed = Evaluate-Freshness `
    -Cadence 'SelectedDays' `
    -Time '02:30' `
    -Days 'Sun' `
    -LastVerifiedUtc '2026-10-25T00:00:00Z' `
    -NowLocal '2026-10-25T05:00:00' `
    -NowUtc '2026-10-25T04:00:00Z' `
    -TimeZone $dstZone
Assert-Match '^Overdue\|' $fallBackMissed 'A backup verified before the first pass of the repeated hour does not cover its slot.'

$paused = Evaluate-Freshness `
    -Enabled $false `
    -TaskState 1 `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T05:00:00Z'
Assert-Match '^Paused\|' $paused 'A disabled task must report Paused rather than overdue.'
Assert-Match '\|Paused\|Automatic backups are paused' $paused 'Paused status must be explicit in text.'

$noVerified = Evaluate-Freshness `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T05:00:00Z'
Assert-Match '^NoVerifiedBackup\|' $noVerified 'An enabled schedule without a verified backup must be explicit.'

$futureClock = Evaluate-Freshness `
    -LastVerifiedUtc '2026-07-21T06:00:00Z' `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T05:00:00Z'
Assert-Match '^ClockAnomaly\|' $futureClock 'A future verified timestamp must be treated as a clock anomaly.'
Assert-Match '\|Clock needs attention\|' $futureClock 'Clock anomalies must have a non-color status label.'

$mismatchedClocks = Evaluate-Freshness `
    -LastVerifiedUtc '2026-07-21T02:30:00Z' `
    -NowLocal '2026-07-21T05:00:00' `
    -NowUtc '2026-07-21T08:00:00Z'
Assert-Match '^ClockAnomaly\|' $mismatchedClocks 'Inconsistent supplied local and UTC clocks must be detected.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('restic-freshness-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    $failedStatus = @{
        schema_version = 1
        run_id = 'failed-after-success'
        state = 'failed'
        started_utc = '2026-07-21T04:00:00Z'
        finished_utc = '2026-07-21T04:05:00Z'
        error_count = 1
        errors = @('fixture failure')
        progress = @{}
        summary = @{}
    } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'status.json') -Value $failedStatus -Encoding UTF8
    $lastSuccess = @{
        schema_version = 1
        run_id = 'verified-before-failure'
        state = 'success'
        started_utc = '2026-07-20T02:00:00Z'
        finished_utc = '2026-07-20T02:30:00Z'
        verification_complete = $true
    } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'last-success.json') -Value $lastSuccess -Encoding UTF8

    [ResticBackuper.Dashboard.BackupFreshnessFixtureHarness]::UseFixtureFolderRoots((Join-Path $fixtureRoot 'engine-roots'))
    $reader = [ResticBackuper.Dashboard.TelemetryReader]::new($fixtureRoot, $false)
    $snapshot = $reader.Load()
    Assert-True $snapshot.IsFailure 'The latest failed status must remain the current run result.'
    Assert-Equal 'failed-after-success' $snapshot.RunId 'The latest failed run must remain independently visible.'
    Assert-Equal ([DateTime]::Parse('2026-07-20T02:30:00Z').ToUniversalTime()) $snapshot.LastVerifiedFinishedUtc 'The older verified success timestamp must be loaded independently.'

    $selfTest = $reader.SelfTestJson() | ConvertFrom-Json
    Assert-True $selfTest.ok 'A failed latest run plus a valid last-success record must pass telemetry self-test.'
    Assert-True ($selfTest.allowed_protected_files -contains 'last-success.json') 'Self-test must declare last-success.json as an allowed protected input.'
    Assert-True $selfTest.last_success.exists 'Self-test must report the protected last-success record.'
    Assert-True $selfTest.last_success.verified_success_record 'Self-test must validate last-success semantics.'
    Assert-Equal '2026-07-20T02:30:00.0000000Z' $selfTest.last_success.verified_finished_utc 'Self-test must expose the verified finish time.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}

$freshnessCode = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\BackupFreshness.cs') -Raw -Encoding UTF8
Assert-True (-not $freshnessCode.Contains('Process.Start')) 'The freshness evaluator must not launch processes.'
Assert-True (-not $freshnessCode.Contains('File.')) 'The freshness evaluator must not read or write files.'
Assert-True (-not $freshnessCode.Contains('TaskScheduleReader')) 'The freshness evaluator must not query or mutate Task Scheduler.'
Assert-True ($freshnessCode.Contains('date.Add(schedule.TimeOfDay)')) 'Freshness must derive occurrences from local calendar dates.'
Assert-True (-not $freshnessCode.Contains('TimeSpan.FromHours(24)')) 'Freshness must not model recurrence as fixed 24-hour intervals.'

[pscustomobject]@{
    ok = $true
    tests = $script:tests
    telemetry_fixture_only = $true
    live_task_queried = $false
    production_task_started = $false
    protected_state_written = $false
} | ConvertTo-Json

