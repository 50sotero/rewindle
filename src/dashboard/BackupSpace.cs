using System;
using System.Collections.Generic;
using System.Linq;

namespace ResticBackuper.Dashboard
{
    // How full the backup location is, and when it fills at the rate the backups grow. The host decides the level here and the page only
    // words it (protectionTone.ts), so a later tray notice can use the same answer. Pure: no file system, no clock, no other dashboard
    // type. Everything it needs comes in through BackupSpaceFacts; every byte count is -1 when it is unknown.
    internal enum BackupSpaceLevel
    {
        Unknown = 0,
        Ok = 1,
        Low = 2,
        Full = 3
    }

    internal enum BackupSpaceReason
    {
        None = 0,
        // At the recent rate the backups fill the drive within the person's Low space warning.
        Forecast = 1,
        // Little room now, whatever the rate: less than 1.5 times the reserve (when Check recovery readiness warns too), or, while the
        // forecast is still learning or unreadable, less than a tenth of the drive above the reserve. Not the tenth where the backup
        // service records nothing to forecast from (Unavailable): there it would be amber for good, and the warning that could tune it
        // is not offered.
        Percent = 2,
        // Less free space than the backup service keeps in reserve, so it refuses to start a backup.
        Reserve = 3
    }

    internal enum BackupSpaceForecastState
    {
        // The run history could not be read.
        Unknown = 0,
        // Too few verified backups, or too short a time, to tell.
        Learning = 1,
        // The backups have added almost nothing lately.
        Flat = 2,
        Growing = 3,
        // The backup service in use records no size of its own, so the card says the forecast isn't available with it
        // (EngineProfile.ForecastsBackupSpace).
        Unavailable = 4
    }

    // One verified backup: when it finished and how much new data it saved.
    internal sealed class BackupSpaceSample
    {
        internal BackupSpaceSample(DateTime finishedUtc, long addedBytes)
        {
            FinishedUtc = finishedUtc;
            AddedBytes = addedBytes;
        }

        public DateTime FinishedUtc { get; private set; }
        public long AddedBytes { get; private set; }
    }

    // One clean-up of old backups that removed backups or freed their space: when it finished, and how much it freed (the free space
    // on the backup location after it minus before it, never below 0), or -1 when that was not measured.
    internal sealed class BackupSpaceCleanUp
    {
        internal BackupSpaceCleanUp(DateTime finishedUtc, long freedBytes)
        {
            FinishedUtc = finishedUtc;
            FreedBytes = freedBytes;
        }

        public DateTime FinishedUtc { get; private set; }
        public long FreedBytes { get; private set; }
    }

    // What clean-up of old backups did to the forecast.
    internal enum BackupSpaceCleanUpEffect
    {
        // No clean-up freed space within the forecast's weeks.
        None = 0,
        // The forecast is net growth: what the backups added, less what clean-up freed in the same weeks.
        Counted = 1,
        // A clean-up within the forecast's weeks freed space that was not measured, so there is no forecast until it is further back.
        Unmeasured = 2
    }

    // Everything the evaluator and the page's state need. -1 means unknown for every byte count.
    internal sealed class BackupSpaceFacts
    {
        public BackupSpaceFacts()
        {
            Kind = "drive";
            Reading = "checking";
            Drive = string.Empty;
            FreeBytes = -1;
            TotalBytes = -1;
            ReserveBytes = -1;
            BackupsBytes = -1;
            ForecastAvailable = true;
            Samples = new List<BackupSpaceSample>();
            CleanUps = new List<BackupSpaceCleanUp>();
            WarnWeeks = BackupSpaceEvaluator.DefaultWarnWeeks;
        }

        // "drive": a drive on or plugged into this PC. "googleDrive": Google Drive for desktop, whose figures are the Google account's storage.
        public string Kind { get; set; }
        // "checking" until the first reading of the current location; "ready" with valid figures; "unknown" when Windows would not say.
        public string Reading { get; set; }
        // "D:", or empty when the path names no drive letter.
        public string Drive { get; set; }
        public long FreeBytes { get; set; }
        public long TotalBytes { get; set; }
        // The free space the backup service keeps (minimum_free_gib); below it, a backup is refused.
        public long ReserveBytes { get; set; }
        public long BackupsBytes { get; set; }
        public bool BackupsEstimated { get; set; }
        public bool HistoryReadable { get; set; }
        public bool ForecastAvailable { get; set; }
        public IList<BackupSpaceSample> Samples { get; set; }
        // Every recorded clean-up of old backups that removed backups or freed their space (the only thing that takes data out of the
        // backup location, and only when the person confirms a list). Empty for a backup service without clean-up.
        public IList<BackupSpaceCleanUp> CleanUps { get; set; }
        public int WarnWeeks { get; set; }
        // The latest run failed because the drive was too full, so the Protection hero already says it.
        public bool RunStoppedForSpace { get; set; }
    }

    internal sealed class BackupSpaceResult
    {
        public BackupSpaceResult()
        {
            Level = BackupSpaceLevel.Unknown;
            Reason = BackupSpaceReason.None;
            ForecastState = BackupSpaceForecastState.Unknown;
            WeeklyBytes = -1;
        }

        public BackupSpaceLevel Level { get; internal set; }
        public BackupSpaceReason Reason { get; internal set; }
        public BackupSpaceForecastState ForecastState { get; internal set; }
        // Only when growing and the free space is known: weeks until the free space reaches the reserve, rounded once to 2 decimals.
        // WeeksRounded is that value rounded to whole weeks, the number the words use and the level was judged on, so the page never
        // rounds again a value the host already judged.
        public double? WeeksLeft { get; internal set; }
        public int? WeeksRounded { get; internal set; }
        // Growing: more than 0. Flat: 0. Otherwise -1.
        public long WeeklyBytes { get; internal set; }
        public BackupSpaceCleanUpEffect CleanUp { get; internal set; }

        internal BackupSpaceResult Copy()
        {
            BackupSpaceResult copy = new BackupSpaceResult();
            copy.Level = Level;
            copy.Reason = Reason;
            copy.ForecastState = ForecastState;
            copy.WeeksLeft = WeeksLeft;
            copy.WeeksRounded = WeeksRounded;
            copy.WeeklyBytes = WeeklyBytes;
            copy.CleanUp = CleanUp;
            return copy;
        }
    }

    internal static class BackupSpaceEvaluator
    {
        internal const int DefaultWarnWeeks = 8;
        internal const int MinimumSamples = 3;
        internal const double PercentFloor = 0.10;
        internal const double ReserveWarningFactor = 1.5;
        internal const double MaximumWeeks = 10000.0;
        internal static readonly TimeSpan Window = TimeSpan.FromDays(56);
        internal static readonly TimeSpan MinimumSpan = TimeSpan.FromDays(7);

        internal static bool IsAllowedWarnWeeks(int weeks)
        {
            return weeks == 4 || weeks == 8 || weeks == 12;
        }

        internal static BackupSpaceResult Evaluate(BackupSpaceFacts facts)
        {
            BackupSpaceFacts known = facts ?? new BackupSpaceFacts();
            BackupSpaceForecastState state;
            BackupSpaceCleanUpEffect cleanUp = BackupSpaceCleanUpEffect.None;
            long weekly;
            if (!known.ForecastAvailable)
            {
                state = BackupSpaceForecastState.Unavailable;
                weekly = -1;
            }
            else if (!known.HistoryReadable)
            {
                state = BackupSpaceForecastState.Unknown;
                weekly = -1;
            }
            else
            {
                weekly = EstimateWeeklyGrowth(known.Samples, known.CleanUps, out state, out cleanUp);
            }
            BackupSpaceResult result = Judge(known, state, weekly);
            result.CleanUp = cleanUp;
            return result;
        }

        // The level and reason for a forecast already worked out, in this order: too full for the next backup; full within the warning
        // at this rate; less than 1.5 times the reserve; with no forecast yet (learning or unreadable), less than a tenth of the drive
        // above the reserve; otherwise fine. Where no forecast is available at all, only the reserve rules apply (see Percent).
        internal static BackupSpaceResult Judge(BackupSpaceFacts facts, BackupSpaceForecastState state, long weeklyBytes)
        {
            BackupSpaceFacts known = facts ?? new BackupSpaceFacts();
            BackupSpaceResult result = new BackupSpaceResult();
            bool growing = state == BackupSpaceForecastState.Growing && weeklyBytes > 0;
            if (state == BackupSpaceForecastState.Growing && !growing)
            {
                state = BackupSpaceForecastState.Flat;
            }
            result.ForecastState = state;
            result.WeeklyBytes = growing ? weeklyBytes : state == BackupSpaceForecastState.Flat ? 0 : -1;
            int warnWeeks = IsAllowedWarnWeeks(known.WarnWeeks) ? known.WarnWeeks : DefaultWarnWeeks;

            long free = known.FreeBytes;
            long total = known.TotalBytes;
            if (free < 0 || total <= 0 || free > total)
            {
                return result;
            }
            long reserve = Math.Max(0, known.ReserveBytes);
            double headroom = (double)free - reserve;
            if (growing)
            {
                double weeks = Math.Min(MaximumWeeks, Math.Max(0.0, headroom) / weeklyBytes);
                double sent = Math.Round(weeks, 2, MidpointRounding.AwayFromZero);
                result.WeeksLeft = sent;
                result.WeeksRounded = (int)Math.Round(sent, MidpointRounding.AwayFromZero);
            }

            if ((reserve > 0 && free < reserve) || free == 0)
            {
                result.Level = BackupSpaceLevel.Full;
                result.Reason = BackupSpaceReason.Reserve;
            }
            else if (growing && result.WeeksRounded.Value <= warnWeeks)
            {
                result.Level = BackupSpaceLevel.Low;
                result.Reason = BackupSpaceReason.Forecast;
            }
            else if (reserve > 0 && free < reserve * ReserveWarningFactor)
            {
                result.Level = BackupSpaceLevel.Low;
                result.Reason = BackupSpaceReason.Percent;
            }
            else if ((state == BackupSpaceForecastState.Learning || state == BackupSpaceForecastState.Unknown) &&
                headroom < PercentFloor * total)
            {
                result.Level = BackupSpaceLevel.Low;
                result.Reason = BackupSpaceReason.Percent;
            }
            else
            {
                result.Level = BackupSpaceLevel.Ok;
            }
            return result;
        }

        // While a backup runs, its own writes can take the free space below the reserve, which the backup service checks only as a run
        // starts. So the card keeps what it said before the run and moves only its figures. A "too full" from before the run is not
        // repeated: a run the service accepted had room, and one it refuses ends within moments and is judged again. With nothing said
        // before the run (the dashboard started during it, or a preview), the level is unknown until the run ends; where the backup
        // service records nothing to forecast from, the answer still says so, so Settings does not offer a warning that would do nothing.
        internal static BackupSpaceResult HoldDuringRun(BackupSpaceResult beforeRun, BackupSpaceFacts facts)
        {
            BackupSpaceResult held = beforeRun == null ? new BackupSpaceResult() : beforeRun.Copy();
            if (held.Level == BackupSpaceLevel.Full)
            {
                held.Level = BackupSpaceLevel.Unknown;
                held.Reason = BackupSpaceReason.None;
            }
            if (facts != null && !facts.ForecastAvailable)
            {
                held.ForecastState = BackupSpaceForecastState.Unavailable;
                held.WeeksLeft = null;
                held.WeeksRounded = null;
                held.WeeklyBytes = -1;
                held.CleanUp = BackupSpaceCleanUpEffect.None;
            }
            return held;
        }

        // What the verified backups of the last 8 weeks saved, per week, leaving out the single biggest one (a folder added once). It
        // reads no clock: the window ends at the newest backup. A newest backup recorded more than the whole window after the one
        // before it (a PC clock that was far ahead for one run) is set aside first, so one bad time cannot hide every real run.
        internal static long EstimateWeeklyGrowth(IList<BackupSpaceSample> samples, out BackupSpaceForecastState state)
        {
            BackupSpaceCleanUpEffect cleanUp;
            return EstimateWeeklyGrowth(samples, null, out state, out cleanUp);
        }

        // The same, net of clean-up of old backups. What the backups added is all they grow by, except where clean-up removed old
        // backups and freed their space, so the forecast takes away what each clean-up freed after the oldest backup in the window
        // opened it (one after the newest backup included: its space is already free). Backups that stay about the same size because
        // the person keeps removing old ones are then flat, not filling the drive. A clean-up in those weeks whose freed space was not
        // measured leaves nothing to take away, so the forecast is still learning until that clean-up is older than the window: it
        // never says "full in N weeks" from what was added alone.
        internal static long EstimateWeeklyGrowth(
            IList<BackupSpaceSample> samples,
            IList<BackupSpaceCleanUp> cleanUps,
            out BackupSpaceForecastState state,
            out BackupSpaceCleanUpEffect cleanUp)
        {
            cleanUp = BackupSpaceCleanUpEffect.None;
            List<BackupSpaceSample> ordered = (samples ?? new List<BackupSpaceSample>())
                .Where(sample => sample != null && sample.AddedBytes >= 0)
                .OrderBy(sample => sample.FinishedUtc)
                .ToList();
            if (ordered.Count >= 2 &&
                ordered[ordered.Count - 1].FinishedUtc - ordered[ordered.Count - 2].FinishedUtc > Window)
            {
                ordered.RemoveAt(ordered.Count - 1);
            }
            if (ordered.Count == 0)
            {
                state = BackupSpaceForecastState.Learning;
                return -1;
            }
            DateTime newest = ordered[ordered.Count - 1].FinishedUtc;
            List<BackupSpaceSample> window = ordered
                .Where(sample => sample.FinishedUtc > newest - Window)
                .ToList();
            if (window.Count < MinimumSamples)
            {
                state = BackupSpaceForecastState.Learning;
                return -1;
            }
            TimeSpan span = newest - window[0].FinishedUtc;
            if (span < MinimumSpan)
            {
                state = BackupSpaceForecastState.Learning;
                return -1;
            }
            DateTime opened = window[0].FinishedUtc;
            double freed = 0;
            foreach (BackupSpaceCleanUp done in (cleanUps ?? new List<BackupSpaceCleanUp>())
                .Where(item => item != null && item.FinishedUtc > opened))
            {
                if (done.FreedBytes < 0)
                {
                    state = BackupSpaceForecastState.Learning;
                    cleanUp = BackupSpaceCleanUpEffect.Unmeasured;
                    return -1;
                }
                freed += done.FreedBytes;
                cleanUp = BackupSpaceCleanUpEffect.Counted;
            }
            // The oldest backup in the window opens the span: what it saved was made before the span began.
            List<double> added = window.Skip(1).Select(sample => (double)sample.AddedBytes).ToList();
            double kept = added.Sum() - added.Max();
            double gross = 0;
            if (kept > 0)
            {
                double perRun = kept / (added.Count - 1);
                double runsPerWeek = added.Count / span.TotalDays * 7.0;
                gross = perRun * runsPerWeek;
            }
            double weekly = Math.Round(gross - freed / span.TotalDays * 7.0, MidpointRounding.AwayFromZero);
            if (double.IsNaN(weekly) || weekly <= 0)
            {
                state = BackupSpaceForecastState.Flat;
                return 0;
            }
            state = BackupSpaceForecastState.Growing;
            return weekly >= long.MaxValue ? long.MaxValue : (long)weekly;
        }
    }
}
