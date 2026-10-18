import AlarmKitBridge
import BandKit
import SwiftUI

/// The rhythm editor (IOS_UI_SPEC, Screen 14). Steps are buzz or pause, with steppers. The limits are 10 steps and 30 s
/// in total (PLAN.md 9.2), and every change is checked by BandKit before it is kept. Previews run on the phone with
/// Core Haptics, and on the band when Tier B is ready.
struct RhythmEditorView: View {
    @Binding var rhythm: RhythmSpec
    let liveState: LiveState

    @State private var phonePlayer = RhythmHapticPlayer()

    /// Preset 2 is the only documented band preset (PLAN.md 9.2). New steps use it.
    private static let buzzPreset: UInt8 = 2
    private static let maxLoops = 30
    private static let pauseStepMs = 100
    private static let maxPauseMs = 5000

    private var steps: [Rhythm.Step] {
        rhythm.steps
    }

    private var totalSeconds: Double {
        (try? rhythm.rhythm().durationSeconds) ?? 0
    }

    var body: some View {
        Form {
            Section {
                ForEach(steps.indices, id: \.self) { index in
                    stepRow(at: index)
                }
                .onDelete(perform: delete)
            } header: {
                Text("Steps")
            } footer: {
                Text("Total \(Format.seconds(totalSeconds)) of \(Format.seconds(Rhythm.maxDurationSeconds)), up to \(Rhythm.maxSteps) steps.")
            }

            Section {
                Menu {
                    Button("Buzz") {
                        add(.buzz(preset: Self.buzzPreset, loops: 1))
                    }
                    Button("Pause") {
                        add(.pause(ms: 300))
                    }
                } label: {
                    Label("Add step", systemImage: "plus.circle")
                }
                .disabled(!RhythmSpec.isValid(steps + [.buzz(preset: Self.buzzPreset, loops: 1)]))
                .accessibilityIdentifier("rhythmEditor.add")
            }

            Section {
                Button {
                    playOnPhone()
                } label: {
                    Label("Preview on phone", systemImage: "iphone")
                }
                .accessibilityIdentifier("rhythmEditor.phone")

                Button {
                    playOnBand()
                } label: {
                    Label("Preview on band", systemImage: "bolt.heart.fill")
                }
                .disabled(liveState.tierBState != .ready)
                .accessibilityIdentifier("rhythmEditor.band")
            } header: {
                Text("Preview")
            } footer: {
                if !RhythmHapticPlayer.supportsHaptics {
                    Text("Haptics are off on this iPhone.")
                } else if liveState.tierBState != .ready {
                    Text("The band preview needs the band channel on Device.")
                }
            }
        }
        .navigationTitle("Rhythm")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func stepRow(at index: Int) -> some View {
        switch steps[index] {
        case let .buzz(preset, loops):
            let count = Int(loops)
            // Clamped, so the step for an out-of-range count is still a valid UInt8 when its guard is false.
            let more = Rhythm.Step.buzz(preset: preset, loops: UInt8(clamping: count + 1))
            let fewer = Rhythm.Step.buzz(preset: preset, loops: UInt8(clamping: count - 1))
            Stepper(
                onIncrement: canReplace(index, with: more, when: count < Self.maxLoops)
                    ? { replace(index, with: more) }
                    : nil,
                onDecrement: count > 1
                    ? { replace(index, with: fewer) }
                    : nil
            ) {
                Label("Buzz, \(count) \(count == 1 ? "loop" : "loops")", systemImage: "waveform")
            }
        case let .pause(ms):
            Stepper(
                onIncrement: canReplace(index, with: .pause(ms: ms + Self.pauseStepMs), when: ms + Self.pauseStepMs <= Self.maxPauseMs)
                    ? { replace(index, with: .pause(ms: ms + Self.pauseStepMs)) }
                    : nil,
                onDecrement: ms > Self.pauseStepMs
                    ? { replace(index, with: .pause(ms: ms - Self.pauseStepMs)) }
                    : nil
            ) {
                Label("Pause, \(ms) ms", systemImage: "pause")
            }
        }
    }

    /// Whether replacing step `index` keeps the rhythm valid. `when` guards the arithmetic before BandKit sees it.
    private func canReplace(_ index: Int, with step: Rhythm.Step, when inRange: Bool) -> Bool {
        guard inRange else { return false }
        var next = steps
        next[index] = step
        return RhythmSpec.isValid(next)
    }

    private func replace(_ index: Int, with step: Rhythm.Step) {
        var next = steps
        next[index] = step
        commit(next)
    }

    private func add(_ step: Rhythm.Step) {
        commit(steps + [step])
    }

    private func delete(at offsets: IndexSet) {
        // A rhythm needs at least one step, so the last step stays.
        guard offsets.count < steps.count else { return }
        var next = steps
        next.remove(atOffsets: offsets)
        commit(next)
    }

    /// Keeps `next` only if BandKit accepts it. Editing a built-in turns it into custom steps.
    private func commit(_ next: [Rhythm.Step]) {
        guard let custom = try? Rhythm(steps: next) else { return }
        rhythm = .custom(custom)
    }

    private func playOnPhone() {
        guard let validated = try? rhythm.rhythm() else { return }
        try? phonePlayer.play(validated)
    }

    private func playOnBand() {
        guard let validated = try? rhythm.rhythm() else { return }
        Task { await liveState.runRhythm(validated) }
    }
}
