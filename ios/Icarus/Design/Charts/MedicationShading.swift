import Metrics

extension Array where Element == MedicationWindow {
    /// The windows clipped to `startMs...endMs`, with empty results dropped. Charts size their x axis to the marks
    /// they draw, so a window that starts before the visible span would stretch the axis. Clipping keeps it fixed.
    func clipped(toMs startMs: Int64, _ endMs: Int64) -> [MedicationWindow] {
        compactMap { window in
            let start = Swift.max(window.startMs, startMs)
            let end = Swift.min(window.endMs, endMs)
            guard end > start else { return nil }
            var clipped = window
            clipped.startMs = start
            clipped.endMs = end
            return clipped
        }
    }
}
