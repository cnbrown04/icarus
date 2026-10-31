import SwiftUI

/// One compact metric tile in Home's vitals row. The tile carries only what a glance needs: the value,
/// its unit and one short state line.
struct HomeVitalTile: View {
    let title: String
    let symbol: String
    var tint: Color = Palette.heartRate
    let value: String
    var unit: String?
    var caption: String?
    var captionTint: Color?
    let accessibilityLabel: String
    let accessibilityValue: String
    /// For UI tests only. Set on the tile's element.
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s4) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(captionTint ?? .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.s48 + Spacing.s24, alignment: .topLeading)
        .padding(Spacing.s12)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .optionalIdentifier(identifier)
    }
}

/// A compact tappable row: a leading symbol, a title and caption, then a trailing value and chevron.
/// Home uses it for the next alarm so the row reads as one line of status rather than a full card.
struct HomeActionRow: View {
    let symbol: String
    var tint: Color = Palette.neutral
    let title: String
    let value: String
    var caption: String?
    var isMuted = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.s12) {
                symbolView
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Spacing.s8) {
                        labels
                        HStack(spacing: Spacing.s4) {
                            valueText
                            chevron
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    labels
                    Spacer(minLength: Spacing.s8)
                    valueText
                    chevron
                }
            }
            .padding(Spacing.s16)
            .cardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbolView: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .font(.body)
            .frame(width: Spacing.s32, height: Spacing.s32)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(title)
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
    }

    private var valueText: some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(isMuted ? Color.secondary : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
