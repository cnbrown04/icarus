import Testing
@testable import BandProtocol

@Suite("SafeCommand denylist")
struct SafeCommandTests {
    @Test func denylistContentsMatchPlan() {
        // PLAN.md 5.3.5: 25, 29, 154, 108, 131
        #expect(SafeCommand.deniedOpcodes == [25, 29, 154, 108, 131])
    }

    @Test func noSafeCommandIsDenied() {
        for command in SafeCommand.allCases {
            #expect(!SafeCommand.deniedOpcodes.contains(command.rawValue), "\(command) is on the denylist")
        }
    }

    @Test func deniedOpcodesCannotBeConstructed() {
        for opcode in SafeCommand.deniedOpcodes {
            #expect(SafeCommand(rawValue: opcode) == nil)
        }
    }

    @Test func rebootOpcodeCannotBeEncoded() {
        // REBOOT_STRAP is 29 (0x1D). Encoding goes only through SafeCommand, and 29 is not a case.
        #expect(SafeCommand(rawValue: 29) == nil)
        #expect(SafeCommand.deniedOpcodes.contains(29))
    }

    @Test func whitelistMatchesPlanOpcodes() {
        let raw = Set(SafeCommand.allCases.map(\.rawValue))
        // 63 (SEND_R10_R11_REALTIME) is a capability whitelist addition, not in PLAN.md 5.3.4's
        // original table (whoop-parity §3.4, PLAN.md §1 ground rules).
        #expect(raw == [3, 10, 11, 14, 22, 23, 26, 34, 35, 63, 66, 67, 79, 80, 122])
    }
}
