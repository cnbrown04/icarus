import SwiftUI

/// Formula sex, birth year, height, weight and optional HRmax (PLAN.md §14 row 4). Used in onboarding and
/// from Settings > Profile.
struct ProfileView: View {
    enum Mode {
        /// Onboarding: a Continue action in the toolbar saves and calls `onContinue`.
        case onboarding(onContinue: () -> Void)
        /// Settings: a Save action saves and returns.
        case settings
    }

    let environment: AppEnvironment
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProfileDraft()
    @State private var loaded = false
    @State private var attempted = false

    var body: some View {
        Form {
            Section {
                Picker("Formula sex", selection: $draft.sex) {
                    Text("Not set").tag(ProfileDraft.Sex?.none)
                    ForEach(ProfileDraft.Sex.allCases) { sex in
                        Text(sex.label).tag(ProfileDraft.Sex?.some(sex))
                    }
                }

                TextField("Birth year", text: $draft.birthYear)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("profile.birthYear")
                TextField("Height (cm)", text: $draft.heightCm)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("profile.height")
                TextField("Weight (kg)", text: $draft.weightKg)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("profile.weight")
                TextField("HRmax (optional)", text: $draft.hrMax)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("profile.hrMax")
            } footer: {
                if attempted, let issue = draft.firstIssue {
                    Text(issue.message)
                } else {
                    Text("Formula sex, birth year, height and weight give calorie estimates. HRmax comes from birth year when blank.")
                }
            }
        }
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle, action: finish)
                    .accessibilityIdentifier("profile.save")
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let row = try? await environment.database.writer.read { try $0.profile() }
            draft = ProfileDraft(row: row)
        }
    }

    private var actionTitle: String {
        if case .onboarding = mode { return "Continue" }
        return "Save"
    }

    private func finish() {
        attempted = true
        guard let row = draft.row() else { return }
        let clock = environment.clock
        let database = environment.database
        Task {
            _ = try? await database.writer.write { db in
                try db.saveProfile(row, atMs: clock.nowMs)
            }
            if case let .onboarding(onContinue) = mode {
                onContinue()
            } else {
                dismiss()
            }
        }
    }
}
