import BandKit
import BandProtocol
import Metrics
import SwiftUI
import SyncKit

/// Semantic colours (IOS_UI_SPEC, "Global look"). System colours, so dark mode and contrast come from the system.
/// Colour only carries meaning: state, thresholds and chart series.
enum Palette {
    /// Deprecated: use `Palette.category(.heart)` (MetricCategory / MetricKind colors).
    static let heartRate = MetricCategory.heart.color
    /// Deprecated: use `Palette.category(.heart)` (MetricCategory / MetricKind colors).
    static let hrv = Color.indigo
    /// Deprecated: use `Palette.category(.sleep)` (MetricCategory / MetricKind colors).
    static let sleep = Color.teal
    /// Deprecated: use `Palette.category(.activity)` (MetricCategory / MetricKind colors).
    static let strain = Color.blue
    /// Stimulant-active windows shaded behind chart data (`MedicationWindowsOverlay`). Neutral on purpose: a
    /// medication window marks a time, not a state, so it must not read as a good or bad colour.
    static let medication = Color.secondary

    /// Recovery bands use the familiar red / yellow / green.
    static func recovery(_ band: Recovery.Band) -> Color {
        switch band {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        }
    }
    /// Stress bands are steps of the mind colour: the words carry the meaning, the colour only steps up.
    static let stressLow = MetricCategory.mind.color.opacity(0.4)
    static let stressModerate = MetricCategory.mind.color.opacity(0.7)
    static let stressHigh = MetricCategory.mind.color
    /// Calories are steps of the activity colour.
    static let caloriesResting = MetricCategory.activity.color.opacity(0.35)
    static let caloriesActive = MetricCategory.activity.color
    static let syncOK = Color.green
    static let warn = Color.orange
    static let error = Color.red
    static let neutral = Color.secondary

    /// Zones 1-5, lowest first: one orange ramp from light to dark, so the zones read as steps of intensity.
    static let zones: [Color] = [0.3, 0.45, 0.6, 0.8, 1.0].map { MetricCategory.activity.color.opacity($0) }

    static func stress(_ band: StressBand) -> Color {
        switch band {
        case .low: Palette.stressLow
        case .moderate: Palette.stressModerate
        case .high: Palette.stressHigh
        }
    }

    static func zone(_ zone: HeartRateZone) -> Color {
        switch zone {
        case .below: Color.gray
        case .zone1: Palette.zones[0]
        case .zone2: Palette.zones[1]
        case .zone3: Palette.zones[2]
        case .zone4: Palette.zones[3]
        case .zone5: Palette.zones[4]
        }
    }

    static func link(_ state: ConnectionState) -> Color {
        switch state {
        case .streaming: Palette.syncOK
        case .idle: Palette.neutral
        case .scanning, .connecting, .discovering, .subscribing, .backoff: Palette.warn
        }
    }

    /// Sleep-quality words, green to red like the stress bands (PLAN.md 8.1's sleep detection proxy).
    static func sleepQuality(_ quality: SleepQuality) -> Color {
        switch quality {
        case .good: Palette.syncOK
        case .fair: Palette.warn
        case .poor: Palette.error
        }
    }

    static func sync(_ phase: SyncPhase) -> Color {
        switch phase {
        case .notPaired: Palette.neutral
        case .idle, .syncing: Palette.syncOK
        case .retrying: Palette.warn
        case .needsRepair: Palette.error
        }
    }
}
