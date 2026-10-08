import Store
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
                Picker(selection: $draft.sex) {
                    Text("Not set").tag(ProfileDraft.Sex?.none)
                    ForEach(ProfileDraft.Sex.allCases) { sex in
                        Text(sex.label).tag(ProfileDraft.Sex?.some(sex))
                    }
                } label: {
                    Label("Formula sex", systemImage: "person.fill")
                }

                LabeledContent {
                    TextField("Required", text: $draft.birthYear)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("profile.birthYear")
                } label: {
                    Label("Birth year", systemImage: "calendar")
                }

                LabeledContent {
                    HStack(spacing: Spacing.s4) {
                        TextField("Required", text: $draft.heightCm)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("profile.height")
                        Text("cm")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Height", systemImage: "ruler")
                }

                LabeledContent {
                    HStack(spacing: Spacing.s4) {
                        TextField("Required", text: $draft.weightKg)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("profile.weight")
                        Text("kg")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Weight", systemImage: "scalemass")
                }
            } footer: {
                Text(bodyFooter)
            }

            Section {
                LabeledContent {
                    HStack(spacing: Spacing.s4) {
                        TextField("From birth year", text: $draft.hrMax)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("profile.hrMax")
                        Text("bpm")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("HRmax", systemImage: "heart.fill")
                }
            } footer: {
                Text(hrMaxFooter)
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

    private var bodyFooter: String {
        if attempted, let issue = draft.firstIssue, issue != .hrMax {
            return issue.message
        }
        return "Sex, age, height and weight set calorie estimates and heart-rate zones."
    }

    private var hrMaxFooter: String {
        if attempted, let issue = draft.firstIssue, issue == .hrMax {
            return issue.message
        }
        return "Blank uses an estimate from birth year."
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
