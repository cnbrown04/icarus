import SwiftUI

/// The one-line key under a chart that shades stimulant windows. Shown only when there is shading to explain.
struct MedicationLegend: View {
    var body: some View {
        Text("Shaded: stimulant active (estimated)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
