import SwiftUI

extension View {
    /// Horizontal page padding, identical on every screen (PLAN.md §15.2 rule 11).
    func pagePadding() -> some View {
        padding(.horizontal, Spacing.s16)
    }

    /// The grouped background behind dashboard cards, extended under the bars.
    func dashboardBackground() -> some View {
        background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    /// The rounded surface behind a card or tile.
    func cardBackground() -> some View {
        background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    /// Sets an accessibility identifier only when one is given. Put it on leaf elements only.
    @ViewBuilder
    func optionalIdentifier(_ id: String?) -> some View {
        if let id {
            accessibilityIdentifier(id)
        } else {
            self
        }
    }
}
