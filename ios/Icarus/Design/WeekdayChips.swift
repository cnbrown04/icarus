import SwiftUI

/// Seven capsule chips for choosing repeat days (IOS_UI_SPEC, Screen 13). Each chip is a button with its full day name
/// as its label. Selected chips are filled with the tint.
struct WeekdayChips: View {
    @Binding var selection: Set<Int>
    var tint: Color = Palette.heartRate

    /// Chips are at least this tall, so each one is a 44 pt target (IOS_UI_SPEC, Global look).
    private static let chipHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: Spacing.s4) {
            ForEach(1...7, id: \.self) { day in
                chip(for: day)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(for day: Int) -> some View {
        let isOn = selection.contains(day)
        return Button {
            if isOn {
                selection.remove(day)
            } else {
                selection.insert(day)
            }
        } label: {
            Text(Weekdays.veryShortName(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: Self.chipHeight)
                .background(isOn ? tint : Palette.neutral.opacity(0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Weekdays.fullName(day))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: isOn)
        .accessibilityIdentifier("alarmEditor.day.\(day)")
    }
}
