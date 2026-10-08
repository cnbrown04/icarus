import AlarmKitBridge
import Foundation
import Store
import Testing
@testable import Icarus

struct AlarmItemTests {
    static let row = AlarmRow(
        id: "0192f6c1-7a3e-7c4d-9b1e-0000000000a1",
        label: "Wake up",
        schedule: #"{"time":"06:30","weekdays":[1,2,3,4,5]}"#,
        rhythm: #""double""#,
        channels: #"["phone","band"]"#,
        enabled: true,
        version: 2
    )

    @Test func decodesScheduleRhythmAndChannels() {
        let item = AlarmItem(row: Self.row)
        #expect(item.schedule?.time == "06:30")
        #expect(item.rhythm == .builtIn(.double))
        #expect(item.channels == [.phone, .band])
        #expect(item.repeatText == "Weekdays")
        #expect(item.rhythmName == "Double")
    }

    @Test func sosKeepsItsCapitals() {
        #expect(BuiltInRhythm.sos.title == "SOS")
        #expect(BuiltInRhythm.ramp.title == "Ramp")
    }

    @Test func repeatTextForOtherPatterns() {
        var row = Self.row
        row.schedule = #"{"time":"06:30","weekdays":[]}"#
        #expect(AlarmItem(row: row).repeatText == "Once")
        row.schedule = #"{"time":"06:30","weekdays":[6,7]}"#
        #expect(AlarmItem(row: row).repeatText == "Weekends")
        row.schedule = #"{"time":"06:30","weekdays":[1,2,3,4,5,6,7]}"#
        #expect(AlarmItem(row: row).repeatText == "Every day")
    }

    @Test func draftRoundTripsThroughARowAndKeepsVersion() throws {
        let draft = AlarmDraft(item: AlarmItem(row: Self.row))
        let saved = try draft.row(existing: Self.row, nowMs: 5_000)
        #expect(saved.id == Self.row.id)
        #expect(saved.version == 2)
        #expect(saved.updatedAt == 5_000)
        #expect(AlarmItem(row: saved).channels == [.phone, .band])
        #expect(AlarmItem(row: saved).schedule?.time == "06:30")
        #expect(AlarmItem(row: saved).rhythm == .builtIn(.double))
    }

    @Test func newAlarmWithoutBandIsPhoneOnlyAndGetsAClientId() throws {
        var draft = AlarmDraft.new(now: Date())
        draft.label = "   "
        let row = try draft.row(existing: nil, nowMs: 1_000)
        #expect(row.label == "Alarm")
        #expect(row.version == 0)
        #expect(AlarmItem(row: row).channels == [.phone])
        #expect(UUID(uuidString: row.id) != nil)
    }
}
