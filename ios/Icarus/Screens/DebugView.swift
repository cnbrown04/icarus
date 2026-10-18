import BandKit
import SwiftUI
import UniformTypeIdentifiers

/// Hidden debug screen (PLAN.md §14 row 18). Opened by five taps on the version row in Settings.
struct DebugView: View {
    let liveState: LiveState
    let environment: AppEnvironment

    private static let listLimit = 200

    @State private var serverRunning = false
    @State private var serverURL: String?
    @State private var serverError: String?

    var body: some View {
        let frames = liveState.frameLog.latest(Self.listLimit)
        List {
            dataServerSection

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
