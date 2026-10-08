# Build status

Branch: `claude/phase-0-scaffolding`. Last updated 2026-10-08 (UTC).
Screenshots from CI are committed per phase under `screenshots/phase-N/{ios,web}`.

## Phases

| Phase | Built | Verified by | Still needs |
|---|---|---|---|
| 0 Scaffolding and CI | Monorepo, XcodeGen app, Axum server, Vite + shadcn Lyra web, all workflows, docs | CI green on Linux and macOS | Nothing |
| 1 Device pipeline | BandKit state machine, CoreBluetooth Tier A transport with state restoration, Pair band, Device and Debug screens, fixture export, TestFlight workflow | BandKit tests; app builds on Xcode 26.6; screenshots | Your band: run `docs/hardware-test.md` and fill `docs/hardware-findings.md` (§5.5). TestFlight needs the App Store Connect secrets (see below) |
| 2 Local store and metrics | Metrics (Swift) and the same in Rust with golden parity; GRDB Store, ingestion, metrics worker, data screens | 93 Metrics, 68 Store tests, 41 golden cases in both languages, independent Python reference | 72 h wear test on real data |
| 3 Server and sync | Postgres schema, auth, pairing, sync batches/config/state, rollups; SyncKit, Server and Sync screens, background tasks | 138 server tests; 57 SyncKit tests; Docker image smoke test | A host (PLAN §20 Q6); a week of real syncing |
| 4 Website | All pages on the API, shadcn Lyra, semantic colour, icons | 107 unit tests, 64 Playwright checks with axe, 10 end-to-end tests against a real server | Your review of the screenshots |
| 5 Alarms, webhooks, APNs | Server alarms, webhook ingress (HMAC, secret URL), dispatcher, APNs; web editors; iOS AlarmKit alarms, rhythms, push handling | Server and package tests | APNs key (`.p8`), a device run of AlarmKit and push |
| 6 Band haptics and alarm (Tier B) | Typed commands, TierBController, CoreBluetooth wiring, Device toggle behind an explainer | 60 BandProtocol, 86 BandKit tests; golden frames reproduced byte for byte | Your band: test buzz, band alarm, preset list (§5.5 items 3, 5, 6) |
| 7 WHOOP API (optional) | OAuth, token refresh lock, webhooks, live summary, web page | 14 integration tests against a mock | WHOOP client id and secret; paths marked [Unverified] |
| 8 Hardening | OpenAPI drift check, security headers, ingress IP limit, export fix, perf test (1 year, all routes under 300 ms locally), backup/restore drill, deploy docs, UI overhaul (iOS) and polish (web) | Tests and drill output in `docs/backup.md` | 30-day soak, battery measurement on device |

## Decisions made during the build (see `shared/api-contract.md` "Decisions" for the API list)

- iOS uses the default SwiftUI look with rounded corners and rich charts (your call, 2026-10-08; PLAN §20 Q9).
- Web keeps Lyra; semantic colours live in `web/src/styles/semantic.css`, never in generated Lyra files.
- The repo is public; the Tier B protocol code stays in it (your call, 2026-10-08).
- Phone alarms are always on; the band is an extra channel.
- SET_CLOCK is not implemented: its payload is not documented (PLAN §5.3.4). Band alarms therefore use the band's own clock. The phone alarm is always armed as well.
- The band alarm cannot be disarmed (no documented command); a deleted alarm can still fire once on the band.

## What you need to provide

1. Apple Developer: bundle id (placeholder `com.cnbrown04.icarus`), team id, App Store Connect API key as repo secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID` (enables `testflight.yml`).
2. APNs auth key (`.p8`, key id, team id) for the server (`docs/deploy.md`).
3. A host for the server and Postgres (`docs/deploy.md` lists options).
4. Profile values (formula sex, birth year, height, weight, HRmax) in the app or website.
5. Optional: WHOOP developer app credentials.

## Known unverified items (marked [Unverified] in code)

- Whether `0x2A37` streams with HR Broadcast off, and whether it carries R-R on your firmware (§5.5).
- iOS bonding of the custom service, haptic preset ids beyond 2, response seq echo.
- `NSData.compressed(using: .zlib)` producing raw DEFLATE for gzip uploads.
- AlarmKit and remote-notification APIs until the macOS build passes with them.
- WHOOP profile, revoke and collection paths.
