import Metrics
import SwiftUI

/// The tabs of the Apple Health–style shell (Summary · Strain · Sleep · Browse).
enum ShellTab: Hashable {
    case summary
    case strain
    case sleep
    case browse
}

/// Every pushed destination, so a screen links by meaning (`NavigationLink(value: AppRoute.metric(.hrv))`) and the
/// destination for each route is decided in exactly one place (`AppRouteDestination`). That is what keeps one page
/// per kind of information: two screens linking to the same route always land on the same page.
enum AppRoute: Hashable {
    /// The one detail page for a metric (D/W/M/6M chart, details, About). Never `.sleep`: the Sleep tab owns sleep.
    case metric(MetricKind)
    /// Nightly vitals against the personal range.
    case vitals
    /// Last 7 days against the 7 before.
    case weekly
    /// The check-in for a day (nil = yesterday).
    case journal(LocalDay?)
    case journalInsights
    case workouts
    case workout(id: String)
}

/// Resolves an `AppRoute` to its page. The only switch over routes in the app.
struct AppRouteDestination: View {
    let route: AppRoute
    let environment: AppEnvironment
    let liveState: LiveState

    var body: some View {
        switch route {
        case let .metric(kind):
            // Sleep has no metric page: the Sleep tab owns it (callers switch tabs instead of pushing).
            MetricDetailView(kind: kind, environment: environment, liveState: liveState)
        case .vitals:
            HealthMonitorView(environment: environment, liveState: liveState, day: today)
        case .weekly:
            WeeklyAssessmentView(environment: environment)
        case let .journal(day):
            JournalView(environment: environment, day: day)
        case .journalInsights:
            JournalInsightsView(environment: environment)
        case .workouts:
            ActivitiesListView(environment: environment, liveState: liveState)
        case let .workout(id):
            ActivityDetailView(environment: environment, activityID: id)
        }
    }

    private var today: LocalDay {
        LocalTime.localDay(containing: environment.clock.nowMs, in: .current)
    }
}

extension View {
    /// Registers the app's route destinations on a `NavigationStack`. Apply once per stack root.
    func appRouteDestinations(environment: AppEnvironment, liveState: LiveState) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppRouteDestination(route: route, environment: environment, liveState: liveState)
        }
    }
}

private struct OpenTabKey: EnvironmentKey {
    static let defaultValue: @MainActor (ShellTab) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Switches the selected tab (e.g. Summary's Sleep ring opens the Sleep tab). Set by the tab shell.
    var openTab: @MainActor (ShellTab) -> Void {
        get { self[OpenTabKey.self] }
        set { self[OpenTabKey.self] = newValue }
    }
}
