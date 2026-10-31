# WHOOP Capability Parity

What the WHOOP/NOOP ecosystem can do with a WHOOP 4.0 strap over BLE, what Icarus does today, and the gap between them. Written 2026-10-17 against the code on `main` (BandProtocol, BandKit, LiveState, Ingestor) and the golden frames in `shared/golden/frames.json`.

Every fact carries a source: `[S8]` bWanShiTong, `[S11]` jmooves, `[S12]` NOOP, `[S15]` my-whoop (ids from PLAN.md §22). Items marked **verified on strap** were confirmed this session on a real band; items marked [Unverified] must be checked on hardware per PLAN.md §5.5 and `docs/hardware-test.md`. Icarus status is read from the code, with file references.

## 1. Ground Rules

- Icarus implements only what PLAN.md §5.3 documents, from published community sources. We never decompile WHOOP software and never copy community code (PLAN.md §6.1). This parity doc tracks capabilities, not code.
- Destructive commands stay denied at the type level (`SafeCommand.deniedOpcodes`, PLAN.md §5.3.5). New capability commands (1, 7, 63, 98) are additions to the *whitelist*, not exceptions to the denylist.
- Frame byte offsets in this doc follow the repo convention used by `RealtimeHeartRate.parse` (`frame[12]` = bpm): byte N of the fully reassembled wire frame, counting the 4-byte envelope header. `FrameCodec.decode` returns `payload` starting at frame byte 7, so frame offset N maps to payload offset N − 7.
- Every command carries at least one payload byte. A command with an empty payload is ACKed by the strap but silently discarded by its command processor — captured official-app frames all carry a dummy byte (NOOP [S12], verified on strap).

## 2. Parity Table

| # | Capability | WHOOP/NOOP Reference | Icarus Status | Notes |
|---|---|---|---|---|
| 1 | Live HR + R-R via standard HRS `0x180D`/`2A37`, unbonded | SIG spec [Official]; NOOP calls it the reliable source [S12] | **Done** | Verified on strap. Parser in `HeartRateMeasurement.swift`; ~1 Hz without bonding. |
| 2 | Standard battery service `0x180F` discovery | PLAN.md §5.3.1 | **Partial** | Discovered in `CoreBluetoothTransport`, but never read — and two sources say `0x2A19` reads a constant 100% stub [S11][S12]. Real battery comes from cmd 26. |
| 3 | Custom service discovery + bonding | Bond via confirmed `GET_BATTERY_LEVEL` (26) write to `61080002` [S12][S15] | **Done** | Verified on strap. CCCDs on before the bond write; handshake starts after ACK + 3 subscriptions (`CoreBluetoothTransport.swift`). |
| 4 | Frame envelope + BLE reassembly | `[0xAA][len u16 LE][crc8][type][seq][cmd][payload][crc32]` [S8][S11][S12][S15] | **Done** | `FrameCodec`/`FrameReassembler`; length-based, never 0xAA resync (PLAN.md §5.3.3). |
| 5 | Per-connection handshake | NOOP: hello → set clock → get clock → disable raw → data range [S12] | **Partial** | Icarus runs GET_HELLO (35) → GET_CLOCK (11) → GET_DATA_RANGE (34), all `[0x00]`, verified on strap. Skips SET_CLOCK (§3.3) and the raw-stream disable (§3.4). |
| 6 | `SET_CLOCK` (cmd 10) — RTC set | 8-byte layout [S12] vs 5-byte [S15-community variant] | **Missing** | The RTC trap (§3.3). |
| 7 | Live realtime HR, type 40 on `61080005` | `TOGGLE_REALTIME_HR` (3) + 30 s re-arm keep-alive [S12] | **Done** | Verified on strap. `frame[12]` bpm, `frame[13]` rr_count, `frame[14..]` RR u16 LE ms (`RealtimeHeartRate.swift`). |
| 8 | Battery via cmd 26 | u16 ÷ 10 % [S11][S15] | **Done** | Verified on strap. `BatteryLevel.percent` reads u16 LE at decoded payload offset 2 — replies lead with a response counter + status byte (live capture `03 01 D8 03 …` → 984 → 98.4 %); the u16 is NOT at offset 0 as the golden test vector had assumed. Polled at most every 10 min (PLAN.md §6.5). |
| 9 | Extended battery info (cmd 98) + battery events on EVENT frames (`battery_pct`/`battery_mV`/charging) | NOOP decoded keys [S12] | **Partial** | Cmd 98 (`[0x00]`) is sent on the 10-min battery limiter after cmd 26 and its reply logged raw; fields not decoded (layout [Unverified]). EVENT id 3 still uses the old percent guess and its raw payload is logged. |
| 10 | Band haptics: `RUN_HAPTICS_PATTERN` (79) / `STOP_HAPTICS` (122) | `[patternId, loops, 0, 0, 0]` [S12] | **Done** | Verified on strap (pattern 2). Rhythm engine in `TierBController` + `Rhythm.swift`. |
| 11 | Band firmware alarm: `SET_ALARM_TIME` (66) | `[0x01] + unix u32 LE + [0,0,0,0]`, golden-validated [S8] | **Done** | Verified on strap. Strap-driven alarm event (57) triggers re-arm of the next occurrence (PLAN.md §9.5). `GET_ALARM_TIME` (67) is read back once after each arming and the match logged (§3.11); reply offset [Unverified]. |
| 12 | Band events: wrist on/off, double tap, charging, haptics fired, unknown ids kept | EVENT ids in PLAN.md §5.3.4 [S11][S12] | **Partial** | Verified on strap (wrist on/off, double tap, hapticsFired; `unknown(100)` seen in logs and kept). Charging on/off (7/8) now emit a charging state and refresh the battery. Battery payload bytes are logged raw, not decoded. Unknown ids are histogrammed in Debug. |
| 13 | Historical data offload: type 47 drain, `SEND_HISTORICAL_DATA` (22), `HISTORICAL_DATA_RESULT` (23) + token echo, METADATA (49) batches | The strap's 14-day biometric store [S11][S12][S15] | **Missing** | The largest gap (§3.1, §3.2). |
| 14 | Realtime raw stream: type 43 (~1.9 KB, IMU/optical) via `SEND_R10_R11_REALTIME` (63) | NOOP sends `[0x01]`/`[0x00]` [S12] | **Missing** | Mostly deliberate: Icarus never turns the flood on and never sends cmd 63 — but it also never *disables* it in the handshake (§3.4). |
| 15 | Console logs (type 50) on `61080005` | NOOP decoded `console_logs` [S12] | **Partial** | Type-50 frames decode to printable lines (`ConsoleLog`) and show in Debug → Band console (last 200). Text layout [Unverified] on hardware. |
| 16 | Memfault diagnostics on `61080007` | [S8][S11][S15] | **Missing** | Not subscribed, deliberately (§3.5). A fourth CCCD changes the bond-order and failure path, which only hardware can test. Next step: a hardware session with the change behind the Tier B toggle. |
| 17 | Version info: `GET_HELLO` reply (fw version/name), `REPORT_VERSION_INFO` (7) | NOOP's `fw_harvard`/`fw_boylston` decoded keys [S12]; PLAN.md §5.5 item 7 | **Partial** | GET_HELLO is sent but its reply payload is discarded. Cmd 7 is not in `SafeCommand`. |
| 18 | Link keep-alive `LINK_VALID` (cmd 1) | NOOP [S12] | **Partial** | `LINK_VALID` (cmd 1, `[0x00]`) written every 30 s while `.ready`, fire-and-forget, cancelled on disable/close. Failures are counted and shown on Device; no reconnect yet. Layout and cadence [Unverified]. |
| 19 | Sleep detection / sleep staging from band records | Derived from type-47 records (skin contact, HR, resp rate, skin temp over night windows) [S11][S12] | **Missing** | Depends on item 13. |
| 20 | Historical IMU stream (type 52) | [S12] | **Missing** | Optional; large frames, little near-term value. |
| 21 | Debug surface: raw frame log + NDJSON session export | Fixture recorder (PLAN.md §7.2) | **Done** | `FrameLog` (last 10 min), scrubbed export. Extend for type 47/49 debugging (§3.1). |

## 3. Missing And Partial Items In Detail

### 3.1 Historical Data Offload (Type 47) — the Big One

**What it is.** The strap keeps a 14-day rolling biometric store and can drain it on request. This is the only path to WHOOP-grade history (HR, PPG, SpO₂, skin temp, respiration, gravity/IMU) without the official cloud — and the substrate for sleep detection (§3.9) [S11][S12][S15].

**What Icarus needs:**

1. **Builders** in `BandCommand.swift` for `SEND_HISTORICAL_DATA` (cmd 22, payload `[0x00]`) and `HISTORICAL_DATA_RESULT` (cmd 23). Both opcodes are already in `SafeCommand` — only the builders are missing.
2. **Drain state machine** in `TierBController` (a task alongside `realtimeTask`, with its own generation so disable/teardown cancels it):
   - Send `SEND_HISTORICAL_DATA` (22, `[0x00]`) as a confirmed write to `61080002` and await its COMMAND_RESPONSE.
   - Records arrive in batches as type 47 (0x2F) frames on `61080005`. Frames can be large and must arrive through the existing length-based reassembler.
   - After each batch, the strap sends a METADATA frame (type 49 / 0x31) on the same characteristic carrying an **8-byte batch token at inner[13:21]** (same frame-offset convention as above).
   - Echo that token back: `HISTORICAL_DATA_RESULT` (23) with payload `[0x01] + token(8 bytes)`, written **confirmed (`.withResponse`)**, as a *fire-and-forget* write — it is an ACK, not a request; do not wait for a COMMAND_RESPONSE for it, or the drain stalls. Byte-exact echo, no reordering of the 8 bytes. If the ACK is not written (or written wrong), the strap **replays the same batch**.
   - The drain is finished when: the strap says drained, **8 s pass with no type-47 traffic**, or a record's timestamp is **within 15 s of now**.
3. **Rate limit and guards** (PLAN.md §6.5): offload at most every 15 min, matching NOOP's cadence [S12]. Persist drained records to the store in batches, mirroring `Ingestor`'s flush discipline (PLAN.md §7.3).

**Gotchas:**

- **Never re-run the handshake mid-offload.** Re-blasting the handshake (GET_HELLO/GET_CLOCK/GET_DATA_RANGE) while a drain is in progress makes the strap refuse type-47 frames until the next connection. `TierBController.connectionOpened` is already guarded by `handshakeStarted` once per connection — keep it that way, and do not add a retry that re-runs the handshake.
- The command queue serialises one command at a time. The drain ACK is not a queued command; it must bypass the `Waiter` machinery or it will deadlock against the in-flight `SEND_HISTORICAL_DATA` reply path.
- Drain competes with the 30 s realtime re-arm for the link. Pause `realtimeTask` while draining (the strap may interleave type 40 frames; the parser ignores nothing, so keep them flowing to `RealtimeHeartRate` but expect gaps).
- Golden vectors exist: the eight `historical_seq0c_*` frames in `shared/golden/frames.json` pass both checksums and are good reassembly tests, but note their `seq` byte is 0x0c — an **older record version (12)** than the version-24 layout below. The decoder must switch on the seq byte, and v12 fields do not line up with v24 after the timestamp.

### 3.2 Type-47 Record Layout (Version 24)

Version of a record = the frame's `seq` byte. Version 24 is the WHOOP 4.0 DSP record, verified on real records this session. Offsets are frame bytes (see §1 Ground Rules):

| Offset | Size | Field | Notes |
|---|---|---|---|
| 11 | 4 | unix u32 LE | Record timestamp (needs a latched RTC, §3.3) |
| 21 | 1 | heart_rate u8 | bpm |
| 22 | 1 | rr_count u8 | R-R values follow per version-24 layout [Unverified exact continuation] |
| 33 / 35 | 2 / 2 | ppg_green / ppg_red_ir u16 LE | Optical samples |
| 40 / 44 / 48 | 4 each | gravity x/y/z f32 LE | First accelerometer triplet |
| 55 | 1 | skin_contact u8 | 0 = off-wrist — the key sleep-staging input |
| 56 / 60 / 64 | 4 each | second gravity triplet f32 LE | Second IMU sample in the record |
| 68 / 70 | 2 each | spo2_red / spo2_ir u16 LE | Ratio-of-rations derived SpO₂, empirical only (PLAN.md §5.4) |
| 72 | 2 | skin_temp_raw u16 LE | Raw; scaling [Unverified] |
| 74 / 76 / 78 | 2 each | ambient / led_drive u16 LE | Sensor context |
| 80 | 2 | resp_rate_raw u16 LE | Raw respiration |
| 82 | 2 | signal_quality u16 LE | PPG quality gate — drop or down-weight records above a threshold |

**What Icarus needs:** a `HistoricalRecord` decoder in BandProtocol keyed on `seq` (version), returning a struct with the fields above and `.unknown(version)` skipping. Unit tests: golden v12 frames assert "parse fails cleanly / skips", synthesized v24 vectors assert field extraction. Add the decoder output to the Debug screen (record count, version histogram, span) before any metrics work — it is the only way to debug a drain.

**Gotchas:** record length varies by version (~96–104 B, PLAN.md §5.3.3) and frames span notifications; raw offsets like `0x66` inside the payload make any 0xAA resync corrupt records (already handled). Skin temp and SpO₂ scalings are empirical; keep them raw in the store and convert at the metrics layer (PLAN.md §8.5).

### 3.3 SET_CLOCK (Cmd 10) — the RTC Trap

**Status:** Icarus deliberately skips SET_CLOCK today (`BandCommand.swift` TODO, PLAN.md §5.3.4): its payload is undocumented and the two community references disagree — 8 bytes `[secs u32 LE][subsecs u32 LE]` (NOOP [S12]) vs 5 bytes `[secs u32 LE][0x01]` (andyguzmaneth, community).

**Why it matters:** a wrong-length payload is **ACKed but NOT latched**. The strap looks fine while its RTC is unset, so historical record timestamps and the firmware alarm drift. This is a silent-failure trap: every handshake "succeeds" while the data is wrong.

**What Icarus needs:**

1. A `setClock(unix:)` builder, defaulting to the 8-byte NOOP layout.
2. Latch verification: send SET_CLOCK, then GET_CLOCK (11) and compare the reply against our time. Only mark the clock set when the echo agrees within a tolerance; if it does not, try the 5-byte variant once, verify again, and surface a `tierBFailure` if neither latches. Cache the working layout per firmware version (PLAN.md §7.2 step 2 says exactly this).
3. Insert into the handshake between GET_HELLO and GET_CLOCK, and re-send on the `rtcLost` event (id 13, already parsed in `BandEventKind`).

**Gotchas:** alarm arming is specified in UTC "after a successful SET_CLOCK" (PLAN.md §9.5) — until the latch check exists, `armedAlarm` should not be trusted to fire at the wall-clock time. u32 unix secures alarms until 2106; the existing `rearmNext` bound already handles it.

### 3.4 Realtime Raw Stream (Type 43, Cmd 63)

~1.9 KB frames of IMU/optical data on `61080005`, controlled by `SEND_R10_R11_REALTIME` (cmd 63, `[0x01]` on / `[0x00]` off) [S12]. Icarus never sends cmd 63, so the stream stays off — mostly the right call (battery, bandwidth, background wake-up budget PLAN.md §6.4).

**What Icarus needs (small):** send cmd 63 `[0x00]` once in the handshake, as NOOP does (PLAN.md §7.2 step 4), so a strap that has the stream on from a previous app's session does not flood the link after we connect. Optionally add `toggleRealtimeRaw(on:)` to the whitelist behind a Debug-only switch later. Keep type 43 frames out of `FrameLog`'s default path (capacity churn) unless debugging.

### 3.5 Console Logs (Type 50) And Memfault Diagnostics (61080007)

**Status:** `PacketType.consoleLogs` (0x32) is decoded and dropped; `61080007` is never subscribed (`CoreBluetoothTransport.customNotifyUUIDs`), even though `FrameLog.recordedCharacteristics` already whitelists the id.

**What Icarus needs:**

1. Add `61080007` to `customNotifyUUIDs` (subscribe it in setup; it is a notify characteristic like the others). Gate behind the existing Tier B toggle — setup failure there must not take down the 03/04/05 path (make a missing 07 non-fatal, unlike 03/04/05).
2. Console logs: in `TierBController.receive`, route type-50 frames into a bounded log (new `BandLog` channel or a small ring in `FrameLog`) and surface the last N lines in the Debug screen. NOOP decodes these as strap console output [S12]; they are the fastest way to see firmware-side errors during hardware sessions (`docs/hardware-test.md`).
3. Memfault: buffer raw chunks (they are coredump/metrics blobs, not text). Minimum viable: count and export them in the NDJSON session so a hardware run can attach them to an issue.

**Gotchas:** the subscribe-order requirement (CCCDs before the bond write) stays; memfault notify must also come on before the bond write or it will be rejected like the others on an unbonded link. Console frames can be large; the reassembler handles it, but confirm the length header matches on real traffic.

### 3.6 Version Info (GET_HELLO Reply, REPORT_VERSION_INFO 7)

**Status:** the handshake sends GET_HELLO (35) but `connectionOpened` discards the reply frame entirely. The reply carries firmware version/name — NOOP's decoded `fw_harvard`/`fw_boylston` keys [S12]. `REPORT_VERSION_INFO` (7) is not in `SafeCommand` at all. `docs/hardware-findings.md` asks for firmware per run and there is no automatic source.

**What Icarus needs:** decode the GET_HELLO reply payload into a `BandIdentity` (firmware name/version strings; exact layout [Unverified] — capture on hardware and pin it), persist it with the remembered band, show it on the Device screen, and include it in the NDJSON export header (scrubbed of serials, per PLAN.md §7.2). Add `reportVersionInfo = 7` to `SafeCommand` with a `[0x00]` builder for the explicit query path.

**Gotchas:** device identity strings may carry serials — route through the export scrubber, never raw-copy into fixtures (NOOP's warning, PLAN.md §7.2).

### 3.7 Extended Battery Info (Cmd 98) And Battery Event Payloads

**Status:** battery arrives only from a cmd 26 poll, at most every 10 min (PLAN.md §6.5). NOOP additionally reads extended battery info (cmd 98) and decodes battery events on EVENT frames carrying `battery_pct`, `battery_mV` and charging state [S12].

**What Icarus needs:**

1. Decode the EVENT (0x30) payload for event id 3 (`batteryLevel`) and ids 7/8 (charging on/off): extract percent/mV/charging and emit a richer `BandEvent.battery` variant. Today `BandEventKind.batteryLevel` reaches LiveState as a bare event with the payload discarded.
2. Add cmd 98 to `SafeCommand` with a `[0x00]` builder and decode its reply (layout [Unverified]; capture on hardware). Poll it on the same 10-minute limiter as cmd 26.
3. Feed mV + charging into the Device screen (charging state already has events; wire them to `batteryPercent` refresh instead of waiting for the next poll).

**Gotchas:** one report says cmd 26 is silent on some recent firmware [S12] — if the poll times out, fall back to event payloads rather than showing "no battery".

### 3.8 Link Keep-Alive (LINK_VALID, Cmd 1)

**Status:** nothing. NOOP sends `LINK_VALID` (cmd 1) to keep the strap-side link state alive [S12]. Icarus only re-arms the realtime HR stream every 30 s, which is a stream keep-alive and doubles as traffic, but a strap that drops the custom link when idle is exactly the kind of failure that shows up as "connected but silent".

**What Icarus needs:** a `linkValid()` builder (cmd 1, `[0x00]`), sent on a timer (NOOP's cadence [S12], [Unverified] exact interval — start at 30 s alongside the realtime re-arm and measure), while `.ready`. On repeated timeouts, treat the link as dead and force the transport to reconnect instead of waiting for CoreBluetooth's own disconnect callback.

**Gotchas:** keep it under the Tier B off switch (it is periodic custom traffic, so it must stop when Tier B stops — put it in a `Task` cancelled in `setEnabled(false)`, like `realtimeTask`).

### 3.9 Sleep Detection And Sleep Staging

**Status:** not implemented, and the largest product-level gap. WHOOP derives sleep stages from the biometric stream; community projects approximate it from type-47 record fields — skin contact (off-wrist gaps), heart rate, respiration rate and skin temp patterns over night windows [S11][S12].

**What Icarus needs (after §3.1–§3.3):**

1. Drain at night: schedule an offload when the strap reports `wristOn` after a long off-wrist period, or on first morning connect. The 14-day store means nothing is lost if the app was dead overnight.
2. Night-window assembly: group type-47 records by (band, sleep session) using skin_contact 0/1 transitions to find the in-bed window; compute per-minute aggregates (mean/HRV-proxy from R-R, resp rate, skin temp delta, signal-quality-weighted PPG).
3. Staging rule engine: heuristic classifier (wake/light/deep/REM) from those aggregates, versioned like every other derived metric (PLAN.md §8.5), stored in `minute_metrics`-style tables, labelled "estimate" (PLAN.md §6.5).
4. UI: a sleep card on Today, clearly marked heuristic. Never a medical claim.

**Gotchas:** timestamps depend on a latched RTC (§3.3) — records offloaded from a strap whose RTC was never set will land hours off and corrupt night windows. Validate against the signal_quality gate (§3.2) so bad PPG minutes don't drive staging. This is derived from our own measurements of our own hardware, so no WHOOP API data is involved (PLAN.md §6.3).

### 3.10 Historical IMU Stream (Type 52)

Not implemented [S12]. Large binary frames, no near-term consumer in Icarus. Keep out of scope; revisit only if a derived metric needs high-rate acceleration. Do not add cmd support to `SafeCommand` until then.

### 3.11 Partial Items Worth Closing Cheaply

- **GET_DATA_RANGE reply discarded** (`TierBController.connectionOpened` drops the reply frame). Decode it — it describes the strap's history window and is the natural precondition check for an offload (§3.1). Layout [Unverified]; capture on hardware.
- **`GET_ALARM_TIME` (67) never sent in production.** After arming (§3.11 of PLAN.md §9.5), read back once to confirm the latch, mirroring the SET_CLOCK verification pattern.
- **Unknown event id 100** observed in logs. Keep `.unknown(id)` handling (already correct), and add an event-id histogram to the Debug export so new firmware events get named from real captures.
- **Standard battery stub**: `0x180F` discovery is dead weight today; either read `0x2A19` once for completeness or document it as intentionally ignored (PLAN.md §5.3.1).

## 4. Suggested Implementation Order

Prioritized toward sleep detection first, then richer device info, then diagnostics. Effort: S = a day, M = a few days, L = a week or more.

| Step | Item | Effort | Why here |
|---|---|---|---|
| 1 | Historical drain state machine + builders 22/23 + token echo (§3.1) | **M** | Everything downstream depends on it; the state machine and ACK path are the hard part. |
| 2 | Type-47 version-24 record decoder + Debug surfacing (§3.2) | **M** | Makes step 1 observable on hardware; golden v12 frames pin the skip-path. |
| 3 | SET_CLOCK with latch verification (§3.3) | **S** | Without it, record timestamps and alarms drift silently — blocks trustworthy sleep windows. |
| 4 | Sleep detection/staging pipeline (§3.9) | **L** | The priority feature; needs 1–3. |
| 5 | GET_HELLO reply decode + REPORT_VERSION_INFO 7 (§3.6) | **S** | Cheap, and every hardware finding in `docs/hardware-findings.md` wants a firmware version. |
| 6 | Extended battery + battery event payloads (§3.7) | **S** | Small, improves the Device screen immediately. |
| 7 | LINK_VALID keep-alive (§3.8) | **S** | Robustness for overnight drains and background relaunches. |
| 8 | Console logs + memfault subscription (§3.5) | **M** | Diagnostics; pays off when steps 1–4 misbehave on hardware. |
| 9 | Raw-stream disable in handshake, cmd 63 `[0x00]` (§3.4) | **S** | One line in the handshake; prevents a flood from foreign sessions. |
| 10 | GET_DATA_RANGE / GET_ALARM_TIME read-backs, unknown-event histogram (§3.11) | **S** | Hygiene; do opportunistically alongside step 5. |
| — | Historical IMU (type 52, §3.10) | — | Deliberately out of scope. |

Each step lands with tests in the existing style: golden vectors where captures exist, synthesized frames where they do not, and a fixture capture per new frame type saved into `shared/golden/frames.json` per the hardware-test workflow.
