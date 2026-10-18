# Hardware test script

Manual checks that need a real WHOOP 4.0 band and a phone. The Simulator and CI cannot run them (PLAN.md §17.1). Caleb runs this script on TestFlight builds. Write the results in `docs/hardware-findings.md`, one run per build.

Record for each run:

- Build number and commit SHA:
- Phone model and iOS version:
- Band firmware (REPORT_VERSION_INFO, PLAN.md §5.5 item 7):
- Date and tester:

Note whether the official WHOOP app was running and whether HR Broadcast was on (PLAN.md §5.5 items 1 and 4). Both are open questions.

## Pair the band

Two ways to reach the Pair band screen:

- First launch: Welcome, then Continue, which opens Pair band.
- Later: Device tab, then Pair band.

Steps:

1. Wait on the Pair band screen. The scan list shows bands as they are found. Tap your band.
2. Record how long it took to show a heart-rate value (the "Heart rate" row), and whether the state went through Connecting to Connected.
3. If no band appears within 20 s, check whether the one-line HR Broadcast hint appears. Then turn HR Broadcast on in the WHOOP app and try again. Record both outcomes (§5.5 item 1).
4. Tap Done (or Skip during first launch) and confirm the Device tab shows the band name and Connected.

Result:

## Hardware-only checks (PLAN.md §17.1)

1. Pair the band (above). Record whether a heart-rate value appears on Today, and how long it took.
   Result:
2. With the app connected, lock the phone for 10 minutes. Unlock it and record the "Last data" age on the Device screen. It should read as an age once it is over 60 s old.
   Result:
3. Background the app for 15 minutes while wearing the band. Record whether data resumes without a manual reconnect.
   Result:
4. Force-quit the app from the app switcher while connected. Relaunch and record whether the band reconnects, and how the gap appears on Today and Trends. Note whether "Collection paused: open Icarus" appears on Device once the gap passes 10 min.
   Result:
5. Overnight: wear the band all night with the phone locked and charging. Next morning, record the data coverage for the night and the sync status on the Sync screen.
   Result:
6. Screen locked for 1 hour, then unlock. Record the longest gap and whether "Collection paused" appeared. Write the numbers in `docs/hardware-findings.md`.
   Result:

## Export a session fixture

Use this after any run where something looked wrong or a fixture is needed for a finding.

1. Open Settings. Tap the Version row five times. The Debug screen opens.
2. Check the "Latest frames" list shows heart-rate frames (characteristic `2a37`, or a `6108000x` characteristic for later phases).
3. Tap Export session and save the file (for example to Files). It covers the last 10 min.
4. Open the file. Each line should look like `{"t":..., "char":"2a37", "hex":"..."}`. It must not contain device names, serials or other characteristics. If you see anything else, do not commit it.
5. Note the file name and the firmware in `docs/hardware-findings.md` under the matching item. Fixtures are added to `ios/Fixtures/` only after review.

## Open protocol questions (PLAN.md §5.5)

Each item is an unresolved contradiction between sources. Resolve it on hardware, then update `docs/protocol/` with a sourced note. Record each answer in `docs/hardware-findings.md`.

1. Does `0x2A37` stream with HR Broadcast off? Is the band discoverable at all with it off? [S9] vs [S11][S12]
   Result:
2. Does `0x2A37` include R-R intervals (flag bit 4) on this firmware, and what fraction of seconds carry at least one R-R interval? [S12][S15] vs [S10]
   Result:
3. Does a `.withResponse` write from iOS bond the custom service (look for the `BLE_BONDED` event)? [S12][S15] vs [S11]
   Result:
4. Can the official WHOOP app and Icarus be connected at the same time? [S11] vs [S15]
   Result:
5. Which SET_CLOCK payload length does this firmware latch (8 or 9 bytes)? [S12]
   Result:
6. Does RUN_HAPTICS_PATTERN 79 with `[2, n, 0, 0, 0]` buzz a WHOOP 4.0, and what does GET_ALL_HAPTICS_PATTERN 80 return? [S12]
   Result:
7. Firmware version (REPORT_VERSION_INFO 7). Record it with every fixture.
   Result:
