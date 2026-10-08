# Icarus

Icarus is a personal, local-first companion for a WHOOP 4.0 band you own: a SwiftUI iOS app that reads the band over Bluetooth LE, stores data offline, derives heart-rate, stress and calorie metrics, fires alarms and haptics, and syncs to a Rust/Postgres backend with a ShadCN (Lyra) website.

Metrics are estimates and are not for medical use. The full specification is in [PLAN.md](PLAN.md).

## Repo layout

| Path | Contents |
|---|---|
| `ios/` | XcodeGen spec (`project.yml`), app target, UI tests, local Swift packages in `ios/Packages/` |
| `server/` | Rust workspace: Axum API, domain core, sqlx database layer, APNs push, jobs |
| `web/` | Vite, React and shadcn (Lyra) website |
| `shared/` | `openapi.yaml` API contract and `golden/` metric fixtures shared by Swift and Rust |
| `ci/` | Python helpers for screenshot naming, contact sheets and aggregation, with unit tests |
| `docs/` | Design rules, hardware test script, screenshot guide, ADRs and protocol notes |
| `.github/` | Workflows, Dependabot and the pull request template |

## Run locally

### Swift packages (Linux, through Docker)

The pure packages build and test on Linux with the Swift 6.2 image. No Swift install is needed.

```bash
docker run --rm -v "$PWD":/work -w /work/ios/Packages/BandProtocol swift:6.2-noble swift test
docker run --rm -v "$PWD":/work -w /work/ios/Packages/Metrics swift:6.2-noble swift test
```

### iOS app (macOS)

Requires macOS, Xcode 26.6 and XcodeGen. The `.xcodeproj` is generated from `ios/project.yml` and is not committed.

```bash
brew install xcodegen
cd ios
xcodegen generate
open Icarus.xcodeproj
```

### Server

Requires Rust stable and Postgres 17. The local database matches the CI service container.

```bash
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=icarus postgres:17

cd server
export DATABASE_URL=postgres://postgres:postgres@localhost:5432/icarus
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run -p icarus-server
```

### Web

Requires Node 22. pnpm is pinned by `packageManager` in `web/package.json`.

```bash
cd web
pnpm install --frozen-lockfile
pnpm dev
```

The checks CI runs are `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm lyra:check`, `pnpm build` and `pnpm e2e`.

## CI

Workflows are in `.github/workflows/`. Every action is pinned to a commit SHA.

| Workflow | Runner | Trigger | Does |
|---|---|---|---|
| `swift-packages.yml` | `ubuntu-latest` (Swift 6.2 container) | PRs and pushes to `main` touching `ios/Packages/**` or `shared/golden/**`; manual | `swift test` for BandProtocol, Metrics and BandKit |
| `ios.yml` | `macos-26` | PRs and pushes to `main` or `claude/**` touching `ios/**`; manual | XcodeGen, `Unit` test plan, SwiftLint; uploads the `.xcresult` on failure |
| `ios-screenshots.yml` | `macos-26` matrix | Push to `main` or `claude/**` touching `ios/**`; PR labelled `screenshots`; manual with `quick` | Screenshot test plan on 3 devices by 2 appearances; commits the set to `screenshots/ios/` and uploads it as an artifact |
| `server.yml` | `ubuntu-latest` with `postgres:17` | PRs and pushes to `main` or `claude/**` touching `server/**`; manual | `cargo fmt`, `cargo clippy -D warnings`, `cargo test --workspace` |
| `web.yml` | `ubuntu-latest` | PRs and pushes to `main` or `claude/**` touching `web/**`; manual | Typecheck, lint, unit tests, Lyra lock check, build, Playwright e2e and screenshots; on push, commits them to `screenshots/web/` |
| `web-lyra-init.yml` | `ubuntu-latest` | Manual | Runs the shadcn Lyra init and component add, regenerates the lock, commits and pushes to the branch |
| `ci.yml` | `ubuntu-latest` | PRs and pushes to `main` or `claude/**` touching `ci/**`; manual | Unit tests for the `ci/` scripts |
| `secrets-scan.yml` | `ubuntu-latest` | PRs, pushes to `main` or `claude/**`; manual | gitleaks over the full history |
| `testflight.yml` | `macos-26` | Manual; tags `ios-v*` | Stub until Phase 1 |

Dependabot checks Cargo, npm, SwiftPM (BandProtocol, Metrics, BandKit), pip and GitHub Actions weekly.

The latest screenshots are committed under `screenshots/ios/` and `screenshots/web/`, with the workflow artifacts as backup. See [docs/screenshots.md](docs/screenshots.md).
