# Hardware findings

Results of the Phase 1 hardware checks (PLAN.md §5.5, §17.1, §19 Phase 1). Caleb fills one run per TestFlight build, using the steps in `docs/hardware-test.md`. Keep each answer short and factual, and attach a fixture for every item that has one.

Do not record device names, serials, tokens or account data here. Fixtures are scrubbed before they are saved (the Debug export already leaves them out, PLAN.md §7.2).

## Run

- Build number and commit SHA:
- Phone model and iOS version:
- Band model and firmware (REPORT_VERSION_INFO, §5.5 item 7): Firmware:
- Date and tester:
- Fixture for this run (file name under `ios/Fixtures/`, or "none"): Fixture:

## §5.5 checklist

For each item, write the result, the firmware it was measured on, and the fixture file if one exists.

### 1. Does 0x2A37 stream with HR Broadcast off? Is the band discoverable with it off?

- Sources in conflict: [S9] vs [S11][S12]
- Setup run A (HR Broadcast on in the WHOOP app):
- Setup run B (HR Broadcast off):
- Result:
- Firmware:
- Fixture:

### 2. Does 0x2A37 include R-R intervals (flag bit 4), and what fraction of seconds carry at least one R-R?

- Sources in conflict: [S12][S15] vs [S10]
- Measured fraction of seconds with R-R (from the fixture):
- Result:
- Firmware:
- Fixture:

### 3. Does a .withResponse write from iOS bond the custom service (look for BLE_BONDED)?

- Sources in conflict: [S12][S15] vs [S11]
- Result:
- Firmware:
- Fixture:

### 4. Can the official WHOOP app and Icarus be connected at the same time?

- Sources in conflict: [S11] vs [S15]
- Result:
- Firmware:
- Fixture:

### 5. Which SET_CLOCK payload length does this firmware latch (8 or 9 bytes)?

- Source: [S12]
- Result: The RTC latches (GET_CLOCK reads back the seconds sent, and the strap resumes banking
  history) only after the handshake writes BOTH forms: the 8-byte `[u32 LE][u32 zero]` body alone
  was ACKed but never latched — the strap RTC stayed months stale and no new history was banked.
  With `setClock(unix:)` followed by `setClockLegacy(unix:)` (the 9-byte `[u32 LE][5 zero]` body),
  GET_CLOCK read back exactly the seconds sent (2026-10-18 capture). Matches NOOP's finding that
  fw 41.17.x latches only the 9-byte form; which of the two forms this strap latched was not
  isolated (both were sent, and isolating them would desync the RTC again).
- Firmware: WHOOP 4.0, GET_HELLO firmware string `8e27cafe` (see ios band log capture)
- Fixture: live capture, `ios/Packages/BandKit` log capture (`BandLog.startCapture`), 2026-10-18
- **Explained 2026-10-30:** the strap silently drops any command whose inner content
  (`[type][seq][cmd][payload]`) is not a multiple of 4 bytes. The 8-byte form's inner is 11 bytes, the
  9-byte form's is 12. `FrameCodec.encodeCommand` now zero-pads every command (OpenStrap `pad4`), so both
  forms carry the same aligned body.

### 5b. SET_READ_POINTER (cmd 33) and re-downloading history (2026-10-30)

- Source: OpenStrap PROTOCOL.md §4.3 ("the cursor can be repositioned") — never exercised by their client.
- Result: with padding the strap accepts cmd 33 and the GET_DATA_RANGE read-cursor word (raw offset 14)
  reads back the requested page, but the next SEND_HISTORICAL_DATA streams from the strap's internal
  position regardless. Tested: rewind 64 pages below U (twice, once after ABORT_HISTORICAL_TRANSMITS cmd 20),
  and skip forward to W − 1 then back (both above U). Every drain began one page after the last-acked page.
  Acked history cannot be re-downloaded with any known command.
- Ring geometry: 131072 pages × ~9.1 records/page ≈ 13.6 days at 1 Hz (ack tokens `[page u32][next u32]`).
- Firmware: WHOOP 4.0, fw 41.17.x
- Fixture: Icarus band log, 2026-10-30 20:46–21:37 ("read-pointer probe" lines)

### 6. Does RUN_HAPTICS_PATTERN 79 with `[2, n, 0, 0, 0]` buzz a WHOOP 4.0, and what does GET_ALL_HAPTICS_PATTERN 80 return?

- Source: [S12]
- Result:
- Firmware:
- Fixture:

### 7. Firmware version (REPORT_VERSION_INFO 7)

- Result:
- Firmware:
- Fixture:

## Background behaviour (§19 Phase 1 exit criteria)

Measure with the app connected and the band worn. Record the Device screen "Last data" age and the Today HR value.

### Screen locked for 1 hour

- Start time and end time:
- Data gaps longer than 60 s (count and longest):
- Did "Collection paused" appear (it needs a gap over 10 min)?:
- Result:
- Fixture:

### App backgrounded overnight (phone locked and charging)

- Start time and end time:
- Data coverage for the night (percent of seconds with a sample):
- Longest gap and when it happened:
- Did "Collection paused" appear?:
- Result:
- Fixture:

### Force-quit (informational, PLAN.md §7.2 [Unverified])

- Did the band reconnect after relaunch without opening the app first? Result:
- Fixture:
