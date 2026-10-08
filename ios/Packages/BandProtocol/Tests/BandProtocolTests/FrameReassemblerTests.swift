import Testing
@testable import BandProtocol

@Suite("FrameReassembler")
struct FrameReassemblerTests {
    private let setAlarm = FrameCodec.encodeCommand(.setAlarmTime, seq: 0x6D, payload: [0x01, 0x42, 0x00, 0x00, 0x00])
    private let broadcastOn = FrameCodec.encodeCommand(.toggleHRBroadcast, seq: 0x08, payload: [0x01])

    private let expectedAlarm = Frame(type: 0x23, seq: 0x6D, cmd: 66, payload: [0x01, 0x42, 0x00, 0x00, 0x00])
    private let expectedBroadcast = Frame(type: 0x23, seq: 0x08, cmd: 0x0E, payload: [0x01])

    private func decodedFrames(_ results: [Result<Frame, FrameError>]) -> [Frame] {
        results.compactMap { try? $0.get() }
    }

    @Test func frameDeliveredOneByteAtATime() throws {
        var reassembler = FrameReassembler()
        var frames: [Frame] = []
        for byte in setAlarm {
            frames += decodedFrames(reassembler.append([byte]))
        }
        #expect(frames == [expectedAlarm])
        #expect(reassembler.pendingByteCount == 0)
    }

    @Test func twoFramesInOneChunk() throws {
        var reassembler = FrameReassembler()
        let results = reassembler.append(setAlarm + broadcastOn)
        #expect(results == [.success(expectedAlarm), .success(expectedBroadcast)])
    }

    @Test func frameSplitAcrossChunksAtHeaderBoundary() throws {
        var reassembler = FrameReassembler()
        let first = reassembler.append(Array(setAlarm[0..<3]))
        #expect(first.isEmpty)
        let results = reassembler.append(Array(setAlarm[3...]))
        #expect(results == [.success(expectedAlarm)])
    }

    @Test func frameWithSyncByteInPayloadSplitInsidePayload() throws {
        let payload: [UInt8] = [0xAA, 0xAA, 0xAA, 0x00]
        let bytes = FrameCodec.encodeCommand(.runHapticsPattern, seq: 0x20, payload: payload)
        var reassembler = FrameReassembler()
        let first = reassembler.append(Array(bytes[0..<6]))
        #expect(first.isEmpty)
        let results = reassembler.append(Array(bytes[6...]))
        #expect(results == [.success(Frame(type: 0x23, seq: 0x20, cmd: 79, payload: payload))])
    }

    @Test func partialFrameThenCompletingFrameInSameChunk() throws {
        var reassembler = FrameReassembler()
        let first = reassembler.append(Array(setAlarm[0..<10]))
        #expect(first.isEmpty)
        let results = reassembler.append(Array(setAlarm[10...]) + broadcastOn)
        #expect(results == [.success(expectedAlarm), .success(expectedBroadcast)])
    }

    @Test func corruptedPayloadIsReportedAndFollowingFrameStillDecodes() throws {
        var corrupted = setAlarm
        corrupted[8] ^= 0x10
        var reassembler = FrameReassembler()
        let results = reassembler.append(corrupted + broadcastOn)
        #expect(results == [.failure(.payloadCRCMismatch), .success(expectedBroadcast)])
    }

    @Test func badHeaderDropsBufferAndDoesNotResyncOnSyncByte() throws {
        // A garbage byte followed by a valid frame. The reassembler must not scan ahead to the 0xAA.
        var reassembler = FrameReassembler()
        let results = reassembler.append([0x00] + setAlarm)
        #expect(results == [.failure(.badSyncByte(0x00))])
        #expect(reassembler.pendingByteCount == 0)

        // The next notification starts clean.
        let next = reassembler.append(broadcastOn)
        #expect(next == [.success(expectedBroadcast)])
    }

    @Test func historicalFrameFromGoldenSetAcrossFiveNotifications() throws {
        // A 96-byte historical packet (aa5c00f02f...) arriving in 20-byte notifications.
        let hex = "aa5c00f02f0c0792b70900cf326966381a8054cc015701fb0200000000000000008c6aff00c8b43bec71aebe33c35b3e9ac1743f000050c5ec71aebe33c35b3e9ac1743fe50146021c03440287016004010c020c300000000000000276ae1006"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
        #expect(bytes.count == 96)

        var reassembler = FrameReassembler()
        var frames: [Frame] = []
        for chunk in stride(from: 0, to: bytes.count, by: 20) {
            frames += decodedFrames(reassembler.append(Array(bytes[chunk..<min(chunk + 20, bytes.count)])))
        }
        #expect(frames.count == 1)
        #expect(frames.first?.payload.count == 85) // 96 bytes - 4 header - 3 inner header - 4 CRC
    }
}
