import Foundation
import Store

/// Editable profile fields for onboarding and Settings (PLAN.md §14 row 4). Text stays as typed until
/// `validated` turns it into a store row.
struct ProfileDraft: Equatable {
    enum Sex: String, CaseIterable, Identifiable {
        case male
        case female

        var id: String { rawValue }

        var label: String {
            switch self {
            case .male: "Male"
            case .female: "Female"
            }
        }
    }

    static let birthYearRange = 1900...2030
    static let heightRange = 100.0...250.0
    static let weightRange = 30.0...300.0
    static let hrMaxRange = 100...230

    var sex: Sex?
    var birthYear = ""
    var heightCm = ""
    var weightKg = ""
    var hrMax = ""

    init() {}

    init(row: ProfileRow?) {
        guard let row else { return }
        sex = row.formulaSex.flatMap { Sex(rawValue: $0) }
        birthYear = row.birthYear.map(String.init) ?? ""
        heightCm = row.heightCm.map(Self.number) ?? ""
        weightKg = row.weightKg.map(Self.number) ?? ""
        hrMax = row.hrMax.map(String.init) ?? ""
    }

    /// Why the draft cannot be saved, or nil when it can. HRmax is optional and may be left blank.
    enum Issue: Equatable {
        case sex
        case birthYear
        case height
        case weight
        case hrMax

        var message: String {
            switch self {
            case .sex: "Choose a formula sex."
            case .birthYear: "Birth year must be from 1900 to 2030."
            case .height: "Height must be from 100 to 250 cm."
            case .weight: "Weight must be from 30 to 300 kg."
            case .hrMax: "HRmax must be from 100 to 230 bpm, or empty."
            }
        }
    }

    /// The first problem with the draft, in form order.
    var firstIssue: Issue? {
        if sex == nil { return .sex }
        if birthYearValue == nil { return .birthYear }
        if heightValue == nil { return .height }
        if weightValue == nil { return .weight }
        if !hrMax.isEmpty, hrMaxValue == nil { return .hrMax }
        return nil
    }

    var isComplete: Bool { firstIssue == nil }

    /// A store row for a complete draft. Nil when `isComplete` is false.
    func row(timeZone: String = "America/Chicago") -> ProfileRow? {
        guard isComplete, let sex, let birthYear = birthYearValue, let height = heightValue, let weight = weightValue else {
            return nil
        }
        return ProfileRow(
            formulaSex: sex.rawValue,
            birthYear: birthYear,
            heightCm: height,
            weightKg: weight,
            hrMax: hrMaxValue,
            tz: timeZone
        )
    }

    private var birthYearValue: Int? {
        guard let value = Int(birthYear.trimmingCharacters(in: .whitespaces)), Self.birthYearRange.contains(value) else {
            return nil
        }
        return value
    }

    private var heightValue: Double? {
        Self.parseNumber(heightCm, in: Self.heightRange)
    }

    private var weightValue: Double? {
        Self.parseNumber(weightKg, in: Self.weightRange)
    }

    private var hrMaxValue: Int? {
        let text = hrMax.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        guard let value = Int(text), Self.hrMaxRange.contains(value) else { return nil }
        return value
    }

    private static func parseNumber(_ text: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              range.contains(value)
        else { return nil }
        return value
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
