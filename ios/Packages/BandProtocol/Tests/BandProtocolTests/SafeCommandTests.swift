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
        // original table (whoop-parity §3.4, PLAN.md §1 ground rules). 33 (SET_READ_POINTER) is
        // the same kind of addition: OpenStrap PROTOCOL.md §2/§4.3's repositionable read cursor,
        // which the app-deleted full-history restore needs.
        // 1 (LINK_VALID) and 98 (GET_EXTENDED_BATTERY_INFO) are whoop-parity §3.8 and §3.7 additions.
        // 20 (ABORT_HISTORICAL_TRANSMITS) is OpenStrap's non-destructive "cancel sync", used around a rewind.
        // 107 (ENABLE_OPTICAL_DATA) opens the wrist-gated optical stream for the Band Tests SpO2 steps; its forced
        // and persistent siblings 108 and 154 stay denied (OpenStrap's stuck-LED footgun).
        #expect(raw == [1, 3, 10, 11, 14, 20, 22, 23, 26, 33, 34, 35, 63, 66, 67, 79, 80, 98, 107, 122])
    }
}
