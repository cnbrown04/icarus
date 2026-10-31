import Charts
import Foundation
import Metrics
import SwiftUI

/// Shades stimulant-active windows (`MedicationWindow`, from `Database.medicationWindows`) behind a time-axis chart.
///
/// The marks are plain `RectangleMark`s, so they go inside a `Chart { }` builder with the data marks. Pass the same
/// y range the chart uses, because a rectangle needs a y extent and the shading must not change the y scale. Shading
/// is `Palette.medication` at low opacity, a neutral tint that marks time, not state.
///
/// Apply it to the time-axis chart (the Shell stream wires this into `HRAreaChart` and `StressTimelineChart`):
///
/// ```swift
/// Chart {
///     MedicationWindowsOverlay.marks(windows, yRange: 0...maxBpm)
///     ForEach(points) { point in
///         LineMark(x: .value("Time", point.date), y: .value("bpm", point.bpm))
///     }
/// }
/// .chartYScale(domain: 0...maxBpm)
/// ```
///
/// `windows` comes from `Database.medicationWindows(from:to:in:)` for the chart's day range. The marks clip to the
/// chart's x domain automatically.
enum MedicationWindowsOverlay {
    /// Opacity of the shading. Low enough that data drawn over it keeps its contrast in both appearances.
    static let fillOpacity = 0.15

    static func marks(_ windows: [MedicationWindow], yRange: ClosedRange<Double>) -> some ChartContent {
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
            RectangleMark(
                xStart: .value("Medication start", Date(epochMs: window.startMs)),
                xEnd: .value("Medication end", Date(epochMs: window.endMs)),
                yStart: .value("Medication band bottom", yRange.lowerBound),
                yEnd: .value("Medication band top", yRange.upperBound)
            )
            .foregroundStyle(Palette.medication.opacity(fillOpacity))
        }
    }
}
