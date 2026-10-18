import Foundation
import Testing
@testable import Store

struct UUIDv7Tests {
    @Test func versionVariantAndTimestampAreSet() {
        let ms: Int64 = 1_791_383_400_123
        let uuid = UUIDv7.make(unixMs: ms)
        let text = uuid.uuidString.lowercased()
        let digits = text.replacingOccurrences(of: "-", with: "")
        #expect(digits.count == 32)
        #expect(digits[digits.index(digits.startIndex, offsetBy: 12)] == "7")
        #expect("89ab".contains(digits[digits.index(digits.startIndex, offsetBy: 16)]))
        #expect(Int64(digits.prefix(12), radix: 16) == ms)
    }

    @Test func laterTimesSortAfterEarlierOnes() {
        let earlier = UUIDv7.make(unixMs: 1_000).uuidString.lowercased()
        let later = UUIDv7.make(unixMs: 2_000).uuidString.lowercased()
        #expect(earlier < later)
    }

    @Test func seededGeneratorIsReproducible() {
        var first = SplitMix64(seed: 7)
        var second = SplitMix64(seed: 7)
        #expect(UUIDv7.make(unixMs: 5, using: &first) == UUIDv7.make(unixMs: 5, using: &second))
    }
}
