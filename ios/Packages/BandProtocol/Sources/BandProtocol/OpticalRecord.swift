import Foundation

/// One R21 record: six optical channels from the band's live raw stream (REALTIME_RAW_DATA, type 0x2B, record
/// type 21 in the frame's `seq` byte). It arrives only while the stream (cmd 63) and the optical path (cmd 107)
/// are on; the band never banks it in history.
///
/// Layout from OpenStrap research `research_playground.py` `parse_r21` (offsets there are on the frame's inner
/// bytes, 3 before `Frame.payload`): unix seconds at 4, LED drive u16 at 11, sample count u16 at 13, then six
/// channels of up to 100 u16 samples at 17, 217, 417, 629, 829 and 1029. OpenStrap names a and b green (b often 0),
/// c infrared and f red ("SpO2 with C"), and leaves d and e unnamed. [Unverified] on Icarus hardware: the Band Tests
/// optical steps store every streamed frame's bytes so this can be re-decoded if the map is off.
public struct OpticalRecord: Sendable, Equatable {
    /// The record type this decodes (the frame's `seq` byte).
    public static let recordType: UInt8 = 21
    /// Channel starts within `Frame.payload`, a to f.
    static let channelOffsets = [17, 217, 417, 629, 829, 1029]
    static let samplesPerChannel = 100
    /// OpenStrap rejects records shorter than 620 inner bytes.
    static let minimumLength = 617

    public let unixSeconds: UInt32
    public let ledDrive: UInt16
    public let sampleCount: UInt16
    /// Channels a to f, each up to 100 samples (shorter when the payload ends first; empty when it ends before).
    public let channels: [[UInt16]]

    /// Decodes an R21 record, or nil for any other frame or a payload too short to hold one.
    public static func parse(_ frame: Frame) -> OpticalRecord? {
        guard frame.packetType == .realtimeRawData, frame.seq == recordType,
              frame.payload.count >= minimumLength
        else { return nil }
        let p = frame.payload
        func u16(_ offset: Int) -> UInt16 { UInt16(p[offset]) | UInt16(p[offset + 1]) << 8 }
        let unix = UInt32(p[4]) | UInt32(p[5]) << 8 | UInt32(p[6]) << 16 | UInt32(p[7]) << 24
        let channels = channelOffsets.map { start in
            stride(from: start, to: start + samplesPerChannel * 2, by: 2)
                .prefix { $0 + 2 <= p.count }
                .map(u16)
        }
        return OpticalRecord(unixSeconds: unix, ledDrive: u16(11), sampleCount: u16(13), channels: channels)
    }
}
