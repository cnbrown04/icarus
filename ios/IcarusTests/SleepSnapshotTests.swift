import Foundation
import Testing
@testable import Icarus

/// Home and Today read `SleepSnapshot.latest`, which must be the newest main sleep. A nap taken after
/// the night is listed on the Sleep screen, but it must not stand in for last night.
struct SleepSnapshotTests {
    private func night(startMs: Int64, isNap: Bool) -> Dashboard.SleepSnapshot.Night {
        Dashboard.SleepSnapshot.Night(
            id: startMs,
            startMs: startMs,
            durationS: 3_600,
            isNap: isNap,
            restingHR: nil,
            rmssdMs: nil,
            quality: .good,
            stages: [],
            stageTotals: [:],
            efficiency: nil
        )
    }

    private func snapshot(_ nights: [Dashboard.SleepSnapshot.Night]) -> Dashboard.SleepSnapshot {
        Dashboard.SleepSnapshot(
            context: Dashboard.Context(profile: nil, timeZone: .current, nowMs: 0, restingHR: nil, maxHR: nil),
            nights: nights
        )
    }

    @Test func latestSkipsANapNewerThanTheMainSleep() {
        // Newest first: an afternoon nap, then last night's main sleep.
        let main = night(startMs: 1_000, isNap: false)
        let nap = night(startMs: 5_000, isNap: true)
        #expect(snapshot([nap, main]).latest?.id == main.id)
    }

    @Test func latestIsTheNewestMainSleepWhenThereIsNoNap() {
        let newer = night(startMs: 5_000, isNap: false)
        let older = night(startMs: 1_000, isNap: false)
        #expect(snapshot([newer, older]).latest?.id == newer.id)
    }

    @Test func latestIsNilWhenOnlyNapsExist() {
        #expect(snapshot([night(startMs: 5_000, isNap: true)]).latest == nil)
    }
}
