import BandKit
import Metrics
import SwiftUI
import SyncKit

/// Semantic colours (IOS_UI_SPEC, "Global look"). System colours, so dark mode and contrast come from the system.
/// Colour only carries meaning: state, thresholds and chart series.
enum Palette {
    static let heartRate = Color.pink
    static let hrv = Color.indigo
    static let sleep = Color.teal
    static let stressLow = Color.green
    static let stressModerate = Color.yellow
    static let stressHigh = Color.red
    static let caloriesResting = Color.orange.opacity(0.5)
    static let caloriesActive = Color.orange
    static let syncOK = Color.green
    static let warn = Color.orange
    static let error = Color.red
    static let neutral = Color.secondary

    /// Zones 1-5, lowest first. Below 50 % is grey.
    static let zones: [Color] = [.blue, .green, .yellow, .orange, .red]

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

    static func sync(_ phase: SyncPhase) -> Color {
        switch phase {
        case .notPaired: Palette.neutral
        case .idle, .syncing: Palette.syncOK
        case .retrying: Palette.warn
        case .needsRepair: Palette.error
        }
    }
}
