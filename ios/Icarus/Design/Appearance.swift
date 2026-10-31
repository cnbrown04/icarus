import SwiftUI

/// The app's colour scheme, set in Settings and applied at the root. Follows the system setting by default.
/// Stored under `@AppStorage("appearance")` as the raw value.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    /// Nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
