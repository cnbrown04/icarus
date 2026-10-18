import SwiftUI

extension View {
    /// The app's state-change animation (ease-out, 200 ms). Off when Reduce Motion is on.
    func stateAnimation<Value: Equatable>(_ value: Value) -> some View {
        modifier(StateAnimationModifier(value: value))
    }

    /// Digits roll when a live number changes. Off under -IcarusUITest, so screenshots never catch a half-rolled value.
    func liveNumberTransition() -> some View {
        modifier(LiveNumberTransitionModifier())
    }
}

private struct LiveNumberTransitionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if LaunchConfig.current.isUITest {
            content
        } else {
            content.contentTransition(.numericText())
        }
    }
}

private struct StateAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
    }
}
