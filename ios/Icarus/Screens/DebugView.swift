import BandKit
import GRDB
import Store
import SwiftUI
import UniformTypeIdentifiers

/// Hidden debug screen (PLAN.md §14 row 18). Opened by five taps on the version row in Settings.
struct DebugView: View {
    let liveState: LiveState
    let environment: AppEnvironment

    private static let listLimit = 200
    /// Rows shown in the metrics inspector.
    private static let inspectorLimit = 20
    private static let recomputeDays = 7

    @State private var serverRunning = false
    @State private var serverURL: String?
    @State private var serverError: String?

    @State private var minuteRows: [MinuteMetricRow] = []
    @State private var sleepRows: [SleepSessionRow] = []
    @State private var inspectorError: String?

    @State private var showsRecomputeConfirm = false
    @State private var isRecomputing = false
    @State private var recomputeResult: String?
    @State private var isProbingReadPointer = false
    @State private var readPointerProbeResult: String?

    var body: some View {
        let frames = liveState.frameLog.latest(Self.listLimit)
        List {
            dataServerSection
            metricsInspectorSection
            recomputeSection

            Section {
                Button(isProbingReadPointer ? "Probing…" : "Probe read-pointer encoding") {
                    isProbingReadPointer = true
                    Task {
                        readPointerProbeResult = await liveState.probeReadPointerEncoding()
                        isProbingReadPointer = false
                    }
                }
                .disabled(isProbingReadPointer || liveState.tierBState != .ready || liveState.drainProgress.isDraining)
                .accessibilityIdentifier("debug.probeReadPointer")
                if let readPointerProbeResult {
                    Text(readPointerProbeResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Band history")
            } footer: {
                Text("Tries each SET_READ_POINTER payload form, rewinding the band's cursor about 10 minutes, and reports which one the band honours. Re-read records are deduplicated.")
            }

            Section {
                NavigationLink {
                    RawDataView(liveState: liveState)
                } label: {
                    Label("Raw band data", systemImage: "waveform.path.ecg")
                }
                LabeledContent("Source", value: liveState.sourceName)
                LabeledContent("Frames kept", value: "\(liveState.frameLog.count)")
                ShareLink(item: sessionExport, preview: SharePreview("Icarus session.ndjson")) {
                    Text("Export session")
                }
                .accessibilityIdentifier("debug.export")
            } footer: {
                Text("Exports the last 10 min of heart-rate frames. Device names and serials are left out.")
            }

            Section {
                if liveState.consoleLog.lines.isEmpty {
                    Text("No console lines yet")
                }
                // Newest first. The ring holds at most `BandConsoleLog.capacity` lines.
                ForEach(liveState.consoleLog.lines.reversed()) { line in
                    VStack(alignment: .leading, spacing: Spacing.s4) {
                        Text(line.at, style: .time)
                            .foregroundStyle(.secondary)
                        Text(line.text)
                            .lineLimit(2)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            } header: {
                Text("Band console")
            } footer: {
                Text("The strap's own firmware log, last \(BandConsoleLog.capacity) lines. The text layout is not yet verified on hardware.")
            }

            Section {
                if liveState.unknownEvents.sorted.isEmpty {
                    Text("None since launch")
                }
                ForEach(liveState.unknownEvents.sorted, id: \.id) { entry in
                    LabeledContent("Event \(entry.id)", value: "\(entry.count)")
                }
            } header: {
                Text("Unknown band events")
            } footer: {
                Text("EVENT ids the app does not name yet, counted since launch. Name them from captures.")
            }

            Section("Latest frames") {
                if frames.isEmpty {
                    Text("No frames yet")
                }
                ForEach(frames) { frame in
                    VStack(alignment: .leading, spacing: Spacing.s4) {
                        HStack(spacing: Spacing.s8) {
                            Text(frame.date, style: .time)
                            Text(frame.characteristic)
                        }
                        Text(frame.hex)
                            .lineLimit(1)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .navigationTitle("Debug")
    }

    private var dataServerSection: some View {
        Section {
            LabeledContent("Status", value: serverRunning ? "Running" : "Stopped")
            if let serverURL {
                Text(serverURL)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button(serverRunning ? "Stop server" : "Start server") {
                if serverRunning {
                    DebugServer.shared.stop()
                } else {
                    DebugServer.shared.start(database: environment.database)
                }
                refreshServerState()
            }
            if let serverError {
                Text(serverError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Data server")
        } footer: {
            Text("Serves the store's rows as JSON to computers on this Wi-Fi. Debug builds only.")
        }
        .onAppear { refreshServerState() }
    }

    private func refreshServerState() {
        serverRunning = DebugServer.shared.isRunning
        serverURL = DebugServer.shared.url
        serverError = DebugServer.shared.lastError
    }

    /// The most recent `minute_metric` and `sleep_session` rows, read straight from the store
    /// through `environment.database` — the same `AppDatabase` the data server above serves.
    private var metricsInspectorSection: some View {
        Group {
            Section {
                Button("Refresh") {
                    Task { await loadMetrics() }
                }
                .disabled(isRecomputing)
                if let inspectorError {
                    Text(inspectorError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(minuteRows, id: \.minuteMs) { row in
                    minuteRow(row)
                }
            } header: {
                Text("Minute metrics (latest \(Self.inspectorLimit))")
            } footer: {
                Text("Straight from the store's minute_metric table.")
            }

            Section {
                if sleepRows.isEmpty {
                    Text("No sleep sessions")
                }
                ForEach(sleepRows, id: \.rowid) { row in
                    sleepRow(row)
                }
            } header: {
                Text("Sleep sessions (latest \(Self.inspectorLimit))")
            } footer: {
                Text("Straight from the store's sleep_session table.")
            }
        }
        .onAppear { Task { await loadMetrics() } }
    }

    private func minuteRow(_ row: MinuteMetricRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(Self.timestampFormatter.string(from: date(row.minuteMs)))
                .font(.system(.caption, design: .monospaced))
            Text([
                "hr \(Self.number(row.hrAvg)) bpm (n \(row.hrN))",
                "rmssd \(Self.number(row.rmssdMs)) ms",
                "stress \(row.stress.map(String.init) ?? "–") \(row.stressState)",
                "kcal \(Self.number(row.kcal))",
            ].joined(separator: " · "))
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)
        }
    }

    private func sleepRow(_ row: SleepSessionRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack(spacing: Spacing.s8) {
                Text(Self.timestampFormatter.string(from: date(row.startMs)))
                Text("→ \(Self.timestampFormatter.string(from: date(row.endMs)))")
            }
            .font(.system(.caption, design: .monospaced))
            Text([
                "\(Self.durationText(row.durationS))",
                "resting \(Self.number(row.restingHr)) bpm",
                "rmssd \(Self.number(row.rmssdMs)) ms",
                "quality \(row.quality)",
                row.isNap ? "nap" : "main sleep",
                "records \(row.recordCount)",
            ].joined(separator: " · "))
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)
        }
    }

    private var recomputeSection: some View {
        Section {
            Button("Recompute last \(Self.recomputeDays) days…") {
                showsRecomputeConfirm = true
            }
            .disabled(isRecomputing)
            if isRecomputing {
                Text("Recomputing…")
            }
            if let recomputeResult {
                Text(recomputeResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Force recompute")
        } footer: {
            Text("Rebuilds minute metrics and sleep sessions from raw data. Daily rollups are computed when read, so they follow automatically.")
        }
        .confirmationDialog(
            "This recomputes the last \(Self.recomputeDays) days from raw data",
            isPresented: $showsRecomputeConfirm,
            titleVisibility: .visible
        ) {
            Button("Recompute", role: .destructive) {
                Task { await recomputeLastWeek() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadMetrics() async {
        do {
            let (minutes, sessions) = try await environment.database.writer.read { db in
                let minutes = try MinuteMetricRow.fetchAll(
                    db,
                    sql: "SELECT * FROM minute_metric ORDER BY minute_ms DESC LIMIT ?",
                    arguments: [Self.inspectorLimit]
                )
                let sessions = try SleepSessionRow.fetchAll(
                    db,
                    sql: "SELECT * FROM sleep_session ORDER BY start_ms DESC LIMIT ?",
                    arguments: [Self.inspectorLimit]
                )
                return (minutes, sessions)
            }
            minuteRows = minutes
            sleepRows = sessions
            inspectorError = nil
        } catch {
            inspectorError = String(describing: error)
        }
    }

    /// Recomputes minute metrics for the last week via a fresh `MetricsWorker` (the app's own
    /// worker lives privately in `AppEnvironment`), then re-derives sleep sessions over the same
    /// window with the store's public `deriveSleepSessions`, using the most recent band.
    private func recomputeLastWeek() async {
        isRecomputing = true
        defer { isRecomputing = false }
        let database = environment.database
        let nowMs = environment.clock.nowMs
        let day: Int64 = 86_400_000
        do {
            let result = try await MetricsWorker(database: database)
                .recomputeBackfill(days: Self.recomputeDays, nowMs: nowMs)
            let sleepWritten = try await database.writer.write { db -> Int in
                guard let bandID = try String.fetchOne(
                    db, sql: "SELECT id FROM band ORDER BY rowid DESC LIMIT 1"
                ) else { return 0 }
                let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
                return try db.deriveSleepSessions(
                    from: nowMs - Int64(Self.recomputeDays) * day,
                    to: nowMs + 1,
                    bandID: bandID,
                    in: zone,
                    computedAtMs: nowMs
                )
            }
            recomputeResult = "Minute rows changed: \(result.changedRows), sleep sessions written: \(sleepWritten)"
            BandLog.tierB(
                .info,
                "debug: force recompute — \(result.changedRows) minute row(s) changed, \(sleepWritten) sleep session(s) written"
            )
            await loadMetrics()
        } catch {
            recomputeResult = "Recompute failed: \(String(describing: error))"
            BandLog.tierB(.error, "debug: force recompute failed: \(String(describing: error))")
        }
    }

    // MARK: Formatting helpers

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func number(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f", value)
    }

    private static func durationText(_ seconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }

    private var sessionExport: SessionExport {
        let start = liveState.now.addingTimeInterval(-FrameLog.exportWindow)
        return SessionExport(ndjson: liveState.frameLog.ndjson(since: start))
    }
}

/// The NDJSON session file, shared through the system share sheet.
private struct SessionExport: Transferable {
    let ndjson: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "ndjson") ?? .plainText) { export in
            Data(export.ndjson.utf8)
        }
    }
}
