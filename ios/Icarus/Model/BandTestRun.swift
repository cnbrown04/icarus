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
    case singleTap
    case tripleTap
    case alarm
    case bluetoothOff
    case offWristCharging

    var label: String {
        switch self {
        case .none: "Nothing"
        case .wristOff: "Band off"
        case .wristOn: "Band on"
        case .doubleTap: "Double tap"
        case .chargingOn: "Charging on"
        case .chargingOff: "Charging off"
        case .buzz: "Buzz"
        case .singleTap: "Single tap"
        case .tripleTap: "Triple tap"
        case .alarm: "Band alarm"
        case .bluetoothOff: "Bluetooth off"
        case .offWristCharging: "Charging off the wrist"
        }
    }
}

/// A guided run: which steps, in order.
enum BandTestSuite: String, Codable, CaseIterable, Sendable {
    /// The first run: still, band off and back on (temperature), double tap, the charger twice, a buzz.
    case wearAndCharging
    /// What the first run did not cover: light and dark, cold and recovery, buzz lengths, tap patterns, the band's
    /// own alarm, a Bluetooth drop, charging off the wrist.
    case sensors

    var title: String {
        switch self {
        case .wearAndCharging: "Wear and Charging"
        case .sensors: "Sensors"
        }
    }

    var summary: String {
        switch self {
        case .wearAndCharging:
            "About 50 minutes: still, band off for 20, back on for 20, a double tap, the charger twice and a buzz."
        case .sensors:
            "About 22 minutes: dark and light, something cold, short and long buzzes, taps, the band's alarm, Bluetooth off, the charger off the wrist."
        }
    }

    var steps: [BandTestStep] {
        switch self {
        case .wearAndCharging:
            [.still, .off, .on, .doubleTap, .chargerOn, .chargerOff, .chargerOnAgain, .chargerOffAgain, .buzz]
        case .sensors:
            [.still, .dark, .light, .cold, .recover, .shortBuzz, .longBuzz, .singleTaps, .tripleTaps, .doubleTaps,
             .bandAlarm, .bluetoothOff, .offWristCharger, .backOn]
        }
    }

    /// The suite a stored run used, from its steps.
    static func of(_ marks: [BandTestMark]) -> BandTestSuite {
        marks.contains { $0.step >= BandTestStep.dark.rawValue } ? .sensors : .wearAndCharging
    }
}

/// One step. The raw value is what `band_test_mark.step` stores, so values never change once used.
enum BandTestStep: Int, CaseIterable, Codable, Sendable {
    case still = 0
    case off = 1
    case on = 2
    case doubleTap = 3
    case chargerOn = 4
    case chargerOff = 5
    case chargerOnAgain = 6
    case chargerOffAgain = 7
    case buzz = 8
    case dark = 9
    case light = 10
    case cold = 11
    case recover = 12
    case shortBuzz = 13
    case longBuzz = 14
    case singleTaps = 15
    case tripleTaps = 16
    case doubleTaps = 17
    case bandAlarm = 18
    case bluetoothOff = 19
    case offWristCharger = 20
    case backOn = 21

    var title: String {
        switch self {
        case .still: "Sit Still"
        case .off: "Take the Band Off"
        case .on: "Put the Band Back On"
        case .doubleTap: "Double-Tap the Band"
        case .chargerOn, .chargerOnAgain: "Put the Band on Its Charger"
        case .chargerOff, .chargerOffAgain: "Take It Off the Charger"
        case .buzz: "Feel for a Buzz"
        case .dark: "Cover the Band"
        case .light: "Shine a Light on It"
        case .cold: "Cool the Band"
        case .recover: "Let It Warm Back Up"
        case .shortBuzz: "Short Buzz"
        case .longBuzz: "Long Buzz"
        case .singleTaps: "Single Taps"
        case .tripleTaps: "Triple Taps"
        case .doubleTaps: "Double Taps"
        case .bandAlarm: "Wait for the Band's Alarm"
        case .bluetoothOff: "Turn Bluetooth Off"
        case .offWristCharger: "Charge It Off Your Wrist"
        case .backOn: "Put the Band Back On"
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
        case .dark: "Keep the band on and cover it completely with your other hand."
        case .light: "Keep the band on and shine your phone's flashlight straight at it from Control Center."
        case .cold: "Keep the band on and hold something cold against it, like a cold can or ice in a bag. Keep it dry."
        case .recover: "Take the cold thing away and keep the band on while it warms back up."
        case .shortBuzz: "Keep the band on. It buzzes once when this step starts."
        case .longBuzz: "Keep the band on. It gives a long buzz when this step starts."
        case .singleTaps: "Tap the band once, three times, about 10 seconds apart."
        case .tripleTaps: "Triple-tap the band, wait 15 seconds, then triple-tap again."
        case .doubleTaps: "Double-tap the band three times, about 10 seconds apart."
        case .bandAlarm: "Keep the band on. The band's own alarm is set for one minute from now; wait for it to buzz."
        case .bluetoothOff: "Turn Bluetooth off in Control Center, wait a minute, then turn it back on before tapping Done."
        case .offWristCharger: "Take the band off and put it on its charger, off your wrist."
        case .backOn: "Take it off the charger and put the band back on your wrist."
        }
    }

    /// The least time the step runs before Done is offered, seconds. Temperature needs its full spans.
    var minimumSeconds: Int {
        switch self {
        case .still, .cold, .recover, .offWristCharger: 180
        case .off, .on: 1_200
        case .doubleTap, .singleTaps, .tripleTaps, .doubleTaps: 45
        case .chargerOn, .chargerOff, .chargerOnAgain, .chargerOffAgain, .longBuzz: 30
        case .buzz, .shortBuzz: 15
        case .dark, .light, .backOn: 60
        case .bandAlarm: 90
        case .bluetoothOff: 75
        }
    }

    /// The notification when this step's time is up, naming what comes next.
    var doneNotice: String {
        switch self {
        case .still: "Time for the next step."
        case .off: "20 minutes are up. Put the band back on."
        case .on: "20 minutes are up. Open Icarus for the last few steps."
        case .cold: "Time to take the cold away."
        case .offWristCharger: "Time to put the band back on."
        default: "Open Icarus for the next step."
        }
    }

    var action: BandTestAction {
        switch self {
        case .still, .dark, .light, .cold, .recover: .none
        case .off: .wristOff
        case .on, .backOn: .wristOn
        case .doubleTap, .doubleTaps: .doubleTap
        case .chargerOn, .chargerOnAgain: .chargingOn
        case .chargerOff, .chargerOffAgain: .chargingOff
        case .buzz, .shortBuzz, .longBuzz: .buzz
        case .singleTaps: .singleTap
        case .tripleTaps: .tripleTap
        case .bandAlarm: .alarm
        case .bluetoothOff: .bluetoothOff
        case .offWristCharger: .offWristCharging
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
        /// The named event that arrived in the same second as every occurrence of this unnamed one, if any.
        var companion: String? = nil
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

    /// How one channel moved between the dark and the lit step, against the still baseline's spread.
    struct LightFinding: Codable, Sendable, Equatable {
        let channel: String
        let dark: Double?
        let lit: Double?
        /// |lit − dark| beyond three baseline spreads (and at least 2 counts).
        let responds: Bool
    }

    /// One temperature-like channel through the cold and recovery steps. A worn sensor lags the surface by about a
    /// minute (Sensors run, 2026-11-01: frame 76 kept falling for a minute after the cold came off), so the cold's
    /// effect is its furthest point across both steps, not the cold step's end.
    struct ColdFinding: Codable, Sendable, Equatable {
        let channel: String
        /// The furthest 30-second mean from the baseline across the cold and recovery steps, minus the still
        /// baseline's last minute.
        let coldChange: Double?
        /// The recovery step's last minute minus that furthest point.
        let recoveryChange: Double?
        /// Moved one way with cold and back after, each by at least 2 counts.
        let responds: Bool
    }

    /// The gap from a buzz's start event (60) to the next event 100, per buzz step.
    struct BuzzFinding: Codable, Sendable, Equatable {
        let step: BandTestStep
        let gapSeconds: Double?
    }

    /// Charging with the band off the wrist: whether the band kept records, and how frame 92 moved.
    struct OffWristChargingFinding: Codable, Sendable, Equatable {
        let records: Int
        let frame92Change: Double?
    }

    let events: [EventFinding]
    /// Actions done (not skipped) during which the band sent no event.
    let silentActions: [BandTestAction]
    let temperature: [TemperatureFinding]
    let breathing: [BreathingFinding]
    var light: [LightFinding] = []
    var cold: [ColdFinding] = []
    var buzzes: [BuzzFinding] = []
    var offWristCharging: OffWristChargingFinding? = nil
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

    /// The channels judged for light: the temperature candidates and the green light.
    static let lightChannels: [(name: String, value: @Sendable (BandTestSample) -> Int?)] = [
        ("Frame 72", { $0.frame72 }),
        ("Frame 74", { $0.frame74 }),
        ("Frame 76", { $0.frame76 }),
        ("Frame 78", { $0.frame78 }),
        ("Frame 92", { $0.frame92 }),
        ("Green Light", { $0.ppgGreen }),
    ]

    /// Events placed at the band's own time (payload bytes 1–4, when they read as a time within a day of arrival)
    /// and kept once per (id, payload): the band delivers each event twice, the copy sometimes minutes later.
    static func distinctEvents(_ events: [StoredBandEvent]) -> [StoredBandEvent] {
        var seen: Set<String> = []
        return events
            .map { event -> StoredBandEvent in
                guard let time = bandTimeMs(event) else { return event }
                return StoredBandEvent(tsMs: time, kind: event.kind, id: event.id, hex: event.hex)
            }
            .sorted { $0.tsMs < $1.tsMs }
            .filter { event in
                // Only a payload carrying the band's time identifies one event; short ones could be two.
                guard let hex = event.hex, hex.count >= 10 else { return true }
                return seen.insert("\(event.id ?? -1)/\(hex)").inserted
            }
    }

    /// The unix seconds at payload bytes 1–4, in ms, when within a day of the stored time.
    static func bandTimeMs(_ event: StoredBandEvent) -> Int64? {
        guard let hex = event.hex, hex.count >= 10 else { return nil }
        let bytes = stride(from: 2, to: 10, by: 2).compactMap { offset -> UInt32? in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt32(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
        guard bytes.count == 4 else { return nil }
        let seconds = Int64(bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24)
        return abs(seconds * 1000 - event.tsMs) <= 86_400_000 ? seconds * 1000 : nil
    }

    /// For an unnamed id: the named event that shares the second of every one of its occurrences.
    static func companion(of id: Int, in events: [StoredBandEvent]) -> String? {
        guard case .unknown = BandEventKind(id: UInt8(clamping: id)) else { return nil }
        let own = events.filter { $0.id == id }
        guard !own.isEmpty else { return nil }
        let named = events.filter { event in
            guard let other = event.id, other != id else { return false }
            if case .unknown = BandEventKind(id: UInt8(clamping: other)) { return false }
            return true
        }
        let candidates = own.map { occurrence in
            Set(named.filter { abs($0.tsMs - occurrence.tsMs) <= 1_000 }.compactMap(\.id))
        }
        guard let shared = candidates.dropFirst().reduce(candidates.first, { $0?.intersection($1) }),
              let match = shared.min()
        else { return nil }
        return BandEventKind(id: UInt8(clamping: match)).displayName
    }

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

        // Events: each placed by the band's own time and kept once (the band delivers every event twice), then the
        // done step it falls in, by id.
        let unique = distinctEvents(events)
        var byID: [Int: [(action: BandTestAction, hex: String)]] = [:]
        var actionsWithEvents: Set<BandTestAction> = []
        for event in unique {
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
                         payloads: hits.map(\.hex), proposed: proposed, companion: companion(of: id, in: unique))
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
        let temperature = on == nil ? [] : temperatureChannels.map { channel -> BandTestResults.TemperatureFinding in
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

        var results = BandTestResults(events: eventFindings, silentActions: silentActions, temperature: temperature,
                                      breathing: breathing, recordCount: samples.count)

        // Sensors run. Light: each channel's mean in the dark and the lit step against the baseline's spread.
        func values(_ span: [BandTestSample]?, _ value: (BandTestSample) -> Int?) -> [Double] {
            (span ?? []).compactMap(value).map(Double.init)
        }
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        func lastMinute(_ span: [BandTestSample]?, _ value: (BandTestSample) -> Int?) -> Double? {
            guard let span, let end = span.map(\.tsMs).max() else { return nil }
            return mean(values(span.filter { $0.tsMs > end - 60_000 }, value))
        }
        if let dark = span(.dark), let lit = span(.light) {
            results.light = Self.lightChannels.map { channel in
                let darkMean = mean(values(dark, channel.value))
                let litMean = mean(values(lit, channel.value))
                let spread = TemperatureChannelCheck.standardDeviation(values(still, channel.value)) ?? 0
                let responds = darkMean.flatMap { d in litMean.map { abs($0 - d) >= max(2, 3 * spread) } } ?? false
                return .init(channel: channel.name, dark: darkMean, lit: litMean, responds: responds)
            }
        }
        // Cold and recovery: the channels that behave like temperature.
        if let coldSpan = span(.cold), let recovery = span(.recover) {
            results.cold = temperatureChannels.map { channel in
                let base = lastMinute(still, channel.value)
                // 30-second means across cold and recovery; the one furthest from the baseline is the cold's effect.
                let bins = Dictionary(grouping: coldSpan + recovery) { $0.tsMs / 30_000 }
                    .compactMap { _, rows in mean(values(rows, channel.value)) }
                let cold = base.flatMap { b in bins.max { abs($0 - b) < abs($1 - b) } }
                let back = lastMinute(recovery, channel.value)
                let coldChange = base.flatMap { b in cold.map { $0 - b } }
                let recoveryChange = cold.flatMap { c in back.map { $0 - c } }
                let responds = coldChange.flatMap { c in recoveryChange.map { r in
                    abs(c) >= 2 && abs(r) >= 2 && (c > 0) != (r > 0)
                } } ?? false
                return .init(channel: channel.name, coldChange: coldChange, recoveryChange: recoveryChange,
                             responds: responds)
            }
        }
        // Buzzes: the gap from the buzz event (60) to the next event 100 inside each buzz step.
        results.buzzes = done.compactMap { mark -> BandTestResults.BuzzFinding? in
            guard let step = step(of: mark), step.action == .buzz else { return nil }
            let inStep = unique.filter { owningStep($0.tsMs, marks: marks) == mark }
            guard let start = inStep.first(where: { $0.id == 60 })?.tsMs else { return .init(step: step, gapSeconds: nil) }
            let end = inStep.first { $0.id == 100 && $0.tsMs >= start }?.tsMs
            return .init(step: step, gapSeconds: end.map { Double($0 - start) / 1000 })
        }
        // Charging off the wrist: records kept, and how frame 92 moved across the step.
        if let charging = span(.offWristCharger) {
            let first = charging.first?.frame92, last = charging.last?.frame92
            results.offWristCharging = .init(records: charging.count,
                                             frame92Change: first.flatMap { f in last.map { Double($0 - f) } })
        }
        return results
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
