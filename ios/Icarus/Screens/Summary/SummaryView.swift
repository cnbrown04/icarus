import Metrics
import Store
import SwiftUI
import SyncKit

/// The first tab, today only. Three rings (sleep, recovery, strain) open their owners, then the key metrics, then at
/// most two highlights from the weekly assessment. Rows that need action sit at the top and appear only when needed.
struct SummaryView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @Environment(\.openTab) private var openTab
    @State private var snapshot: SummarySnapshot?

    var body: some View {
        List {
            if showsActionSection {
                actionSection
            }
            ringsSection
            keyMetricsSection
            if let highlights = snapshot?.highlights, !highlights.isEmpty {
                highlightsSection(highlights)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Summary")
        .refreshable {
            await environment.sync.runNow()
            await reload()
        }
        .task {
            // The store changes with each sync, but the clock moves on its own, so reload every minute too.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func reload() async {
        let nowMs = environment.clock.nowMs
        if let loaded = try? await environment.database.writer.read({ db in
            try SummarySnapshot.load(db, nowMs: nowMs)
        }) {
            snapshot = loaded
        }
    }

    // MARK: Action rows

    private var showsJournal: Bool { snapshot?.journalPrompt == true }

    /// Collection stopped for more than the paused threshold. A band that never connected shows nothing.
    private var showsBand: Bool { liveState.lastDataAt != nil && liveState.isCollectionPaused }

    private var showsRepair: Bool { environment.sync.status.phase == .needsRepair }

    private var showsStorage: Bool { environment.storageFailed }

    private var showsActionSection: Bool { showsJournal || showsBand || showsRepair || showsStorage }

    /// One actionable row: a title and a one-line detail beneath it, neither wrapping.
    private func actionRow(_ title: String, detail: String, symbol: String, tint: Color = .primary) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(title)
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint == .primary ? Color.secondary : tint)
        }
    }

    private var actionSection: some View {
        Section {
            if showsJournal {
                NavigationLink(value: AppRoute.journal(nil)) {
                    actionRow("Log Yesterday", detail: "Journal check-in", symbol: Symbol.journal)
                }
            }
            if showsBand, let lastData = liveState.lastDataAt {
                let age = DataAge.text(seconds: environment.clock.now.timeIntervalSince(lastData))
                actionRow("Band Not Connected", detail: "Last data \(age)", symbol: Symbol.band, tint: Palette.warn)
            }
            if showsRepair {
                NavigationLink {
                    ServerView(sync: environment.sync)
                } label: {
                    actionRow("Pair Server Again", detail: "The server rejected this iPhone", symbol: Symbol.server)
                }
            }
            if showsStorage {
                actionRow(
                    "Not Saved",
                    detail: "Data from this launch is not stored",
                    symbol: "externaldrive.badge.exclamationmark",
                    tint: Palette.error
                )
            }
        }
    }

    // MARK: Rings

    private var ringsSection: some View {
        Section {
            HStack(alignment: .top, spacing: Spacing.s12) {
                sleepRing
                recoveryRing
                strainRing
            }
            .padding(.vertical, Spacing.s8)
        }
    }

    private var sleepRing: some View {
        let sleep = snapshot?.scores.sleep
        let performance = sleep?.performancePct
        return Button {
            openTab(.sleep)
        } label: {
            ScoreDial(
                title: "Sleep",
                fraction: (performance ?? 0) / 100,
                valueText: performance.map { "\(Int($0.rounded()))" } ?? "—",
                unit: performance == nil ? nil : "%",
                caption: sleep.map { Format.duration(Int64($0.asleepSec.rounded())) } ?? "No sleep yet",
                tint: Palette.category(.sleep),
                accessibilityValue: performance.map { "\(Int($0.rounded())) percent" } ?? "No sleep yet"
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens sleep")
    }

    /// Recovery is an empty ring while it calibrates, with the nights count as its caption. Otherwise the ring takes
    /// the band colour (red, yellow or green), which carries the meaning.
    private var recoveryRing: some View {
        let readout = RecoveryReadout(outcome: snapshot?.scores.recovery)
        let calibrating = readout.isCalibrating
        return NavigationLink(value: AppRoute.metric(.recovery)) {
            ScoreDial(
                title: "Recovery",
                fraction: calibrating ? 0 : readout.fraction,
                valueText: calibrating ? "—" : readout.value,
                unit: readout.hasScore && !calibrating ? "%" : nil,
                caption: recoveryCaption,
                tint: calibrating ? Palette.neutral : readout.tint,
                accessibilityValue: calibrating ? readout.caption : readout.summary
            )
        }
        .buttonStyle(.plain)
    }

    private var recoveryCaption: String {
        switch snapshot?.scores.recovery {
        case let .scored(score)?:
            let nights = score.hrvBaseline.nValid
            return nights < Recovery.minNightsTrust ? "\(nights) of \(Recovery.minNightsTrust)" : "From last night"
        case let .insufficientBaseline(_, validNights)?:
            return "\(validNights) of \(Recovery.minNightsTrust)"
        case nil:
            return "No night yet"
        }
    }

    /// The strain ring with the Strain Coach target band, drawn only once recovery is scored.
    private var strainRing: some View {
        let strain = snapshot?.scores.strain?.whoopScale
        let target = StrainCoach.target(recoveryPercent: scoredRecovery)
        let scale = StrainCoach.scaleMax
        let band: ClosedRange<Double>? = target.isCalibrating ? nil : {
            let low = min(max(target.low / scale, 0), 1)
            return low...min(max(target.high / scale, low), 1)
        }()
        let caption = "Target \(Int(target.low))–\(Int(target.high))"
        let valueText = strain.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        return Button {
            openTab(.strain)
        } label: {
            ScoreDial(
                title: "Strain",
                fraction: (strain ?? 0) / scale,
                valueText: valueText,
                unit: strain == nil ? nil : "of 21",
                caption: caption,
                tint: Palette.category(.activity),
                band: band,
                accessibilityValue: strain.map { "\($0.formatted(.number.precision(.fractionLength(1)))) of 21, \(caption)" }
                    ?? "No data yet"
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens strain")
    }

    /// Recovery as 0 to 100 when it is scored and not calibrating, else nil (the neutral Strain target).
    private var scoredRecovery: Double? {
        guard case let .scored(score)? = snapshot?.scores.recovery, score.hrvBaseline.nValid >= Recovery.minNightsTrust else {
            return nil
        }
        return score.score
    }

    // MARK: Key metrics

    private var keyMetricsSection: some View {
        Section("Key Metrics") {
            ForEach(SummarySnapshot.keyMetrics, id: \.self) { kind in
                NavigationLink(value: AppRoute.metric(kind)) {
                    MetricRow(kind: kind, value: displayValue(kind), unit: kind.unit, caption: caption(kind))
                }
            }
            NavigationLink(value: AppRoute.vitals) {
                HStack {
                    Label("Vitals", systemImage: Symbol.vitals)
                    Spacer(minLength: Spacing.s8)
                    Text(vitalsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func displayValue(_ kind: MetricKind) -> String? {
        guard let value = snapshot?.readings[kind]?.value else { return nil }
        return value.formatted(.number.precision(.fractionLength(kind.fractionDigits)))
    }

    /// The time for stress, "Last night" for values from the main sleep, and the state word when there is no value.
    private func caption(_ kind: MetricKind) -> String? {
        guard let snapshot, let reading = snapshot.readings[kind] else { return nil }
        if kind == .stress {
            if reading.value == nil { return reading.state.map { stateWord($0) } }
            return reading.atMs.map { Format.clock($0, in: snapshot.timeZone) }
        }
        return reading.value == nil ? "No night yet" : "Last night"
    }

    private func stateWord(_ state: String) -> String {
        switch state {
        case "calibrating": "Calibrating"
        case "exertion": "During exertion"
        case "stale": "Stale"
        default: "Not enough data"
        }
    }

    private var vitalsText: String {
        guard let snapshot else { return "—" }
        let summary = HealthMonitor.summary(snapshot.vitals.statuses)
        guard summary.evaluated > 0 else { return "Calibrating" }
        return "\(summary.inRange) of \(summary.evaluated) in range"
    }

    // MARK: Highlights

    private func highlightsSection(_ highlights: [String]) -> some View {
        Section("Highlights") {
            NavigationLink(value: AppRoute.weekly) {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    ForEach(highlights, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
