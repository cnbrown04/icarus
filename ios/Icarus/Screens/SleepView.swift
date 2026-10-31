import Metrics
import Store
import SwiftUI

/// The Sleep tab, the one place sleep is shown. It opens on the chosen range: D shows the night's hypnogram, and W, M
/// and 6M show one bar per night, where dragging selects a night. Below the chart come that night's stages, its scores,
/// tonight's bedtimes and the previous nights. Each previous night opens the same sections.
struct SleepView: View {
    let environment: AppEnvironment

    @State private var snapshot: SleepModel.Snapshot?
    @State private var range: SleepModel.Range = .week
    /// The night on show. Nil means the latest main sleep.
    @State private var selectedID: Int64?
    /// The night whose bed and wake times are being corrected (`SleepEditView`).
    @State private var editing: Dashboard.SleepSnapshot.Night?
    /// Bumped after a correction is stored, to reload at once.
    @State private var refreshToken = 0

    /// Reloads when the range or a correction changes.
    private struct LoadKey: Hashable {
        let range: SleepModel.Range
        let token: Int
    }

    private var timeZone: TimeZone {
        snapshot?.timeZone ?? Dashboard.fallbackZone
    }

    /// The night on show: the selected one when the range holds it, else the latest main sleep.
    private var shown: SleepModel.Day? {
        guard let snapshot else { return nil }
        if let selectedID, let day = snapshot.days.first(where: { $0.id == selectedID }) {
            return day
        }
        return snapshot.latest
    }

    /// The Dashboard night behind the shown one, for its hypnogram and Edit. Nil outside the seven-night window.
    private var shownNight: Dashboard.SleepSnapshot.Night? {
        guard let id = shown?.id else { return nil }
        return snapshot?.recent.nights.first { $0.id == id }
    }

    var body: some View {
        List {
            if let snapshot {
                if snapshot.recent.nights.isEmpty {
                    Section {
                        EmptyStateRow(text: "Sleep appears once the band has synced its history.", actionTitle: nil, action: nil)
                    }
                } else {
                    chartSection(snapshot)
                    if let shown {
                        stagesSection(shown)
                        scoresSection(shown, snapshot: snapshot)
                    }
                    tonightSection(snapshot)
                    previousSection(snapshot)
                }
            }
            aboutSection
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    editing = shownNight
                }
                .disabled(shownNight == nil)
                .accessibilityIdentifier("sleep.editTimes")
            }
        }
        .task(id: LoadKey(range: range, token: refreshToken)) {
            let selectedRange = range
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try SleepModel.load(db, nowMs: nowMs, range: selectedRange)
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

    // MARK: Chart

    private func chartSection(_ snapshot: SleepModel.Snapshot) -> some View {
        Section {
            if let shown {
                nightHeader(
                    asleepS: shown.asleepS,
                    startMs: shown.startMs,
                    durationS: shown.durationS,
                    timeZone: timeZone
                )
            }
            Picker("Range", selection: $range) {
                ForEach(SleepModel.Range.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            chart(snapshot)
                .frame(height: ChartHeight.detail)
        }
    }

    @ViewBuilder
    private func chart(_ snapshot: SleepModel.Snapshot) -> some View {
        if range == .day {
            if let night = shownNight, night.isStaged {
                SleepStageChart(segments: night.stages, totals: night.stageTotals)
            } else {
                Text("Stages pending")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            SleepNightBars(days: snapshot.days.filter { !$0.isNap }, selectedID: $selectedID)
        }
    }

    // MARK: Night sections

    private func stagesSection(_ day: SleepModel.Day) -> some View {
        Section("Stages") {
            stageRows(totals: day.totals)
        }
    }

    private func scoresSection(_ day: SleepModel.Day, snapshot: SleepModel.Snapshot) -> some View {
        let row = snapshot.scores[day.wakeDayKey]
        let latest = day.id == snapshot.latest?.id ? snapshot.recent.latestScores : nil
        return Section("Scores") {
            scoreRows(efficiency: day.efficiency, row: row, latest: latest)
        }
    }

    // MARK: Tonight

    private func tonightSection(_ snapshot: SleepModel.Snapshot) -> some View {
        let inputs = snapshot.coaching.inputs
        let zone = snapshot.timeZone
        return Section("Tonight") {
            if let wake = inputs.wake {
                let plans = SleepPlanner.plans(wakeSec: wake.wakeSec, needSec: inputs.tonightNeedSec, timing: inputs.timing)
                ForEach(plans, id: \.target) { plan in
                    HStack {
                        Text(plan.target.label)
                        Spacer(minLength: Spacing.s8)
                        Text(Format.clock(plan.bedtimeSec * 1000, in: zone))
                            .monospacedDigit()
                    }
                }
                Text("Wake \(Format.clock(wake.wakeSec * 1000, in: zone)) · \(sourceText(wake.source))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                EmptyStateRow(text: "No wake time. Set an alarm to plan bedtimes.", actionTitle: nil, action: nil)
            }
        }
    }

    /// "alarm", or "median of 7 nights" when no alarm is within a day.
    private func sourceText(_ source: WakePlan.Source) -> String {
        switch source {
        case .alarm:
            "alarm"
        case let .medianOfRecentWakes(nights):
            "median of \(nights) nights"
        }
    }

    // MARK: Previous nights

    @ViewBuilder
    private func previousSection(_ snapshot: SleepModel.Snapshot) -> some View {
        let latestID = snapshot.latest?.id
        let nights = snapshot.recent.nights.filter { $0.id != latestID }
        if !nights.isEmpty {
            Section("Previous Nights") {
                ForEach(nights) { night in
                    NavigationLink {
                        SleepNightDetailView(
                            night: night,
                            row: snapshot.scores[SleepModel.wakeDayKey(startMs: night.startMs, durationS: night.durationS, in: timeZone)],
                            timeZone: timeZone
                        )
                    } label: {
                        previousLabel(night)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Edit") {
                            editing = night
                        }
                    }
                }
            }
        }
    }

    private func previousLabel(_ night: Dashboard.SleepSnapshot.Night) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(alignment: .firstTextBaseline) {
                nightTitle(night)
                Spacer(minLength: Spacing.s8)
                Text(Format.duration(night.asleepS))
                    .monospacedDigit()
            }
            if night.isStaged {
                SleepStageBar(totals: night.stageTotals, showsLegend: false)
            }
        }
        .padding(.vertical, Spacing.s4)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            DisclosureGroup("About Sleep") {
                Text("Times, stages and scores are estimates from heart rate and motion, not WHOOP's measurements. Nights without stages count their whole time in bed as asleep. Naps are listed with the nights and never replace the main sleep.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A prior night, with the same header, stages and scores as the Sleep tab shows for the night on show.
private struct SleepNightDetailView: View {
    let night: Dashboard.SleepSnapshot.Night
    let row: DailyScoreRow?
    let timeZone: TimeZone

    var body: some View {
        List {
            Section {
                nightHeader(asleepS: night.asleepS, startMs: night.startMs, durationS: night.durationS, timeZone: timeZone)
                if night.isStaged {
                    SleepStageChart(segments: night.stages, totals: night.stageTotals)
                        .frame(height: ChartHeight.detail)
                } else {
                    Text("Stages pending")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Stages") {
                stageRows(totals: night.stageTotals)
            }
            Section("Scores") {
                scoreRows(efficiency: night.efficiency, row: row, latest: nil)
            }
        }
        .navigationTitle(nightTitle(night))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Shared rows

/// Time asleep, large, over the bed and wake window.
private func nightHeader(asleepS: Int64, startMs: Int64, durationS: Int64, timeZone: TimeZone) -> some View {
    VStack(alignment: .leading, spacing: Spacing.s4) {
        Text(Format.duration(asleepS))
            .font(.figureLarge)
            .monospacedDigit()
        Text(sleepWindow(startMs: startMs, durationS: durationS, timeZone: timeZone))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
    .padding(.vertical, Spacing.s4)
}

/// Deep, Core, REM and Awake, each with its duration and share of the night. Unstaged nights say so.
@ViewBuilder
private func stageRows(totals: [SleepStage: Int]) -> some View {
    if totals.isEmpty {
        Text("Stages pending")
            .font(.footnote)
            .foregroundStyle(.secondary)
    } else {
        ForEach(SleepStage.stackOrder, id: \.self) { stage in
            LabeledContent(stageTitle(stage)) {
                Text("\(Format.duration(seconds: totals[stage] ?? 0)) · \(Format.percent(SleepStageTotals.percent(stage, of: totals)))")
                    .monospacedDigit()
            }
        }
    }
}

/// Performance, need, debt and efficiency from the night's `daily_score` row, and regularity and consistency for the
/// latest night only. Each value has one source. A stimulant near sleep onset is one row.
@ViewBuilder
private func scoreRows(efficiency: Double?, row: DailyScoreRow?, latest: DailyScores?) -> some View {
    scoreRow("Performance", row?.sleepPerformance.map { Format.percent($0 / 100) })
    scoreRow("Need", row?.sleepNeedSec.map { Format.duration($0) })
    scoreRow("Debt", row?.sleepDebtSec.map { $0 > 0 ? Format.duration($0) : "None" })
    scoreRow("Efficiency", efficiency.map { Format.percent($0) })
    scoreRow("Regularity", latest?.sleepRegularityIndex.map { "\(Int($0.rounded()))" })
    scoreRow("Consistency", latest?.sleepConsistency.map { Format.percent($0) })
    if latest?.stimulantNearSleepOnset == true {
        LabeledContent("Stimulant at Bedtime", value: "Within 1 h")
    }
}

private func scoreRow(_ title: String, _ value: String?) -> some View {
    LabeledContent(title) {
        Text(value ?? "—")
            .monospacedDigit()
    }
}

/// The night is labelled by the day it started. A nap says so.
private func nightTitle(_ night: Dashboard.SleepSnapshot.Night) -> Text {
    let date = Text(Date(epochMs: night.startMs), style: .date)
    return night.isNap ? Text("\(date) · Nap") : date
}

private func sleepWindow(startMs: Int64, durationS: Int64, timeZone: TimeZone) -> String {
    let wakeMs = startMs + durationS * 1_000
    return "\(Format.clock(startMs, in: timeZone))–\(Format.clock(wakeMs, in: timeZone))"
}

private func stageTitle(_ stage: SleepStage) -> String {
    switch stage {
    case .deep: "Deep"
    case .light: "Core"
    case .rem: "REM"
    case .wake: "Awake"
    }
}
