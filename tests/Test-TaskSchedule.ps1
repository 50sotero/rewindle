$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\TaskSchedule.cs') -Raw -Encoding UTF8
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
    public static class TaskScheduleFixtureHarness
    {
        public static string Parse(
            string xml,
            string launcher,
            string root,
            string sid)
        {
            TaskSchedule schedule;
            string error;
            bool valid = TaskScheduleReader.TryParseTaskXml(
                xml,
                launcher,
                root,
                sid,
                new TaskScheduleRuntimeInfo(
                    BackupTaskState.Ready,
                    new System.DateTime(2026, 7, 21, 2, 0, 0)),
                out schedule,
                out error);
            if (!valid)
            {
                return "ERROR|" + error;
            }
            return "OK|" + schedule.Cadence.ToString() + "|" +
                TaskScheduleCanonicalizer.FormatTime(schedule.TimeOfDay) + "|" +
                TaskScheduleCanonicalizer.FormatDays(schedule.Days) + "|" +
                (schedule.Enabled ? "1" : "0") + "|" +
                (schedule.StartWhenAvailable ? "1" : "0") + "|" +
                (schedule.WakeToRun ? "1" : "0") + "|" +
                (schedule.AllowStartOnBatteries ? "1" : "0") + "|" +
                (schedule.StopIfGoingOnBatteries ? "1" : "0") + "|" +
                schedule.Summary + "|" + schedule.NextRunDisplay + "|" +
                schedule.SemanticFingerprint;
        }

        // How a trigger's start was written: its clock time, the UTC offset it carries (none for a local start), and
        // whether the page is told the runs move with the clocks.
        public static string ParseStart(
            string xml,
            string launcher,
            string root,
            string sid)
        {
            TaskSchedule schedule;
            string error;
            if (!TaskScheduleReader.TryParseTaskXml(
                xml,
                launcher,
                root,
                sid,
                new TaskScheduleRuntimeInfo(BackupTaskState.Ready, null),
                out schedule,
                out error))
            {
                return "ERROR|" + error;
            }
            return TaskScheduleCanonicalizer.FormatTime(schedule.WrittenTimeOfDay) + "|" +
                (schedule.FixedUtcOffset.HasValue
                    ? schedule.FixedUtcOffset.Value.ToString(@"hh\:mm", System.Globalization.CultureInfo.InvariantCulture)
                    : "local") + "|" +
                (schedule.ClockChangeNote.Length > 0 ? "note" : "no-note");
        }

        // The last run Task Scheduler reported, as the parsed schedule carries it ("none" when it carries none).
        public static string ParseLastRun(
            string xml,
            string launcher,
            string root,
            string sid,
            string lastRun)
        {
            TaskSchedule schedule;
            string error;
            if (!TaskScheduleReader.TryParseTaskXml(
                xml,
                launcher,
                root,
                sid,
                new TaskScheduleRuntimeInfo(
                    BackupTaskState.Ready,
                    null,
                    string.IsNullOrEmpty(lastRun)
                        ? (System.DateTime?)null
                        : System.DateTime.Parse(lastRun, System.Globalization.CultureInfo.InvariantCulture)),
                out schedule,
                out error))
            {
                return "ERROR|" + error;
            }
            return schedule.LastRunTime.HasValue
                ? schedule.LastRunTime.Value.ToString("yyyy-MM-ddTHH:mm:ss", System.Globalization.CultureInfo.InvariantCulture)
                : "none";
        }

        public static string Request(
            string cadence,
            string time,
            string days,
            bool enabled,
            bool startWhenAvailable,
            bool wakeToRun,
            bool allowStartOnBatteries,
            bool stopIfGoingOnBatteries,
            string sid,
            string baseline,
            string nonce)
        {
            string[] tokens = string.IsNullOrEmpty(days)
                ? new string[0]
                : days.Split(',');
            ScheduleChangeRequest request;
            string error;
            if (!ScheduleChangeRequest.TryCreate(
                cadence,
                time,
                tokens,
                enabled,
                startWhenAvailable,
                wakeToRun,
                allowStartOnBatteries,
                stopIfGoingOnBatteries,
                out request,
                out error))
            {
                return "ERROR|" + error;
            }
            return "OK|" + request.CadenceArgument + "|" + request.TimeArgument + "|" +
                request.DaysArgument + "|" + request.Summary + "|" +
                TaskScheduleCanonicalizer.ComputeRequestDigest(
                    sid,
                    baseline,
                    request,
                    nonce);
        }
    }
}
'@
Add-Type -TypeDefinition ((Join-DashboardSources @($engineProfileSource, $source)) + [Environment]::NewLine + $harness) `
    -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Xml.dll')

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

$sid = 'S-1-5-21-111-222-333-1001'
$root = 'C:\Program Files\ResticBackuper'
$launcher = Join-Path $root 'ResticBackuperTaskLauncher.exe'

function New-Xml {
    param(
        [string]$Trigger,
        [string]$Settings = '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><AllowHardTerminate>true</AllowHardTerminate><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><WakeToRun>true</WakeToRun><Enabled>true</Enabled><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority>',
        [string]$UserSid = $sid,
        [string]$Command = $launcher,
        [string]$WorkingDirectory = $root
    )
    return @"
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
 <RegistrationInfo><URI>\ResticBackuper</URI></RegistrationInfo>
 <Triggers>$Trigger</Triggers>
 <Principals><Principal id="Author"><UserId>$UserSid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
 <Settings>$Settings</Settings>
 <Actions Context="Author"><Exec><Command>$Command</Command><WorkingDirectory>$WorkingDirectory</WorkingDirectory></Exec></Actions>
</Task>
"@
}

function Parse([string]$Xml) {
    return [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::Parse($Xml, $launcher, $root, $sid)
}

$daily = '<CalendarTrigger><StartBoundary>2026-07-21T02:05:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>'
$dailyResult = Parse (New-Xml -Trigger $daily)
Assert-Match '^OK\|Daily\|02:05\|\|1\|1\|1\|1\|0\|Daily at 02:05\|' $dailyResult 'Daily policy must parse with its flags and summary.'
Assert-Match '\|Tue, 21 Jul 02:00\|[0-9a-f]{64}$' $dailyResult 'Next-run display and semantic fingerprint must be exposed.'

# A start written with a UTC offset (New-ScheduledTaskTrigger writes one) keeps its clock time in that offset rather than
# the local time on its start date; a start without one is local time and says nothing about the clocks.
function Parse-Start { param([string]$Trigger) return [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::ParseStart((New-Xml -Trigger $Trigger), $launcher, $root, $sid) }
$pinnedStart = Parse-Start ($daily.Replace('2026-07-21T02:05:00', '2026-07-20T01:00:00+01:00'))
Assert-Match '^01:00\|01:00\|note$' $pinnedStart 'A start with an offset must keep its written time and offset.'
$utcStart = Parse-Start ($daily.Replace('2026-07-21T02:05:00', '2026-07-20T00:00:00Z'))
Assert-Match '^00:00\|00:00\|note$' $utcStart 'A start in UTC (Z) must be read as offset zero.'
Assert-Match '^02:05\|local\|no-note$' (Parse-Start $daily) 'A local start must stay local with no clock-change note.'

# The task's last run reaches the schedule, so freshness can tell a missed backup Windows has yet to start from one it tried.
# Task Scheduler reports a task that never ran as 30 Dec 1899 (some builds as 1999), which is no run at all.
function Parse-LastRun { param([string]$LastRun) return [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::ParseLastRun((New-Xml -Trigger $daily), $launcher, $root, $sid, $LastRun) }
Assert-Equal '2026-07-21T08:01:00' (Parse-LastRun '2026-07-21T08:01:00') 'The last run must be carried to the schedule.'
Assert-Equal 'none' (Parse-LastRun '1899-12-30T00:00:00') 'A never-run marker from 1899 must not be a last run.'
Assert-Equal 'none' (Parse-LastRun '1999-11-30T00:00:00') 'A never-run marker from 1999 must not be a last run.'
Assert-Equal 'none' (Parse-LastRun '') 'An unknown last run must stay unknown.'

$defaultEnabledSettings = '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><AllowHardTerminate>true</AllowHardTerminate><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><WakeToRun>true</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority>'
Assert-Match '^OK\|Daily\|02:05\|\|1\|' (Parse (New-Xml -Trigger $daily -Settings $defaultEnabledSettings)) 'An omitted task Enabled setting must use the Windows schema default of true.'
$disabledSettings = $defaultEnabledSettings.Replace('<ExecutionTimeLimit>', '<Enabled>false</Enabled><ExecutionTimeLimit>')
Assert-Match '^OK\|Daily\|02:05\|\|0\|' (Parse (New-Xml -Trigger $daily -Settings $disabledSettings)) 'An explicit disabled task must remain disabled.'
$schemaDefaultTrigger = $daily.Replace('<Enabled>true</Enabled>', '')
$installedStyleSettings = '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><StartWhenAvailable>true</StartWhenAvailable><WakeToRun>true</WakeToRun>'
Assert-Match '^OK\|Daily\|02:05\|\|1\|1\|1\|1\|0\|' (Parse (New-Xml -Trigger $schemaDefaultTrigger -Settings $installedStyleSettings)) 'Schema-default settings and trigger enablement emitted by Windows must parse with their effective values.'

$weekly = '<CalendarTrigger><StartBoundary>2026-07-21T23:45:00</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek><Friday/><Sunday/><Monday/></DaysOfWeek></ScheduleByWeek></CalendarTrigger>'
$weeklyResult = Parse (New-Xml -Trigger $weekly)
Assert-Match '^OK\|SelectedDays\|23:45\|Sun,Mon,Fri\|' $weeklyResult 'Selected weekdays must use canonical order.'
Assert-Match '\|Sun, Mon, Fri at 23:45\|' $weeklyResult 'Selected weekdays must have a human summary.'

$formatted = New-Xml -Trigger $daily
$compact = ($formatted -replace '>\s+<', '><').Trim()
$formattedFingerprint = ($dailyResult -split '\|')[-1]
$compactFingerprint = ((Parse $compact) -split '\|')[-1]
Assert-Equal $formattedFingerprint $compactFingerprint 'Whitespace-only XML differences must not alter the fingerprint.'

Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger '')) 'A missing trigger must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger ($daily + $daily))) 'Multiple triggers must fail.'
$timeTrigger = '<TimeTrigger><StartBoundary>2026-07-21T02:00:00</StartBoundary></TimeTrigger>'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $timeTrigger)) 'Non-calendar triggers must fail.'
$repetition = $daily.Replace('<Enabled>true</Enabled>', '<Repetition><Interval>PT1H</Interval></Repetition><Enabled>true</Enabled>')
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $repetition)) 'Repeating triggers must fail.'
$randomDelay = $daily.Replace('<Enabled>true</Enabled>', '<RandomDelay>PT5M</RandomDelay><Enabled>true</Enabled>')
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $randomDelay)) 'Unrepresented calendar options must fail.'
$foreignBoundary = $daily.Replace('<Enabled>true</Enabled>', '<x:Enabled xmlns:x="urn:unexpected">true</x:Enabled><Enabled>true</Enabled>')
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $foreignBoundary)) 'Foreign-namespace trigger options must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily.Replace('<DaysInterval>1</DaysInterval>', '<DaysInterval>2</DaysInterval>'))) 'Daily intervals other than one must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $weekly.Replace('<WeeksInterval>1</WeeksInterval>', '<WeeksInterval>2</WeeksInterval>'))) 'Weekly intervals other than one must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $weekly.Replace('<Friday/><Sunday/><Monday/>', ''))) 'Selected-days schedules need a weekday.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $weekly.Replace('<Friday/><Sunday/><Monday/>', '<Monday/><Monday/>'))) 'Duplicate weekdays must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily.Replace('02:05:00', '02:05:30'))) 'Sub-minute trigger times must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily.Replace('<Enabled>true</Enabled>', '<Enabled>false</Enabled>'))) 'An independently disabled trigger must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily -UserSid 'S-1-5-21-9-9-9-9')) 'A different principal SID must fail.'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily -Command 'C:\Windows\System32\cmd.exe')) 'A different action must fail.'
$missingLimit = '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><AllowHardTerminate>true</AllowHardTerminate><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><WakeToRun>true</WakeToRun><Enabled>true</Enabled><Priority>7</Priority>'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily -Settings $missingLimit)) 'The protected zero execution-time limit must be explicit.'
$emptyEnabled = '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><AllowHardTerminate>true</AllowHardTerminate><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><WakeToRun>true</WakeToRun><Enabled/><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority>'
Assert-Match '^ERROR\|' (Parse (New-Xml -Trigger $daily -Settings $emptyEnabled)) 'Empty Boolean settings must not inherit a permissive default.'

$nonce = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$baseline = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
$requestResult = [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::Request(
    'SelectedDays', '04:30', 'Fri,Sun,Mon', $true, $true, $false, $false, $true,
    $sid, $baseline, $nonce)
Assert-Match '^OK\|SelectedDays\|04:30\|Sun,Mon,Fri\|Sun, Mon, Fri at 04:30\|[0-9a-f]{64}$' $requestResult 'A valid request must normalize and expose a digest.'

$canonicalDays = 'Sun,Mon,Fri'
$payload = @(
    'ResticBackuper.ScheduleRequest.v1',
    $sid,
    'apply',
    $baseline,
    'selecteddays',
    '04:30',
    $canonicalDays,
    '1',
    '1',
    '0',
    '0',
    '1',
    $nonce
) -join "`n"
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $expectedDigest = ([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($payload)))).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha.Dispose()
}
Assert-Equal $expectedDigest (($requestResult -split '\|')[-1]) 'The request digest must match the protected manager contract exactly.'

$badDaily = [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::Request(
    'Daily', '02:00', 'Mon', $true, $true, $true, $true, $false,
    $sid, $baseline, $nonce)
Assert-Match '^ERROR\|' $badDaily 'Daily requests must reject selected weekdays.'
$badSelected = [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::Request(
    'SelectedDays', '02:00', '', $true, $true, $true, $true, $false,
    $sid, $baseline, $nonce)
Assert-Match '^ERROR\|' $badSelected 'Selected-days requests need a weekday.'
$badTime = [ResticBackuper.Dashboard.TaskScheduleFixtureHarness]::Request(
    'Daily', '24:00', '', $true, $true, $true, $true, $false,
    $sid, $baseline, $nonce)
Assert-Match '^ERROR\|' $badTime 'Invalid HH:mm values must fail.'

[pscustomobject]@{
    ok = $true
    tests = $script:tests
    parser_only = $true
    live_task_queried = $false
    production_task_started = $false
} | ConvertTo-Json
