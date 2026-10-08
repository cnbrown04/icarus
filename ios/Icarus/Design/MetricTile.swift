import SwiftUI

/// One number with its label, an optional caption, a change chip and a visual slot (IOS_UI_SPEC, Design).
/// Every tile has the same rows: header, value, one secondary line, then a visual slot of fixed height, so tiles in a
/// grid line up. Pass `EmptyView()` as the visual when there is none.
enum MetricTileLayout {
    /// Height of a tile's visual slot: a sparkline, a gauge or a ring.
    static let visualHeight: CGFloat = Spacing.s48 + Spacing.s8
}

struct MetricTile<Chart: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Palette.heartRate
    let value: String
    var unit: String?
    var caption: String?
    /// Current minus previous period. Shown as a chip with its unit.
    var change: Double?
    var changeUnit = ""
    var valueIdentifier: String?
    @ViewBuilder let chart: () -> Chart

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: Spacing.s32, height: Spacing.s32)
                    .background(tint.opacity(0.15), in: Circle())
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text(value)
                    .font(.metricValue)
                    .monospacedDigit()
                    .liveNumberTransition()
                    .optionalIdentifier(valueIdentifier)
                if let unit {
                    Text(unit)
                        .font(.metricUnit)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let change {
                    DeltaChip(change: change, unit: changeUnit)
                }
            }
            .frame(minHeight: Spacing.s24, alignment: .leading)
            Spacer(minLength: Spacing.s8)
            chart()
                .frame(height: MetricTileLayout.visualHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.s16)
        .cardBackground()
    }
}

/// A change against the previous period, with a direction symbol. Colour is neutral: a rise is not a good or bad sign by itself.
struct DeltaChip: View {
    let change: Double
    let unit: String

    private var rounded: Int { Int(change.rounded()) }

    private var text: String {
        let sign = rounded > 0 ? "+" : ""
        return unit.isEmpty ? "\(sign)\(rounded)" : "\(sign)\(rounded) \(unit)"
    }

    private var symbol: String {
        if rounded > 0 { return "arrow.up.right" }
        if rounded < 0 { return "arrow.down.right" }
        return "arrow.right"
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// A label and a value in a small card, for the stats row on detail screens.
struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.metricValue)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
        .cardBackground()
    }
}
