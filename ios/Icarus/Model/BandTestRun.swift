import BandProtocol
import Foundation
import Metrics
import Store

// Band Tests: a guided run that turns the band's unexplained signals into labelled examples. The user does one
// known thing per step (still, band off, band back on, double-tap, charger on and off twice, a buzz) and confirms
// it; each step's span is stored (`band_test_mark`). Afterwards the band's banked records are synced and the
// results are worked out here from the labelled spans: which event id each action sends, which record channel
// behaves like temperature (`TemperatureChannelCheck`), and how the green-light breathing estimate compares with
// the R-R one (`GreenLightRespiration`, `RespiratoryRate`). Nothing here names anything in code: the shared
// report is the evidence for doing that.

/// The things a step asks the user to do that the band may announce with an event.
enum BandTestAction: String, Codable, Sendable {
    case none
    case wristOff
    case wristOn
    case doubleTap
    case chargingOn
    case chargingOff
    case buzz

    var label: String {
        switch self {
        case .none: "Nothing"
        case .wristOff: "Band off"
        case .wristOn: "Band on"
        case .doubleTap: "Double tap"
        case .chargingOn: "Charging on"
        case .chargingOff: "Charging off"
        case .buzz: "Buzz"
        }
    }
}

/// One step of a run, in order.
enum BandTestStep: Int, CaseIterable, Codable, Sendable {
    case still
    case off
    case on
    case doubleTap
    case chargerOn
    case chargerOff
    case chargerOnAgain
    case chargerOffAgain
    case buzz

    var title: String {
        switch self {
        case .still: "Sit Still"
        case .off: "Take the Band Off"
        case .on: "Put the Band Back On"
        case .doubleTap: "Double-Tap the Band"
        case .chargerOn, .chargerOnAgain: "Put the Band on Its Charger"
        case .chargerOff, .chargerOffAgain: "Take It Off the Charger"
        case .buzz: "Feel for a Buzz"
        }
    }

    var instruction: String {
        switch self {
        case .still: "Keep the band on your wrist and stay still."
        case .off: "Take the band off and leave it on a table, away from your phone and anything warm."
        case .on: "Put the band back on your wrist and stay still while it warms up."
        case .doubleTap: "Double-tap the band, wait 30 seconds, then double-tap again."
        case .chargerOn: "Clip the battery pack onto the band, or put it on its charger."
        case .chargerOff: "Take the battery pack or charger off."
        case .chargerOnAgain: "Put the charger back on once more."
        case .chargerOffAgain: "Take it off once more."
        case .buzz: "Keep the band on. It buzzes when this step starts."
        }
    }

    /// The least time the step runs before Done is offered, seconds. Temperature needs its full spans.
    var minimumSeconds: Int {
        switch self {
        case .still: 180
        case .off, .on: 1_200
        case .doubleTap: 45
        case .chargerOn, .chargerOff, .chargerOnAgain, .chargerOffAgain: 30
        case .buzz: 15
        }
    }

    /// The notification when this step's time is up, naming what comes next.
    var doneNotice: String {
        switch self {
        case .still: "Time to take the band off and leave it on a table."
        case .off: "20 minutes are up. Put the band back on."
        case .on: "20 minutes are up. Open Icarus for the last few steps."
        default: "Open Icarus for the next step."
        }
    }

    var action: BandTestAction {
        switch self {
        case .still: .none
        case .off: .wristOff
        case .on: .wristOn
        case .doubleTap: .doubleTap
        case .chargerOn, .chargerOnAgain: .chargingOn
        case .chargerOff, .chargerOffAgain: .chargingOff
        case .buzz: .buzz
        }
    }
}

/// What a run found, worked out from its marks, the band's events and its synced records.
struct BandTestResults: Codable, Sendable, Equatable {
    /// One event id seen during the run.
    struct EventFinding: Codable, Sendable, Equatable {
        let id: Int
        /// The current name ("Event 42" until named).
        let name: String
        /// The action of each step it arrived in, in order.
        let actions: [BandTestAction]
        /// The payload bytes of each occurrence, hex.
        let payloads: [String]
        /// The one action every occurrence matched, when it happened at least twice and in no other step.
        let proposed: BandTestAction?
    }

    /// One record channel judged as temperature. Nil verdict: the run's spans had no records for it.
    struct TemperatureFinding: Codable, Sendable, Equatable {
        let channel: String
        let verdict: TemperatureChannelCheck.Verdict?
    }

    /// Breathing over one still step: the R-R estimate, the green-light estimate, or why it was withheld.
    struct BreathingFinding: Codable, Sendable, Equatable {
        let step: BandTestStep
        let rrBrpm: Double?
        let greenBrpm: Double?
        let greenWithheld: String?
    }

    let events: [EventFinding]
    /// Actions done (not skipped) during which the band sent no event.
    let silentActions: [BandTestAction]
    let temperature: [TemperatureFinding]
    let breathing: [BreathingFinding]
    /// Band records found inside the run, so an empty result reads as "not synced", not "nothing found".
    let recordCount: Int
}

enum BandTestAnalysis {
    /// An event arriving this long after its step was confirmed still belongs to it: the user taps Done right
    /// after acting, and the band reports a moment later.
    static let eventGraceMs: Int64 = 15_000

    /// The channels judged as temperature, by frame offset.
    static let temperatureChannels: [(name: String, value: @Sendable (BandTestSample) -> Int?)] = [
        ("Frame 72", { $0.frame72 }),
        ("Frame 74", { $0.frame74 }),
        ("Frame 76", { $0.frame76 }),
        ("Frame 78", { $0.frame78 }),
        ("Frame 92", { $0.frame92 }),
    ]

    /// The step an event belongs to: the step whose span contains it, else the latest step that ended within
    /// `eventGraceMs` before it. Nil when that step was skipped, or none qualifies.
    static func owningStep(_ tsMs: Int64, marks: [BandTestMark]) -> BandTestMark? {
        let owner = marks.first { tsMs >= $0.startMs && tsMs < $0.endMs }
            ?? marks.filter { tsMs >= $0.endMs && tsMs <= $0.endMs + eventGraceMs }.max { $0.endMs < $1.endMs }
        guard let owner, !owner.skipped else { return nil }
        return owner
    }

    static func results(marks: [BandTestMark], events: [StoredBandEvent], samples: [BandTestSample]) -> BandTestResults {
        let done = marks.filter { !$0.skipped }
        func step(of mark: BandTestMark) -> BandTestStep? { BandTestStep(rawValue: mark.step) }

        // Events: the done step each falls in, by id.
        var byID: [Int: [(action: BandTestAction, hex: String)]] = [:]
        var actionsWithEvents: Set<BandTestAction> = []
        for event in events.sorted(by: { $0.tsMs < $1.tsMs }) {
            guard let mark = owningStep(event.tsMs, marks: marks),
                  let action = step(of: mark)?.action,
                  let id = event.id ?? BandEventKind(storageName: event.kind).map({ Int($0.id) })
            else { continue }
            byID[id, default: []].append((action, event.hex ?? ""))
            actionsWithEvents.insert(action)
        }
        let eventFindings = byID.keys.sorted().map { id -> BandTestResults.EventFinding in
            let hits = byID[id] ?? []
            let actions = hits.map(\.action)
            let distinct = Set(actions)
            let proposed = hits.count >= 2 && distinct.count == 1 && distinct.first != BandTestAction.none
                ? distinct.first : nil
            return .init(id: id, name: BandEventKind(id: UInt8(clamping: id)).displayName, actions: actions,
                         payloads: hits.map(\.hex), proposed: proposed)
        }
        let silent = done.compactMap { step(of: $0)?.action }
            .filter { $0 != .none && !actionsWithEvents.contains($0) }
        var seen: Set<BandTestAction> = []
        let silentActions = silent.filter { seen.insert($0).inserted }

        // Temperature: the still, off and on spans.
        func span(_ wanted: BandTestStep) -> [BandTestSample]? {
            guard let mark = done.first(where: { step(of: $0) == wanted }) else { return nil }
            return samples.filter { $0.tsMs >= mark.startMs && $0.tsMs < mark.endMs }
        }
        let still = span(.still), off = span(.off), on = span(.on)
        let temperature = temperatureChannels.map { channel -> BandTestResults.TemperatureFinding in
            func points(_ span: [BandTestSample]?) -> [(t: Double, v: Double)] {
                (span ?? []).compactMap { sample in channel.value(sample).map { (Double(sample.tsMs) / 1000, Double($0)) } }
            }
            let b = points(still), o = points(off), n = points(on)
            guard !b.isEmpty, !o.isEmpty, !n.isEmpty else { return .init(channel: channel.name, verdict: nil) }
            return .init(channel: channel.name, verdict: TemperatureChannelCheck.judge(baseline: b, off: o, on: n))
        }

        // Breathing: the two still spans.
        let breathing = [BandTestStep.still, .on].compactMap { wanted -> BandTestResults.BreathingFinding? in
            guard let window = span(wanted), !window.isEmpty else { return nil }
            let beats = window.flatMap { sample in sample.rrMs.map { RRSample(tsMs: sample.tsMs, rrMs: $0) } }
            let rr = RespiratoryRate.windowEstimate(beats)?.brpm
            let greenSamples = window.filter { $0.ppgGreen != nil }
            let heartRates = window.compactMap(\.bpm).map(Double.init)
            let green = GreenLightRespiration.estimate(
                green: greenSamples.compactMap(\.ppgGreen).map(Double.init),
                timesSec: greenSamples.map { Double($0.tsMs) / 1000 },
                meanHeartRate: heartRates.isEmpty ? nil : heartRates.reduce(0, +) / Double(heartRates.count),
                gravity: greenSamples.compactMap(\.gravity).count == greenSamples.count
                    ? greenSamples.compactMap(\.gravity) : nil
            )
            switch green {
            case let .success(brpm):
                return .init(step: wanted, rrBrpm: rr, greenBrpm: brpm, greenWithheld: nil)
            case let .failure(reason):
                return .init(step: wanted, rrBrpm: rr, greenBrpm: nil, greenWithheld: reason.reason.rawValue)
            }
        }

        return BandTestResults(events: eventFindings, silentActions: silentActions, temperature: temperature,
                               breathing: breathing, recordCount: samples.count)
    }
}

/// The shared report: the run's marks, its results, and each temperature candidate's per-minute mean (so a verdict
/// can be checked by eye). No heart rate or other health data.
struct BandTestReport: Codable, Sendable {
    /// One minute of the run: minutes since the first step began, and each candidate channel's mean.
    struct ChannelMinute: Codable, Sendable, Equatable {
        let minute: Int
        let frame72: Double?
        let frame74: Double?
        let frame76: Double?
        let frame78: Double?
        let frame92: Double?
    }

    let runID: String
    let marks: [BandTestMark]
    let results: BandTestResults
    let channelMinutes: [ChannelMinute]

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
    /// Each candidate channel's mean per minute since `startMs`, oldest first.
    static func channelMinutes(_ samples: [BandTestSample], from startMs: Int64) -> [BandTestReport.ChannelMinute] {
        let byMinute = Dictionary(grouping: samples) { Int(($0.tsMs - startMs) / 60_000) }
        func mean(_ minute: [BandTestSample], _ value: (BandTestSample) -> Int?) -> Double? {
            let values = minute.compactMap(value)
            return values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
        }
        return byMinute.keys.sorted().map { minute in
            let rows = byMinute[minute] ?? []
            return .init(minute: minute, frame72: mean(rows) { $0.frame72 }, frame74: mean(rows) { $0.frame74 },
                         frame76: mean(rows) { $0.frame76 }, frame78: mean(rows) { $0.frame78 },
                         frame92: mean(rows) { $0.frame92 })
        }
    }

    /// Loads a run's marks, the events and records inside it, and works out its results.
    static func load(runID: String, from database: AppDatabase) async throws -> BandTestReport? {
        try await database.writer.read { db in
            guard let marks = try db.bandTestRuns().first(where: { $0.first?.runID == runID }),
                  let start = marks.map(\.startMs).min(), let end = marks.map(\.endMs).max()
            else { return nil }
            let events = try db.bandEvents(fromMs: start, toMs: end + eventGraceMs + 1, limit: 2_000)
            let samples = try db.bandTestSamples(fromMs: start, toMs: end)
            return BandTestReport(runID: runID, marks: marks,
                                  results: results(marks: marks, events: events, samples: samples),
                                  channelMinutes: channelMinutes(samples, from: start))
        }
    }
}
