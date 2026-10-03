using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace ResticBackuper.Dashboard
{
    internal enum BackupFreshnessState
    {
        Unavailable = 0,
        Healthy = 1,
        NoVerifiedBackup = 2,
        Overdue = 3,
        Paused = 4,
        ClockAnomaly = 5
    }

    internal sealed class BackupFreshnessResult
    {
        internal BackupFreshnessResult(
            BackupFreshnessState state,
            DateTime? lastVerifiedUtc,
            DateTime? lastVerifiedLocal,
            DateTime? latestDueLocal,
            DateTime? latestDueUtc,
            DateTime? nextScheduledLocal,
            string statusLabel,
            string detail)
        {
            State = state;
            LastVerifiedUtc = lastVerifiedUtc;
            LastVerifiedLocal = lastVerifiedLocal;
            LatestDueLocal = latestDueLocal;
            LatestDueUtc = latestDueUtc;
            NextScheduledLocal = nextScheduledLocal;
            StatusLabel = statusLabel ?? string.Empty;
            Detail = detail ?? string.Empty;
        }

        public BackupFreshnessState State { get; private set; }
        public DateTime? LastVerifiedUtc { get; private set; }
        public DateTime? LastVerifiedLocal { get; private set; }
        public DateTime? LatestDueLocal { get; private set; }
        public DateTime? LatestDueUtc { get; private set; }
        public DateTime? NextScheduledLocal { get; private set; }
        public string StatusLabel { get; private set; }
        public string Detail { get; private set; }

        public bool NeedsAttention
        {
            get
            {
                return State == BackupFreshnessState.NoVerifiedBackup ||
                    State == BackupFreshnessState.Overdue ||
                    State == BackupFreshnessState.ClockAnomaly ||
                    State == BackupFreshnessState.Unavailable;
            }
        }
    }

    internal static class BackupFreshnessEvaluator
    {
        internal static readonly TimeSpan DefaultGracePeriod = TimeSpan.FromHours(2);
        internal static readonly TimeSpan ClockTolerance = TimeSpan.FromMinutes(5);
        private const int MaximumCalendarLookbackDays = 15;
        private const int MaximumCalendarLookaheadDays = 15;
        private const int MaximumInvalidLocalMinutes = 180;
        private static readonly TimeSpan TimeZoneRefreshInterval = TimeSpan.FromSeconds(30);
        private static readonly object timeZoneRefreshGate = new object();
        private static DateTime lastTimeZoneRefreshUtc = DateTime.MinValue;

        public static BackupFreshnessResult Evaluate(
            TaskSchedule schedule,
            DateTime? lastVerifiedFinishedUtc,
            DateTime nowLocal,
            DateTime nowUtc)
        {
            return Evaluate(
                schedule,
                lastVerifiedFinishedUtc,
                nowLocal,
                nowUtc,
                TimeZoneInfo.Local,
                DefaultGracePeriod);
        }

        // Evaluates against the clocks as they are this moment. .NET Framework keeps the time zone it found when the process
        // started, and this app lives in the tray for days, so a computer that changes time zone would go on working out due
        // times in the old zone while the Task Scheduler's own next-run time is already in the new one. The cached zone is
        // dropped (at most every 30 seconds) before the local and UTC clocks are read, so both come from the same zone data.
        // coveredThroughUtc is a moment up to which the last verified backup is taken to have been current (see
        // DashboardWindow.NoteScheduleReplaced); null when there is none.
        public static BackupFreshnessResult EvaluateNow(
            TaskSchedule schedule,
            DateTime? lastVerifiedFinishedUtc,
            DateTime? coveredThroughUtc)
        {
            RefreshLocalTimeZone();
            DateTime nowUtc = DateTime.UtcNow;
            DateTime nowLocal = DateTime.Now;
            return Evaluate(
                schedule,
                lastVerifiedFinishedUtc,
                nowLocal,
                nowUtc,
                TimeZoneInfo.Local,
                DefaultGracePeriod,
                coveredThroughUtc);
        }

        // Whether two schedules run on the same days at the same time of day. A change to anything else about the task (power
        // conditions, the missed-run setting) does not move a run.
        internal static bool SameRunTimes(TaskSchedule first, TaskSchedule second)
        {
            return first != null && second != null &&
                first.Cadence == second.Cadence &&
                first.TimeOfDay == second.TimeOfDay &&
                TaskScheduleCanonicalizer.SameDays(first.Days, second.Days);
        }

        internal static BackupFreshnessResult Evaluate(
            TaskSchedule schedule,
            DateTime? lastVerifiedFinishedUtc,
            DateTime nowLocal,
            DateTime nowUtc,
            TimeZoneInfo localTimeZone,
            TimeSpan gracePeriod)
        {
            return Evaluate(
                schedule,
                lastVerifiedFinishedUtc,
                nowLocal,
                nowUtc,
                localTimeZone,
                gracePeriod,
                null);
        }

        internal static BackupFreshnessResult Evaluate(
            TaskSchedule schedule,
            DateTime? lastVerifiedFinishedUtc,
            DateTime nowLocal,
            DateTime nowUtc,
            TimeZoneInfo localTimeZone,
            TimeSpan gracePeriod,
            DateTime? coveredThroughUtc)
        {
            if (localTimeZone == null)
            {
                throw new ArgumentNullException("localTimeZone");
            }
            if (gracePeriod < TimeSpan.Zero || gracePeriod > TimeSpan.FromDays(7))
            {
                throw new ArgumentOutOfRangeException("gracePeriod");
            }

            DateTime localNow = DateTime.SpecifyKind(nowLocal, DateTimeKind.Unspecified);
            DateTime utcNow = NormalizeSuppliedUtc(nowUtc);
            DateTime? verifiedUtc = lastVerifiedFinishedUtc.HasValue
                ? NormalizeSuppliedUtc(lastVerifiedFinishedUtc.Value)
                : (DateTime?)null;
            DateTime? verifiedLocal = verifiedUtc.HasValue
                ? TimeZoneInfo.ConvertTimeFromUtc(verifiedUtc.Value, localTimeZone)
                : (DateTime?)null;

            if (schedule == null)
            {
                return Result(
                    BackupFreshnessState.Unavailable,
                    verifiedUtc,
                    verifiedLocal,
                    null,
                    null,
                    null,
                    "Schedule unavailable",
                    "The installed backup schedule could not be verified.");
            }

            DateTime? nextScheduledLocal = FindNextScheduledLocal(schedule, localNow, localTimeZone);
            if (!schedule.Enabled || schedule.State == BackupTaskState.Disabled)
            {
                return Result(
                    BackupFreshnessState.Paused,
                    verifiedUtc,
                    verifiedLocal,
                    null,
                    null,
                    nextScheduledLocal,
                    "Paused",
                    verifiedLocal.HasValue
                        ? "Automatic backups are paused. Last verified " + FormatLocal(verifiedLocal.Value) + "."
                        : "Automatic backups are paused and no verified backup has been recorded.");
            }

            if (!IsLocalClockConsistent(localNow, utcNow, localTimeZone))
            {
                return Result(
                    BackupFreshnessState.ClockAnomaly,
                    verifiedUtc,
                    verifiedLocal,
                    null,
                    null,
                    nextScheduledLocal,
                    "Clock needs attention",
                    "Windows reports inconsistent local and UTC time. Check the date, time and time zone settings.");
            }

            if (verifiedUtc.HasValue && verifiedUtc.Value > utcNow.Add(ClockTolerance))
            {
                return Result(
                    BackupFreshnessState.ClockAnomaly,
                    verifiedUtc,
                    verifiedLocal,
                    null,
                    null,
                    nextScheduledLocal,
                    "Clock needs attention",
                    "The last verified backup is timestamped in the future (" +
                        FormatLocal(verifiedLocal.Value) + "). Check the Windows clock.");
            }

            DateTime? latestDueLocal;
            DateTime? latestDueUtc;
            FindLatestDueOccurrence(
                schedule,
                localNow,
                utcNow,
                localTimeZone,
                gracePeriod,
                out latestDueLocal,
                out latestDueUtc);

            if (!verifiedUtc.HasValue)
            {
                string noVerifiedDetail = "No completed, verified backup has been recorded.";
                if (nextScheduledLocal.HasValue)
                {
                    noVerifiedDetail += " Next scheduled " + FormatLocal(nextScheduledLocal.Value) + ".";
                }
                return Result(
                    BackupFreshnessState.NoVerifiedBackup,
                    null,
                    null,
                    latestDueLocal,
                    latestDueUtc,
                    nextScheduledLocal,
                    "No verified backup",
                    noVerifiedDetail);
            }

            // The last verified backup was current up to coveredThroughUtc when the schedule moved its runs (it was healthy
            // just before), so a slot the new schedule has before then is one that never existed. It stands in for the
            // backup's own time in this comparison only; what is shown as "last verified" stays the real one. A moment that
            // is ahead of the clock is ignored.
            DateTime verifiedForDue = verifiedUtc.Value;
            if (coveredThroughUtc.HasValue)
            {
                DateTime covered = NormalizeSuppliedUtc(coveredThroughUtc.Value);
                if (covered > verifiedForDue && covered <= utcNow)
                {
                    verifiedForDue = covered;
                }
            }
            if (latestDueUtc.HasValue &&
                verifiedForDue.Add(ClockTolerance) < latestDueUtc.Value)
            {
                return Result(
                    BackupFreshnessState.Overdue,
                    verifiedUtc,
                    verifiedLocal,
                    latestDueLocal,
                    latestDueUtc,
                    nextScheduledLocal,
                    "Overdue",
                    "No verified backup covers the " + FormatLocal(latestDueLocal.Value) +
                        " scheduled run. Last verified " + FormatLocal(verifiedLocal.Value) + ".");
            }

            string healthyDetail = "Last verified " + FormatLocal(verifiedLocal.Value) + ".";
            if (nextScheduledLocal.HasValue)
            {
                healthyDetail += " Next scheduled " + FormatLocal(nextScheduledLocal.Value) + ".";
            }
            return Result(
                BackupFreshnessState.Healthy,
                verifiedUtc,
                verifiedLocal,
                latestDueLocal,
                latestDueUtc,
                nextScheduledLocal,
                "Healthy",
                healthyDetail);
        }

        private static BackupFreshnessResult Result(
            BackupFreshnessState state,
            DateTime? verifiedUtc,
            DateTime? verifiedLocal,
            DateTime? latestDueLocal,
            DateTime? latestDueUtc,
            DateTime? nextScheduledLocal,
            string statusLabel,
            string detail)
        {
            return new BackupFreshnessResult(
                state,
                verifiedUtc,
                verifiedLocal,
                latestDueLocal,
                latestDueUtc,
                nextScheduledLocal,
                statusLabel,
                detail);
        }

        private static void FindLatestDueOccurrence(
            TaskSchedule schedule,
            DateTime localNow,
            DateTime utcNow,
            TimeZoneInfo localTimeZone,
            TimeSpan gracePeriod,
            out DateTime? latestDueLocal,
            out DateTime? latestDueUtc)
        {
            latestDueLocal = null;
            latestDueUtc = null;
            for (int offset = 0; offset <= MaximumCalendarLookbackDays; offset++)
            {
                DateTime date = localNow.Date.AddDays(-offset);
                if (!RunsOnDate(schedule, date.DayOfWeek))
                {
                    continue;
                }
                DateTime scheduledLocal = DateTime.SpecifyKind(
                    date.Add(schedule.TimeOfDay),
                    DateTimeKind.Unspecified);
                DateTime scheduledUtc;
                // A slot in the hour that repeats when the clocks go back is due from its first occurrence, so a run at either
                // of the two covers it. Taking the later one called a backup that ran at the first an overdue one for a day.
                if (!TryResolveLocalToUtc(
                    scheduledLocal,
                    localTimeZone,
                    false,
                    out scheduledUtc,
                    out scheduledLocal))
                {
                    continue;
                }
                if (scheduledUtc.Add(gracePeriod) <= utcNow)
                {
                    latestDueLocal = scheduledLocal;
                    latestDueUtc = scheduledUtc;
                    return;
                }
            }
        }

        private static DateTime? FindNextScheduledLocal(
            TaskSchedule schedule,
            DateTime localNow,
            TimeZoneInfo localTimeZone)
        {
            if (!schedule.Enabled || schedule.State == BackupTaskState.Disabled)
            {
                return null;
            }
            for (int offset = 0; offset <= MaximumCalendarLookaheadDays; offset++)
            {
                DateTime date = localNow.Date.AddDays(offset);
                if (!RunsOnDate(schedule, date.DayOfWeek))
                {
                    continue;
                }
                DateTime scheduledLocal = DateTime.SpecifyKind(
                    date.Add(schedule.TimeOfDay),
                    DateTimeKind.Unspecified);
                DateTime ignoredUtc;
                if (!TryResolveLocalToUtc(
                    scheduledLocal,
                    localTimeZone,
                    false,
                    out ignoredUtc,
                    out scheduledLocal))
                {
                    continue;
                }
                if (scheduledLocal > localNow)
                {
                    return scheduledLocal;
                }
            }
            return null;
        }

        private static bool RunsOnDate(TaskSchedule schedule, DayOfWeek day)
        {
            return schedule.Cadence == BackupScheduleCadence.Daily ||
                (schedule.Days != null && schedule.Days.Contains(day));
        }

        // Whether the local clock reading and the UTC reading describe one moment. In the hour that repeats when the clocks go
        // back a local time is two moments an hour apart, and either one is right, so the reading is consistent when any of its
        // offsets agrees with UTC. A local time that does not exist (the hour skipped when they go forward) cannot be read off
        // a real clock, so it stays an anomaly.
        private static bool IsLocalClockConsistent(
            DateTime localNow,
            DateTime utcNow,
            TimeZoneInfo localTimeZone)
        {
            if (localTimeZone.IsInvalidTime(localNow))
            {
                return false;
            }
            TimeSpan[] offsets = localTimeZone.IsAmbiguousTime(localNow)
                ? localTimeZone.GetAmbiguousTimeOffsets(localNow)
                : new[] { localTimeZone.GetUtcOffset(localNow) };
            foreach (TimeSpan offset in offsets)
            {
                DateTime candidateUtc = DateTime.SpecifyKind(localNow - offset, DateTimeKind.Utc);
                if (AbsoluteDifference(candidateUtc, utcNow) <= ClockTolerance)
                {
                    return true;
                }
            }
            return false;
        }

        // Drops the cached local time zone, at most once every 30 seconds (see EvaluateNow).
        private static void RefreshLocalTimeZone()
        {
            lock (timeZoneRefreshGate)
            {
                DateTime now = DateTime.UtcNow;
                // A clock that moved back is not "less than 30 seconds since", and a zone change often comes with one.
                if (now >= lastTimeZoneRefreshUtc && now - lastTimeZoneRefreshUtc < TimeZoneRefreshInterval)
                {
                    return;
                }
                lastTimeZoneRefreshUtc = now;
                TimeZoneInfo.ClearCachedData();
            }
        }

        private static bool TryResolveLocalToUtc(
            DateTime local,
            TimeZoneInfo localTimeZone,
            bool preferLaterAmbiguousOccurrence,
            out DateTime utc,
            out DateTime adjustedLocal)
        {
            adjustedLocal = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
            utc = DateTime.MinValue;
            int shiftedMinutes = 0;
            while (localTimeZone.IsInvalidTime(adjustedLocal) &&
                shiftedMinutes < MaximumInvalidLocalMinutes)
            {
                adjustedLocal = adjustedLocal.AddMinutes(1);
                shiftedMinutes++;
            }
            if (localTimeZone.IsInvalidTime(adjustedLocal))
            {
                return false;
            }

            if (localTimeZone.IsAmbiguousTime(adjustedLocal))
            {
                TimeSpan[] offsets = localTimeZone.GetAmbiguousTimeOffsets(adjustedLocal);
                if (offsets == null || offsets.Length == 0)
                {
                    return false;
                }
                DateTime resolvedLocal = adjustedLocal;
                IEnumerable<DateTime> candidates = offsets.Select(
                    offset => DateTime.SpecifyKind(resolvedLocal - offset, DateTimeKind.Utc));
                utc = preferLaterAmbiguousOccurrence
                    ? candidates.Max()
                    : candidates.Min();
                return true;
            }

            utc = TimeZoneInfo.ConvertTimeToUtc(adjustedLocal, localTimeZone);
            return true;
        }

        private static DateTime NormalizeSuppliedUtc(DateTime value)
        {
            if (value.Kind == DateTimeKind.Local)
            {
                return value.ToUniversalTime();
            }
            return DateTime.SpecifyKind(value, DateTimeKind.Utc);
        }

        private static TimeSpan AbsoluteDifference(DateTime first, DateTime second)
        {
            TimeSpan difference = first - second;
            return difference < TimeSpan.Zero ? difference.Negate() : difference;
        }

        private static string FormatLocal(DateTime value)
        {
            return value.ToString("ddd, d MMM HH:mm", CultureInfo.CurrentCulture);
        }
    }
}
