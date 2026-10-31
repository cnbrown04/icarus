import SwiftUI

/// A slim proportional bar for zone or band minutes. The segments carry the colour; the caption or
/// the detail screen carries the labels.
struct MinuteStrip: View {
    struct Segment: Identifiable {
        let id: Int
        let minutes: Int
        let color: Color
    }

    let segments: [Segment]
    let accessibilityLabel: String
    let accessibilityValue: String

    private var total: Int {
        segments.reduce(0) { $0 + $1.minutes }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: .zero) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(
                            width: proxy.size.width * CGFloat(segment.minutes) / CGFloat(max(total, 1)),
                            height: proxy.size.height
                        )
                }
            }
        }
        .frame(height: Spacing.s8)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}
