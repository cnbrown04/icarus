import Metrics
import Store
import SwiftUI

/// Minutes in each heart-rate zone as one capsule, with a legend of the zones that have minutes (IOS_UI_SPEC, Design).
struct ZoneBar: View {
    let zones: [ZoneMinutes]

    private struct Segment {
        let x: CGFloat
        let width: CGFloat
        let color: Color
    }

    private var total: Int {
        zones.reduce(0) { $0 + $1.minutes }
    }

    private var populated: [ZoneMinutes] {
        zones.filter { $0.minutes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    ForEach(Array(segments(width: proxy.size.width).enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: segment.width, height: proxy.size.height)
                            .offset(x: segment.x)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: Spacing.s16)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.s8) {
                ForEach(Array(populated.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: Spacing.s8) {
                        Circle()
                            .fill(Palette.zone(entry.zone))
                            .frame(width: Spacing.s8, height: Spacing.s8)
                        Text(Format.zoneLabel(entry.zone))
                            .font(.subheadline)
                        Spacer(minLength: Spacing.s8)
                        Text(Format.minutes(entry.minutes))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func segments(width: CGFloat) -> [Segment] {
        guard total > 0 else { return [] }
        var result: [Segment] = []
        var x: CGFloat = 0
        for entry in zones where entry.minutes > 0 {
            let segmentWidth = width * CGFloat(entry.minutes) / CGFloat(total)
            result.append(Segment(x: x, width: segmentWidth, color: Palette.zone(entry.zone)))
            x += segmentWidth
        }
        return result
    }
}
