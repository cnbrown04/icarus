import Metrics
import SwiftUI

/// The Browse tab: every metric, workout, journal entry and report, grouped by category. No values here; they
/// live on Summary and on each detail page.
struct BrowseView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @Environment(\.openTab) private var openTab

    var body: some View {
        List {
            categorySection(.activity) {
                metricRow("Strain", symbol: Symbol.strain, category: .activity, route: .metric(.strain))
                metricRow("Calories", symbol: Symbol.calories, category: .activity, route: .metric(.calories))
                metricRow("Workouts", symbol: Symbol.workouts, category: .activity, route: .workouts)
            }
            categorySection(.heart) {
                metricRow("Heart rate", symbol: Symbol.heartRate, category: .heart, route: .metric(.heartRate))
                metricRow("Resting heart rate", symbol: Symbol.restingHR, category: .heart, route: .metric(.restingHR))
                metricRow("Heart rate variability", symbol: Symbol.hrv, category: .heart, route: .metric(.hrv))
            }
            categorySection(.recovery) {
                metricRow("Recovery", symbol: Symbol.recovery, category: .recovery, route: .metric(.recovery))
                metricRow("Vitals", symbol: Symbol.vitals, category: .recovery, route: .vitals)
            }
            categorySection(.mind) {
                metricRow("Stress", symbol: Symbol.stress, category: .mind, route: .metric(.stress))
            }
            categorySection(.respiratory) {
                metricRow(
                    "Respiratory rate",
                    symbol: Symbol.respiratoryRate,
                    category: .respiratory,
                    route: .metric(.respiratoryRate)
                )
            }
            categorySection(.sleep) {
                Button {
                    openTab(.sleep)
                } label: {
                    browseLabel("Sleep", symbol: Symbol.sleep, color: MetricCategory.sleep.color)
                }
                .accessibilityIdentifier("browse.sleep")
            }

            Section("Journal") {
                NavigationLink(value: AppRoute.journal(nil)) {
                    browseLabel("Check-in", symbol: Symbol.journal, color: .secondary)
                }
                .accessibilityIdentifier("browse.checkIn")
                NavigationLink(value: AppRoute.journalInsights) {
                    browseLabel("Insights", symbol: Symbol.journal, color: .secondary)
                }
                .accessibilityIdentifier("browse.insights")
            }

            Section("Reports") {
                NavigationLink(value: AppRoute.weekly) {
                    browseLabel("Weekly assessment", symbol: Symbol.weekly, color: .secondary)
                }
                .accessibilityIdentifier("browse.weekly")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.large)
    }

    /// A category section. The header is the category title.
    private func categorySection<Rows: View>(
        _ category: MetricCategory,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        Section(category.title) {
            rows()
        }
    }

    private func metricRow(_ title: String, symbol: String, category: MetricCategory, route: AppRoute) -> some View {
        NavigationLink(value: route) {
            browseLabel(title, symbol: symbol, color: category.color)
        }
        .accessibilityIdentifier("browse.\(title)")
    }

    /// Symbol and title. Only the glyph takes its colour; the title stays primary text.
    private func browseLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }
}
