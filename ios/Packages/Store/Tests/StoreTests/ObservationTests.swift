import Foundation
import Testing
@testable import Store

struct ObservationTests {
    @Test func emitsAgainAfterAWriteChangesTheResult() async throws {
        let database = try AppDatabase.inMemory()
        var iterator = database.observe { try $0.profile() }.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial == .some(nil))

        _ = try await database.writer.write { db in
            try db.saveProfile(ProfileRow(formulaSex: "female", birthYear: 1985), atMs: 1)
        }
        let updated = try await iterator.next()
        #expect(updated??.formulaSex == "female")
    }
}
