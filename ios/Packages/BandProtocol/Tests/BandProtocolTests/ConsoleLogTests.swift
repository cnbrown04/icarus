import Testing
@testable import BandProtocol

@Suite("Console log text (type 50)")
struct ConsoleLogTests {
    @Test func splitsNewlinesAndDropsEmptyLines() {
        let text = Array("boot ok\n\nrtc 1234\r\n".utf8)
        #expect(ConsoleLog.lines(payload: text) == ["boot ok", "rtc 1234"])
    }

    @Test func stripsControlBytesAndKeepsTheRestOfTheLine() {
        // A NUL and a 0x01 header byte in front of the text, and a DEL in the middle.
        let payload: [UInt8] = [0x00, 0x01] + Array("warn\u{7F}ing".utf8)
        #expect(ConsoleLog.lines(payload: payload) == ["warning"])
    }

    @Test func invalidUTF8IsReplacedAndTheReplacementIsDropped() {
        // 0xFF can never start UTF-8: lossy decoding yields U+FFFD, which is stripped.
        let payload: [UInt8] = Array("ok".utf8) + [0xFF] + Array(" done".utf8)
        #expect(ConsoleLog.lines(payload: payload) == ["ok done"])
    }

    @Test func tabsBecomeSpacesAndEdgesAreTrimmed() {
        #expect(ConsoleLog.lines(payload: Array("\t a\tb  ".utf8)) == ["a b"])
    }

    @Test func emptyAndAllControlPayloadsYieldNoLines() {
        #expect(ConsoleLog.lines(payload: []).isEmpty)
        #expect(ConsoleLog.lines(payload: [0x00, 0x02, 0x0D]).isEmpty)
    }
}
