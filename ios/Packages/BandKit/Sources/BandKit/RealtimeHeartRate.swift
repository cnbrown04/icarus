import BandProtocol
import Foundation

/// WHOOP 4.0 REALTIME_DATA (type 40) heart rate.
///
/// Field positions are anchored to the frame, verified against two independent real captures
/// that agree (NOOP's 4.0 parity fixture: hr 60, R-R 1000 ms; bWanShiTong's capture: hr 66):
/// frame[12] = bpm u8, frame[13] = R-R count u8, frame[14..] = R-R u16 LE ms (up to 4).
/// Relative to the decoded `Frame.payload` (which starts after the cmd byte at frame[6]),
/// that is payload[5], payload[6] and payload[7..].
enum RealtimeHeartRate {
    static func parse(_ payload: [UInt8]) -> HeartRateMeasurement? {
        guard payload.count >= 7 else { return nil }
        let bpm = Int(payload[5])
        // Sane pulse range: the byte is valid but worthless outside it.
        guard (30 ... 250).contains(bpm) else { return nil }
        let count = min(Int(payload[6]), 4)
        guard payload.count >= 7 + count * 2 else { return nil }
        var rr: [Double] = []
        for i in 0 ..< count {
            let value = Int(payload[7 + i * 2]) | (Int(payload[8 + i * 2]) << 8)
            rr.append(Double(value))
        }
        return HeartRateMeasurement(
            bpm: bpm,
            sensorContact: .notSupported,
            energyExpendedKJ: nil,
            rrIntervalsMs: rr
        )
    }
}
