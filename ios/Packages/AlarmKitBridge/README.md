# AlarmKitBridge

Phone alarms and haptics for Icarus (PLAN.md 9). Depends only on BandKit, so the pure parts build and test on Linux.

- `Schedule/`: `AlarmSchedule` (the wire `{"time","weekdays"}` rule) and `AlarmPlanner` (next occurrence across DST and
  time zones, and the earliest one for the band's single slot).
- `Rhythm/`: `RhythmSpec` (built-in names and custom steps, wire codec, BandKit validation), `HapticTimeline` (pure
  timing) and `RhythmHapticPlayer` (Core Haptics, `canImport(CoreHaptics)`).
- `Scheduling/`: `AlarmScheduling`, `InMemoryAlarmScheduler` (tests and UI tests), and `AlarmKitScheduler`
  (`canImport(AlarmKit)`, iOS 26). The AlarmKit calls are marked [Unverified] until the macOS build confirms them.
- `Notifications/`: the ICARUS_ALARM category identifiers and `AlarmNotifier` (`canImport(UserNotifications)`).

Not compiled on Linux: AlarmKit, CoreHaptics, UserNotifications.
