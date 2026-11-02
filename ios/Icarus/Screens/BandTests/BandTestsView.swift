import BandKit
import BandProtocol
import Metrics
import Store
import SwiftUI
import UserNotifications

/// Band Tests: start the guided run, and every past run's results. The run needs the band connected on the band
/// channel, since its records and optical stream are what it measures.
struct BandTestsView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var runs: [[BandTestMark]] = []
    @State private var runner: BandTestRunner?
    /// A run the app was closed in the middle of, offered for resuming.
    @State private var unfinished = BandTestRunner.InProgress.saved

    var body: some View {
        List {
            if let unfinished {
                Section {
                    Button("Resume Run") {
                        runner = BandTestRunner(environment: environment, liveState: liveState, resuming: unfinished)
                    }
                    .accessibilityIdentifier("bandTests.resume")
                }
            }
            ForEach(BandTestSuite.allCases, id: \.self) { suite in
                Section {
                    Button("Start \(suite.title) Run") {
                        BandTestRunner.InProgress.clear()
                        runner = BandTestRunner(environment: environment, liveState: liveState)
                    }
                    .disabled(liveState.tierBState != .ready)
                    .accessibilityIdentifier("bandTests.start")
                } footer: {
                    Text(suite.summary)
                }
            }
            if !runs.isEmpty {
                Section("Runs") {
                    ForEach(runs, id: \.first?.runID) { marks in
                        if let runID = marks.first?.runID, let start = marks.first?.startMs {
                            NavigationLink {
                                BandTestResultsView(environment: environment, runID: runID)
                            } label: {
                                LabeledContent {
                                    Text("\(marks.filter { !$0.skipped }.count) of \(BandTestStep.allCases.count) steps")
                                } label: {
                                    Text(Date(epochMs: start), format: .dateTime.month(.abbreviated).day().hour().minute())
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Band Tests")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $runner, onDismiss: { unfinished = BandTestRunner.InProgress.saved }) { runner in
            NavigationStack {
                BandTestRunView(runner: runner, environment: environment) {
                    runner.stop()
                    self.runner = nil
                }
            }
        }
        .task {
            do {
                for try await value in environment.database.observe({ try $0.bandTestRuns() }) {
                    // Only runs of the current steps: the finished earlier runs used steps 0–21.
                    runs = value.filter { marks in marks.allSatisfy { BandTestStep(rawValue: $0.step) != nil } }
                }
            } catch {
                runs = []
            }
        }
    }
}

/// Drives one run: the current step, when it started, saving each step's span and reading, the optical stream
/// during the optical steps, and the sync at the end.
@MainActor @Observable
final class BandTestRunner: Identifiable {
    enum Phase: Equatable {
        case step(BandTestStep)
        case syncing
        case finished
    }

    /// The step under way, saved at each step's start so a run survives the app being closed during a long step.
    /// Cleared when the run ends or is stopped.
    struct InProgress: Codable, Equatable {
        let runID: String
        let step: Int
        let startedAt: Date

        private static let key = "bandTests.inProgress"

        static var saved: InProgress? {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let saved = try? JSONDecoder().decode(InProgress.self, from: data),
                  BandTestStep(rawValue: saved.step) != nil
            else { return nil }
            return saved
        }

        func save() {
            UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
        }

        static func clear() {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Steps at least this long post a notification when their time is up: the user is away from the phone.
    private static let notifyAfterSeconds = 180
    private static let notificationID = "bandTests.stepDone"

    let id: String
    private(set) var phase: Phase
    private(set) var stepStartedAt: Date
    /// Frames of the realtime-raw stream received during the optical steps, saved when they end.
    private(set) var capturedFrames = 0

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let liveState: LiveState
    @ObservationIgnored private var frames: [BandTestFrame] = []

    init(environment: AppEnvironment, liveState: LiveState, resuming saved: InProgress? = nil) {
        self.environment = environment
        self.liveState = liveState
        if let saved, let step = BandTestStep(rawValue: saved.step) {
            id = saved.runID
            phase = .step(step)
            stepStartedAt = saved.startedAt
            if step.streamsOptical { startStream() }
        } else {
            id = UUID().uuidString
            let first = BandTestStep.allCases[0]
            phase = .step(first)
            stepStartedAt = Date()
            begin(first)
        }
    }

    var drainFraction: Double? { liveState.drainProgress.fraction }

    /// "Step 3 of 7".
    func position(of step: BandTestStep) -> String {
        "Step \((BandTestStep.allCases.firstIndex(of: step) ?? 0) + 1) of \(BandTestStep.allCases.count)"
    }

    /// Seconds before Done is offered for the current step.
    func secondsLeft(at now: Date) -> Int {
        guard case let .step(step) = phase else { return 0 }
        return max(0, step.minimumSeconds - Int(now.timeIntervalSince(stepStartedAt)))
    }

    /// Saves the step as under way, schedules its notification, and starts the optical stream when it needs one.
    private func begin(_ step: BandTestStep) {
        InProgress(runID: id, step: step.rawValue, startedAt: stepStartedAt).save()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        if step.streamsOptical, liveState.rawFrameSink == nil { startStream() }
        guard step.minimumSeconds >= Self.notifyAfterSeconds else { return }
        let content = UNMutableNotificationContent()
        content.title = "Band Tests"
        content.body = step.doneNotice
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(step.minimumSeconds), repeats: false)
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger))
        }
    }

    /// Collects every realtime-raw frame and asks the band for its optical stream.
    private func startStream() {
        liveState.rawFrameSink = { [weak self] frame, at in
            guard let self, frame.packetType == .realtimeRawData else { return }
            self.frames.append(BandTestFrame(tsMs: Int64(at.timeIntervalSince1970 * 1000), seq: Int(frame.seq),
                                             payload: frame.payload))
            self.capturedFrames += 1
        }
        Task { await liveState.setOpticalStream(true) }
    }

    /// Turns the optical stream off and stores what it sent.
    private func endStream() async {
        guard liveState.rawFrameSink != nil else { return }
        liveState.rawFrameSink = nil
        await liveState.setOpticalStream(false)
        let captured = frames
        frames.removeAll()
        let runID = id
        try? await environment.database.writer.write { db in try db.saveBandTestFrames(runID: runID, captured) }
    }

    /// Ends the run without finishing it: the steps already done stay stored, nothing is resumed, the stream stops.
    func stop() {
        InProgress.clear()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        Task { await endStream() }
    }

    /// Ends the current step (done or skipped) with its reading, stores its span, and moves on. After the last step
    /// the band's banked records are synced so the results have them.
    func finishStep(skipped: Bool, reading: Double?) async {
        guard case let .step(step) = phase else { return }
        let mark = BandTestMark(
            runID: id,
            step: step.rawValue,
            label: step.title,
            startMs: Int64(stepStartedAt.timeIntervalSince1970 * 1000),
            endMs: Int64(Date().timeIntervalSince1970 * 1000),
            skipped: skipped,
            reading: skipped ? nil : reading
        )
        try? await environment.database.writer.write { db in try db.saveBandTestMark(mark) }
        let steps = BandTestStep.allCases
        if let index = steps.firstIndex(of: step), index + 1 < steps.count {
            let next = steps[index + 1]
            if step.streamsOptical, !next.streamsOptical { await endStream() }
            phase = .step(next)
            stepStartedAt = Date()
            begin(next)
        } else {
            await endStream()
            InProgress.clear()
            phase = .syncing
            if liveState.tierBState == .ready {
                await liveState.drainFullHistory()
            }
            phase = .finished
        }
    }
}

/// The run screen: one step at a time, then the sync, then the results.
struct BandTestRunView: View {
    let runner: BandTestRunner
    let environment: AppEnvironment
    let onClose: () -> Void

    var body: some View {
        Group {
            switch runner.phase {
            case let .step(step):
                BandTestStepCard(runner: runner, step: step)
                    .id(step)
            case .syncing:
                VStack(spacing: Spacing.s16) {
                    if let fraction = runner.drainFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text("Syncing the band's records")
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.s24)
            case .finished:
                BandTestResultsView(environment: environment, runID: runner.id)
            }
        }
        .navigationTitle("Band Tests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(runner.phase == .finished ? "Done" : "Stop", action: onClose)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// One step: the instruction, the countdown, the reading when the step asks for one, and Done or Skip.
private struct BandTestStepCard: View {
    let runner: BandTestRunner
    let step: BandTestStep

    @State private var text = ""
    /// Fahrenheit where the region uses it.
    @State private var fahrenheit = Locale.current.measurementSystem == .us

    /// The entered reading in storage units (°C, or %), or nil when blank or not a number.
    private var reading: Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        if step.reading == .temperature, fahrenheit { return (value - 32) * 5 / 9 }
        return value
    }

    /// A temperature step needs its reading; an oximeter reading is optional.
    private var readingMissing: Bool { step.reading == .temperature && reading == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text(runner.position(of: step))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.title2.weight(.semibold))
            Text(step.instruction)
                .font(.body)
            if step.streamsOptical {
                Text("Light sensor frames received: \(runner.capturedFrames.formatted())")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            readingField
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = runner.secondsLeft(at: context.date)
                VStack(spacing: Spacing.s12) {
                    if left > 0 {
                        Text(Duration.seconds(left), format: .time(pattern: .minuteSecond))
                            .font(.figureLarge)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        Task { await runner.finishStep(skipped: false, reading: reading) }
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(left > 0 || readingMissing)
                    .accessibilityIdentifier("bandTests.done")
                    Button("Skip This Step") {
                        Task { await runner.finishStep(skipped: true, reading: nil) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(Spacing.s24)
    }

    @ViewBuilder private var readingField: some View {
        switch step.reading {
        case .none:
            EmptyView()
        case .temperature:
            HStack(spacing: Spacing.s12) {
                TextField("Thermometer reading", text: $text)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("bandTests.reading")
                Picker("Unit", selection: $fahrenheit) {
                    Text("°F").tag(true)
                    Text("°C").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
        case .oxygen:
            HStack(spacing: Spacing.s12) {
                TextField("Pulse oximeter % (optional)", text: $text)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("bandTests.reading")
                Text("%").foregroundStyle(.secondary)
            }
        }
    }
}

/// One run's results: the temperature calibration points, what the optical channels show, the red/infrared ratio
/// through the breath hold, and the report to share.
struct BandTestResultsView: View {
    let environment: AppEnvironment
    let runID: String

    @State private var report: BandTestReport?
    @State private var reportFile: URL?
    private let fahrenheit = Locale.current.measurementSystem == .us

    var body: some View {
        List {
            if let results = report?.results {
                if results.recordCount == 0 {
                    Section {
                        Text("No band records for this run yet. Sync the band, then open the run again.")
                            .foregroundStyle(.secondary)
                    }
                }
                temperatureSection(results)
                opticalSection(results)
                ratioSection(results)
            }
            if let reportFile {
                Section {
                    ShareLink(item: reportFile) {
                        Label("Share Report", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            report = try? await BandTestAnalysis.load(runID: runID, from: environment.database)
            reportFile = try? report?.file()
        }
    }

    private func degrees(_ celsius: Double) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(fahrenheit ? "°F" : "°C")"
    }

    private func temperatureSection(_ results: BandTestResults) -> some View {
        Section {
            if let room = results.room {
                LabeledRow(title: "Room", value: "\(degrees(room.celsius)) · \(room.counts.formatted(.number.precision(.fractionLength(0)))) counts")
            }
            if let skin = results.skin {
                LabeledRow(title: "Skin", value: "\(degrees(skin.celsius)) · \(skin.counts.formatted(.number.precision(.fractionLength(0)))) counts")
            }
            if let calibration = results.calibration {
                LabeledRow(title: "Per Count", value: "\(calibration.slope.formatted(.number.precision(.fractionLength(3)))) °C")
            } else {
                Text("Needs both thermometer readings and the band's records around them.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Temperature")
        } footer: {
            Text("Frame 76 against the thermometer at room temperature and on your wrist.")
        }
    }

    private func opticalSection(_ results: BandTestResults) -> some View {
        Section {
            LabeledRow(title: "Optical Records", value: results.opticalRecords.formatted())
            LabeledRow(title: "Stream Frames",
                       value: results.framesByType.sorted { $0.key < $1.key }.map { "type \($0.key) × \($0.value)" }
                           .joined(separator: ", ").ifEmpty("None"))
            if let rate = results.sampleRate {
                LabeledRow(title: "Samples a Second", value: rate.formatted(.number.precision(.fractionLength(1))))
            }
            if let heartRate = results.heartRate {
                LabeledRow(title: "Heart Rate", value: "\(Int(heartRate.rounded())) bpm")
            }
            ForEach(results.channels, id: \.channel) { finding in
                LabeledRow(title: "Channel \(finding.channel)", value: channelText(finding))
            }
        } header: {
            Text("Light Sensors")
        } footer: {
            Text("✓ marks a channel whose rhythm matches your heart rate: it sees the pulse.")
        }
    }

    private func ratioSection(_ results: BandTestResults) -> some View {
        Section {
            ForEach(results.ratios, id: \.step) { finding in
                LabeledRow(title: finding.step.title, value: ratioText(finding))
            }
        } header: {
            Text("Red to Infrared")
        } footer: {
            Text("Pulse oximeters work from this ratio: it rises as oxygen falls. A pulse oximeter's readings beside it are what turn it into a percentage.")
        }
    }

    private func channelText(_ finding: BandTestResults.ChannelFinding) -> String {
        guard let summary = finding.summary else { return "No data" }
        let pulse = summary.pulsePerMinute.map { "\(Int($0.rounded()))/min" } ?? "no rhythm"
        let size = (summary.acOverDC * 100).formatted(.number.precision(.significantDigits(2)))
        return "\(pulse) · \(size)%\(finding.followsPulse ? " ✓" : "")"
    }

    private func ratioText(_ finding: BandTestResults.RatioFinding) -> String {
        let ratio = finding.ratio.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "—"
        guard let oximeter = finding.oximeter else { return ratio }
        return "\(ratio) · oximeter \(Int(oximeter.rounded()))%"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
