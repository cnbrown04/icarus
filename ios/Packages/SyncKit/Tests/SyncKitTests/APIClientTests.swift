import Foundation
import Testing
@testable import SyncKit

struct APIClientTests {
    @Test func sendsBearerTokenAndJSONAccept() async throws {
        let transport = ScriptedTransport()
        let client = APIClient(baseURL: testServer, token: "abc", transport: transport, now: { testNow })
        _ = try await client.send("GET", "/v1/sync/state")
        let request = try #require(await transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer abc")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.url.absoluteString == "https://icarus.test/v1/sync/state")
    }

    @Test func keepsAPathPrefixOfTheServerURL() async throws {
        let transport = ScriptedTransport()
        let client = APIClient(baseURL: URL(string: "https://host.test/icarus/")!, token: nil, transport: transport)
        _ = try await client.send("GET", "/v1/sync/config", query: [URLQueryItem(name: "since", value: "7")])
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://host.test/icarus/v1/sync/config?since=7")
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func decodesProblemDocumentAndSlug() async throws {
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(401, slug: "unauthorized", detail: "Token revoked")))
        let client = APIClient(baseURL: testServer, token: "abc", transport: transport)
        let body = Data("{}".utf8)
        do {
            _ = try await client.postBatch(body: body, batchID: "b1", contentEncoding: nil)
            Issue.record("Expected an HTTP error")
        } catch let APIError.http(status, problem, _) {
            #expect(status == 401)
            #expect(problem?.slug == "unauthorized")
            #expect(problem?.detail == "Token revoked")
        }
    }

    @Test func parsesRetryAfterSeconds() async throws {
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(429, slug: "rate-limited", detail: "Slow down", headers: ["Retry-After": "30"])))
        let client = APIClient(baseURL: testServer, token: "abc", transport: transport, now: { testNow })
        do {
            _ = try await client.postBatch(body: Data("{}".utf8), batchID: "b1", contentEncoding: nil)
            Issue.record("Expected an HTTP error")
        } catch let APIError.http(status, _, retryAfter) {
            #expect(status == 429)
            #expect(retryAfter == 30)
        }
    }

    @Test func parsesRetryAfterHTTPDate() {
        let later = RetryAfter.seconds("Wed, 07 Oct 2026 14:31:00 GMT", now: testNow)
        #expect(later == 60)
        let past = RetryAfter.seconds("Wed, 07 Oct 2026 14:00:00 GMT", now: testNow)
        #expect(past == 0)
        #expect(RetryAfter.seconds("soon", now: testNow) == nil)
        #expect(RetryAfter.seconds(nil, now: testNow) == nil)
    }

    @Test func networkFailureIsNotAnHTTPError() async throws {
        let transport = ScriptedTransport()
        await transport.queueBatch(.failure)
        let client = APIClient(baseURL: testServer, token: "abc", transport: transport)
        do {
            _ = try await client.postBatch(body: Data("{}".utf8), batchID: "b1", contentEncoding: nil)
            Issue.record("Expected a network error")
        } catch APIError.network {
            // expected
        }
    }

    @Test func serverURLNeedsHTTPSExceptForLocalhost() {
        #expect(ServerURL.parse("icarus.example.com")?.absoluteString == "https://icarus.example.com")
        #expect(ServerURL.parse("https://icarus.example.com/") != nil)
        #expect(ServerURL.parse("http://icarus.example.com") == nil)
        #expect(ServerURL.parse("http://localhost:8080")?.port == 8080)
        #expect(ServerURL.parse("   ") == nil)
    }
}
