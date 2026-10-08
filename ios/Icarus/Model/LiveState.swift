import BandKit
import Foundation
import Observation

/// Live band data for Today, Device and the sparkline. Consumes a BandTransport.
@MainActor
@Observable
final class LiveState {
    enum Connection: Equatable {
        case idle
        case connected
        case disconnected
    }

    struct Sample: Identifiable, Equatable {
        let date: Date
        let bpm: Int

        var id: Date { date }
    }

    static let sparklineWindow: TimeInterval = 15 * 60

    private(set) var connection: Connection = .idle
    private(set) var latestBPM: Int?
    private(set) var lastDataAt: Date?
    private(set) var samples: [Sample] = []
    let sourceName: String

    private let transport: any BandTransport
    private let clock: AppClock
    private var consumeTask: Task<Void, Never>?

    init(transport: any BandTransport, sourceName: String, clock: AppClock) {
        self.transport = transport
        self.sourceName = sourceName
        self.clock = clock
    }

    /// Under -IcarusUITest, replays the bundled fixture with no pauses, so the final state is
    /// reached almost immediately. Otherwise, the synthetic generator runs in real time.
    static func makeForLaunch(_ config: LaunchConfig) -> LiveState {
        let clock = AppClock(fixedNow: config.fixedNow)
        if config.isUITest {
            let name = config.fixtureName ?? "resting_day"
            if let url = Bundle.main.url(forResource: name, withExtension: "ndjson"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return LiveState(
                    transport: FixtureTransport(ndjson: text, speed: .infinity),
                    sourceName: "Fixture \(name)",
                    clock: clock
                )
            }
        }
        return LiveState(
            transport: SyntheticTransport(seed: 1),
            sourceName: "Synthetic",
            clock: clock
        )
    }

    var connectionText: String {
        switch connection {
        case .idle: "Not connected"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }

    func start() {
        guard consumeTask == nil else { return }
        consumeTask = Task {
            await self.transport.start()
            for await event in self.transport.events {
                self.apply(event)
            }
        }
    }

    private func apply(_ event: BandEvent) {
        switch event {
        case .connected:
            connection = .connected
        case .disconnected:
            connection = .disconnected
        case let .hr(measurement, receivedAt):
            latestBPM = measurement.bpm
            lastDataAt = receivedAt
            samples.append(Sample(date: receivedAt, bpm: measurement.bpm))
            trimSamples()
        case .battery:
            break
        }
    }

    private func trimSamples() {
        let cutoff = clock.now.addingTimeInterval(-Self.sparklineWindow)
        let staleCount = samples.prefix(while: { $0.date < cutoff }).count
        if staleCount > 0 {
            samples.removeFirst(staleCount)
        }
    }
}
