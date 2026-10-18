/// Rebuilds frames from BLE notification chunks of any size.
///
/// Framing is length-based: the header (sync byte, length, CRC-8) is validated before the
/// length is trusted. A header failure discards the buffered bytes. The reassembler never
/// scans forward for 0xAA, because payloads can contain that byte.
public struct FrameReassembler: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Appends one notification payload and returns the results for every frame it completes, in order.
    public mutating func append(_ chunk: [UInt8]) -> [Result<Frame, FrameError>] {
        buffer.append(contentsOf: chunk)
        var output: [Result<Frame, FrameError>] = []

        while buffer.count >= 4 {
            if buffer[0] != FrameCodec.syncByte {
                output.append(.failure(.badSyncByte(buffer[0])))
                buffer.removeAll()
                break
            }
            guard CRC.crc8(buffer[1...2]) == buffer[3] else {
                output.append(.failure(.headerCRCMismatch))
                buffer.removeAll()
                break
            }
            let length = Int(buffer[1]) | (Int(buffer[2]) << 8)
            guard length >= 7 else {
                output.append(.failure(.invalidLength(length)))
                buffer.removeAll()
                break
            }
            let total = 4 + length
            guard buffer.count >= total else { break }

            let frameBytes = Array(buffer[0..<total])
            buffer.removeFirst(total)
            do {
                output.append(.success(try FrameCodec.decode(frameBytes)))
            } catch {
                output.append(.failure(error))
            }
        }
        return output
    }

    /// Bytes received but not yet part of a complete frame.
    public var pendingByteCount: Int { buffer.count }
}
