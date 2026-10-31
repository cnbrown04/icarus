/// Algorithm version per metric family (PLAN.md 8.5). Stored with every derived row.
public struct AlgoVersion: Sendable, Equatable {
    public let hr: Int
    public let hrv: Int
    public let stress: Int
    public let kcal: Int

    public init(hr: Int, hrv: Int, stress: Int, kcal: Int) {
        self.hr = hr
        self.hrv = hrv
        self.stress = stress
        self.kcal = kcal
    }

    /// Stress 3: R-R fallback to the HR-only path, 12-window R-R days, and medication-aware baselines (Part B).
    public static let current = AlgoVersion(hr: 1, hrv: 1, stress: 3, kcal: 1)
}
