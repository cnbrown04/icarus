import Metrics

/// SF Symbol names, one per concept. Every concept has exactly one symbol, and no symbol stands for two concepts,
/// so an icon always means the same thing on every screen. Render them hierarchically; tint a glyph with its
/// category colour only where it marks a metric (see `MetricCategory`).
///
/// | Concept | Symbol | Concept | Symbol |
/// |---|---|---|---|
/// | Heart rate | `heart.fill` | Strain | `flame.fill` |
/// | Resting heart rate | `heart.text.square.fill` | Calories | `bolt.fill` |
/// | Heart rate variability | `waveform.path.ecg` | Sleep | `bed.double.fill` |
/// | Stress | `brain.head.profile` | Vitals | `cross.case.fill` |
/// | Respiratory rate | `lungs.fill` | Workouts | `figure.run` |
/// | Recovery | `arrow.clockwise.heart.fill` | Journal | `book.closed` |
/// | Weekly assessment | `calendar` | Alarms | `alarm` |
/// | Profile | `person.crop.circle` | Band | `bolt.heart` |
/// | Medications | `pills` | Server | `server.rack` |
/// | Record an activity | `plus` | | |
enum Symbol {
    static let heartRate = "heart.fill"
    static let restingHR = "heart.text.square.fill"
    static let hrv = "waveform.path.ecg"
    static let stress = "brain.head.profile"
    static let respiratoryRate = "lungs.fill"
    static let recovery = "arrow.clockwise.heart.fill"
    static let strain = "flame.fill"
    static let calories = "bolt.fill"
    static let sleep = "bed.double.fill"
    static let vitals = "cross.case.fill"
    static let workouts = "figure.run"
    static let journal = "book.closed"
    static let weekly = "calendar"
    static let alarms = "alarm"
    static let profile = "person.crop.circle"
    static let band = "bolt.heart"
    static let medications = "pills"
    static let server = "server.rack"
    static let record = "plus"
}

extension MetricKind {
    /// The symbol for this metric's glyph (`Symbol` table).
    var symbol: String {
        switch self {
        case .heartRate: Symbol.heartRate
        case .restingHR: Symbol.restingHR
        case .hrv: Symbol.hrv
        case .stress: Symbol.stress
        case .respiratoryRate: Symbol.respiratoryRate
        case .recovery: Symbol.recovery
        case .strain: Symbol.strain
        case .calories: Symbol.calories
        case .sleep: Symbol.sleep
        }
    }
}
