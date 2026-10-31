import Metrics
import Store
import SwiftUI

/// Journal insights: next-morning recovery, sleep performance and HRV on days with and without each behaviour.
/// Effects appear only once both sides reach `JournalInsights.minimumDaysPerSide` days. The rest are listed with the
/// days still needed. This is correlation, not cause, and the screen says so.
struct JournalInsightsView: View {
    let environment: AppEnvironment

    @State private var model: JournalInsightsModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: JournalInsightsModel(database: environment.database, clock: environment.clock))
    }

    var body: some View {
        List {
            if model.loaded {
                Section {
                    if confirmed.isEmpty {
                        EmptyStateRow(text: "No effects yet. Answer the check-in each morning.", actionTitle: nil, action: nil)
                    } else {
                        ForEach(confirmed) { insight in
                            InsightRow(insight: insight)
                        }
                    }
                } header: {
                    Text("Effects")
                } footer: {
                    Text("Correlation, not cause.")
                }

                if !pending.isEmpty {
                    Section("Needs more days") {
                        ForEach(pending, id: \.id) { item in
                            Text("\(item.label) needs \(item.moreDays) more \(item.moreDays == 1 ? "day" : "days")")
                        }
                    }
                }
            }

            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(Palette.error)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load()
        }
        .refreshable {
            await model.load()
        }
    }

    /// Confident effects, largest standardised effect first (the unstandardised difference when SD is unknown).
    private var confirmed: [JournalInsight] {
        model.insights
            .filter { $0.effect.isConfident }
            .sorted { lhs, rhs in
                let left = abs(lhs.effect.effectSize ?? lhs.effect.difference ?? 0)
                let right = abs(rhs.effect.effectSize ?? rhs.effect.difference ?? 0)
                return left != right ? left > right : lhs.id < rhs.id
            }
    }

    /// Behaviours with answers or doses in the window but no confident effect on any metric, with the fewest days
    /// still needed on their thinnest side.
    private var pending: [PendingItem] {
        let byBehaviour = Dictionary(grouping: model.insights, by: \.behaviourID)
        return byBehaviour.compactMap { _, group -> PendingItem? in
            guard !group.contains(where: { $0.effect.isConfident }) else { return nil }
            let withData = group.filter { $0.effect.with.days + $0.effect.without.days > 0 }
            guard let first = withData.first, let moreDays = withData.map(\.effect.moreDaysNeeded).min() else {
                return nil
            }
            return PendingItem(id: first.behaviourID, label: first.label, moreDays: moreDays)
        }
        .sorted { $0.label < $1.label }
    }

    private struct PendingItem: Identifiable {
        let id: String
        let label: String
        let moreDays: Int
    }
}

/// One confident effect, phrased as "Recovery 8 % lower with alcohol".
private struct InsightRow: View {
    let insight: JournalInsight

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Palette.neutral)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("journal.insight.\(insight.behaviourID).\(insight.effect.metric.rawValue)")
    }

    private var headline: String {
        let effect = insight.effect
        guard let difference = effect.difference else { return insight.effect.metric.label }
        let magnitude = Int(abs(difference).rounded())
        let phrase = "with \(lowercasedFirst(insight.label))"
        let metric = effect.metric.label
        if magnitude == 0 {
            return "\(metric) unchanged \(phrase)"
        }
        let direction = difference < 0 ? "lower" : "higher"
        return "\(metric) \(magnitude) \(effect.metric.unit) \(direction) \(phrase)"
    }

    private var detail: String {
        let effect = insight.effect
        var text = "n = \(effect.with.days) vs \(effect.without.days)"
        if let size = effect.effectSize {
            text += ", effect size \(size.formatted(.number.precision(.fractionLength(1))))"
        }
        return text
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
