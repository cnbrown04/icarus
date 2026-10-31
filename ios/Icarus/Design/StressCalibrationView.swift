import Metrics
import SwiftUI

/// The one-line calibration explanation on Today's stress card.
struct StressCalibrationNote: View {
    let progress: StressCalibrationProgress
    let state: StressState?

    private var copy: (title: String, detail: String) {
        StressCalibrationCopy.make(progress: progress, state: state)
    }

    private var symbol: String {
        switch state {
        case .some(.hrOnly): "heart.text.square"
        case .some(.insufficient): "questionmark.circle"
        default: progress.isCalibrated ? "checkmark.circle" : "hourglass"
        }
    }

    private var tint: Color {
        switch state {
        case .some(.hrOnly): Palette.warn
        case .some(.insufficient): Palette.warn
        default: progress.isCalibrated ? Palette.syncOK : Palette.warn
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.subheadline)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(copy.title)
                    .font(.subheadline.weight(.semibold))
                Text(copy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The full calibration section on the stress detail screen: progress, the qualifying rule, the
/// recent days and the HR-only fallback with its caveat.
struct StressCalibrationDetail: View {
    let progress: StressCalibrationProgress
    let state: StressState?
    let timeZone: TimeZone

    private var requiredWindows: Int {
        progress.latestDay?.requiredWindows ?? Stress.minAwakeWindowsPerDay
    }

    private var qualifyingMinutes: Int {
        requiredWindows * Int(LocalTime.msPerWindow / LocalTime.msPerMinute)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            if progress.days.isEmpty {
                Text("Stress needs a max heart rate or birth year before a baseline can be built. Add one in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                status
                Text("Stress compares each window with your own recent days, so it needs a baseline before values appear.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(StressCalibrationCopy.make(progress: progress, state: state).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("A day qualifies with \(requiredWindows) awake five-minute windows "
                    + "(\(Format.duration(minutes: qualifyingMinutes))) of valid R-R, "
                    + "outside sleep and exertion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                lookbackDays
                Divider()
                hrOnly
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(progress.qualifyingDays) of \(progress.requiredDays) days")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: Spacing.s8)
                Text(progress.isCalibrated ? "Calibrated" : "\(progress.daysNeeded) to go")
                    .font(.caption)
                    .foregroundStyle(progress.isCalibrated ? Palette.syncOK : .secondary)
            }
            ProgressView(value: Double(progress.qualifyingDays), total: Double(progress.requiredDays))
                .tint(Palette.stressModerate)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stress calibration")
        .accessibilityValue("\(progress.qualifyingDays) of \(progress.requiredDays) days qualify")
    }

    private var lookbackDays: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text("Recent days")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(progress.days.prefix(7)) { lookbackDay in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                    Text(dayLabel(lookbackDay.day))
                        .font(.caption)
                    Spacer(minLength: Spacing.s8)
                    Text("\(lookbackDay.validWindowCount)/\(lookbackDay.requiredWindows) windows")
                        .font(.caption)
                        .monospacedDigit()
                    if lookbackDay.qualifiesForRR {
                        Text("Qualified")
                            .font(.caption2)
                            .foregroundStyle(Palette.syncOK)
                    } else {
                        Text("\(lookbackDay.validMinutesNeeded) min needed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(dayLabel(lookbackDay.day)), \(lookbackDay.validWindowCount) of \(lookbackDay.requiredWindows) valid windows"))
                .accessibilityValue(Text(lookbackDay.qualifiesForRR
                    ? "Qualified"
                    : "\(lookbackDay.validMinutesNeeded) minutes still needed"))
            }
            if progress.days.count > 7 {
                Text("Showing the 7 most recent of \(progress.days.count) days in the \(progress.lookbackDays)-day lookback.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var hrOnly: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text("HR-only fallback")
                .font(.caption.weight(.semibold))
            if progress.isHROnlyCalibrated {
                Text("Ready from \(progress.hrOnlyDays) days. It uses heart rate without HRV, so it is less "
                    + "specific and is labelled HR only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Without R-R, \(progress.requiredDays) days of heart-rate windows can still score a fallback. "
                    + "\(progress.hrOnlyDays) of \(progress.requiredDays) are ready; "
                    + "\(StressCalibrationCopy.daysNeeded(progress.hrOnlyDaysNeeded)) to go. "
                    + "It uses heart rate without HRV, so it is less specific and is labelled HR only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dayLabel(_ day: LocalDay) -> String {
        let date = Date(epochMs: LocalTime.localTime(day, hour: 12, in: timeZone))
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }
}

/// Shared wording for the compact note and the detail section, so the two cannot disagree.
private enum StressCalibrationCopy {
    static func make(
        progress: StressCalibrationProgress,
        state: StressState?
    ) -> (title: String, detail: String) {
        (title: title(progress: progress, state: state), detail: detail(progress: progress, state: state))
    }

    static func daysNeeded(_ count: Int) -> String {
        guard count > 0 else { return "no more days" }
        return count == 1 ? "1 more day" : "\(count) more days"
    }

    private static func title(progress: StressCalibrationProgress, state: StressState?) -> String {
        guard !progress.days.isEmpty else { return "Calibration unavailable" }
        switch state {
        case .some(.hrOnly):
            return "HR only — \(progress.qualifyingDays) of \(progress.requiredDays) R-R days"
        case .some(.insufficient) where progress.isCalibrated:
            return "Baseline ready"
        case .some(.exertion):
            return "Exertion"
        default:
            break
        }
        if progress.isCalibrated {
            return "Calibrated — \(progress.qualifyingDays) of \(progress.requiredDays) days"
        }
        return "Calibrating — \(progress.qualifyingDays) of \(progress.requiredDays) days"
    }

    private static func detail(progress: StressCalibrationProgress, state: StressState?) -> String {
        guard !progress.days.isEmpty else {
            return "Add max heart rate or birth year in Settings so a baseline can be built."
        }
        let required = progress.latestDay?.requiredWindows ?? Stress.minAwakeWindowsPerDay
        let minutes = required * Int(LocalTime.msPerWindow / LocalTime.msPerMinute)

        switch state {
        case .some(.hrOnly):
            return "R-R needs \(daysNeeded(progress.daysNeeded)). HR-only values use heart rate without HRV, "
                + "so they are less precise."
        case .some(.insufficient):
            if progress.isCalibrated {
                return "The baseline is ready, but its median heart rate or R-R is missing for this window, "
                    + "so no value can be computed."
            }
            return calibratingDetail(progress: progress, minutes: minutes)
        case .some(.exertion):
            return "Stress is not scored during exertion. It returns when heart rate reserve falls below 40 %."
        default:
            return calibratingDetail(progress: progress, minutes: minutes)
        }
    }

    private static func calibratingDetail(progress: StressCalibrationProgress, minutes: Int) -> String {
        if progress.isCalibrated {
            return "\(progress.qualifyingDays) of \(progress.requiredDays) days in the last "
                + "\(progress.lookbackDays) days qualified."
        }
        return "Needs \(daysNeeded(progress.daysNeeded)); each needs at least "
            + "\(Format.duration(minutes: minutes)) of valid R-R outside sleep and exertion."
    }
}
