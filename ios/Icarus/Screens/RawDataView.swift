import BandKit
import BandProtocol
import SwiftUI

/// Advanced raw band data (Settings > Advanced): a live viewer for everything the band sends.
/// Three sections — the app's live values, the most recent decoded historical record with all its
/// fields, and a capped stream of the decoded frames arriving now, the REALTIME_RAW_DATA (0x2B)
/// accel/PPG flood included.
///
/// Performance: the flood never stops while the band streams (~10 frames/s), so the ring in
/// `FrameLog` stays tiny and renders only the newest frames, newest first. Hex is built lazily —
/// the stream row formats a prefix only, and the full payload hex exists only in the detail view.
struct RawDataView: View {
    let liveState: LiveState

    /// Rendering cap for the stream; older frames are already gone from the ring.
    private static let streamLimit = 200
    /// Payload bytes whose hex shows in a stream row; the detail view has the rest.
    private static let rowHexBytes = 12

    var body: some View {
        List {
            liveValues
            latestRecord
            frameStream
        }
        .navigationTitle("Raw band data")
        // The 0x2B flood is off after every Tier B handshake, so this viewer asks for it while it
        // is open. `.task(id:)` runs on appear and again whenever Tier B moves — including to
        // `.ready` after a handshake, which re-asserts the flood on the new link. `.onDisappear`
        // turns it off, so the ~1.9 KB/s stream never runs unseen (PLAN.md 7.2 step 4). A viewer
        // open while the band channel is off does nothing: the flood needs the channel.
        .task(id: liveState.tierBState) {
            guard liveState.tierBState == .ready else { return }
            await liveState.setRealtimeRawFlood(true)
        }
        .onAppear {
            guard liveState.tierBState == .ready else { return }
            Task { await liveState.setRealtimeRawFlood(true) }
        }
        .onDisappear {
            Task { await liveState.setRealtimeRawFlood(false) }
        }
    }

    // MARK: Live values

    private var liveValues: some View {
        Section {
            LabeledContent("Connection", value: liveState.connectionText)
            LabeledContent {
                Text(liveState.latestBPM.map { "\($0) bpm" } ?? "--")
                    .monospacedDigit()
            } label: {
                Text("Heart rate")
            }
            LabeledContent {
                Text(liveState.batteryPercent.map { Format.percent($0) } ?? "--")
                    .monospacedDigit()
            } label: {
                Text("Battery")
            }
            LabeledContent("Channel status", value: tierBStateText)
            LabeledContent {
                lastDataText
            } label: {
                Text("Last data")
            }
            LabeledContent {
                lastBandEventText
            } label: {
                Text("Last band event")
            }
            LabeledContent {
                Text(liveState.now, format: .dateTime)
            } label: {
                Text("App clock")
            }
            LabeledContent("Source", value: liveState.sourceName)
            if let firmware = liveState.bandInfo?.firmwareVersion {
                LabeledContent("Firmware", value: firmware)
            }
            if let serial = liveState.bandInfo?.serial {
                LabeledContent("Serial", value: serial)
            }
        } header: {
            Text("Live values")
        } footer: {
            Text("Frames arrive here as the band sends them; nothing is parsed beyond the header.")
        }
    }

    private var tierBStateText: String {
        switch liveState.tierBState {
        case .disabled: "Off"
        case .awaitingLink: "Waiting for band"
        case .handshaking: "Connecting"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }

    @ViewBuilder
    private var lastDataText: some View {
        if let last = liveState.lastDataAt {
            Text(last, style: .time)
        } else {
            Text("None")
        }
    }

    @ViewBuilder
    private var lastBandEventText: some View {
        if let kind = liveState.lastBandEvent, let at = liveState.lastBandEventAt {
            HStack(spacing: Spacing.s4) {
                Text(String(describing: kind))
                Text(at, style: .time)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("None")
        }
    }

    // MARK: Latest decoded record

    @ViewBuilder
    private var latestRecord: some View {
        Section("Latest decoded record") {
            if let record = liveState.lastHistoricalRecord {
                LabeledContent("Version", value: "\(record.version)")
                LabeledContent("Time", value: Self.recordDate(record))
                LabeledContent("Heart rate", value: "\(record.heartRate)")
                LabeledContent("R-R ms", value: rrText(record))
                LabeledContent("PPG green", value: "\(record.ppgGreen)")
                LabeledContent("PPG red/IR", value: "\(record.ppgRedIr)")
                LabeledContent("Gravity g", value: Self.gravity(record.gravity))
                LabeledContent("Skin contact", value: record.skinContact ? "On wrist" : "Off wrist")
                LabeledContent("Gravity 2 g", value: Self.gravity(record.secondaryGravity))
                LabeledContent("SpO₂ red", value: "\(record.spo2Red)")
                LabeledContent("SpO₂ IR", value: "\(record.spo2Ir)")
                LabeledContent("Skin temp raw", value: "\(record.skinTempRaw)")
                LabeledContent("Ambient drive", value: "\(record.ambientDrive)")
                LabeledContent("LED drive 1", value: "\(record.ledDrive1)")
                LabeledContent("LED drive 2", value: "\(record.ledDrive2)")
                LabeledContent("Resp rate raw", value: "\(record.respRateRaw)")
                LabeledContent("Signal quality", value: "\(record.signalQuality)")
            } else {
                Text("No drain yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func recordDate(_ record: HistoricalRecord) -> String {
        Date(timeIntervalSince1970: TimeInterval(record.unixSeconds))
            .formatted(date: .abbreviated, time: .standard)
    }

    private static func gravity(_ gravity: HistoricalRecord.Gravity) -> String {
        String(format: "%.3f / %.3f / %.3f", gravity.x, gravity.y, gravity.z)
    }

    private func rrText(_ record: HistoricalRecord) -> String {
        record.rrIntervalsMs.isEmpty
            ? "None"
            : record.rrIntervalsMs.map { String($0) }.joined(separator: ", ")
    }

    // MARK: Frame stream

    private var frameStream: some View {
        Section {
            ForEach(frames) { entry in
                NavigationLink {
                    FrameDetailView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.s4) {
                        HStack(spacing: Spacing.s8) {
                            Text(entry.date, style: .time)
                            Text(Self.packetTypeName(entry))
                            Text("\(entry.bytes.count) B")
                                .foregroundStyle(.secondary)
                        }
                        Text(Self.hexPreview(entry))
                            .lineLimit(1)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        } header: {
            Text("Frame stream")
        } footer: {
            Text("Newest \(Self.streamLimit) decoded frames, newest first. Tap a row for the full hex.")
        }
    }

    private var frames: [FrameLog.Entry] {
        liveState.frameLog.latestFrames(Self.streamLimit)
    }

    /// A short packet-type label, e.g. "2B raw" — the raw-data flood the viewer exists for.
    private static func packetTypeName(_ entry: FrameLog.Entry) -> String {
        guard let type = entry.packetType else { return entry.characteristic }
        switch PacketType(rawValue: type) {
        case .command: return "23 cmd"
        case .commandResponse: return "24 reply"
        case .realtimeData: return "28 live HR"
        case .realtimeRawData: return "2B raw"
        case .historicalData: return "2F history"
        case .event: return "30 event"
        case .metadata: return "31 metadata"
        case .consoleLogs: return "32 console"
        case nil: return String(format: "%02X ?", type)
        }
    }

    /// Hex of the first bytes only, so a stream of flood rows never formats whole payloads.
    private static func hexPreview(_ entry: FrameLog.Entry) -> String {
        var text = entry.bytes.prefix(rowHexBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
        if entry.bytes.count > rowHexBytes {
            text += " …"
        }
        return text
    }
}

/// The full detail of one decoded frame: its header and the complete payload hex, selectable for copying.
private struct FrameDetailView: View {
    let entry: FrameLog.Entry

    var body: some View {
        List {
            Section("Header") {
                LabeledContent("Time") {
                    Text(entry.date, style: .time)
                }
                LabeledContent("Packet type", value: entry.characteristic)
                if let seq = entry.seq {
                    LabeledContent("Seq", value: "\(seq)")
                }
                if let cmd = entry.cmd {
                    LabeledContent("Cmd", value: "\(cmd)")
                }
                LabeledContent("Payload bytes", value: "\(entry.bytes.count)")
            }
            Section("Payload hex") {
                Text(entry.hex)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Frame")
    }
}
