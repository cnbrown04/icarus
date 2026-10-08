import BandKit

/// Records requested sleeps instead of sleeping.
actor RecordingClock: ReplayClock {
    private(set) var requestedSeconds: [Double] = []

    func sleep(seconds: Double) async throws {
        requestedSeconds.append(seconds)
    }
}

/// One NDJSON line carrying a 0x2A37 payload: flags 0x16, the given bpm (below 256), and one R-R of 1000 ms (raw 1024 = 0x0400, sent little-endian as 00 04).
func heartRateLine(t: Double, bpm: Int) -> String {
    let hex = "16" + String(bpm, radix: 16) + "0004"
    return #"{"t": \#(t), "char": "2a37", "hex": "\#(hex)"}"#
}
