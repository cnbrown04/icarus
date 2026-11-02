import BandProtocol
import Foundation
import Metrics
import Store

// Band Tests: a guided run that turns the band's unexplained signals into labelled examples. The user does one
// known thing per step and confirms it; each step's span is stored (`band_test_mark`), with what the user read off a
// reference instrument where the step asks for one.
//
// The run here is Optical and Temperature. The earlier Wear and Charging and Sensors runs (2026-11-01) are done:
// they named the band's events and identified frame 76 as the skin sensor. This one gathers what the next two
// features need:
// - Skin temperature in degrees: frame 76 against an infrared thermometer at room temperature (the band's own
//   sensor face after 20 minutes on a table) and at skin temperature (the wrist the moment the band comes off).
// - SpO2: the band's R21 optical records (`OpticalRecord`), streamed only on request (cmd 63 + cmd 107), while
//   still, during a breath hold and after it. Whether the red and infrared channels pulse with the heart, and how
//   their ratio of ratios moves, decides whether SpO2 can be built; a pulse oximeter's readings, when entered,
//   are what it would be calibrated against.

/// What a step asks the user to read off an instrument.
enum BandTestReading: Sendable, Equatable {
    case none
    /// An infrared thermometer, required.
    case temperature
    /// A fingertip pulse oximeter, optional.
    case oxygen
}

/// A guided run: which steps, in order.
enum BandTestSuite: String, Codable, CaseIterable, Sendable {
    case opticalAndTemperature

    var title: String { "Optical and Temperature" }

    var summary: String {
        "About 45 minutes: the band on a table for 20, back on to settle, the light sensors with a breath hold, then your wrist temperature. You need an infrared thermometer; a fingertip pulse oximeter is optional."
    }

    var steps: [BandTestStep] { BandTestStep.allCases }
}

/// One step. The raw value is what `band_test_mark.step` stores, so values never change once used. 0–21 belonged to
/// the finished Wear and Charging and Sensors runs and are not reused.
enum BandTestStep: Int, CaseIterable, Codable, Sendable {
    case roomTemperature = 22
    case backOn = 23
    case settle = 24
    case opticalStill = 25
    case breathHold = 26
    case breatheNormally = 27
    case wristTemperature = 28

    var title: String {
        switch self {
        case .roomTemperature: "Leave the Band on a Table"
        case .backOn: "Put It Back On"
        case .settle: "Let It Settle"
        case .opticalStill: "Sit Still"
        case .breathHold: "Hold Your Breath"
        case .breatheNormally: "Breathe Normally"
        case .wristTemperature: "Measure Your Wrist"
        }
    }

    var instruction: String {
        switch self {
        case .roomTemperature:
            "Take the band off and leave it on a table, sensor side up, away from your phone and anything warm. When the time is up, point the thermometer at the band's sensor (the side that touches your skin) and enter the reading."
        case .backOn: "Put the band straight back on and sit still."
        case .settle: "Keep the band on and sit still while it warms to your skin."
        case .opticalStill:
            "The band's light sensors stream now. Rest your arm and stay still. If you have a pulse oximeter on a finger, enter its reading at the end."
        case .breathHold:
            "Breathe out normally, then hold your breath as long as is comfortable, up to 45 seconds. Stop at once if you feel unwell. With a pulse oximeter, enter the lowest reading you saw."
        case .breatheNormally: "Breathe normally and stay still."
        case .wristTemperature:
            "Take the band off and straight away point the thermometer at your wrist where the sensor sat. Enter the reading, then put the band back on."
        }
    }

    /// The least time the step runs before Done is offered, seconds.
    var minimumSeconds: Int {
        switch self {
        case .roomTemperature: 1_200
        case .backOn: 180
        case .settle: 900
        case .opticalStill: 120
        case .breathHold: 20
        case .breatheNormally: 60
        case .wristTemperature: 10
        }
    }

    var reading: BandTestReading {
        switch self {
        case .roomTemperature, .wristTemperature: .temperature
        case .opticalStill, .breathHold: .oxygen
        default: .none
        }
    }

    /// The steps during which the band streams its optical records.
    var streamsOptical: Bool { [.opticalStill, .breathHold, .breatheNormally].contains(self) }

    /// The notification when this step's time is up, naming what comes next.
    var doneNotice: String {
        switch self {
        case .roomTemperature: "Time to measure the band's sensor and put it back on."
        case .settle: "Time for the light sensor steps."
        default: "Open Icarus for the next step."
        }
    }
}

/// What a run found, worked out from its marks, its synced records and its captured stream.
struct BandTestResults: Codable, Sendable, Equatable {
    /// One calibration point: a thermometer reading and frame 76 at that moment.
    struct TemperaturePoint: Codable, Sendable, Equatable {
        let celsius: Double
        let counts: Double
    }

    /// The line through the two points, °C = slope · counts + offset.
    struct TemperatureCalibration: Codable, Sendable, Equatable {
        let slope: Double
        let offset: Double

        func celsius(_ counts: Double) -> Double { slope * counts + offset }
    }

    /// One optical channel over a step.
    struct ChannelFinding: Codable, Sendable, Equatable {
        /// "a" to "f", with OpenStrap's name where it has one.
        let channel: String
        let summary: OpticalAnalysis.ChannelSummary?
        /// The pulse rhythm lands within `pulseMatchBPM` of the band's heart rate.
        let followsPulse: Bool
    }

    /// The red/infrared ratio of ratios over one step, with the oximeter's reading when entered.
    struct RatioFinding: Codable, Sendable, Equatable {
        let step: BandTestStep
        let ratio: Double?
        let oximeter: Double?
    }

    let room: TemperaturePoint?
    let skin: TemperaturePoint?
    let calibration: TemperatureCalibration?
    /// Frames captured, by record type (`Frame.seq`), so an unexpected stream shows up.
    let framesByType: [String: Int]
    let opticalRecords: Int
    /// Samples a second in the optical records, from their own timestamps.
    let sampleRate: Double?
    /// Mean heart rate from the band's records while still.
    let heartRate: Double?
    let channels: [ChannelFinding]
    let ratios: [RatioFinding]
    /// Band records found inside the run, so an empty result reads as "not synced", not "nothing found".
    let recordCount: Int
}

enum BandTestAnalysis {
    /// A channel follows the pulse when its strongest rhythm is this close to the heart rate, beats a minute.
    static let pulseMatchBPM = 8.0
    /// Records averaged for the room point: the first ones after the band goes back on, before it warms.
    static let roomRecords = 10
    /// OpenStrap's names for the R21 channels.
    static let channelNames = ["a (green)", "b (green)", "c (infrared)", "d", "e", "f (red)"]

    static func results(marks: [BandTestMark], samples: [BandTestSample], frames: [BandTestFrame]) -> BandTestResults {
        let done = marks.filter { !$0.skipped }
        func mark(_ step: BandTestStep) -> BandTestMark? { done.first { $0.step == step.rawValue } }

        // Temperature: the room point is the first records after the band goes back on (the sensor still at the
        // table's temperature); the skin point is the last worn minute before the wrist was measured.
        var room: BandTestResults.TemperaturePoint?
        if let reading = mark(.roomTemperature)?.reading, let on = mark(.backOn) {
            let first = samples.filter { $0.tsMs >= on.startMs && $0.tsMs < on.endMs }
                .compactMap(\.frame76).prefix(roomRecords).map(Double.init)
            if !first.isEmpty { room = .init(celsius: reading, counts: first.reduce(0, +) / Double(first.count)) }
        }
        var skin: BandTestResults.TemperaturePoint?
        if let wrist = mark(.wristTemperature), let reading = wrist.reading {
            let last = samples.filter { $0.tsMs >= wrist.startMs - 60_000 && $0.tsMs < wrist.startMs }
                .compactMap(\.frame76).map(Double.init)
            if !last.isEmpty { skin = .init(celsius: reading, counts: last.reduce(0, +) / Double(last.count)) }
        }
        var calibration: BandTestResults.TemperatureCalibration?
        if let room, let skin, skin.counts != room.counts {
            let slope = (skin.celsius - room.celsius) / (skin.counts - room.counts)
            calibration = .init(slope: slope, offset: room.celsius - slope * room.counts)
        }

        // Optical: decode the R21 records, then each step's channels.
        var byType: [String: Int] = [:]
        for frame in frames { byType["\(frame.seq)", default: 0] += 1 }
        let records = frames.compactMap { frame in
            OpticalRecord.parse(Frame(type: PacketType.realtimeRawData.rawValue, seq: UInt8(clamping: frame.seq),
                                      cmd: 0, payload: frame.payload)).map { (tsMs: frame.tsMs, record: $0) }
        }
        let rate = sampleRate(records.map(\.record))
        func channelSamples(_ step: BandTestStep, _ index: Int) -> [Double] {
            guard let span = mark(step) else { return [] }
            return records.filter { $0.tsMs >= span.startMs && $0.tsMs <= span.endMs }
                .flatMap { $0.record.channels[index] }.map(Double.init)
        }
        let still = mark(.opticalStill)
        let heartRates = still.map { span in
            samples.filter { $0.tsMs >= span.startMs && $0.tsMs < span.endMs }.compactMap(\.bpm).map(Double.init)
        } ?? []
        let heartRate = heartRates.isEmpty ? nil : heartRates.reduce(0, +) / Double(heartRates.count)
        let channels = channelNames.indices.map { index -> BandTestResults.ChannelFinding in
            let summary = rate.flatMap { OpticalAnalysis.summarize(channelSamples(.opticalStill, index), sampleRate: $0) }
            let follows = summary?.pulsePerMinute.flatMap { pulse in heartRate.map { abs(pulse - $0) <= pulseMatchBPM } }
            return .init(channel: channelNames[index], summary: summary, followsPulse: follows ?? false)
        }
        let ratios = [BandTestStep.opticalStill, .breathHold, .breatheNormally].map { step -> BandTestResults.RatioFinding in
            let red = rate.flatMap { OpticalAnalysis.summarize(channelSamples(step, 5), sampleRate: $0) }
            let infrared = rate.flatMap { OpticalAnalysis.summarize(channelSamples(step, 2), sampleRate: $0) }
            let ratio = red.flatMap { r in infrared.flatMap { OpticalAnalysis.ratioOfRatios(red: r, infrared: $0) } }
            return .init(step: step, ratio: ratio, oximeter: mark(step)?.reading)
        }

        return BandTestResults(room: room, skin: skin, calibration: calibration, framesByType: byType,
                               opticalRecords: records.count, sampleRate: rate, heartRate: heartRate,
                               channels: channels, ratios: ratios, recordCount: samples.count)
    }

    /// Samples a second: every record's samples but the last's, over the seconds between the first and last
    /// record's own timestamps. Nil with fewer than two records or no time between them.
    static func sampleRate(_ records: [OpticalRecord]) -> Double? {
        guard let first = records.first, let last = records.last, last.unixSeconds > first.unixSeconds else { return nil }
        let samples = records.dropLast().reduce(0) { $0 + ($1.channels.first?.count ?? 0) }
        return Double(samples) / Double(last.unixSeconds - first.unixSeconds)
    }
}

/// The shared report: the run's marks, its results, frame 76 a minute at a time, and the first optical records'
/// channels, so a result can be checked by eye. No heart rate or other health data beyond what the results hold.
struct BandTestReport: Codable, Sendable {
    /// One minute of the run: minutes since the first step began, and frame 76's mean.
    struct ChannelMinute: Codable, Sendable, Equatable {
        let minute: Int
        let frame76: Double?
    }

    let runID: String
    let marks: [BandTestMark]
    let results: BandTestResults
    let channelMinutes: [ChannelMinute]
    /// The first few R21 records as decoded, channel by channel.
    let opticalSamples: [[[Int]]]

    /// The report as a JSON file in the temporary directory, for `ShareLink`.
    func file() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("band-test-\(runID.prefix(8)).json")
        try encoder.encode(self).write(to: url)
        return url
    }
}

extension BandTestAnalysis {
    /// Frame 76's mean per minute since `startMs`, oldest first.
    static func channelMinutes(_ samples: [BandTestSample], from startMs: Int64) -> [BandTestReport.ChannelMinute] {
        let byMinute = Dictionary(grouping: samples) { Int(($0.tsMs - startMs) / 60_000) }
        return byMinute.keys.sorted().map { minute in
            let values = (byMinute[minute] ?? []).compactMap(\.frame76)
            return .init(minute: minute,
                         frame76: values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count))
        }
    }

    /// Loads a run's marks, records and captured frames, and works out its results.
    static func load(runID: String, from database: AppDatabase) async throws -> BandTestReport? {
        try await database.writer.read { db in
            guard let marks = try db.bandTestRuns().first(where: { $0.first?.runID == runID }),
                  let start = marks.map(\.startMs).min(), let end = marks.map(\.endMs).max()
            else { return nil }
            let samples = try db.bandTestSamples(fromMs: start, toMs: end)
            let frames = try db.bandTestFrames(runID: runID)
            let optical = frames.compactMap { frame in
                OpticalRecord.parse(Frame(type: PacketType.realtimeRawData.rawValue, seq: UInt8(clamping: frame.seq),
                                          cmd: 0, payload: frame.payload))
            }
            return BandTestReport(
                runID: runID,
                marks: marks,
                results: results(marks: marks, samples: samples, frames: frames),
                channelMinutes: channelMinutes(samples, from: start),
                opticalSamples: optical.prefix(3).map { $0.channels.map { $0.map(Int.init) } }
            )
        }
    }
}
