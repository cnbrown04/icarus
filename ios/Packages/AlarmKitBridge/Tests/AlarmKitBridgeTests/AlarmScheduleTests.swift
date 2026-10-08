import Foundation
import Testing
@testable import AlarmKitBridge

struct AlarmScheduleTests {
    @Test func decodesTheWireFormatAndNormalisesWeekdays() throws {
        let data = Data(#"{"time":"06:30","weekdays":[5,1,1]}"#.utf8)
        let schedule = try JSONDecoder().decode(AlarmSchedule.self, from: data)
        #expect(schedule.hour == 6)
        #expect(schedule.minute == 30)
        #expect(schedule.weekdays == [1, 5])
        #expect(schedule.time == "06:30")
    }

    @Test func rejectsMalformedTimesAndWeekdays() {
        let bad = [
            #"{"time":"6:30","weekdays":[1]}"#,
            #"{"time":"25:00","weekdays":[]}"#,
            #"{"time":"12:60","weekdays":[]}"#,
            #"{"time":"12:00","weekdays":[0]}"#,
            #"{"time":"12:00","weekdays":[8]}"#,
        ]
        for text in bad {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(AlarmSchedule.self, from: Data(text.utf8))
            }
        }
    }

    @Test func encodesTheWireFormat() throws {
        let schedule = try #require(AlarmSchedule(hour: 9, minute: 5, weekdays: [7, 6]))
        let data = try JSONEncoder().encode(schedule)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["time"] as? String == "09:05")
        #expect(object["weekdays"] as? [Int] == [6, 7])
    }
}
