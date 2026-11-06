$ErrorActionPreference = 'Stop'

# Whether the dashboard calls a move of the backup location interrupted only when it is. Compiles the dashboard's
# recovery-status sources (no window) and checks them against this dashboard's own move, a move run by a process that is
# still running, one that has ended, one whose process id was reused, and the earlier edition's record without owner
# fields. Hermetic: every Windows folder the dashboard reads is moved under a disposable folder in %TEMP%, and the only
# processes started are a waiting cmd.exe and nothing else.

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function Read-DashboardSource {
    param([string]$Name)
    return Get-Content -LiteralPath (Join-Path $project ('src\dashboard\' + $Name)) -Raw -Encoding UTF8
}
function Join-DashboardSources {
    param([string[]]$Parts)
    $usingPattern = '(?m)^using\s+[^;]+;\s*\r?\n'
    $usings = @($Parts | ForEach-Object {
        [regex]::Matches($_, $usingPattern) | ForEach-Object { $_.Value.Trim() }
    } | Sort-Object -Unique)
    $bodies = @($Parts | ForEach-Object { [regex]::Replace($_, $usingPattern, '') })
    return ($usings -join [Environment]::NewLine) + [Environment]::NewLine + ($bodies -join [Environment]::NewLine)
}

$harness = @'
namespace ResticBackuper.Dashboard
{
    public static class RepositoryRecoveryFixtureHarness
    {
        public static void UseFixtureFolderRoots(string root)
        {
            EngineProfile.UseFolderRootsForTesting(root);
        }

        public static string StateDirectory()
        {
            return EngineProfile.Current.StateDirectory();
        }

        public static string Classify(string journalJson)
        {
            return Describe(RepositoryManagerLauncher.ClassifyRecovery(journalJson));
        }

        public static string Current()
        {
            return Describe(RepositoryManagerLauncher.GetRecoveryStatus());
        }

        public static void BeginOwnMove()
        {
            RepositoryManagerLauncher.BeginOwnMove();
        }

        public static void EndOwnMove()
        {
            RepositoryManagerLauncher.EndOwnMove();
        }

        public static bool IsSameProcessAlive(int processId, long creationFileTimeUtc)
        {
            return ProcessLiveness.IsSameProcessAlive(processId, creationFileTimeUtc);
        }

        public static string OwnMoveMessage()
        {
            return RepositoryManagerLauncher.OwnMoveRunningMessage;
        }

        public static string MoveMessage()
        {
            return RepositoryManagerLauncher.MoveRunningMessage;
        }

        // "<exists><recoverable><running>|<message>", for example "110|Moving your backups ... was interrupted ...".
        private static string Describe(RepositoryRecoveryStatus status)
        {
            return (status.Exists ? "1" : "0") +
                (status.IsRecoverable ? "1" : "0") +
                (status.IsMoveRunning ? "1" : "0") + "|" + status.Message;
        }
    }
}
'@

$sources = @(
    (Read-DashboardSource 'EngineProfile.cs'),
    (Read-DashboardSource 'AtomicFile.cs'),
    (Read-DashboardSource 'SourceConfiguration.cs'),
    (Read-DashboardSource 'ProcessLiveness.cs'),
    (Read-DashboardSource 'RepositoryManager.cs')
)
Add-Type -TypeDefinition ((Join-DashboardSources $sources) + [Environment]::NewLine + $harness) `
    -ReferencedAssemblies @(
        'System.dll',
        'System.Core.dll',
        'System.Xml.dll',
        'System.Web.Extensions.dll'
    )
$fixtureHarness = [ResticBackuper.Dashboard.RepositoryRecoveryFixtureHarness]

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
function Assert-Status {
    param([string]$Actual, [string]$Expected, [string]$Message)
    # Expected is "none", "running" or "interrupted" (blocked is "exists, not recoverable, not running").
    $flags = $Actual.Substring(0, 3)
    $wanted = switch ($Expected) {
        'none' { '000' }
        'running' { '101' }
        'interrupted' { '110' }
        'blocked' { '100' }
        default { throw "Unknown expected status $Expected." }
    }
    Assert-Equal $wanted $flags "$Message (status '$Actual')"
}
function New-Journal {
    # A journal like Manage-Repository's, with only the fields this check reads besides a few of the others.
    param([object]$OwnerProcessId, [object]$OwnerCreation, [switch]$NoOwner)
    $journal = [ordered]@{
        schema_version = 1
        state = 'copying'
        old_repository = 'D:\Backups\Rewindle'
        new_repository = 'E:\Backups\Rewindle'
    }
    if (-not $NoOwner) {
        $journal.owner_process_id = $OwnerProcessId
        $journal.owner_process_creation_filetime_utc = $OwnerCreation
    }
    return ($journal | ConvertTo-Json -Compress)
}
function Get-CreationFileTime {
    # The same conversion Manage-Repository.ps1 makes for owner_process_creation_filetime_utc.
    param([Diagnostics.Process]$Process)
    return [long]$Process.StartTime.ToFileTimeUtc()
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('RRS-T-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
$child = $null
try {
    # Before anything reads a folder: the dashboard's Program Files and ProgramData become fixture folders.
    $fixtureHarness::UseFixtureFolderRoots($fixture)
    $stateDirectory = $fixtureHarness::StateDirectory()
    Assert-True ($stateDirectory.StartsWith($fixture + '\', [StringComparison]::OrdinalIgnoreCase)) 'The state folder must be inside the fixture.'
    $journalPath = Join-Path $stateDirectory 'repository-relocation.journal.json'
    $ownMessage = $fixtureHarness::OwnMoveMessage()
    $moveMessage = $fixtureHarness::MoveMessage()
    foreach ($text in @($ownMessage, $moveMessage)) {
        Assert-True ($text -notmatch '(?i)repositor|journal|snapshot|restic|interrupt') "A running move is told in plain words: '$text'."
    }

    # No record: nothing is pending, and nothing is running.
    Assert-Status ($fixtureHarness::Current()) 'none' 'No record means no unfinished move.'

    # This dashboard's own move: running from the moment the manager started until it has exited, without reading the
    # record (the manager is replacing it), and the record's presence still blocks every change (Exists).
    $fixtureHarness::BeginOwnMove()
    try {
        $own = $fixtureHarness::Current()
        Assert-Status $own 'running' 'This dashboard''s own move is running.'
        Assert-Equal ('101|' + $ownMessage) $own 'This dashboard''s own move says what is happening.'
    }
    finally {
        $fixtureHarness::EndOwnMove()
    }
    Assert-Status ($fixtureHarness::Current()) 'none' 'Once the own move has ended, its status ends too.'

    # A record whose permissions are not the protected ones (any file a test can write) is not trusted...
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    [IO.File]::WriteAllText($journalPath, (New-Journal -NoOwner), [Text.UTF8Encoding]::new($false))
    Assert-Status ($fixtureHarness::Current()) 'blocked' 'A record with the wrong permissions is not trusted.'
    # ...but during this dashboard's own move it is the manager's working file, and the move is running.
    $fixtureHarness::BeginOwnMove()
    try {
        Assert-Status ($fixtureHarness::Current()) 'running' 'The own move is running whatever its record looks like mid-write.'
    }
    finally {
        $fixtureHarness::EndOwnMove()
    }
    Assert-Status ($fixtureHarness::Current()) 'blocked' 'After the own move, the record is judged again.'
    [IO.File]::Delete($journalPath)

    # Process liveness against this very process, with the creation time converted as the manager converts its own.
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $selfCreation = Get-CreationFileTime $self
    Assert-True ($fixtureHarness::IsSameProcessAlive($PID, $selfCreation)) 'A running process with its exact creation time is alive.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive($PID, $selfCreation + 1)) 'A later creation time is another process (a reused process id).'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive($PID, $selfCreation - 1)) 'An earlier creation time is another process.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive(0, $selfCreation)) 'Process id 0 is never a move.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive(-1, $selfCreation)) 'A negative process id is never a move.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive($PID, 0)) 'A missing creation time is never a move.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive($PID, -5)) 'A negative creation time is never a move.'

    # The earlier edition's record names no process: without a move of this dashboard's own, it is interrupted, as before.
    $legacy = $fixtureHarness::Classify((New-Journal -NoOwner))
    Assert-Status $legacy 'interrupted' 'A record without owner fields is an interrupted move.'
    Assert-True ($legacy -match 'interrupted') 'An interrupted move still says so.'
    Assert-Status ($fixtureHarness::Classify($null)) 'interrupted' 'An unreadable record is an interrupted move, as before.'
    Assert-Status ($fixtureHarness::Classify('')) 'interrupted' 'An empty record is an interrupted move, as before.'

    # Owner fields that are not exactly what the manager writes count as no owner, even when they name a running process.
    $creationText = $selfCreation.ToString([Globalization.CultureInfo]::InvariantCulture)
    $malformed = [ordered]@{
        'process id as text' = (New-Journal -OwnerProcessId ([string]$PID) -OwnerCreation $creationText)
        'creation time as a number' = (New-Journal -OwnerProcessId $PID -OwnerCreation $selfCreation)
        'creation time with a leading zero' = (New-Journal -OwnerProcessId $PID -OwnerCreation ('0' + $creationText))
        'creation time with a sign' = (New-Journal -OwnerProcessId $PID -OwnerCreation ('+' + $creationText))
        'creation time with a space' = (New-Journal -OwnerProcessId $PID -OwnerCreation ($creationText + ' '))
        'empty creation time' = (New-Journal -OwnerProcessId $PID -OwnerCreation '')
        'missing creation time' = ('{"schema_version":1,"owner_process_id":' + $PID + '}')
        'missing process id' = ('{"schema_version":1,"owner_process_creation_filetime_utc":"' + $creationText + '"}')
        'process id zero' = (New-Journal -OwnerProcessId 0 -OwnerCreation $creationText)
        'negative process id' = (New-Journal -OwnerProcessId (-$PID) -OwnerCreation $creationText)
        'creation time past Int64' = (New-Journal -OwnerProcessId $PID -OwnerCreation '18446744073709551615')
        'not JSON' = 'owner_process_id'
        'a JSON list' = ('[' + $PID + ',"' + $creationText + '"]')
    }
    foreach ($case in $malformed.GetEnumerator()) {
        Assert-Status ($fixtureHarness::Classify($case.Value)) 'interrupted' "A record with a $($case.Key) is read as having no owner."
    }

    # A move run by another process (a dashboard that restarted during the move): running while that same process runs.
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), '/d /c "set /p line="')
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.CreateNoWindow = $true
    $child = [Diagnostics.Process]::Start($start)
    $childId = $child.Id
    $childCreation = Get-CreationFileTime $child
    $childJournal = New-Journal -OwnerProcessId $childId -OwnerCreation $childCreation.ToString([Globalization.CultureInfo]::InvariantCulture)
    Assert-True ($fixtureHarness::IsSameProcessAlive($childId, $childCreation)) 'The waiting child process is alive.'
    $running = $fixtureHarness::Classify($childJournal)
    Assert-Equal ('101|' + $moveMessage) $running 'A record naming a running process is a running move, not an interrupted one.'
    $reused = New-Journal -OwnerProcessId $childId -OwnerCreation ($childCreation + 1).ToString([Globalization.CultureInfo]::InvariantCulture)
    Assert-Status ($fixtureHarness::Classify($reused)) 'interrupted' 'A record naming a reused process id is an interrupted move.'

    # While the manager replaces its record, the record can be missing or unreadable for an instant. The process a trusted
    # record named a moment ago is still running, so the move is still running.
    Assert-Status ($fixtureHarness::Current()) 'running' 'A record missing for an instant during a running move does not end the move.'
    [IO.File]::WriteAllText($journalPath, $childJournal, [Text.UTF8Encoding]::new($false))
    Assert-Status ($fixtureHarness::Current()) 'running' 'A record unreadable for an instant during a running move does not alarm.'

    # The process ends (its process object stays while this test holds a handle): the move is interrupted.
    $child.StandardInput.Close()
    Assert-True ($child.WaitForExit(10000)) 'The child process ends once its input is closed.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive($childId, $childCreation)) 'An ended process is not alive while a handle keeps it.'
    $ended = $fixtureHarness::Classify($childJournal)
    Assert-Status $ended 'interrupted' 'A record naming a process that has ended is an interrupted move.'
    Assert-True ($ended -match 'interrupted') 'An interrupted move says so.'
    Assert-Status ($fixtureHarness::Current()) 'blocked' 'Once the moving process has ended, the record is judged as it is.'
    [IO.File]::Delete($journalPath)
    Assert-Status ($fixtureHarness::Current()) 'none' 'Once the moving process has ended and the record is gone, nothing is pending.'

    $child.Dispose()
    $child = $null
    Assert-Status ($fixtureHarness::Classify($childJournal)) 'interrupted' 'A record naming a process that is gone is an interrupted move.'
    Assert-True (-not $fixtureHarness::IsSameProcessAlive($childId, $childCreation)) 'A process that is gone is not alive.'

    # The earlier edition's record during this dashboard's own move: running (the in-process fallback).
    [IO.File]::WriteAllText($journalPath, (New-Journal -NoOwner), [Text.UTF8Encoding]::new($false))
    $fixtureHarness::BeginOwnMove()
    try {
        Assert-Status ($fixtureHarness::Current()) 'running' 'The earlier edition''s move started here is running while it runs.'
    }
    finally {
        $fixtureHarness::EndOwnMove()
    }
}
finally {
    if ($null -ne $child) {
        try { if (-not $child.HasExited) { $child.Kill() } } catch { }
        $child.Dispose()
    }
    $fixtureHarness::UseFixtureFolderRoots($null)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Split-Path -Leaf $fixture) -like 'RRS-T-*' -and
        $fixture.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $fixture)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

Write-Host "Repository recovery status tests passed: $script:tests assertions."
