# Icarus — repo context

Living context for agents and sessions. Read this first. Deep detail lives in `PLAN.md`
(protocol spec), `docs/status.md` (phase checklist), `docs/whoop-parity.md` (protocol parity),
`docs/hardware-findings.md` (hardware-verified answers).

## What this repo is

A self-hosted WHOOP-band companion (the band works without a WHOOP subscription):

- `ios/` — SwiftUI iPhone app + local Swift packages (`Packages/`: BandProtocol, BandKit,
  Metrics, Store, SyncKit, AlarmKitBridge). Ingests live band data over BLE, derives
  minute metrics / sleep sessions, syncs to the server.
- `server/` — Rust workspace (icarus-api/core/db/jobs/push/server), Postgres via Docker.
- `web/` — Vite + React + TS (Lyra) dashboard, all planned pages + Playwright E2E.
- `shared/openapi.yaml` — API contract; drift-checked by both sides' tests.
- CI: 12 workflow files; docs/status.md records all phases 0–8 built and CI green.

Phases 0–8 (per git log + docs/status.md) are committed. **Not done**: deployment (no
host running), APNs push (client code written but commented `[push disabled]`, gated on an
APNs `.p8` key + signing capability), TestFlight (no ASC secrets), Apple Watch, passkeys.

## iOS environment facts (Caleb's machine)

- Toolchain: xcode-select points at CLT; **everything needs
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`** (xcodebuild, swift build/test).
- Phone: iPhone 17 Pro Max, UDID `00008150-00025C2C21D1401C`, bundle `com.cnbrown04.icarus`.
  Install: `xcrun devicectl device install app --device <udid> <DerivedData>/Build/Products/Debug-iphoneos/Icarus.app`.
  Launch needs the phone **unlocked**; user prefers to start the app themselves after install.
- App builds: `cd ios && xcodebuild -project Icarus.xcodeproj -scheme Icarus
  -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates build`.
- New files require `xcodegen generate` (project.yml) before xcodebuild sees them.
- **Tests**: use `ios/scripts/run_tests.sh [pkg…]` ONLY. It is strictly sequential with
  timeout + tree-kill recovery. Concurrent package tests race on shared `.build` dirs
  (packages depend on each other) and stall; killed runs orphan `swiftpm-testing-helper`
  and wedge later runs — the script sweeps orphans first. Stalls are fixed by this;
  don't reintroduce parallel test runs.
- On-device debug artifacts (DEBUG builds): `Library/Application Support/Icarus/` —
  `band_log.txt` (+ timestamped rotations, keep 24) via BandLogCapture, `debug_dump.json`
  (rewritten after each stored batch), `icarus.sqlite` (+ WAL; copies race with
  checkpointing — prefer the dump for consistency). Pull with
  `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer
  --domain-identifier com.cnbrown04.icarus --source … --destination …`.
- `DebugServer`: in-app HTTP (DEBUG only, port 8087) — `/db /historical /sleep /hr
  /minutes /events /frames /bands /log /healthz`. Over Wi-Fi the first connection usually
  works, then goes EHOSTUNREACH — retry with delays; USB devicectl is the reliable path.

## Band state (hardware-verified on Caleb's WHOOP 4.0, fw 41.17.x)

- Frame: `[0xAA][len u16 LE][crc8][type][seq][cmd][payload][crc32 LE]`; `Frame.payload`
  starts at frame byte 7. Metadata meta_type = `frame.cmd` (1=START 2=END 3=COMPLETE).
- The v24 record parser offsets are payload-relative (NOOP's frame-absolute minus 7):
  unix@4, hr@14, rr_count@15, rr_first@16, ppg@26/28, gravity@33, contact@48, gravity2@49,
  spo2@61/63, temp@65, ambient@67, led@69/71, resp@73, quality@75, min length 77.
- HISTORICAL_DATA_RESULT (cmd 23) ack = `[0x01 SUCCESS] + token` (OpenStrap-verified);
  only HISTORY_END is acked; HISTORY_COMPLETE ends the drain.
- Handshake order (hello-first, per OpenStrap §3 + NOOP): GET_HELLO → GET_CLOCK (logged
  "before SET_CLOCK" — the RTC persistence probe) → SET_CLOCK both forms (8-byte + legacy
  9-byte) *only when drift ≥ 2 s* (NOOP ClockPolicy) → GET_CLOCK (logged after) →
  [opt-in flood disable] → GET_DATA_RANGE (decoded: oldest…newest unix, ring W/U/T≈131072,
  "pages behind") → [armed alarm] → battery → TOGGLE_REALTIME_HR → SEND_HISTORICAL_DATA.
- SET_CLOCK on this fw latches only the 9-byte legacy form; the 8-byte form is ACKed but
  not latched (docs/hardware-findings.md Q5). Sending both is harmless.
- The strap's RTC **persists** across disconnects (observed drift 1 s on every reconnect).
- Drain rules: oldest-first; stop on HISTORY_COMPLETE / quiet 8 s / live edge (record
  within 15 s of now) / run cap 60 s (so sync never starves live HR); persist decoded
  records BEFORE acking a batch's trim (flush-on-ack); cadence = NOOP BackfillPolicy
  (15-min periodic floor, 90-s event floor, empty-streak backoff ×4 cap, auto-triggers
  skipped while the strap clock is untrusted).
- Full-history restore: `drainFullHistory()` rewinds the read cursor to the oldest banked
  extent (`W ≥ T ? W − T : 0`) via SET_READ_POINTER, then drains back-to-back until empty/
  COMPLETE/live edge. Safe to re-drain (OpenStrap §4.3).

## Hard-won lessons (do not regress)

1. **The strap records autonomously.** OpenStrap's PROTOCOL.md: "The band is a sensor pipe — it
   does no analytics on-device. It records raw + lightly-processed sensor records to flash and
   streams/relays them to a phone." Confirmed live 2026-10-19 evening: the app was killed
   17:25–21:14 and the strap had banked the whole window (drained later as records stamped
   20:00–21:23). Earlier records appearing only during "linked" windows reflected the drain
   cadence, not recording. Consequence: a killed app never loses strap-side data — it just
   arrives later, and the UI must show the strap→app sync so that arrival is visible.
   Flash is a ring (~131k records ≈ 36 h; OpenStrap: the ack cursor advances but the client
   never erases flash — re-draining with SET_READ_POINTER is safe).
2. Decoding timestamps off the full frame envelope latches garbage: header+CRC straddle
   words land inside the plausible-unix window (an EMPTY reply's straddle read as
   "1050 h ahead"; a real reply's as "26001 h ahead") and falsely pause all automatic
   drains. Timestamp scans run on payload bytes; `newestUnix` prefers the newest
   not-future word (NOOP semantics) — an any-scan variant was tried and reverted.
3. Deriving sleep per drain-batch with a sliding window spams `sleep_session` (a new
   start_ms key per flush). Derivation runs over the band's whole stored span (stable
   keys + ON CONFLICT replaces), skipped when a flush deduped to zero new rows.
4. Persist-then-ack is the durability invariant: acked batches flush to the store
   immediately (the strap's trim cursor advances on ack; don't hold a drain in memory).
5. The 0x2B realtime-raw flood: reference clients never disable it; NOOP's "R22Disable"
   is a WHOOP 5/MG feature-flag system (opcode 120), not this command. Icarus leaves it
   on; the opt-in lives in DeviceView → Experimental ("Disable raw sensor flood").
6. Dropped history must still reach the HR graph: drained records backfill
   `hr_sample`/`rr_interval` (same physiological gate + dedupe as realtime ingest) and
   recompute their minute metrics. The graph reads `hr_sample`, which only realtime
   ingest wrote — without the backfill, drained gaps stayed invisible forever.

## Current status (as of 2026-10-20 early)

- All packages green: BandProtocol 105, BandKit 154, Metrics 120, Store 95, SyncKit 58.
- Tabs: **Today · Alarms · Settings** (Trends removed; 7/30/90-day spans now live on the
  metric detail screens; Device is Settings → Band).
- Today page (rich): live HR + 15-min sparkline + today avg/max/coverage; RHR (night-window
  labelled) + 7-day trend; HRV RMSSD (+SDNN) + trend; stress value/band/average/peak/band
  minutes + per-minute area timeline + calibration progress; Apple-sleep-style HR **zone
  timeline** + zone-minute bars; sleep card with bedtime→wake, night RHR, RMSSD, vs-average
  duration; calories total/active/BMR.
- Calibration transparency: `StressCalibrationProgress` (7 nights required, 14-day lookback,
  12 five-minute night windows each, HR-only fallback) surfaced as "X of 7 nights" plus a
  per-night breakdown and what still needs collecting on Stress detail.
- Read-time timeline APIs live in Store/Dashboard (`HRZoneTimeline`, `StressTimeline`,
  `StressDaySummary`, `Dashboard.hrZoneTimeline/stressTimeline/stressCalibration`).
- Installed build includes: full-history drain (Band → History, live progress), live
  strap→app sync feedback (`BandEvent.drainProgress` → `LiveState.drainProgress`),
  whole-batch minute-metric backfill, multi-observer `onTierBChange`, Server sync
  renamed/clarified, Settings units/HRmax, raw data viewer, configurable retention, debug
  metrics inspector, and the rich Today page above.
- Not built (deliberate): Recovery and Strain scores. OpenStrap/analytics computes
  recovery/strain/sleep from published cited methods — porting those is the next health-metric
  body of work. Sleep stages, SpO₂ and respiratory rate are not derivable from this hardware
  (NOOP: respiration is not in the record; SpO₂ not recoverable from time-multiplexed PPG).
- Working tree committed; phone on `com.cnbrown04.icarus` build with all of the above.
- Pending feature follow-ups: none blocking. Open hardware questions: SET_READ_POINTER's exact
  units + re-ack replay behavior on the live strap (probe via the Band → History drain).
- Bigger backlog (not started): server deployment, APNs push enablement, TestFlight,
  WHOOP-derived HRmax/calorie cross-check, SpO₂/temp/resp converted displays (gated on
  verified raw→unit mappings), watch app, passkeys.
