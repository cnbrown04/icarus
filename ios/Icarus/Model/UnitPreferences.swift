import Metrics
import SwiftUI

/// Which unit system length and mass display in. `system` follows the locale.
enum LengthMassUnits: String, CaseIterable, Identifiable {
    case system
    case metric
    case imperial

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .metric: "Metric (cm, kg)"
        case .imperial: "Imperial (ft+in, lb)"
        }
    }
}

/// User-chosen display units. Storage, the store schema and the web-server wire format stay metric
/// (cm, kg); these preferences only change what forms and views show. Conversions live in
/// `Metrics.UnitConversions` and are unit-tested there.
///
/// Values persist in UserDefaults via `@AppStorage` (raw strings, same pattern as `SyncInterval`).
/// Views hold their own instance (`@StateObject private var units = UnitPreferences()`); instances
/// re-read UserDefaults when created, and a local write fires `objectWillChange` for the view that
/// made it. Cross-view live refresh is not wired up — re-create the instance or read at appear.
@MainActor
final class UnitPreferences: ObservableObject {
    static let lengthMassKey = "units.lengthMass"

    @AppStorage(UnitPreferences.lengthMassKey) private var lengthMassRaw = LengthMassUnits.system.rawValue {
        didSet { objectWillChange.send() }
    }

    /// Length and mass unit system.
    var lengthMass: LengthMassUnits {
        get { LengthMassUnits(rawValue: lengthMassRaw) ?? .system }
        set { lengthMassRaw = newValue.rawValue }
    }

    /// Height and weight display in ft+in and lb.
    var isImperial: Bool {
        switch lengthMass {
        case .system: !Locale.current.usesMetricSystem
        case .metric: false
        case .imperial: true
        }
    }
}
