# WHOOP-app roadmap

What it takes for Icarus to behave like a dedicated WHOOP app, written 2026-10-30. `docs/whoop-parity.md`
tracks the BLE protocol (now mostly closed: drain, v24 decode, SET_CLOCK, sleep staging all shipped). This
file tracks the *product*: the screens, scores and habits loop the WHOOP app is built around, and what
Icarus still lacks. Every agent working a stream below reads `CONTEXT.md` and `docs/design-rules.md` first.

Scores stay labelled proxies (published methods, not WHOOP's proprietary models), per `DailyScores`.

## Gap list

| # | WHOOP-app feature | Icarus today | Stream |
|---|---|---|---|
| 1 | Overview: three dials (Sleep %, Recovery %, Strain /21) for a chosen day, swipe/chevron between days | Home tiles for today only | Shell |
| 2 | Recovery screen: score, contributors (HRV, RHR, resp rate, sleep perf) vs 30-day baseline, trend | Home tile only | Health |
| 3 | Health Monitor: nightly vitals vs personal range ("4/4 in range"), skin-temp deviation | None (skin temp stored raw) | Health |
| 4 | Trends: 7 / 30 / 90-day charts per metric (recovery, HRV, RHR, sleep, strain, stress) | Per-detail 7-day trends only | Health |
| 5 | Strain screen: live day strain dial, zone time, calories, Strain Coach target band from recovery, band buzz on reaching it | Home tile only | Strain |
| 6 | Activities: auto-detected + manually recorded workouts with per-activity strain, zones, kcal, HR chart | None | Activities |
| 7 | Sleep Planner: tonight's bedtime to hit Peak / Perform / Get-by given need, debt and wake time | Need/debt numbers only | Strain (coaching) |
| 8 | Weekly Performance Assessment: last week vs the one before | None | Strain (coaching) |
| 9 | Journal: morning behaviour check-in (caffeine, alcohol, late meal, screens, medication…) | None | Journal |
| 10 | Journal insights: recovery / sleep with vs without each behaviour | None | Journal |
| 11 | Medications as a set-once calculation input (Settings only; scheduled doses assumed, as-needed doses logged there), shaded effect windows. No daily tracking in Journal (user, 2026-10-30) | Data layer (wave 1) | Journal (UI) + Med-stress |
| 12 | Medication-aware stress baseline; "stimulant active at bedtime" sleep flag | None | Med-stress |
| 13 | Device: charging state, battery events, link keep-alive, firmware/console diagnostics | Battery poll only | Band |
| 14 | Smart alarm (wake in light sleep inside a window) | None | Later: needs an overnight live-staging spike |
| 15 | Home-screen widgets / workout Live Activity | None | Later: needs an app-group DB move |

## Navigation contract (the Shell stream implements it; feature streams only build screens)

Tabs: **Overview · Sleep · Strain · Health**. Toolbar trailing on every tab: Journal (`book.closed`), Alarms
(`bell`), Settings (`gearshape`) as sheets, as today. The current Today tab's live content moves: live HR +
day strain → Strain; HR / stress / calories timelines → Health. Overview holds the three dials, a day pager
and cards that deep-link into the other tabs.

Feature streams expose a public entry view each and do NOT edit `RootView.swift`, `HomeView.swift`,
`TodayView.swift` or `Dashboard.swift`; they put their queries in their own model file. Entry views take
`(environment: AppEnvironment, liveState: LiveState)` and, where day-scoped, `day: LocalDay`.

| Stream | Entry views it must expose |
|---|---|
| Health | `RecoveryDetailView`, `HealthMonitorView`, `TrendsView`, `HealthTabView` (composes them + existing HR/stress/calorie detail links) |
| Strain | `StrainTabView` (live HR, dial, coach, zones, activities slot), `SleepPlannerCard`, `WeeklyAssessmentView` |
| Activities | `ActivitiesListView`, `ActivityDetailView`, `RecordActivityView`, `ActivitiesSection` (embeddable list for Strain tab) |
| Journal | `JournalView` (today's check-in), `JournalInsightsView`, `MedicationsView` (Settings), `MedicationWindowsOverlay` (chart band) |

## Shared constraints

- **Schema versions are pre-assigned** to avoid collisions: v8 medications (wave 1), **v9 activities**,
  **v10 journal**. Nobody else adds a migration.
- **Design**: `docs/design-rules.md` is binding (spacing scale, ≤3 type sizes, colour only for meaning, no
  gradients/glows, sentence case, numbers before words, units). WHOOP-like means *structure and
  vocabulary* — dials, day pager, coach bands, journal loop — not WHOOP's branding. Reuse `Palette`
  (`recovery(_:)`, `strain`, `sleep`, `zones`), `RingProgress`, `DashboardCard`, `MetricTile`, `ChartCard`.
  New shared components go in `ios/Icarus/Design/` with a doc comment.
- **Tests**: pure logic lives in Metrics/Store with Swift Testing tests; views get a compile check. Agents
  in parallel worktrees run `swift test` per package directly and never `pkill` (see `ios/scripts/run_tests.sh`
  for why it is not safe to run concurrently).
- **Local-only**: new tables are not synced to the server yet; note it in the stream's commit.

## Waves

1. Done/running: full-history drain wrap fix, stress v2 (awake baseline), medication data layer.
2. Parallel feature streams: Health, Strain (+coaching), Activities, Journal (+medication UI), Med-stress, Band.
3. Shell: tabs, Overview dials + day pager, wiring every entry view; then full test run and device install.
4. Later: smart alarm, widgets / Live Activity, server sync for the new tables, web parity.
