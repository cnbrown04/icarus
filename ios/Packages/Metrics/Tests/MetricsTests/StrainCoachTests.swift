import Testing
@testable import Metrics

@Suite("StrainCoach target bands and the once-per-day target buzz gate")
struct StrainCoachTests {
    private let day = LocalDay(year: 2026, month: 10, day: 30)
    private let nextDay = LocalDay(year: 2026, month: 10, day: 31)

    /// Feeds one observation and returns whether it asked for the buzz.
    private func feed(_ gate: inout TargetBuzzGate, _ strain: Double?, _ target: StrainTarget?, _ day: LocalDay) -> Bool {
        gate.observe(strain: strain, target: target, day: day)
    }

    // MARK: - Target bands

    @Test func greenRecoveryTargetsPush() {
        for recovery in [67.0, 85.0, 100.0] {
            let target = StrainCoach.target(recoveryPercent: recovery)
            #expect(target.low == 14 && target.high == 18, "recovery \(recovery)")
            #expect(target.label == "Push")
            #expect(target.recoveryBand == .green)
            #expect(!target.isCalibrating)
        }
    }

    @Test func yellowRecoveryTargetsMaintain() {
        for recovery in [34.0, 50.0, 66.9] {
            let target = StrainCoach.target(recoveryPercent: recovery)
            #expect(target.low == 10 && target.high == 14, "recovery \(recovery)")
            #expect(target.label == "Maintain")
            #expect(target.recoveryBand == .yellow)
        }
    }

    @Test func redRecoveryTargetsRestore() {
        for recovery in [0.0, 20.0, 33.9] {
            let target = StrainCoach.target(recoveryPercent: recovery)
            #expect(target.low == 6 && target.high == 10, "recovery \(recovery)")
            #expect(target.label == "Restore")
            #expect(target.recoveryBand == .red)
        }
    }

    @Test func missingRecoveryIsCalibratingWithTheNeutralBand() {
        let target = StrainCoach.target(recoveryPercent: nil)
        #expect(target.low == 10 && target.high == 14)
        #expect(target.label == "Calibrating")
        #expect(target.isCalibrating)
        #expect(target.recoveryBand == nil)
    }

    @Test func nonFiniteRecoveryIsTreatedAsMissing() {
        #expect(StrainCoach.target(recoveryPercent: .nan).isCalibrating)
    }

    @Test func reachingTheTargetUsesTheLowerEdgeInclusively() {
        let target = StrainCoach.target(recoveryPercent: 80)
        #expect(!StrainCoach.hasReached(strain: 13.99, target: target))
        #expect(StrainCoach.hasReached(strain: 14, target: target))
        #expect(StrainCoach.hasReached(strain: 17, target: target))
    }

    // MARK: - Buzz gate

    @Test func buzzFiresOnceWhenStrainCrossesTheLowerEdge() {
        var gate = TargetBuzzGate()
        let target = StrainCoach.target(recoveryPercent: 80) // 14 to 18
        let fired1 = feed(&gate, 9, target, day)
        #expect(fired1 == false)
        let fired2 = feed(&gate, 14.2, target, day)
        #expect(fired2 == true)
        let fired3 = feed(&gate, 15, target, day)
        #expect(fired3 == false)
        let fired4 = feed(&gate, 16, target, day)
        #expect(fired4 == false)
        #expect(gate.firedDay == day)
    }

    @Test func aDayAlreadyInTheBandWhenObservedDoesNotBuzz() {
        var gate = TargetBuzzGate()
        let target = StrainCoach.target(recoveryPercent: 80)
        // The first value of the day is the starting point, not a crossing.
        let fired5 = feed(&gate, 15, target, day)
        #expect(fired5 == false)
        let fired6 = feed(&gate, 16, target, day)
        #expect(fired6 == false)
        #expect(gate.firedDay == nil)
    }

    @Test func aRelaunchOnTheSameDayDoesNotBuzzAgain() {
        var gate = TargetBuzzGate(firedDay: day)
        let target = StrainCoach.target(recoveryPercent: 80)
        let fired7 = feed(&gate, 5, target, day)
        #expect(fired7 == false)
        let fired8 = feed(&gate, 15, target, day)
        #expect(fired8 == false)
    }

    @Test func aNewDayCanBuzzAgain() {
        var gate = TargetBuzzGate()
        let target = StrainCoach.target(recoveryPercent: 80)
        _ = feed(&gate, 5, target, day)
        let fired9 = feed(&gate, 15, target, day)
        #expect(fired9 == true)
        _ = feed(&gate, 2, target, nextDay)
        let fired10 = feed(&gate, 14, target, nextDay)
        #expect(fired10 == true)
        #expect(gate.firedDay == nextDay)
    }

    @Test func missingStrainOrTargetNeverBuzzes() {
        var gate = TargetBuzzGate()
        let target = StrainCoach.target(recoveryPercent: 80)
        _ = feed(&gate, 5, target, day)
        let fired11 = feed(&gate, nil, target, day)
        #expect(fired11 == false)
        let fired12 = feed(&gate, 15, nil, day)
        #expect(fired12 == false)
        #expect(gate.firedDay == nil)
    }
}
