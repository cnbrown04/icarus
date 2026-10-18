import Metrics
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
    @StateObject private var units = UnitPreferences()
    /// Imperial display buffers. One-way sync: edits flow into the draft's canonical cm/kg (see
    /// `storeHeightImperial` / `storeWeightImperial`); the buffers are only re-seeded from the draft
    /// when a stored profile loads (`loadImperialBuffers`), so typing is never rewritten underneath.
    @State private var heightFeet = ""
    @State private var heightInches = ""
    @State private var weightPounds = ""

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

                if units.isImperial {
                    LabeledContent {
                        HStack(spacing: Spacing.s4) {
                            TextField("ft", text: $heightFeet)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("profile.height")
                                .onChange(of: heightFeet) { _, _ in storeHeightImperial() }
                            Text("ft")
                                .foregroundStyle(.secondary)
                            TextField("in", text: $heightInches)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("profile.heightInches")
                                .onChange(of: heightInches) { _, _ in storeHeightImperial() }
                            Text("in")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Height", systemImage: "ruler")
                    }
                } else {
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
                }

                if units.isImperial {
                    LabeledContent {
                        HStack(spacing: Spacing.s4) {
                            TextField("Required", text: $weightPounds)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("profile.weight")
                                .onChange(of: weightPounds) { _, _ in storeWeightImperial() }
                            Text("lb")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Weight", systemImage: "scalemass")
                    }
                } else {
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
                }
            } footer: {
                Text(bodyFooter)
            }

            Section {
                LabeledContent {
                    HStack(spacing: Spacing.s4) {
                        TextField(hrMaxPlaceholder, text: $draft.hrMax)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("profile.hrMax")
                        Text("bpm")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Max heart rate", systemImage: "heart.fill")
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
            loadImperialBuffers()
        }
    }

    private var bodyFooter: String {
        if attempted, let issue = draft.firstIssue, issue != .hrMax {
            return issue.message(isImperial: units.isImperial)
        }
        return "Sex, age, height and weight set calorie estimates and heart-rate zones."
    }

    private var hrMaxFooter: String {
        if attempted, let issue = draft.firstIssue, issue == .hrMax {
            return issue.message(isImperial: units.isImperial)
        }
        if let estimate = hrMaxEstimate {
            return "Heart-rate zones and calorie burn use this. Blank applies the Tanaka estimate, 208 − 0.7 × age (≈\(estimate) bpm here); a lab- or field-tested value overrides it."
        }
        return "Heart-rate zones and calorie burn use this. Blank applies the Tanaka estimate, 208 − 0.7 × age; a lab- or field-tested value overrides it."
    }

    /// Tanaka estimate from the entered birth year, shown as the HRmax placeholder.
    private var hrMaxEstimate: Int? {
        guard let year = Int(draft.birthYear.trimmingCharacters(in: .whitespaces)),
              ProfileDraft.birthYearRange.contains(year)
        else { return nil }
        let age = max(Calendar.current.component(.year, from: Date()) - year, 0)
        return Int(HeartRateZones.tanakaMaxHR(ageYears: age).rounded())
    }

    private var hrMaxPlaceholder: String {
        hrMaxEstimate.map { "≈\($0) (estimated)" } ?? "Optional"
    }

    /// Seeds the imperial display buffers from the draft's canonical metric text. Blank when the
    /// value does not parse (fresh onboarding or a cleared field).
    private func loadImperialBuffers() {
        guard units.isImperial else { return }
        if let cm = draft.parsedHeightCm {
            let (feet, inches) = UnitConversions.feetInches(fromCm: cm)
            heightFeet = "\(feet)"
            heightInches = "\(inches)"
        }
        if let kg = draft.parsedWeightKg {
            weightPounds = ProfileDraft.number(UnitConversions.poundsDisplay(fromKg: kg))
        }
    }

    /// Canonical cm for the typed feet + inches. Blank inches counts as 0 while typing; anything
    /// unparseable (or 13+ inches) clears the canonical value so the range error shows.
    private func storeHeightImperial() {
        let feetText = heightFeet.trimmingCharacters(in: .whitespaces)
        let inchesText = heightInches.trimmingCharacters(in: .whitespaces)
        guard let feet = Int(feetText), feet >= 0 else {
            draft.heightCm = ""
            return
        }
        let inches = inchesText.isEmpty ? 0 : Int(inchesText)
        guard let inches, inches >= 0, inches < 12 else {
            draft.heightCm = ""
            return
        }
        draft.heightCm = ProfileDraft.number(UnitConversions.cm(fromFeetInches: feet, inches: inches))
    }

    /// Canonical kg (one decimal) for the typed pounds. Anything unparseable clears the canonical
    /// value so the range error shows.
    private func storeWeightImperial() {
        guard let pounds = ProfileDraft.parseLooseText(weightPounds), pounds > 0 else {
            draft.weightKg = ""
            return
        }
        draft.weightKg = ProfileDraft.number(UnitConversions.kilograms(fromPoundsDisplay: pounds))
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
