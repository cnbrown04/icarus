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
            }

            Section {
                header
                MetricDetailChart(data: data ?? .placeholder(kind: kind, range: range), selection: $selection)
                    .frame(height: ChartHeight.detail)
                    .accessibilityHidden(data == nil)
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
        .task(id: range) {
            let kind = kind
            let range = range
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try MetricDetailModel.load(db, nowMs: nowMs, kind: kind, range: range)
            }) {
                data = value
            }
        }
        .onChange(of: range) {
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
        if let data {
            Section {
                if data.kind.aggregation == .sum {
                    LabeledRow(title: "Total", value: data.value.map { MetricFormat.withUnit($0, kind) } ?? "—")
                } else {
                    LabeledRow(title: "Average", value: data.value.map { MetricFormat.withUnit($0, kind) } ?? "—")
                    LabeledRow(title: "Minimum", value: data.minimum.map { MetricFormat.withUnit($0, kind) } ?? "—")
                    LabeledRow(title: "Maximum", value: data.maximum.map { MetricFormat.withUnit($0, kind) } ?? "—")
                }
                if let change = changeText(data) {
                    LabeledRow(title: "Change", value: change)
                }
            }
        }
    }

    /// The change against the previous equal period, e.g. "+3 bpm vs previous 7 days".
    private func changeText(_ data: MetricDetailData) -> String? {
        guard let value = data.value, let previous = data.previousValue else { return nil }
        let comparison = data.range == .day ? "yesterday" : "previous \(data.range.days) days"
        return "\(MetricFormat.change(value - previous, kind)) vs \(comparison)"
    }
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
