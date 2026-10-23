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
- **Hardware finding 2026-10-23 (contradicts the "re-drain is safe" assumption below):** a
  full-history restore at 00:28 (cursor 74268→0) replayed only ~50k records, starting
  2026-10-22 10:49 EDT. The 2026-10-21 19:35 → 10-22 10:49 span, which the old build had
  drained and ACKED but mostly never stored, did not come back. Treat acked data as gone:
  persist-then-ack is the only protection.
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
3. Never derive per drain-batch. Batches arrive every ~0.4 s; deriving sleep + metrics over
   the whole span per batch took ~4 s each, queued the backlog in memory behind already-sent
   acks, and iOS killed/relaunched the app every ~16 min — so the store kept only ~3 of every
   16 minutes of history (all data before 2026-10-23 is chunked like that). Now: per batch
   only `HistoryPipeline.persist` (insert rows); `HistoryDerivationScheduler` derives once,
   4 s after a drain settles, over the drained range (sessions starting ≥ 24 h before it are
   REPLACED — stale keys and their hypnograms deleted).
4. Persist-then-ack is the durability invariant, enforced in BandKit: with a
   `HistoricalSink` installed, `TierBController` awaits the store BEFORE writing
   HISTORICAL_DATA_RESULT; a failed store leaves the batch unacked (the strap re-sends it).
   Handing records to the app and acking straight away was NOT durable.
7. The strap records 24/7, so "contiguous worn data touching 21:00–06:00" is not sleep (that
   rule made a 20 h "night"). Sleep windows come from `SleepDetector` (NOOP Stage 0 port:
   gravity stillness spine + HR confirmation + 60 min/16 h bounds + off-wrist + daytime nap
   guard + one main sleep per noon-to-noon day). `SleepDeriver` only summarises a window.
   Validated on the 2026-10-21 night: 01:13→09:42 EDT vs. the wearer's "~2:00→9:30".
8. Local time = the DEVICE zone. Profiles used to be saved as hard-coded America/Chicago on
   an Eastern phone (every time was an hour early); launch now syncs `profile.tz` to
   `TimeZone.current` and re-derives sleep when it changes. Headline sleep = time asleep
   (staged light+deep+REM), not bed→wake.
5. The 0x2B realtime-raw flood: reference clients never disable it; NOOP's "R22Disable"
   is a WHOOP 5/MG feature-flag system (opcode 120), not this command. Icarus leaves it
   on; the opt-in lives in DeviceView → Experimental ("Disable raw sensor flood").
6. Dropped history must still reach the HR graph: drained records backfill
   `hr_sample`/`rr_interval` (same physiological gate + dedupe as realtime ingest) and
   recompute their minute metrics. The graph reads `hr_sample`, which only realtime
   ingest wrote — without the backfill, drained gaps stayed invisible forever.

## Current status (as of 2026-10-20)

- All packages green: BandProtocol 105, BandKit 154, Metrics 132, Store 102, SyncKit 58.
- **Navigation**: bottom tabs **Home + Today**; **Settings (gear) and Alarms (bell) are top-right
  toolbar buttons** opening modal sheets (rooted in NavigationStack with Done).
- **Home** (summary): greeting + live pill; Last night (duration, quality, bedtime→wake, night RHR,
  compact stage bar; tap → Sleep); vitals row (RHR / HRV / stress incl. calibrating X/7); today's
  activity (zones + calories); next alarm; one-line server-sync status.
- **Today** (decluttered): live HR hero + one stat line; 2×2 tiles (RHR, HRV, Stress, Calories);
  zone timeline + slim zone strip; stress timeline + band strip; compact sleep card. Detail
  explainers live only on the detail screens.
- **Sleep staging**: faithful port of NOOP `SleepStagerV2` (30 s epochs; gravity movement/jerk,
  HR mean/flatness, R-R RSA regularity, cycle prior + REM-latency guard, Viterbi smoothing).
  Runs during sleep derivation, persisted in `sleep_stage_segment` (schema v4), keyed by
  (band_id, session_start_ms), re-derived idempotently; totals + efficiency exclude wake.
  UI: hypnogram (Wake/REM/Light/Deep) on Sleep (latest + per-night detail), compact stage bar
  on Home.
- **Sleep data audit (2026-10-20, our own DB)**: `resp_rate_raw` constant 3073 (165k records) =
  fixed trailer, NOT respiration; `signal_quality` constant 3074; `spo2_red/ir` constant
  633/636 → SpO₂ not recoverable; `ppg_green` varies (real); `skin_temp_raw` varies (relative
  only); **gravity + R-R (≈87 % of sleep records) are the usable staging inputs** — exactly
  what NOOP V2 consumes. Respiration regularity is recovered from R-R (RSA), per upstream.
- Installed build includes everything above plus the full-history drain, live drain progress,
  whole-batch metric backfill, multi-observer onTierBChange, Server-sync clarity fixes,
  Settings units/HRmax, raw viewer, configurable retention, debug inspector.
- Not built (deliberate): Recovery and Strain scores (next body of work; OpenStrap/analytics has
  published-method implementations); sleep-stage accuracy is approximate (NOOP: ~65–73 % epoch
  ceiling EEG-free, not PSG-validated).
- Working tree committed; phone on `com.cnbrown04.icarus` build with all of the above.
- Pending feature follow-ups: none blocking. Open hardware questions: SET_READ_POINTER's exact
  units + re-ack replay behavior on the live strap (probe via the Band → History drain).
- Bigger backlog (not started): server deployment, APNs push enablement, TestFlight,
  WHOOP-derived HRmax/calorie cross-check, SpO₂/temp/resp converted displays (gated on
  verified raw→unit mappings), watch app, passkeys.
