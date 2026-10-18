import Foundation

/// Age rules for live values (PLAN.md §15.4 rule 24, §7.2).
enum DataAge {
    /// Values older than this show their age on screen.
    static let staleAfter: TimeInterval = 60
    /// A gap longer than this shows the "Collection paused" banner.
    static let pausedAfter: TimeInterval = 600

    /// "42 s ago", "4 min ago", "3 h ago".
    static func text(seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0))
        if whole < 60 { return "\(whole) s ago" }
        if whole < 3600 { return "\(whole / 60) min ago" }
        return "\(whole / 3600) h ago"
    }

    /// The age to show for data received at `date`, or nil while the data is fresh.
    static func staleText(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let age = now.timeIntervalSince(date)
        return age > staleAfter ? text(seconds: age) : nil
    }

    static func isPaused(since date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) > pausedAfter
    }
}
