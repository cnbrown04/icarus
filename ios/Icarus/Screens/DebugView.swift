import BandKit
import SwiftUI
import UniformTypeIdentifiers

/// Hidden debug screen (PLAN.md §14 row 18). Opened by five taps on the version row in Settings.
struct DebugView: View {
    let liveState: LiveState

    private static let listLimit = 200

    var body: some View {
        let frames = liveState.frameLog.latest(Self.listLimit)
        List {
            Section {
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
