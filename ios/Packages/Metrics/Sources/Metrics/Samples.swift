/// Sensor contact as stored in `hr_sample.contact` (PLAN.md 10.2). Storage NULL maps to nil.
/// BandProtocol `notSupported` also maps to nil, because the store cannot tell it apart from unknown.
public enum SensorContact: Sendable, Equatable {
    case detected
    case notDetected
}

/// One heart-rate reading at 1 Hz (PLAN.md 8.1). `tsMs` is epoch ms UTC.
public struct HeartRateSample: Sendable, Equatable {
    public let tsMs: Int64
    public let bpm: Int
    /// Nil means unknown. Only `.notDetected` is excluded from aggregation.
    public let contact: SensorContact?

    public init(tsMs: Int64, bpm: Int, contact: SensorContact? = nil) {
        self.tsMs = tsMs
        self.bpm = bpm
        self.contact = contact
    }
}

/// One accepted R-R interval (PLAN.md 8.2). `tsMs` is the receive time of the carrying notification.
public struct RRSample: Sendable, Equatable {
    public let tsMs: Int64
    public let rrMs: Double

    public init(tsMs: Int64, rrMs: Double) {
        self.tsMs = tsMs
        self.rrMs = rrMs
    }
}
