import Metrics
import Store
import SwiftUI

/// The activities that started on one local day, as a compact card for the Strain tab. Each row opens
/// `ActivityDetailView`. Entry view for the Activities stream (`environment`, `day`).
struct ActivitiesSection: View {
    let environment: AppEnvironment
    let day: LocalDay

    @State private var snapshot: ActivitiesModel.DaySnapshot?

    var body: some View {
        DashboardCard(title: "Activities", symbol: "figure.run", tint: Palette.strain) {
            if let snapshot, !snapshot.activities.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s12) {
                    ForEach(snapshot.activities, id: \.id) { row in
                        NavigationLink {
                            ActivityDetailView(environment: environment, activityID: row.id)
                        } label: {
                            ActivityRowView(row: row, timeZone: snapshot.timeZone)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("No activities")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: day) {
            let target = day
            for await value in environment.snapshots(every: .seconds(60), { db, _ in
                try ActivitiesModel.day(db, day: target)
            }) {
                snapshot = value
            }
        }
    }
}
