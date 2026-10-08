import SwiftUI

extension View {
    /// Horizontal page padding, identical on every screen (PLAN.md §15.2 rule 11).
    func pagePadding() -> some View {
        padding(.horizontal, Spacing.s16)
    }
}
