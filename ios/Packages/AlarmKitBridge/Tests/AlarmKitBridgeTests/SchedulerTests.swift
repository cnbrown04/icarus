import Foundation
import Testing
@testable import AlarmKitBridge

struct SchedulerTests {
    @Test func inMemorySchedulerReplacesByIdAndCancels() async throws {
        let scheduler = InMemoryAlarmScheduler()
        let id = UUID(uuidString: "0192F6C1-7A3E-7C4D-9B1E-0000000000A1")!
        let schedule = try #require(AlarmSchedule(hour: 6, minute: 30, weekdays: [1]))
        let fire = Date(timeIntervalSince1970: 1_791_472_200)
        try await scheduler.schedule(ScheduledAlarm(id: id, label: "Old", schedule: schedule, nextFire: fire))
        try await scheduler.schedule(ScheduledAlarm(id: id, label: "Wake up", schedule: schedule, nextFire: fire))
        #expect(await scheduler.scheduled.count == 1)
        #expect(await scheduler.scheduled[id]?.label == "Wake up")
        try await scheduler.cancel(id: id)
        #expect(await scheduler.scheduled.isEmpty)
    }

    @Test func notificationIdentifiersMatchThePayloadCategory() {
        #expect(AlarmNotificationIdentifiers.category == "ICARUS_ALARM")
        #expect(AlarmNotificationIdentifiers.snoozeSeconds == 300)
    }
}
