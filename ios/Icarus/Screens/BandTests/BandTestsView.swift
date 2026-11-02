import AlarmKitBridge
import BandKit
import Metrics
import Store
import SwiftUI
import UserNotifications

/// Band Tests: start a guided run, and every past run's results. A run takes about 50 minutes and needs the band
/// connected on the band channel, since its events and records are what it measures.
struct BandTestsView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var runs: [[BandTestMark]] = []
    @State private var runner: BandTestRunner?
    /// A run the app was closed in the middle of, offered for resuming.
    @State private var unfinished = BandTestRunner.InProgress.saved

    var body: some View {
        List {
            Section {
                if let unfinished {
                    Button("Resume Run") {
                        runner = BandTestRunner(environment: environment, liveState: liveState, resuming: unfinished)
                    }
                    .accessibilityIdentifier("bandTests.resume")
                }
                Button(unfinished == nil ? "Start a Run" : "Start a New Run") {
                    BandTestRunner.InProgress.clear()
                    runner = BandTestRunner(environment: environment, liveState: liveState)
                }
                .disabled(liveState.tierBState != .ready)
                .accessibilityIdentifier("bandTests.start")
            } footer: {
                Text("About 50 minutes: still, band off for 20, back on for 20, then a double tap, the charger twice and a buzz. The band channel must be on.")
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
                    runs = value
                }
            } catch {
                runs = []
            }
        }
    }
}

/// Drives one run: the current step, when it started, saving each step's span, and the sync at the end.
@MainActor @Observable
final class BandTestRunner: Identifiable {
    enum Phase: Equatable {
        case step(BandTestStep)
        case syncing
        case finished
    }

    /// The step under way, saved at each step's start so a run survives the app being closed during the long
    /// band-off and band-on steps. Cleared when the run ends or is stopped.
    struct InProgress: Codable, Equatable {
        let runID: String
        let step: Int
        let startedAt: Date

        private static let key = "bandTests.inProgress"

        static var saved: InProgress? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(InProgress.self, from: $0) }
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

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let liveState: LiveState

    init(environment: AppEnvironment, liveState: LiveState, resuming saved: InProgress? = nil) {
        self.environment = environment
        self.liveState = liveState
        if let saved, let step = BandTestStep(rawValue: saved.step) {
            id = saved.runID
            phase = .step(step)
            stepStartedAt = saved.startedAt
        } else {
            id = UUID().uuidString
            phase = .step(.still)
            stepStartedAt = Date()
            begin(.still)
        }
    }

    /// Saves the step as under way and schedules its notification.
    private func begin(_ step: BandTestStep) {
        InProgress(runID: id, step: step.rawValue, startedAt: stepStartedAt).save()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
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

    /// Ends the run without finishing it: the steps already done stay stored, nothing is resumed.
    func stop() {
        InProgress.clear()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    var drainFraction: Double? { liveState.drainProgress.fraction }

    /// Seconds before Done is offered for the current step.
    func secondsLeft(at now: Date) -> Int {
        guard case let .step(step) = phase else { return 0 }
        return max(0, step.minimumSeconds - Int(now.timeIntervalSince(stepStartedAt)))
    }

    /// Ends the current step (done or skipped), stores its span, and moves on. After the last step the band's
    /// banked records are synced so the results have them.
    func finishStep(skipped: Bool) async {
        guard case let .step(step) = phase else { return }
        let mark = BandTestMark(
            runID: id,
            step: step.rawValue,
            label: step.title,
            startMs: Int64(stepStartedAt.timeIntervalSince1970 * 1000),
            endMs: Int64(Date().timeIntervalSince1970 * 1000),
            skipped: skipped
        )
        try? await environment.database.writer.write { db in try db.saveBandTestMark(mark) }
        if let next = BandTestStep(rawValue: step.rawValue + 1) {
            phase = .step(next)
            stepStartedAt = Date()
            begin(next)
            if next == .buzz, let double = try? RhythmSpec.builtIn(.double).rhythm() {
                Task { await liveState.runRhythm(double) }
            }
        } else {
            stop()
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
                stepCard(step)
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

    private func stepCard(_ step: BandTestStep) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Step \(step.rawValue + 1) of \(BandTestStep.allCases.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.title2.weight(.semibold))
            Text(step.instruction)
                .font(.body)
            Spacer()
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
                        Task { await runner.finishStep(skipped: false) }
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(left > 0)
                    .accessibilityIdentifier("bandTests.done")
                    Button("Skip This Step") {
                        Task { await runner.finishStep(skipped: true) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(Spacing.s24)
    }
}

/// One run's results: the events each action sent, the temperature verdict per channel, breathing by both
/// methods, and the report to share.
struct BandTestResultsView: View {
    let environment: AppEnvironment
    let runID: String

    @State private var report: BandTestReport?
    @State private var reportFile: URL?

    var body: some View {
        List {
            if let results = report?.results {
                if results.recordCount == 0 {
                    Section {
                        Text("No band records for this run yet. Sync the band, then open the run again.")
                            .foregroundStyle(.secondary)
                    }
                }
                eventsSection(results)
                temperatureSection(results)
                breathingSection(results)
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

    private func eventsSection(_ results: BandTestResults) -> some View {
        Section("Events") {
            ForEach(results.events, id: \.id) { finding in
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    HStack {
                        Text(finding.name)
                        Spacer(minLength: Spacing.s8)
                        if let proposed = finding.proposed {
                            Text("\(proposed.label) · \(finding.actions.count) of \(finding.actions.count)")
                                .foregroundStyle(Palette.syncOK)
                        }
                    }
                    Text(finding.actions.map(\.label).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let companion = finding.companion {
                        Text("Comes with \(companion.lowercased())")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(results.silentActions, id: \.self) { action in
                LabeledRow(title: action.label, value: "No event")
            }
            if results.events.isEmpty, results.silentActions.isEmpty {
                Text("No events").foregroundStyle(.secondary)
            }
        }
    }

    private func temperatureSection(_ results: BandTestResults) -> some View {
        Section {
            ForEach(results.temperature, id: \.channel) { finding in
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    HStack {
                        Text(finding.channel)
                        Spacer(minLength: Spacing.s8)
                        Text(verdictWord(finding.verdict))
                            .foregroundStyle(finding.verdict?.passes == true ? Palette.syncOK : .secondary)
                    }
                    if let verdict = finding.verdict {
                        Text(detail(verdict))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Temperature")
        } footer: {
            Text("A temperature channel changes slowly, moves steadily one way with the band off and back with it on.")
        }
    }

    private func breathingSection(_ results: BandTestResults) -> some View {
        Section("Breathing") {
            ForEach(results.breathing, id: \.step) { finding in
                LabeledRow(
                    title: finding.step == .still ? "Sitting Still" : "Back On",
                    value: "R-R \(rate(finding.rrBrpm)) · Green \(finding.greenBrpm.map(rate) ?? (finding.greenWithheld ?? "—"))"
                )
            }
        }
    }

    private func verdictWord(_ verdict: TemperatureChannelCheck.Verdict?) -> String {
        guard let verdict else { return "No records" }
        return verdict.passes ? "Passed" : "Failed"
    }

    private func detail(_ verdict: TemperatureChannelCheck.Verdict) -> String {
        func number(_ value: Double?) -> String {
            value.map { $0.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) } ?? "—"
        }
        let step = verdict.medianStep.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        return "\(step)/s · off \(number(verdict.offChange)) · on \(number(verdict.onChange))"
    }

    private func rate(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
    }
}
