import AlarmKitBridge
import BandKit
import Foundation
import Observation
import Store
import SyncKit

/// Keeps the phone and band alarms armed from the store (PLAN.md 9.5). It re-arms on every alarm change, at launch,
/// when the app comes to the foreground, on a time zone change, when the band becomes ready, and after the band
/// alarm fires. Every scheduled alarm goes to AlarmKit. The band gets the earliest next one, since it has one slot.
@MainActor
@Observable
final class AlarmCoordinator {
    /// Every live alarm, earliest time of day first.
    private(set) var items: [AlarmItem] = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let scheduler: any AlarmScheduling
    /// Nil in UI tests, so no notification prompt appears.
    @ObservationIgnored private let notifier: AlarmNotifier?
    @ObservationIgnored private let sync: SyncController
    @ObservationIgnored private let clock: AppClock
    @ObservationIgnored private let phonePlayer = RhythmHapticPlayer()
    @ObservationIgnored private weak var band: LiveState?
    /// What was last sent to AlarmKit for each id, so an unchanged alarm is not scheduled again.
    @ObservationIgnored private var armedSignatures: [String: String] = [:]
    @ObservationIgnored private var started = false

    /// Ids armed in an earlier launch, so an alarm deleted or disabled while the app was closed is cancelled.
    private static let armedIDsKey = "alarmkit.armedIDs"

    init(
        database: AppDatabase,
        scheduler: any AlarmScheduling,
        notifier: AlarmNotifier?,
        sync: SyncController,
        clock: AppClock
    ) {
        self.database = database
        self.scheduler = scheduler
        self.notifier = notifier
        self.sync = sync
        self.clock = clock
    }

    /// Starts observing the store and the time zone. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        let database = database
        Task { [weak self] in
            do {
                for try await rows in database.observe({ try $0.alarms() }) {
                    guard let self else { return }
                    self.items = rows.map(AlarmItem.init(row:)).sorted { $0.minuteOfDay < $1.minuteOfDay }
                    await self.armPhone()
                    await self.armBand()
                }
            } catch {
                // The observation ends only when the store fails. Nothing else depends on it, so it is not retried.
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange) {
                guard let self else { return }
                await self.rearmAll()
            }
        }
    }

    /// Lets the coordinator arm the band, and re-arms it when Tier B becomes ready or the band alarm fires.
    func connect(band: LiveState) {
        self.band = band
        band.onTierBChange = { [weak self] state in
            guard state == .ready, let self else { return }
            Task { await self.armBand() }
        }
        band.onBandEvent = { [weak self] kind in
            guard kind == .strapDrivenAlarmExecuted, let self else { return }
            Task { await self.armBand() }
        }
        band.onLinkAlive = { [weak self] in
            guard let self else { return }
            self.bandWokeUp()
        }
    }

    /// Asks for alarm and notification permission. The system asks once; later calls return the stored answer.
    func ensureAuthorization() async {
        _ = try? await scheduler.requestAuthorization()
        _ = try? await notifier?.requestAuthorization()
        await rearmAll()
    }

    /// Re-arms the phone and the band from the current items.
    func rearmAll() async {
        await armPhone()
        await armBand()
    }

    /// Saves an edit locally, then sends it. Offline saves stay dirty and go out on the next sync run.
    func save(_ draft: AlarmDraft) async throws {
        await ensureAuthorization()
        let nowMs = clock.nowMs
        try await database.writer.write { db in
            let existing = try draft.id.flatMap { try db.alarm(id: $0) }
            let row = try draft.row(existing: existing, nowMs: nowMs)
            try db.saveAlarmEdit(row, nowMs: nowMs)
        }
        await sync.pushAlarmEdits()
    }

    func setEnabled(_ id: String, _ enabled: Bool) async {
        let nowMs = clock.nowMs
        try? await database.writer.write { db in
            guard var row = try db.alarm(id: id) else { return }
            row.enabled = enabled
            try db.saveAlarmEdit(row, nowMs: nowMs)
        }
        await sync.pushAlarmEdits()
    }

    func delete(_ id: String) async {
        let nowMs = clock.nowMs
        try? await database.writer.write { db in
            try db.deleteAlarmEdit(id: id, nowMs: nowMs)
        }
        await sync.pushAlarmEdits()
    }

    /// Plays the rhythm on the phone, and on the band when it is ready, and posts a test alert. Returns the line the
    /// editor shows under the Test button.
    func testLocally(_ draft: AlarmDraft) async -> String {
        guard let rhythm = try? draft.rhythm.rhythm() else { return "This rhythm cannot be played." }
        try? phonePlayer.play(rhythm)
        var places = "the phone"
        if let band, band.tierBState == .ready {
            await band.runRhythm(rhythm)
            places = "the phone and the band"
        }
        try? await notifier?.post(title: "Test alarm", body: draft.label.isEmpty ? "Alarm" : draft.label)
        return "Ran on \(places)."
    }

    // MARK: Arming

    /// Schedules every enabled scheduled alarm on AlarmKit and cancels the ones that are gone or disabled.
    private func armPhone() async {
        guard await scheduler.authorization() == .authorized else { return }
        let now = clock.now
        var wanted: [String: ScheduledAlarm] = [:]
        for item in items where item.enabled && item.kind == "scheduled" {
            guard let schedule = item.schedule,
                  let uuid = UUID(uuidString: item.id),
                  let fire = AlarmPlanner.nextOccurrence(of: schedule, after: now)
            else { continue }
            wanted[item.id] = ScheduledAlarm(id: uuid, label: item.label, schedule: schedule, nextFire: fire)
        }

        let previous = UserDefaults.standard.stringArray(forKey: Self.armedIDsKey) ?? []
        for id in previous where wanted[id] == nil {
            if let uuid = UUID(uuidString: id) {
                try? await scheduler.cancel(id: uuid)
            }
        }
        for id in Array(armedSignatures.keys) where wanted[id] == nil {
            armedSignatures[id] = nil
        }

        for (id, alarm) in wanted {
            let signature = "\(alarm.label)|\(alarm.schedule.time)|\(alarm.schedule.weekdays)|\(alarm.nextFire.timeIntervalSince1970)"
            guard armedSignatures[id] != signature else { continue }
            do {
                try await scheduler.schedule(alarm)
                armedSignatures[id] = signature
            } catch {
                armedSignatures[id] = nil
            }
        }
        UserDefaults.standard.set(Array(wanted.keys), forKey: Self.armedIDsKey)
    }

    /// Arms the earliest next band alarm, when Tier B is ready. Nothing is sent otherwise (PLAN.md 9.5).
    private func armBand() async {
        guard let band, band.tierBState == .ready else { return }
        let rules = items.filter { $0.enabled && $0.channels.contains(.band) }.compactMap(\.schedule)
        await band.armBandAlarm(AlarmPlanner.earliest(rules, after: clock.now))
    }

    // MARK: Opportunistic dispatch pull (PLAN.md 9.3 mitigation 1)

    /// UserDefaults key for the Experimental toggle on the Device screen. Off by default: the pull
    /// spends band wake-ups on unrelated network work, which the plan accepts only for a personal
    /// TestFlight build.
    static let opportunisticPullKey = "alarms.opportunisticPull"
    /// At most one pull per 30 s of band wake-ups (PLAN.md 9.3).
    private static let pullInterval: TimeInterval = 30

    @ObservationIgnored private var lastPullAt: Date?
    /// Dispatch ids played in this launch. A delivered dispatch never buzzes twice; one whose ack
    /// failed is forgotten, so a later pull replays it (the server resends until it is acked).
    @ObservationIgnored private var playedDispatches: Set<String> = []

    /// A band wake-up arrived: the link came alive, or a realtime heart-rate notification was
    /// delivered (`LiveState.onLinkAlive`). Alarm push is disabled, so this pull is how a webhook
    /// dispatch still plays when the app happens to be awake. Skips when the toggle is off, no
    /// server is paired, or the last pull was less than 30 s ago.
    func bandWokeUp() {
        guard UserDefaults.standard.bool(forKey: Self.opportunisticPullKey) else { return }
        guard sync.status.phase != .notPaired else { return }
        let now = clock.now
        guard lastPullAt.map({ now.timeIntervalSince($0) >= Self.pullInterval }) ?? true else { return }
        lastPullAt = now
        BandLog.tierB(.info, "alarms: opportunistic pull triggered by a band wake-up")
        Task { await deliverPulledDispatches() }
    }

    /// Plays and acks every dispatch the server still lists as unacked. The handling mirrors the
    /// foreground push delivery (PLAN.md 9.3): the phone haptic and a local alert play, the band
    /// buzzes when the channel allows it, and the ack reports what each side did. Each dispatch
    /// plays once per launch.
    private func deliverPulledDispatches() async {
        let pending: [PendingDispatch]
        do {
            pending = try await sync.engine.pendingDispatches()
        } catch {
            BandLog.tierB(.info, "alarms: opportunistic pull failed: \(String(describing: error))")
            return
        }
        let fresh = pending.filter { !playedDispatches.contains($0.id) }
        BandLog.tierB(.info, "alarms: opportunistic pull: \(fresh.count) new of \(pending.count) pending dispatch(es)")
        for dispatch in fresh {
            playedDispatches.insert(dispatch.id)
            let bandAck = await playOnBand(dispatch.rhythmJSON)
            if let rhythm = try? RhythmSpec(jsonText: dispatch.rhythmJSON).rhythm() {
                try? phonePlayer.play(rhythm)
            }
            try? await notifier?.post(title: "Alarm", body: dispatch.message ?? "Alarm from the server")
            do {
                try await sync.engine.ackDispatch(id: dispatch.id, phone: .shown, band: bandAck)
            } catch {
                playedDispatches.remove(dispatch.id)
            }
        }
    }

    /// The band's part of a dispatch, acked the same way the push router acks foreground delivery:
    /// buzz when the band channel is on, the link streams and Tier B is ready; report why not otherwise.
    private func playOnBand(_ rhythmJSON: String) async -> BandAck {
        guard BandChannel.isEnabled else { return .disabled }
        guard let band, band.state == .streaming else { return .notConnected }
        guard band.tierBState == .ready,
              let spec = try? RhythmSpec(jsonText: rhythmJSON),
              let rhythm = try? spec.rhythm()
        else { return .failed }
        await band.runRhythm(rhythm)
        return .ok
    }
}
