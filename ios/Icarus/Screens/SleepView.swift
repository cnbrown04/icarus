import Metrics
import SwiftUI

/// The last 7 days of derived sleep sessions (PLAN.md 8.1, 10.2 v2), main sleep and naps. Sessions come from
/// the band's offloaded history (PLAN.md 5.3.4), so the list stays empty until a sync has drained it. The
/// latest main sleep shows its stored hypnogram inline; other entries open a detail with the same chart and
/// facts. Naps are labelled, and they never replace the latest main sleep.
struct SleepView: View {
    let environment: AppEnvironment

    @State private var snapshot: Dashboard.SleepSnapshot?
    /// The night whose bed and wake times are being corrected (`SleepEditView`).
    @State private var editing: Dashboard.SleepSnapshot.Night?
    /// Bumped after a correction is stored, to reload the list at once.
    @State private var refreshToken = 0

    private var timeZone: TimeZone {
        snapshot?.context.timeZone ?? Dashboard.fallbackZone
    }

    var body: some View {
        List {
            if let nights = snapshot?.nights, !nights.isEmpty {
                ForEach(nights) { night in
                    if night.id == snapshot?.latest?.id {
                        latestSection(night)
                    } else {
                        priorNightSection(night)
                    }
                }
            } else {
                Section {
                    Text("Sleep appears once the band has synced its history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sleep")
        .task(id: refreshToken) {
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try Dashboard.sleep(db, nowMs: nowMs)
            }) {
                snapshot = value
            }
        }
        .sheet(item: $editing) { night in
            SleepEditView(environment: environment, night: night, timeZone: timeZone) {
                refreshToken += 1
            }
        }
    }

    // MARK: Nights

    /// The latest main sleep carries the full hypnogram and stage breakdown.
    private func latestSection(_ night: Dashboard.SleepSnapshot.Night) -> some View {
        Section {
            nightStages(night)
            nightFacts(night, timeZone: timeZone)
            Button("Edit times") {
                editing = night
            }
            .accessibilityIdentifier("sleep.editTimes")
        } header: {
            nightTitle(night)
        }
    }

    /// Older nights keep a compact summary in the list and open the chart on tap.
    private func priorNightSection(_ night: Dashboard.SleepSnapshot.Night) -> some View {
        Section {
            NavigationLink {
                SleepNightDetailView(night: night, timeZone: timeZone)
            } label: {
                priorNightLabel(night)
            }
            .swipeActions(edge: .trailing) {
                Button("Edit times") {
                    editing = night
                }
                .tint(.blue)
            }
        } header: {
            nightTitle(night)
        }
    }

    private func priorNightLabel(_ night: Dashboard.SleepSnapshot.Night) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(Format.duration(night.asleepS))
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: Spacing.s8)
                Text(Format.sleepQuality(night.quality))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.sleepQuality(night.quality))
            }

            HStack(spacing: Spacing.s8) {
                Text(sleepWindow(night, in: timeZone))
                Spacer(minLength: Spacing.s8)
                if let efficiency = night.efficiency {
                    Text("Asleep \(Format.percent(efficiency))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if night.isStaged {
                SleepStageBar(totals: night.stageTotals, showsLegend: false)
                Text(SleepStageTotals.summary(night.stageTotals))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            } else {
                Text("Stages not yet computed — sync to update")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.s4)
    }
}

/// A prior night's hypnogram, stage breakdown and the facts the list used to show inline.
private struct SleepNightDetailView: View {
    let night: Dashboard.SleepSnapshot.Night
    let timeZone: TimeZone

    var body: some View {
        List {
            Section {
                nightStages(night)
            } header: {
                nightTitle(night)
            }

            Section("Night") {
                nightFacts(night, timeZone: timeZone)
            }
        }
        .navigationTitle(Text(Date(epochMs: night.startMs), style: .date))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Shared rows

/// The chart, stage totals and efficiency, or the honest empty state for a night that predates staging.
@ViewBuilder
private func nightStages(_ night: Dashboard.SleepSnapshot.Night) -> some View {
    if night.isStaged {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            SleepStageChart(segments: night.stages, totals: night.stageTotals)
                .frame(height: Spacing.s48 * 3)
            SleepStageSummaryRow(totals: night.stageTotals)
            HStack(spacing: Spacing.s8) {
                Text("Time asleep")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s8)
                Text(night.efficiency.map { Format.percent($0) } ?? "--")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, Spacing.s4)
    } else {
        Text("Stages not yet computed — sync to update")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

@ViewBuilder
private func nightFacts(_ night: Dashboard.SleepSnapshot.Night, timeZone: TimeZone) -> some View {
    LabeledContent("Bed → wake") {
        Text(sleepWindow(night, in: timeZone))
            .monospacedDigit()
    }
    LabeledContent("Asleep") {
        Text(Format.duration(night.asleepS))
            .monospacedDigit()
    }
    LabeledContent("In bed") {
        Text(Format.duration(night.durationS))
            .monospacedDigit()
    }
    LabeledContent("Quality") {
        Text(Format.sleepQuality(night.quality))
            .foregroundStyle(Palette.sleepQuality(night.quality))
    }
    LabeledContent("Median HR") {
        Text(night.restingHR.map { Format.number($0, unit: "bpm") } ?? "--")
            .monospacedDigit()
    }
    LabeledContent("RMSSD") {
        Text(night.rmssdMs.map { Format.number($0, unit: "ms") } ?? "--")
            .monospacedDigit()
    }
}

/// The night is labelled by the day it started (PLAN.md 8.1's evening-to-morning window). A nap says so.
private func nightTitle(_ night: Dashboard.SleepSnapshot.Night) -> Text {
    let date = Text(Date(epochMs: night.startMs), style: .date)
    return night.isNap ? date + Text(" · Nap") : date
}

private func sleepWindow(_ night: Dashboard.SleepSnapshot.Night, in timeZone: TimeZone) -> String {
    let wakeMs = night.startMs + night.durationS * 1_000
    return "\(Format.clock(night.startMs, in: timeZone)) – \(Format.clock(wakeMs, in: timeZone))"
}
