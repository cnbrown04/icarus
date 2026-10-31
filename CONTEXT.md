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
- **Record fields (2026-10-23, OpenStrap PROTOCOL.md §5 + 44k real frames):** the v24 "contact"
  byte is a contact-QUALITY value, not a wear flag; on-wrist = HR present (`SleepRecord.isOnWrist`).
  The second gravity triplet is a byte-identical mirror the strap sends. v25 records are a PPG
  waveform stream whose every second duplicates a v24 record: only the timestamp is decoded and
  they are not stored (NOOP's v25 "gravity" was retracted by OpenStrap; real data agrees).
- **Hardware finding 2026-10-23 (contradicts the "re-drain is safe" assumption below):** a
  full-history restore at 00:28 (cursor 74268→0) replayed only ~50k records, starting
  2026-10-22 10:49 EDT. The 2026-10-21 19:35 → 10-22 10:49 span, which the old build had
  drained and ACKED but mostly never stored, did not come back. Treat acked data as gone:
  persist-then-ack is the only protection.
- **Hardware findings 2026-10-30 (four on-band probes; logs in the session, fw 41.17.x).**
  1. **The ring is PAGES of ~9 records.** HISTORICAL_DATA_RESULT tokens are `[page u32][next u32]`
     (`34 E8 01 00 01 00 00 00`); one drain advanced 381 pages for 3,487 records, and the backlog grows
     ~1 page per 9 s. T = 131072 pages ≈ 1.2 M records ≈ **13.6 days** (WHOOP says 14) — NOT "131k ≈ 36 h".
  2. **Command frames must be padded to a 4-byte inner** (`[type][seq][cmd][payload]`, OpenStrap `pad4`).
     The strap silently drops unaligned commands. `FrameCodec.encodeCommand` pads now. This is why the
     bare-u32 SET_READ_POINTER (inner 7) never did anything, and why the 8-byte SET_CLOCK (inner 11) was
     "ACKed but not latched" (hardware-findings Q5).
  3. **GET_DATA_RANGE words** (raw offsets, u32 LE): 10 = ?, **14 = read cursor** (`DataRange.readCursor`;
     equals the next ack token's first word; SET_READ_POINTER writes it; persists across connections),
     18 = W (write), 22 = U (trails the cursor by a few pages), 26 = 1 (unknown), 30 = T.
  4. **No rewind is possible with known commands.** Padded SET_READ_POINTER moves the read-cursor word
     exactly as asked, but the next drain still streams from the strap's internal position (just after the
     last acked page) — backwards (below U), forwards (skip to W − 1), and after ABORT_HISTORICAL_TRANSMITS
     (cmd 20) alike. OpenStrap's client defines `cmd_set_read_pointer` but never calls it. So **acked data
     cannot be re-downloaded**: persist-then-ack remains the only protection, and every earlier "restore"
     just drained the unacked U→W backlog (10-28: 10,967 pages ≈ 107k records).
- History button (Band screen) = "Sync all pending band data": back-to-back drains of the unacked
  backlog until caught up (`drainFullHistory()` keeps its name; no rewind). Gaps: 10-21/22 were acked
  unstored by old builds (gone); 10-24…26 the band was not worn.

## Hard-won lessons (do not regress)

1. **The strap records autonomously.** OpenStrap's PROTOCOL.md: "The band is a sensor pipe — it
   does no analytics on-device. It records raw + lightly-processed sensor records to flash and
   streams/relays them to a phone." Confirmed live 2026-10-19 evening: the app was killed
   17:25–21:14 and the strap had banked the whole window (drained later as records stamped
   20:00–21:23). Earlier records appearing only during "linked" windows reflected the drain
   cadence, not recording. Consequence: a killed app never loses strap-side data — it just
   arrives later, and the UI must show the strap→app sync so that arrival is visible.
   Flash is a ring of 131072 pages × ~9 records ≈ 13.6 days, but only the UNACKED part can ever be
   drained: no known command makes the strap re-send acked pages (2026-10-30 findings).
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

## Scores (2026-10-23)

- `Database.dailyScores(day:in:)` (Store/DailyScores.swift) feeds the Overview dials and
  Sleep (performance, need, debt, respiratory rate, regularity). Metrics ports: Recovery/Strain
  (NOOP), SleepNeed/SleepRegularity (NOOP debt + OpenStrap need/SRI), RespiratoryRate (OpenStrap RSA).
- Strain uses Banister: Edwards zones start at 50 % HRR and scored a normal day 0.
- Recovery baseline is one entry per local day over 60 days; shown as "Calibrating · n/14" until 14
  (`RecoveryReadout` in HealthModel.swift is the one place that logic lives).
- Nightly RHR/HRV baselines come from the main sleep that ended on the day (fallback
  00:00–06:00). Session RHR = lowest gated 5-min mean; RMSSD = mean of 5-min windows, never across gaps.
- Sleep edits (`sleep_edit`, v6) are replayed onto every re-derivation.
- **Stress (algo v3, 2026-10-30).** v1 scored awake windows against the SLEEP baseline (median ≈ 62 bpm,
  tiny MAD), so 49 % of the user's scored minutes were ≥ 95. Now: baseline = awake windows (outside
  sleep, not exertion) of the 14 prior local days; a day qualifies with 24 HR windows (12 for the R-R
  baseline); sigma floors 4 bpm / 0.15 lnRMSSD; stress = round(100·Φ(raw − 0.44)) so the awake median
  scores ≈ 33; hr_only weight 0.5; a valid-R-R window falls back to hr_only while the R-R baseline
  calibrates. With stimulant windows (medications), medicated and unmedicated windows get their own
  baselines (≥ 5 qualifying days each), else the combined one. Rust mirror (`icarus-core`) has the
  non-medication rules only and was edited without `cargo` locally — CI is its first compile.
- Stale minute rows (old algo, or `algo_version = 0` set by `markStressStale` after a medication edit)
  rebuild via `MetricsWorker.recomputeStaleRows` — at launch and right after medication edits.
- **Medications are a calculation input, not a tracker** (user's call): Settings → Medications only.
  Scheduled doses are assumed taken (opt-in "Skip a day"); as-needed doses are logged there. They feed
  the medicated stress baseline and the "stimulant within 1 h of sleep onset" line on Sleep/Recovery.

## Current status (as of 2026-10-30)

- All packages green (2026-10-30): BandProtocol 117, BandKit 172, Metrics 336, Store 197, SyncKit 59,
  AlarmKitBridge 27. App + test targets build for device (no iPhone simulator installed on this Mac).
- **Navigation (2026-10-31, Apple Health–style; plan `~/.claude/plans/humming-watching-raven.md`)**: tabs
  **Summary · Sleep · Strain · Browse**; ONE profile button (`ProfileSheet`: profile, band, medications,
  alarms, display, coaching, server, storage, advanced, about) trails every tab root. Rule: each piece of
  information has exactly one page. Pages link by `AppRoute` (`Screens/AppRoute.swift`); `AppRouteDestination`
  is the only route → page switch, registered once per tab stack in `MainTabView`.
  - **Summary**: three rings (Sleep %, Recovery, Strain + coach band) → Sleep tab / Recovery page / Strain tab;
    key metrics (`MetricRow`: resting HR, HRV, stress, respiratory rate) + Vitals; ≤ 2 weekly highlights;
    rows only when actionable (journal yesterday, band not connected, re-pair, storage).
  - **Sleep** owns sleep: D/W/M/6M (hypnogram / stacked nightly bars), stages, scores, tonight's planner, nights.
  - **Strain**: strain ring, live HR → Heart rate page, zones, calories, today's workouts, "+" records one.
  - **Browse**: every metric by category (no values) + Journal, Insights, Weekly assessment.
  - **Metric page** (`MetricDetailView`, one template for every metric but sleep): D/W/M/6M, header follows
    the drag, details (avg/min/max/change), one per-metric section, and the "About" disclosure — the ONLY
    place for method/estimate text.
  - Data: every screen reads `MetricSeries` (`metricLatest/metricDays/metricIntraday/heartRateRange`) over
    the `daily_score` cache (v11, refreshed per day after drains, backfilled 180 d at launch). Resting HR/HRV
    come from the main sleep session; sleep need/debt from the SleepDebt ledger — one source each.
  - Design tokens: `MetricCategory` colors (heart pink, activity orange, recovery green, sleep teal, mind
    purple, respiratory blue) only on category glyphs and chart series; `Symbol` (one SF Symbol per concept);
    `Font.figure*`; `.metricChartStyle()`; `EmptyStateRow`. Appearance follows the system.
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
