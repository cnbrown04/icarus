import SwiftUI

/// Scheduled alarms (IOS_UI_SPEC, Screen 12): large times, repeat days, a rhythm chip, channel symbols and a toggle.
/// Swipe deletes after a confirmation. The toolbar "+" and the empty state both open the editor.
struct AlarmsView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var editor: EditorTarget?
    @State private var pendingDelete: AlarmItem?

    /// What the editor sheet opens on: a new alarm, or a saved one.
    private enum EditorTarget: Identifiable {
        case new
        case edit(AlarmItem)

        var id: String {
            switch self {
            case .new: "new"
            case let .edit(item): item.id
            }
        }
    }

    private var alarms: AlarmCoordinator { environment.alarms }
    private var sync: SyncController { environment.sync }

    var body: some View {
        Group {
            if alarms.items.isEmpty {
                emptyState
            } else {
                alarmList
            }
        }
        .navigationTitle("Alarms")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New alarm")
                .accessibilityIdentifier("alarms.add")
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case .new:
                AlarmEditorView(environment: environment, liveState: liveState, initial: .new())
            case let .edit(item):
                AlarmEditorView(environment: environment, liveState: liveState, initial: AlarmDraft(item: item))
            }
        }
        .confirmationDialog(
            "Delete alarm?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete {
                    Task { await alarms.delete(item.id) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("The alarm is removed from this phone and the server.")
        }
        .overlay(alignment: .bottom) {
            if sync.alarmConflictNotice {
                ToastBanner(message: SyncController.alarmConflictMessage)
                    .onTapGesture { sync.dismissAlarmConflictNotice() }
            }
        }
        .animation(.easeOut(duration: 0.2), value: sync.alarmConflictNotice)
        .task(id: sync.alarmConflictNotice) {
            guard sync.alarmConflictNotice else { return }
            try? await Task.sleep(for: .seconds(4))
            sync.dismissAlarmConflictNotice()
        }
        .task {
            await alarms.ensureAuthorization()
        }
        .refreshable {
            await sync.runNow()
        }
    }

    private var alarmList: some View {
        List {
            ForEach(alarms.items) { item in
                AlarmListRow(
                    item: item,
                    onOpen: { editor = .edit(item) },
                    onToggle: { enabled in
                        Task { await alarms.setEnabled(item.id, enabled) }
                    }
                )
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No alarms", systemImage: "alarm.fill")
        } actions: {
            Button("New alarm") {
                editor = .new
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("alarms.empty.add")
        }
    }
}

/// One alarm. The time and label open the editor. The toggle arms or disarms the alarm.
private struct AlarmListRow: View {
    let item: AlarmItem
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(item.timeDate, style: .time)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(item.enabled ? Color.primary : Color.secondary)
                        .accessibilityIdentifier("alarms.time")
                    Text(item.label)
                        .font(.headline)
                        .foregroundStyle(item.enabled ? Color.primary : Color.secondary)
                        .accessibilityIdentifier("alarms.label")
                    HStack(spacing: Spacing.s8) {
                        Text(item.repeatText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        RhythmChip(name: item.rhythmName)
                        ChannelSymbols(channels: item.channels)
                    }
                    if item.enabled, let next = item.nextFire(after: Date()) {
                        Text("Next \(next, format: .dateTime.weekday(.abbreviated).hour().minute())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(item.label, isOn: Binding(get: { item.enabled }, set: onToggle))
                .labelsHidden()
                .accessibilityIdentifier("alarms.toggle")
        }
    }
}

/// The rhythm name as a small capsule.
private struct RhythmChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s4)
            .background(Palette.neutral.opacity(0.15), in: Capsule())
    }
}

/// Which channels ring: the phone, and the band when Tier B is on for the alarm.
private struct ChannelSymbols: View {
    let channels: Set<AlarmChannel>

    var body: some View {
        HStack(spacing: Spacing.s4) {
            if channels.contains(.phone) {
                Image(systemName: "iphone")
                    .accessibilityLabel("Phone")
            }
            if channels.contains(.band) {
                Image(systemName: "bolt.heart.fill")
                    .accessibilityLabel("Band")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
