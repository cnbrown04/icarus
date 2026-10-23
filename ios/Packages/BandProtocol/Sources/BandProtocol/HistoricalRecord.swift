/// One WHOOP 4.0 HISTORICAL_DATA (type 47) record: a 1 Hz biometric sample from the strap's
/// on-device store, offloaded by SEND_HISTORICAL_DATA (cmd 22, PLAN.md 5.3.4).
///
/// There is no record-schema section in PLAN.md yet; this parser is self-contained and follows the
/// community-reverse-engineered layout (NOOP project, verified against 762 real records). Marked
/// [Community-verified] where NOOP anchors a field, [Unverified] for gaps the captures never filled.
///
/// ## Record version
/// The version byte of a type-47 record is the frame's `seq` field. Version 24 is the WHOOP 4.0
/// DSP record parsed here. Version 25 (the 84-byte WHOOP 4.0 firmware layout) is NOT a
/// `HistoricalRecord`: it has no per-second biometrics the app can use, so `HistoricalRecordV25`
/// decodes its timestamp only, and this parser rejects it with `.unsupportedVersion(25)`. Other
/// versions (for example the 85-byte version-12 records in the S8 capture, `shared/golden/frames.json`
/// names `historical_seq0c_*`) have a different layout and are rejected with `.unsupportedVersion`
/// rather than decoded into wrong numbers.
///
/// ## Version-24 payload layout
/// Offsets in the table below are **frame-absolute**, exactly as NOOP's schema numbers them
/// (`whoop_protocol.json`): they count from the 0xAA sync byte, so the envelope — sync, length u16,
/// CRC-8, type, seq, cmd — occupies frame bytes 0–6 and `Frame.payload` starts at frame byte 7. The
/// parser therefore reads `Frame.payload[offset - 7]` (see `Layout`, whose constants are already
/// shifted). All multi-byte values are little-endian.
///
/// Verified byte-for-byte against NOOP's real on-wrist WHOOP 4.0 record (fw 41.17.6.0, `Whoop4HistoricalV24HardwareTests`):
/// unix 1,780,928,574 (2026-06-08) at frame 11, HR 109 at frame 21, R-R [555, 564] at frame 23,
/// |gravity| ≈ 1 g at frame 40, worn skin-temp ≈ 861 at frame 72.
///
/// | Frame offset | Size | Field | Status |
/// |---|---|---|---|
/// | 0–10 | 11 | envelope prefix (0xAA, length, CRC-8, type, seq, cmd) | [Community-verified] |
/// | 11 | 4 | unix seconds u32 | [Community-verified] |
/// | 15–20 | 6 | undocumented | [Unverified] |
/// | 21 | 1 | heart rate u8 (0 = no reading) | [Community-verified] |
/// | 22 | 1 | R-R count u8 | [Community-verified] |
/// | 23 | 2·count | R-R intervals u16 LE, ms | [Community-verified] |
/// | 33 | 2 | PPG green u16 | [Community-verified] |
/// | 35 | 2 | PPG red/IR u16 | [Community-verified] |
/// | 40, 44, 48 | 4 each | gravity x, y, z, f32 | [Community-verified] |
/// | 55 | 1 | skin contact u8 (0 = off-wrist, else on-wrist) | [Community-verified] offsets; [Disputed] meaning, see `skinContact` |
/// | 56, 60, 64 | 4 each | second gravity triplet f32 | [Community-verified] offsets; the 12 bytes are a byte-identical copy of 40–51, see `secondaryGravity` |
/// | 68 | 2 | SpO₂ red raw u16 | [Community-verified] |
/// | 70 | 2 | SpO₂ IR raw u16 | [Community-verified] |
/// | 72 | 2 | skin temperature raw u16 | [Community-verified] |
/// | 74, 76, 78 | 2 each | ambient light and LED drives u16 | [Community-verified], meaning per slot unconfirmed |
/// | 80 | 2 | respiratory rate raw u16 | [Community-verified] |
/// | 82 | 2 | signal quality u16 | [Community-verified] |
///
/// ## Cross-check against golden frames
/// The eight `historical_seq0c_*` frames in `shared/golden/frames.json` are **version 12** records
/// (S8 source, 85-byte payload) and do **not** use this layout. In those frames a u16 record counter
/// sits at payload offset 0 (increments by exactly 1 across consecutive frames, which step 1 second
/// apart) and a plausible unix u32 sits at payload offset 4 (2024-06-12 05:31:52 UTC). Both are
/// different from version 24, so the parser rejects them; they stay in the golden set as
/// unsupported-version fixtures.
public struct HistoricalRecord: Sendable, Equatable {
    /// The record layout this parser decodes (the frame `seq` byte of a real record).
    public static let supportedVersion: UInt8 = 24

    /// Version byte of the record: the frame `seq` field. Always `supportedVersion` for a parsed value.
    public let version: UInt8

    /// Record time as unix seconds (offset 11, u32 LE).
    public let unixSeconds: UInt32
    /// Raw heart rate byte (offset 21). 0 means the strap recorded no reading.
    public let heartRate: Int
    /// R-R intervals in milliseconds, at most `maxRRCount` entries (offset 23, u16 LE each).
    public let rrIntervalsMs: [UInt16]
    /// PPG green raw (offset 33).
    public let ppgGreen: UInt16
    /// PPG red/IR raw (offset 35).
    public let ppgRedIr: UInt16
    /// Gravity triplet at offsets 40/44/48, in g.
    public let gravity: Gravity
    /// On-wrist flag (offset 55): 0 = off-wrist, any other value = on-wrist.
    ///
    /// [Disputed] Offset and value range are NOT enough to call this a wear flag. OpenStrap
    /// (`os-protocol/lib/src/records.dart`, `R24.skinContact` doc) reads the same byte as the sign and
    /// exponent byte of an integer-valued float32 at offsets 52–55 and says not to infer wear state
    /// from it. Our 44,352 real v24 frames (device3 band log, 2026-10-23) take only the values
    /// {0, 64–70, 195–198}, the exponent pattern OpenStrap reports; 0 appears in 1,552 of them.
    /// Left unchanged here, because the sleep pipeline depends on this boolean.
    public let skinContact: Bool
    /// Second gravity triplet at offsets 56/60/64, in g.
    ///
    /// Verdict (investigated 2026-10-23): the strap DUPLICATES the first triplet. The parser reads the
    /// right bytes, so this is not a copy/paste or offset bug. Evidence:
    /// - OpenStrap `os-research/PROTOCOL.md` §5 (inner offsets, +4 for the frame): `[36:48]` accel,
    ///   `[52:64]` "f32 ×3 — byte-identical mirror of `[36:48]` (not an extra sensor)", validated.
    /// - OpenStrap `records.dart` (`R24.accelG` doc): inner[52:64] is byte-identical to inner[36:48] in
    ///   all 1,887 real v24 records.
    /// - Icarus, device3 band log: frame bytes 40–51 equal bytes 56–67 in 44,352 of 44,352 v24 frames.
    /// - NOOP `whoop_protocol.json` labels it "2nd accel/gravity triplet" at the same offset 56, with no
    ///   verified meaning. Its 12 bytes add no information beyond `gravity`, so downstream code must not
    ///   treat it as an independent measurement.
    public let secondaryGravity: Gravity
    /// SpO₂ red raw (offset 68). No raw-to-percent mapping is verified, so nothing converts it.
    public let spo2Red: UInt16
    /// SpO₂ IR raw (offset 70).
    public let spo2Ir: UInt16
    /// Skin temperature raw (offset 72). The raw-to-celsius mapping is not verified.
    public let skinTempRaw: UInt16
    /// Ambient light / LED drive at offsets 74/76/78 ([Community-verified] offsets, per-slot meaning unconfirmed).
    public let ambientDrive: UInt16
    public let ledDrive1: UInt16
    public let ledDrive2: UInt16
    /// Respiratory rate raw (offset 80). The raw-to-breaths-per-minute mapping is not verified.
    public let respRateRaw: UInt16
    /// Signal quality raw (offset 82). The raw-to-fraction mapping is not verified.
    public let signalQuality: UInt16

    public init(
        version: UInt8 = supportedVersion,
        unixSeconds: UInt32,
        heartRate: Int,
        rrIntervalsMs: [UInt16],
        ppgGreen: UInt16,
        ppgRedIr: UInt16,
        gravity: Gravity,
        skinContact: Bool,
        secondaryGravity: Gravity,
        spo2Red: UInt16,
        spo2Ir: UInt16,
        skinTempRaw: UInt16,
        ambientDrive: UInt16,
        ledDrive1: UInt16,
        ledDrive2: UInt16,
        respRateRaw: UInt16,
        signalQuality: UInt16
    ) {
        self.version = version
        self.unixSeconds = unixSeconds
        self.heartRate = heartRate
        self.rrIntervalsMs = rrIntervalsMs
        self.ppgGreen = ppgGreen
        self.ppgRedIr = ppgRedIr
        self.gravity = gravity
        self.skinContact = skinContact
        self.secondaryGravity = secondaryGravity
        self.spo2Red = spo2Red
        self.spo2Ir = spo2Ir
        self.skinTempRaw = skinTempRaw
        self.ambientDrive = ambientDrive
        self.ledDrive1 = ledDrive1
        self.ledDrive2 = ledDrive2
        self.respRateRaw = respRateRaw
        self.signalQuality = signalQuality
    }

    /// One accelerometer triplet, in g.
    public struct Gravity: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double

        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// Why a frame could not be decoded as a version-24 record.
    public enum ParseError: Error, Equatable, Sendable {
        /// The frame is not HISTORICAL_DATA (type 47).
        case notHistoricalData(UInt8)
        /// The record version (frame `seq`) is not 24. The record is left for a future parser
        /// instead of decoded into wrong numbers.
        case unsupportedVersion(UInt8)
        /// The payload is shorter than the fixed field table requires.
        case payloadTooShort(length: Int, required: Int)
    }

    /// Fixed field offsets **within `Frame.payload`**. The table above numbers fields
    /// frame-absolute (NOOP's numbering); `Frame.payload` starts at frame byte 7, so each constant
    /// here is its table value minus 7.
    private enum Layout {
        /// The payload must reach the end of `signalQuality` (payload offset 77 = frame 84).
        static let minimumLength = 77
        static let unixSeconds = 4
        static let heartRate = 14
        static let rrCount = 15
        static let rrFirst = 16
        static let ppgGreen = 26
        static let ppgRedIr = 28
        static let gravity = 33
        static let skinContact = 48
        // Payload 49 = frame 56 = OpenStrap inner[52]: the byte-identical copy of `gravity` (see
        // `secondaryGravity`). The offset is right; the strap writes the same 12 bytes twice.
        static let secondaryGravity = 49
        static let spo2Red = 61
        static let spo2Ir = 63
        static let skinTempRaw = 65
        static let ambientDrive = 67
        static let ledDrive1 = 69
        static let ledDrive2 = 71
        static let respRateRaw = 73
        static let signalQuality = 75
    }

    /// Five fixed R-R slots (payload 16–25) precede the next fixed field, so at most this many
    /// intervals are reported. A larger `rr_count` byte is clamped and the excess is dropped
    /// ([Unverified]: no capture shows more than 5).
    public static let maxRRCount = 5

    /// Decodes one version-24 record from a HISTORICAL_DATA frame.
    public static func parse(_ frame: Frame) throws(ParseError) -> HistoricalRecord {
        guard frame.packetType == .historicalData else {
            throw .notHistoricalData(frame.type)
        }
        guard frame.seq == supportedVersion else {
            throw .unsupportedVersion(frame.seq)
        }
        let payload = frame.payload
        guard payload.count >= Layout.minimumLength else {
            throw .payloadTooShort(length: payload.count, required: Layout.minimumLength)
        }

        let declaredCount = Int(payload[Layout.rrCount])
        let count = min(declaredCount, maxRRCount)
        var rr: [UInt16] = []
        rr.reserveCapacity(count)
        for i in 0..<count {
            rr.append(u16(payload, Layout.rrFirst + i * 2))
        }

        return HistoricalRecord(
            version: frame.seq,
            unixSeconds: u32(payload, Layout.unixSeconds),
            heartRate: Int(payload[Layout.heartRate]),
            rrIntervalsMs: rr,
            ppgGreen: u16(payload, Layout.ppgGreen),
            ppgRedIr: u16(payload, Layout.ppgRedIr),
            gravity: gravity(payload, Layout.gravity),
            skinContact: payload[Layout.skinContact] != 0,
            secondaryGravity: gravity(payload, Layout.secondaryGravity),
            spo2Red: u16(payload, Layout.spo2Red),
            spo2Ir: u16(payload, Layout.spo2Ir),
            skinTempRaw: u16(payload, Layout.skinTempRaw),
            ambientDrive: u16(payload, Layout.ambientDrive),
            ledDrive1: u16(payload, Layout.ledDrive1),
            ledDrive2: u16(payload, Layout.ledDrive2),
            respRateRaw: u16(payload, Layout.respRateRaw),
            signalQuality: u16(payload, Layout.signalQuality)
        )
    }

    // MARK: Byte readers

    private static func u16(_ payload: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
    }

    private static func u32(_ payload: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(payload[offset])
            | (UInt32(payload[offset + 1]) << 8)
            | (UInt32(payload[offset + 2]) << 16)
            | (UInt32(payload[offset + 3]) << 24)
    }

    private static func f32(_ payload: [UInt8], _ offset: Int) -> Double {
        Double(Float(bitPattern: u32(payload, offset)))
    }

    private static func gravity(_ payload: [UInt8], _ offset: Int) -> Gravity {
        Gravity(x: f32(payload, offset), y: f32(payload, offset + 4), z: f32(payload, offset + 8))
    }
}

/// A version-25 HISTORICAL_DATA record (WHOOP 4.0, 84-byte frame, `frame.seq == 25`), decoded as far as
/// the references agree: its unix second, and nothing else.
///
/// Offsets are `Frame.payload` offsets (NOOP's frame-absolute offset minus 7):
/// - unix u32 LE at payload 4 (frame 11). NOOP `PostHooks.swift` v25 branch `u32(frame, 11, limit)`
///   (~line 353) and `HistoricalStreams.kt` `histU32(11, limit)` (~line 266); OpenStrap
///   `records.dart` `_parseV25` `getUint32(7)` on `inner` (inner starts at frame byte 4, so frame 11).
///   Verified on 1,400 real frames (device3 log): within each burst the value rises by 1 per record
///   (38 records repeat the previous second), and bursts are about 1,154 s apart.
/// - minimum payload 72 (frame 79): NOOP `frame.count >= 79`; OpenStrap `inner.length < 75` rejects,
///   and inner = frame[4:], so frame 79.
///
/// Deliberately NOT decoded, and why:
/// - Heart rate and R-R: v25 has no per-second beat field. OpenStrap `_parseV25` returns HR 0 and warns
///   that a peak pass over the bursts invents a ~60 bpm rhythm from the burst cadence.
/// - Gravity. NOOP's v25 branch reads i16 / 16384 at frame 73/75/77 (`PostHooks.swift` ~lines 357–371,
///   `HistoricalStreams.kt` ~lines 267–275). OpenStrap `records.dart` `_parseV25` retracts it: it is not
///   gravity, and the 'z' axis takes three distinct values. Icarus check on 1,400 real v25 frames
///   (device3 band log): correlation with the v24 gravity of the same second is -0.19, -0.08 and -0.00,
///   and the 'y' and 'z' axes take 6 and 3 distinct values. Decoding it would fabricate stillness.
/// - The 24 Hz optical waveform at frames 23–72 (OpenStrap: "a raw ~24 Hz PPG waveform").
///
/// Storage warning: every v25 record shares its unix second with a v24 record from the same drain
/// (1,400 of 1,400 in the device3 log). `historical_record` is `UNIQUE (band_id, ts_ms)` with
/// `INSERT OR IGNORE`, so storing a v25 row could shadow the real v24 heart-rate row for that second.
/// Do not write these to `historical_record`. They add nothing the v24 record lacks.
public struct HistoricalRecordV25: Sendable, Equatable {
    /// The record layout this type decodes (the frame `seq` byte).
    public static let supportedVersion: UInt8 = 25

    /// Version byte of the record: the frame `seq` field. Always `supportedVersion` for a parsed value.
    public let version: UInt8
    /// Record time as unix seconds (payload offset 4, u32 LE).
    public let unixSeconds: UInt32

    /// Minimum payload for a whole v25 frame (frame byte 79). NOOP and OpenStrap both reject shorter ones.
    private static let minimumLength = 72
    private static let unixOffset = 4

    /// Decodes one version-25 record from a HISTORICAL_DATA frame.
    public static func parse(_ frame: Frame) throws(HistoricalRecord.ParseError) -> HistoricalRecordV25 {
        guard frame.packetType == .historicalData else {
            throw .notHistoricalData(frame.type)
        }
        guard frame.seq == supportedVersion else {
            throw .unsupportedVersion(frame.seq)
        }
        let payload = frame.payload
        guard payload.count >= minimumLength else {
            throw .payloadTooShort(length: payload.count, required: minimumLength)
        }
        return HistoricalRecordV25(version: frame.seq, unixSeconds: u32(payload, unixOffset))
    }

    private static func u32(_ payload: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(payload[offset])
            | (UInt32(payload[offset + 1]) << 8)
            | (UInt32(payload[offset + 2]) << 16)
            | (UInt32(payload[offset + 3]) << 24)
    }
}

/// A METADATA (type 49) frame seen during a history offload (PLAN.md 5.3.4).
///
/// After each offloaded batch the strap sends one METADATA frame; the app echoes the 8-byte token
/// it carries with HISTORICAL_DATA_RESULT (cmd 23) as a confirmed write, or the strap replays the
/// batch. The token sits at `inner[13:21]` of the frame, where `inner = [type][seq][cmd] + payload`
/// (PLAN.md 5.3.3). Because the inner bytes start at frame byte 4, that is `payload[10..<18]` and
/// frame bytes `17..<25`; any write-up placing the token at frame bytes 13–21 is off by the 4-byte
/// envelope header.
///
/// Cross-check: all four `metadata_seq*` golden frames in `shared/golden/frames.json` (S8 source)
/// carry the same constant 8 bytes at `payload[10..<18]` (`2E 47 01 00 04 00 00 00`), consistent
/// with a per-offload token rather than a per-frame counter. [Unverified] on 4.0 hardware: no
/// golden capture includes a type-49 frame from a real 4.0 offload, so the byte range must be
/// confirmed there before the echo is trusted.
public enum HistoricalMetadata {
    /// The 8-byte token byte range: `payload[10..<18]`, i.e. `inner[13:21]`.
    static let tokenRange = 10..<18

    /// The token to echo back with HISTORICAL_DATA_RESULT, or nil when the payload is too short
    /// to carry one.
    public static func token(fromPayload payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= tokenRange.upperBound else { return nil }
        return Array(payload[tokenRange])
    }

    /// The metadata struct's field layout for a HISTORY_END (NOOP PostHooks `metadata` hook,
    /// hardware-verified): `struct '<LHLL'` starting at payload byte 0 — unix u32 @ 0, subsec u16
    /// @ 4, an unverified u32 @ 6 (OpenStrap calls it the batch counter), trim cursor u32 @ 10.
    /// The trim cursor is the FIRST u32 of the 8-byte ack token (payload[10:14]).
    ///
    /// `0xFFFFFFFF` is the strap's "no valid flash cursor" sentinel (NOOP): on an END with no
    /// banked rows it means the strap has no history to offload; after a run that persisted rows
    /// it means "caught up". Callers must distinguish the two.
    public static func trimCursor(fromPayload payload: [UInt8]) -> UInt32? {
        guard payload.count >= 14 else { return nil }
        return u32(payload, 10)
    }

    /// The HISTORY_END's own unix timestamp (u32 LE @ payload 0): the strap's RTC reading when the
    /// batch closed. A genuine offload is always PAST-dated (banked history); an END dated days
    /// into the FUTURE is a corrupt strap clock. Nil when the payload is too short.
    public static func endUnix(fromPayload payload: [UInt8]) -> UInt32? {
        guard payload.count >= 4 else { return nil }
        return u32(payload, 0)
    }

    private static func u32(_ payload: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(payload[offset])
            | (UInt32(payload[offset + 1]) << 8)
            | (UInt32(payload[offset + 2]) << 16)
            | (UInt32(payload[offset + 3]) << 24)
    }
}
