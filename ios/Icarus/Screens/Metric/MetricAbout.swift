import Metrics

/// The method and estimate text for each metric, shown once in the page's "About" disclosure. Nothing else in the
/// app repeats it, so a metric's method is stated in one place.
enum MetricAbout {
    static func sentences(_ kind: MetricKind) -> [String] {
        switch kind {
        case .heartRate:
            [
                "Each point is the average of one minute of band readings.",
                "Zones are shares of your heart-rate reserve, from your resting and maximum heart rate.",
            ]
        case .restingHR:
            ["Taken from the main sleep of the day."]
        case .hrv:
            [
                "RMSSD, from the beat-to-beat intervals in the main sleep of the day.",
                "Estimated from the band's sensor data, not a clinical measure.",
            ]
        case .stress:
            [
                "Estimated from heart-rate variability and heart rate, against your own baseline.",
                "Values need 7 qualifying days before they appear. Until then the state reads Calibrating.",
                "Stimulant windows are estimated from your profiles and logged doses.",
            ]
        case .respiratoryRate:
            [
                "Estimated from heart-rhythm variation in the main sleep.",
                "Blank when the signal is too thin.",
            ]
        case .recovery:
            [
                "Estimated from your own 30-night baseline of HRV, resting heart rate, respiratory rate and sleep performance.",
                "Calibrating until the baseline has enough nights.",
            ]
        case .strain:
            [
                "Estimated from heart rate against your resting and maximum heart rate.",
                "The target is a heuristic, not a WHOOP score.",
            ]
        case .calories:
            [
                "Estimated from heart rate and your profile.",
                "Active and resting are estimates too.",
            ]
        case .sleep:
            ["Sleep is shown on the Sleep tab."]
        }
    }
}
