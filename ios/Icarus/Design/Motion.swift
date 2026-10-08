import SwiftUI

extension View {
    /// The app's state-change animation (ease-out, 200 ms). Off when Reduce Motion is on.
    func stateAnimation<Value: Equatable>(_ value: Value) -> some View {
        modifier(StateAnimationModifier(value: value))
    }
}

private struct StateAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
    }
}
