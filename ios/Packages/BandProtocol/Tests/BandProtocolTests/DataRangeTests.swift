import Foundation
import Testing
@testable import BandProtocol

// Byte-parity port of NOOP's `DataRangeTests` (github.com/ryanbr/noop @ ef165de4, XCTest → swift-testing):
// `DataRange.newestUnix` offset/future-date correctness. Same real WHOOP 4.0 GET_DATA_RANGE fixtures, so
// an edit that drifts from NOOP's hardware-verified decode fails here.
@Suite("DataRange decoders")
struct DataRangeTests {
    private let skew48h = 48 * 3600         // futureSkewSeconds twin (NOOP BackfillContinuation default)
    private let wallNow = 1_783_786_000      // 2026-07-11 ~16:06, just after the captured newest
    private let realNewest = 1_783_785_625   // 2026-07-11 16:00:25 (frame a)

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { off in
            let start = s.index(s.startIndex, offsetBy: off)
            let end = s.index(start, offsetBy: 2)
            return UInt8(s[start..<end], radix: 16)!
        }
    }

    /// Little-endian u32 `value` written at `offset` into a `size`-byte frame (rest zero).
    private func frameWithU32(_ size: Int, _ offset: Int, _ value: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        for k in 0..<4 { b[offset + k] = UInt8((value >> (8 * k)) & 0xFF) }
        return b
    }

    // MARK: newestUnix (every-offset scan with future guards)

    @Test func readsRealWhoop4NewestAtByteOffset8() {
        // Three real captured frames → their true newest (offset-8 u32), all 2026-07-11 ~16:00.
        let expected: [(String, Int)] = [
            ("aa100057305d22009968526a083900001d2e2263", 1_783_785_625), // 16:00:25
            ("aa10005730612200a268526ab0290000e87d155d", 1_783_785_634), // 16:00:34
            ("aa100057307c2200e768526a78760000c997138d", 1_783_785_703), // 16:01:43
        ]
        for (h, ts) in expected {
            #expect(DataRange.newestUnix(from: hex(h), wallNowUnix: wallNow, futureSkewSeconds: skew48h) == ts,
                    "newest for \(h) should be its offset-8 value, not nil")
        }
    }

    @Test func loneFutureStraddleNeverBecomesFrontier() {
        let future = wallNow + 400 * 86_400
        var frame = frameWithU32(16, 4, realNewest)
        for k in 0..<4 { frame[10 + k] = UInt8((future >> (8 * k)) & 0xFF) }
        #expect(DataRange.newestUnix(from: frame, wallNowUnix: wallNow, futureSkewSeconds: skew48h) == realNewest)
    }

    @Test func allFutureFrameStillReturnsFutureSoTheGuardFires() {
        let future = wallNow + 400 * 86_400
        #expect(DataRange.newestUnix(from: frameWithU32(12, 4, future),
                                     wallNowUnix: wallNow, futureSkewSeconds: skew48h) == future)
    }

    @Test func valueJustInsideTheSkewIsPresentNotFuture() {
        let within = wallNow + 40 * 3600     // 40h ahead, under the 48h skew
        #expect(DataRange.newestUnix(from: frameWithU32(12, 4, within),
                                     wallNowUnix: wallNow, futureSkewSeconds: skew48h) == within)
    }

    // MARK: oldestUnix (aligned-from-7; asymmetric with newestUnix by design)

    /// The whole reason `oldestUnix` scans the aligned grid instead of every offset: the real WHOOP 4.0
    /// frame carries a spurious plausible straddle at byte offset 6 (1_754_857_506, ~11 months BEFORE the
    /// true newest at offset 8). An any-offset MIN would return it → a bogus deep backlog. The aligned grid
    /// skips it, so this frame (no distinct oldest word) → nil. Guards against a future "consistency" refactor.
    @Test func oldestAlignedScanSkipsTheSpuriousOffset6Straddle() {
        #expect(DataRange.oldestUnix(from: hex("aa100057305d22009968526a083900001d2e2263")) == nil)
    }

    @Test func oldestReadsAGridAlignedWord() {
        #expect(DataRange.oldestUnix(from: frameWithU32(12, 7, 1_750_000_000)) == 1_750_000_000)
    }

    @Test func oldestKeepsTheMinimumAcrossGridWords() {
        var frame = frameWithU32(16, 7, 1_800_000_000)              // grid offset 7
        for k in 0..<4 { frame[11 + k] = UInt8((1_750_000_000 >> (8 * k)) & 0xFF) } // grid offset 11
        #expect(DataRange.oldestUnix(from: frame) == 1_750_000_000)
    }

    // MARK: pagesBehind (ring backlog). Byte-parity with NOOP's Kotlin-pinned cases.

    /// Frame (zero-filled) with W/U/T u32 LE at the pagesBehind offsets (cmdOff+12/16/24).
    private func pagesFrame(cmdOff: Int, w: Int, u: Int, t: Int, size: Int = 40) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        func put(_ off: Int, _ v: Int) { for k in 0..<4 { b[off + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        put(cmdOff + 12, w); put(cmdOff + 16, u); put(cmdOff + 24, t)
        return b
    }

    @Test func pagesBehindNormalNoWrap() {   // W > U ⇒ W − U
        #expect(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 500, u: 200, t: 1024), cmdOff: 6) == 300)
    }

    @Test func pagesBehindWraparound() {     // W < U ⇒ W + (T − U); synthetic — no real capture has crossed the wrap yet
        #expect(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 100, u: 800, t: 1000), cmdOff: 6) == 300)
    }

    @Test func pagesBehindTooShortIsNil() {
        #expect(DataRange.pagesBehind(from: [UInt8](repeating: 0, count: 20), cmdOff: 6) == nil)
    }

    @Test func pagesBehindImplausibleIsNil() {
        #expect(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 1, u: 1, t: 0), cmdOff: 6) == nil)               // capacity 0
        #expect(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 1, u: 1, t: 1_783_785_625), cmdOff: 6) == nil)  // T is a timestamp → over ceiling
        #expect(DataRange.pagesBehind(from: pagesFrame(cmdOff: 6, w: 5, u: 2000, t: 1000), cmdOff: 6) == nil)        // U ≥ T
    }

    /// Real captures (NOOP #791 WHOOP4, #815 WHOOP 5.0/MG) — confirms the offset fix against hardware, not
    /// just synthetic math. All four are the non-wrapped case (W > U); ring capacity `T` is 131072 in every one.
    @Test func pagesBehindRealCaptures() {
        let cases: [(String, Int, Int)] = [
            // WHOOP4, cmdOff 6 (Galaxy S24 Ultra capture, #791)
            ("aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
             "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04", 6, 83),
            // WHOOP 5.0/MG, cmdOff 10 (#815)
            ("aa014c00010032d124cc22040101c0890100b4890100b6890100b4890100110000000000020012000000" +
             "e2ff1d00785ac169707d0000edeb626a5c0f0000edeb626a5c0f0000feeb626a5c0f00000000a7c3ec16", 10, 2),
            ("aa014c00010032d1241e22050101008a0100dd890100e5890100dd890100110000000000020" +
             "05d00000088ff1d00da5dc169b87e000002ee626a0000000002ee626a000000005dee626a140e000000009f8dfab4", 10, 8),
            ("aa014c00010032d124982207010180b901005ab7010048b901005ab7010010000000000002" +
             "00da1b00000ee31d00b0e1ff69d7430000a3ab266a3d4a0000a3ab266a3d4a00007cc7266a5c4f00000000623977f5", 10, 494),
        ]
        for (h, cmdOff, expected) in cases {
            #expect(DataRange.pagesBehind(from: hex(h), cmdOff: cmdOff) == expected,
                    "pagesBehind for \(h) at cmdOff \(cmdOff) should be \(expected)")
        }
    }

    // MARK: ringState (the full W/U/T ring words behind pagesBehind)

    /// The real captures above decode to the full ring state, not just the backlog: W/U/T land on
    /// the same NOOP-confirmed offsets, and `pagesBehind` is the derived wraparound arithmetic.
    @Test func ringStateDecodesTheRealCapturesWriteReadAndCapacity() {
        let cases: [(String, Int, RingState)] = [
            // WHOOP4, cmdOff 6 (#791): W − U = 67491 − 67408 = 83 pages behind.
            ("aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
             "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04", 6,
             RingState(write: 67_491, read: 67_408, capacity: 131_072)),
            // WHOOP 5.0/MG, cmdOff 10 (#815): W − U = 100790 − 100788 = 2 pages behind.
            ("aa014c00010032d124cc22040101c0890100b4890100b6890100b4890100110000000000020012000000" +
             "e2ff1d00785ac169707d0000edeb626a5c0f0000edeb626a5c0f0000feeb626a5c0f00000000a7c3ec16", 10,
             RingState(write: 100_790, read: 100_788, capacity: 131_072)),
        ]
        for (h, cmdOff, expected) in cases {
            #expect(DataRange.ringState(from: hex(h), cmdOff: cmdOff) == expected)
        }
    }

    /// The wraparound shape the real captures have not crossed yet: `W < U` ⇒ W + (T − U).
    @Test func ringStatePagesBehindAppliesTheWraparoundFormula() {
        let state = RingState(write: 100, read: 800, capacity: 1000)
        #expect(state.pagesBehind == 300)
        #expect(DataRange.ringState(from: pagesFrame(cmdOff: 6, w: 100, u: 800, t: 1000), cmdOff: 6) == state)
    }

    @Test func ringStateRejectsTheSameImplausibleFramesAsPagesBehind() {
        #expect(DataRange.ringState(from: [UInt8](repeating: 0, count: 20), cmdOff: 6) == nil)                                     // too short
        #expect(DataRange.ringState(from: pagesFrame(cmdOff: 6, w: 1, u: 1, t: 0), cmdOff: 6) == nil)                              // capacity 0
        #expect(DataRange.ringState(from: pagesFrame(cmdOff: 6, w: 1, u: 1, t: 1_783_785_625), cmdOff: 6) == nil)                  // T is a timestamp
        #expect(DataRange.ringState(from: pagesFrame(cmdOff: 6, w: 5, u: 2000, t: 1000), cmdOff: 6) == nil)                        // U ≥ T
        #expect(DataRange.ringState(from: pagesFrame(cmdOff: 6, w: 2000, u: 5, t: 1000), cmdOff: 6) == nil)                        // W ≥ T
    }

    // MARK: FrameCodec.reencode (the raw-byte seam BandKit uses to reach the decoders)

    @Test func reencodeRebuildsTheExactRawBytes() throws {
        // The three real frames above round-trip decode → reencode → identical bytes, so scanning
        // offsets is identical whether the caller holds raw bytes or a decoded Frame.
        for h in ["aa100057305d22009968526a083900001d2e2263",
                  "aa10005730612200a268526ab0290000e87d155d",
                  "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
                  "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"] {
            let raw = hex(h)
            #expect(FrameCodec.reencode(try FrameCodec.decode(raw)) == raw)
        }
    }

    /// The offset-8 newest sits OFF the payload-only grid alignment: scanning a payload slice instead of
    /// the re-encoded raw bytes would shift the oldest grid and miss it. Pins why the controller must
    /// hand the decoders raw (re-encoded) bytes.
    @Test func newestDecodesFromAReencodedCommandResponse() throws {
        let raw = hex("aa100057305d22009968526a083900001d2e2263")
        let frame = try FrameCodec.decode(raw)
        #expect(DataRange.newestUnix(from: FrameCodec.reencode(frame), wallNowUnix: wallNow, futureSkewSeconds: skew48h) == realNewest)
        #expect(DataRange.oldestUnix(from: FrameCodec.reencode(frame)) == nil)
    }

    // MARK: ring state + read cursor, real fw 41.17.x capture (2026-10-30 20:46:30)

    /// GET_DATA_RANGE reply captured just before the restore whose (unpadded) rewind the strap ignored.
    @Test func realCaptureDecodesRingStateAndReadCursor() {
        let raw = hex("aa4c00a7246f2235010" + "1c0e9010034e80100afe9010030e80100010000000000020095"
            + "0d00000af11300efa72a6af8700000592de56ad00100007c2de56a784a00005d3ae56a006e00000000" + "22c44669")
        let ring = DataRange.ringState(from: raw, cmdOff: 6)
        #expect(ring == RingState(write: 125_359, read: 124_976, capacity: 131_072))
        #expect(ring?.pagesBehind == 383)
        // The read cursor equals the first word of the next ack token (`34 E8 01 00` = 124980).
        #expect(DataRange.readCursor(from: raw, cmdOff: 6) == 124_980)
        #expect(DataRange.readCursor(from: Array(raw.prefix(17)), cmdOff: 6) == nil)
    }
}
