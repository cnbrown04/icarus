import BandKit
import Foundation
import Testing

@Suite struct BandIdentityStoreTests {
    private func makeStore() throws -> (UserDefaultsBandIdentityStore, UserDefaults, String) {
        let suite = "icarus.bandkit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (UserDefaultsBandIdentityStore(defaults: defaults), defaults, suite)
    }

    @Test func emptyStoreHasNoBand() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.load() == nil)
    }

    @Test func savedBandSurvivesANewStoreInstance() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try #require(UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1"))
        store.save(RememberedBand(id: id, name: "Band A"))

        let reloaded = UserDefaultsBandIdentityStore(defaults: defaults)
        #expect(reloaded.load() == RememberedBand(id: id, name: "Band A"))
    }

    @Test func savingNilForgetsTheBand() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.save(RememberedBand(id: UUID(), name: nil))
        store.save(nil)
        #expect(store.load() == nil)
    }
}
