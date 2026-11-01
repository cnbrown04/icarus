import Metrics
import Store
import SwiftUI

/// The one detail page for a metric: a range control, a header with the value for the range, one main chart, the
/// details for the range, the metric's own section and the method text under About. Every metric except sleep
/// opens this page (sleep belongs to the Sleep tab). Dragging the chart shows the selected point in the header.
struct MetricDetailView: View {
    let kind: MetricKind
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var range: MetricRange
    @State private var data: MetricDetailData?
    @State private var selection: Date?
    @State private var aboutExpanded = false
    /// Nightly vitals over W, M and 6M: one value per night (Average) or every reading behind them (All Readings).
    @State private var display: ChartDisplay = .average

    init(kind: MetricKind, environment: AppEnvironment, liveState: LiveState) {
        self.kind = kind
        self.environment = environment
        self.liveState = liveState
        _range = State(initialValue: MetricRange.defaultRange(for: kind))
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(MetricRange.options(for: kind)) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Range")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                header
                MetricDetailChart(data: data ?? .placeholder(kind: kind, range: range), selection: $selection)
                    .frame(height: ChartHeight.detail)
                    .accessibilityHidden(data == nil)
                if kind.isNightly, range != .day {
                    Picker("Show", selection: $display) {
                        ForEach(ChartDisplay.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("metric.display")
                }
                if let data, !data.dayPoints.isEmpty {
                    Text("Lighter: awake. Sleep readings set the nightly value.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !visibleMedication.isEmpty {
                    Text("Shaded: stimulant active")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            detailsSection

            MetricSpecificSections(data: data ?? .placeholder(kind: kind, range: range))

            Section {
                DisclosureGroup("About", isExpanded: $aboutExpanded) {
                    ForEach(MetricAbout.sentences(kind), id: \.self) { sentence in
                        Text(sentence)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: data == nil ? .placeholder : [])
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await environment.sync.runNow()
        }
        .task(id: LoadKey(range: range, display: display)) {
            let kind = kind
            let range = range
            let readings = display == .readings
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try MetricDetailModel.load(db, nowMs: nowMs, kind: kind, range: range, readings: readings)
            }) {
                data = value
            }
        }
        .onChange(of: range) {
            selection = nil
        }
        .onChange(of: display) {
            selection = nil
        }
    }

    // MARK: Header

    /// The value for the range, or the selected point while the chart is being dragged, with one caption line.
    private var header: some View {
        let readout = headerReadout
        return VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(readout.value)
                    .font(.figureLarge)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = kind.unit, readout.value != "—" {
                    Text(unit)
                        .font(.figureUnit)
                        .foregroundStyle(.secondary)
                }
            }
            Text(readout.caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.s4)
        .accessibilityElement(children: .combine)
    }

    private var headerReadout: (value: String, caption: String) {
        guard let data else { return ("—", " ") }
        if let selection {
            if data.range == .day, let point = data.nearestPoint(to: selection) {
                return (MetricFormat.number(point.value, kind), Format.clock(point.tsMs, in: data.timeZone))
            }
            if data.showsReadings, let point = data.nearestPoint(to: selection) {
                let date = MetricFormat.shortDate(Date(epochMs: point.tsMs), in: data.timeZone)
                return (MetricFormat.number(point.value, kind), "\(date), \(Format.clock(point.tsMs, in: data.timeZone))")
            }
            if let row = data.nearestRow(to: selection), let value = row.value {
                return (MetricFormat.number(value, kind), MetricFormat.shortDate(row.date, in: data.timeZone))
            }
        }
        let value = data.value.map { MetricFormat.number($0, kind) } ?? "—"
        return (value, data.caption)
    }

    /// Stimulant windows on the day view, shown only for heart rate and stress.
    private var visibleMedication: [MedicationWindow] {
        data?.medication ?? []
    }

    // MARK: Details

    @ViewBuilder private var detailsSection: some View {
        if let data, data.kind.isNightly, data.range == .day {
            nightDetails(data)
        } else if let data {
            Section {
                if data.kind.aggregation == .sum {
                    LabeledRow(title: "Total", value: data.value.map { MetricFormat.withUnit($0, kind) } ?? "—")
                } else {
                    LabeledRow(title: "Average", value: data.value.map { MetricFormat.withUnit($0, kind) } ?? "—")
                    LabeledRow(title: "Minimum", value: data.minimum.map { MetricFormat.withUnit($0, kind) } ?? "—")
                    LabeledRow(title: "Maximum", value: data.maximum.map { MetricFormat.withUnit($0, kind) } ?? "—")
                }
                // A running total today against all of yesterday is not a comparison (it reads "−1,091 kcal" at 15:51).
                if let value = data.value, let previous = data.previousValue,
                   !(data.kind.aggregation == .sum && data.range == .day) {
                    // The comparison is the title and only the change sits on the right, so the row never wraps.
                    LabeledRow(title: changeTitle(data.range), value: MetricFormat.change(value - previous, kind))
                }
            }
        }
    }

    /// Last night's value, the spread of the readings behind it and how many there are, then the change from the
    /// night before.
    private func nightDetails(_ data: MetricDetailData) -> some View {
        Section {
            LabeledRow(title: "Last Night", value: data.value.map { MetricFormat.withUnit($0, kind) } ?? "—")
            LabeledRow(title: "Lowest Reading", value: data.minimum.map { MetricFormat.withUnit($0, kind) } ?? "—")
            LabeledRow(title: "Highest Reading", value: data.maximum.map { MetricFormat.withUnit($0, kind) } ?? "—")
            LabeledRow(title: "Readings", value: data.points.count.formatted())
            if let value = data.value, let previous = data.previousValue {
                LabeledRow(title: "Change from Previous Night", value: MetricFormat.change(value - previous, kind))
            }
        }
    }

    /// "Change from Yesterday", "Change from Previous Week", …: what the change on the right compares against.
    private func changeTitle(_ range: MetricRange) -> String {
        switch range {
        case .day: "Change from Yesterday"
        case .week: "Change from Previous Week"
        case .month: "Change from Previous Month"
        case .sixMonths: "Change from Previous 6 Months"
        }
    }
}

/// What a nightly vital's W, M and 6M chart draws.
enum ChartDisplay: String, CaseIterable, Identifiable {
    /// One value per night: the resting floor, the HRV mean or the respiratory median.
    case average
    /// Every window reading those nightly values summarise.
    case readings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .average: "Average"
        case .readings: "All Readings"
        }
    }
}

/// What a metric page's data depends on: a change to either reloads it.
private struct LoadKey: Hashable {
    let range: MetricRange
    let display: ChartDisplay
}

extension MetricDetailData {
    /// Stand-in while the first read is pending, so the page lays out with its real structure under a redaction.
    static func placeholder(kind: MetricKind, range: MetricRange) -> MetricDetailData {
        MetricDetailData(
            kind: kind,
            range: range,
            timeZone: .current,
            nowMs: 0,
            dayStartMs: 0,
            dayEndMs: 0,
            points: [],
            rows: [],
            value: nil,
            minimum: nil,
            maximum: nil,
            previousValue: nil,
            caption: " ",
            zones: [],
            medication: [],
            calibration: nil,
            calories: nil,
            snapshot: nil
        )
    }
}
