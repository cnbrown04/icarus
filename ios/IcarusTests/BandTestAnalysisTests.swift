import Foundation
import Metrics
import Store
import Testing
@testable import Icarus

struct BandTestAnalysisTests {
    /// A run whose steps follow each other, `seconds` long each (still and the two wear spans 20 minutes).
    private func marks(skipping skipped: Set<BandTestStep> = []) -> [BandTestMark] {
        var start: Int64 = 0
        return BandTestStep.allCases.map { step in
            let length: Int64 = [.still, .off, .on].contains(step) ? 1_200_000 : 60_000
            defer { start += length }
            return BandTestMark(runID: "r", step: step.rawValue, label: step.title, startMs: start,
                                endMs: start + length, skipped: skipped.contains(step))
        }
    }

    private func mark(_ step: BandTestStep, in marks: [BandTestMark]) -> BandTestMark {
        marks.first { $0.step == step.rawValue }!
    }

    @Test func anEventSeenInBothChargerStepsIsProposedAsChargingOn() {
        let run = marks()
        let events = [BandTestStep.chargerOn, .chargerOnAgain].map { step in
            StoredBandEvent(tsMs: mark(step, in: run).startMs + 5_000, kind: "event_42", id: 42, hex: "01")
        }
        let results = BandTestAnalysis.results(marks: run, events: events, samples: [])
        let finding = results.events.first { $0.id == 42 }
        #expect(finding?.proposed == .chargingOn)
        #expect(finding?.name == "Event 42")
        #expect(results.silentActions.contains(.doubleTap))
    }

    @Test func anEventSeenInTwoDifferentActionsIsNotProposed() {
        let run = marks()
        let events = [BandTestStep.chargerOn, .doubleTap].map { step in
            StoredBandEvent(tsMs: mark(step, in: run).startMs + 5_000, kind: "event_42", id: 42, hex: nil)
        }
        let results = BandTestAnalysis.results(marks: run, events: events, samples: [])
        #expect(results.events.first?.proposed == nil)
    }

    @Test func skippedStepsNeverCount() {
        let run = marks(skipping: [.chargerOn, .chargerOnAgain])
        let events = [BandTestStep.chargerOn, .chargerOnAgain].map { step in
            StoredBandEvent(tsMs: mark(step, in: run).startMs + 5_000, kind: "event_42", id: 42, hex: nil)
        }
        let results = BandTestAnalysis.results(marks: run, events: events, samples: [])
        #expect(results.events.isEmpty)
        #expect(!results.silentActions.contains(.chargingOn))
    }

    @Test func aSlowChannelThatMovesOffAndBackPassesAndAFastOneFails() {
        let run = marks()
        let off = mark(.off, in: run), on = mark(.on, in: run)
        let samples = stride(from: Int64(0), to: on.endMs, by: 1_000).map { ts -> BandTestSample in
            let t = Double(ts) / 1000
            let slow: Double
            if ts < off.startMs {
                slow = 300
            } else if ts < on.startMs {
                slow = 300 + 40 * (1 - exp(-(t - Double(off.startMs) / 1000) / 400))
            } else {
                slow = 300 + 38 * exp(-(t - Double(on.startMs) / 1000) / 300)
            }
            let fast = 600 + 11 * (Int(t) % 2)
            return BandTestSample(tsMs: ts, frame72: fast, frame76: Int(slow.rounded()))
        }
        let results = BandTestAnalysis.results(marks: run, events: [], samples: samples)
        let byChannel = Dictionary(uniqueKeysWithValues: results.temperature.map { ($0.channel, $0.verdict) })
        #expect(byChannel["Frame 76"]??.passes == true)
        #expect(byChannel["Frame 72"]??.passes == false)
        #expect(byChannel["Frame 92"] == .some(nil))
    }
}

struct BandTestReportTests {
    @Test func channelMinutesAverageEachMinuteFromTheRunStart() {
        let samples = [
            BandTestSample(tsMs: 1_000, frame76: 300),
            BandTestSample(tsMs: 30_000, frame76: 302),
            BandTestSample(tsMs: 61_000, frame76: 310, frame92: 7),
        ]
        let minutes = BandTestAnalysis.channelMinutes(samples, from: 0)
        #expect(minutes.map(\.minute) == [0, 1])
        #expect(minutes[0].frame76 == 301)
        #expect(minutes[0].frame92 == nil)
        #expect(minutes[1].frame92 == 7)
    }

    @Test func anInProgressRunRoundTrips() {
        let saved = BandTestRunner.InProgress(runID: "r", step: 2, startedAt: Date(timeIntervalSince1970: 100))
        saved.save()
        #expect(BandTestRunner.InProgress.saved == saved)
        BandTestRunner.InProgress.clear()
        #expect(BandTestRunner.InProgress.saved == nil)
    }
}

struct BandTestEventTimingTests {
    /// Real charging-on payloads from the first run: the band's time is bytes 1–4, and each event arrived twice.
    @Test func eventsArePlacedByTheBandsTimeAndKeptOnce() {
        let bandSeconds: Int64 = 0x6AE7_EE42
        let events = [
            StoredBandEvent(tsMs: bandSeconds * 1000 + 300, kind: "charging_on", id: 7, hex: "0042eee76a583d0000"),
            StoredBandEvent(tsMs: bandSeconds * 1000 + 300, kind: "event_21", id: 21, hex: "0042eee76a403c0000"),
            StoredBandEvent(tsMs: bandSeconds * 1000 + 95_000, kind: "charging_on", id: 7, hex: "0042eee76a583d0000"),
        ]
        let distinct = BandTestAnalysis.distinctEvents(events)
        #expect(distinct.count == 2)
        #expect(distinct.allSatisfy { $0.tsMs == bandSeconds * 1000 })
        #expect(BandTestAnalysis.companion(of: 21, in: distinct) == "Charging on")
        #expect(BandTestAnalysis.companion(of: 7, in: distinct) == nil)
    }
}
