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
- Result:
- Firmware:
- Fixture:

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
