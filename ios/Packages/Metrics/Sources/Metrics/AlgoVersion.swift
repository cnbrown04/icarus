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

    public static let current = AlgoVersion(hr: 1, hrv: 1, stress: 1, kcal: 1)
}
