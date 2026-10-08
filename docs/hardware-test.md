# Hardware test script

Manual checks that need a real WHOOP 4.0 band and a phone. The Simulator and CI cannot run them (PLAN.md §17.1). Caleb runs this script on TestFlight builds, and the results are recorded per release.

Record for each run:

- Build number and commit SHA:
- Phone model and iOS version:
- Band firmware (REPORT_VERSION_INFO, PLAN.md §5.5 item 7):
- Date and tester:

## Hardware-only checks (PLAN.md §17.1)

1. Pair the band from the Pair band onboarding screen. Record whether a heart-rate value appears on Today, and how long it took.
   Result:
2. With the app connected, lock the phone for 10 minutes. Unlock it and record the last-data time on the Device screen.
   Result:
3. Background the app for 15 minutes while wearing the band. Record whether data resumes without a manual reconnect.
   Result:
4. Force-quit the app from the app switcher while connected. Relaunch and record whether the band reconnects, and how the gap appears on Today and Trends.
   Result:
5. Overnight: wear the band all night with the phone locked and charging. Next morning, record the data coverage for the night and the sync status on the Sync screen.
   Result:

## Open protocol questions (PLAN.md §5.5)

Each item is an unresolved contradiction between sources. Resolve it on hardware, then update `docs/protocol/` with a sourced note.

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
