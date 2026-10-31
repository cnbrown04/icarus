import SwiftUI

/// Corner radii, the only ones the app uses.
enum Radius {
    /// Cards, tiles and sheets.
    static let card: CGFloat = 16
    /// Controls and small chips.
    static let control: CGFloat = 10
}

/// The rounded surface behind Summary rows and detail headers: padding, a grouped background and the card radius.
/// It is only the container. Put no icon or title chrome inside, and never nest a card in a card.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Spacing.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
    }
}
