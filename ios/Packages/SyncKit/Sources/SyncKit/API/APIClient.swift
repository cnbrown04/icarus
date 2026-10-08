import Foundation

/// Failures from the sync API. A non-2xx response carries its problem document when it has one.
public enum APIError: Error, Equatable, Sendable {
    /// No response arrived: offline, DNS, TLS, timeout.
    case network(String)
    case http(status: Int, problem: Problem?, retryAfter: TimeInterval?)
    case decoding(String)
    case invalidServerURL
}

/// RFC 9457 problem document (api-contract.md, Conventions).
public struct Problem: Decodable, Equatable, Sendable {
    public let type: String?
    public let title: String?
    public let status: Int?
    public let detail: String?

    /// `pairing-code-invalid` for `urn:icarus:problem:pairing-code-invalid`.
    public var slug: String? {
        guard let type else { return nil }
        let prefix = "urn:icarus:problem:"
        return type.hasPrefix(prefix) ? String(type.dropFirst(prefix.count)) : type
    }
}

/// Result of `POST /v1/sync/batches` that succeeded. A duplicate counts as success (api-contract.md, Sync).
public struct BatchReceipt: Equatable, Sendable {
    public let status: Int
    public let duplicate: Bool
    public let serverTime: String?
}

public struct APIClient: Sendable {
    public let baseURL: URL
    private let token: String?
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(baseURL: URL, token: String?, transport: any HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.now = now
    }

    /// Sends one request. Any non-2xx status throws `APIError.http`.
    public func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        try await perform(try makeRequest(method, path, query: query, headers: headers, body: body))
    }

    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.perform(request)
        } catch {
            throw APIError.network("Request failed")
        }
        guard (200..<300).contains(response.status) else {
            throw APIError.http(
                status: response.status,
                problem: try? JSONDecoder().decode(Problem.self, from: response.body),
                retryAfter: RetryAfter.seconds(response.header("Retry-After"), now: now())
            )
        }
        return response
    }

    /// Sends a request and decodes its 2xx body.
    public func json<T: Decodable & Sendable>(
        _ type: T.Type,
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        let response = try await send(method, path, query: query, headers: [:], body: body)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw APIError.decoding("Unexpected \(path) response")
        }
    }

    /// The request for one batch upload. The background session builds its URLRequest from this.
    public func batchRequest(batchID: String, contentEncoding: String?, body: Data?) throws -> HTTPRequest {
        var headers = ["Idempotency-Key": batchID]
        if let contentEncoding {
            headers["Content-Encoding"] = contentEncoding
        }
        return try makeRequest("POST", "/v1/sync/batches", query: [], headers: headers, body: body)
    }

    /// Uploads one batch body. A 2xx is success even when its body cannot be read.
    public func postBatch(body: Data, batchID: String, contentEncoding: String?) async throws -> BatchReceipt {
        let response = try await perform(try batchRequest(batchID: batchID, contentEncoding: contentEncoding, body: body))
        let decoded = try? JSONDecoder().decode(ReceiptBody.self, from: response.body)
        return BatchReceipt(
            status: response.status,
            duplicate: decoded?.duplicate ?? false,
            serverTime: decoded?.serverTime
        )
    }

    private struct ReceiptBody: Decodable {
        let duplicate: Bool?
        let serverTime: String?

        enum CodingKeys: String, CodingKey {
            case duplicate
            case serverTime = "server_time"
        }
    }

    private func makeRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data?
    ) throws -> HTTPRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidServerURL
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidServerURL }
        var headers = headers
        headers["Accept"] = "application/json"
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        return HTTPRequest(method: method, url: url, headers: headers, body: body)
    }
}

/// Retry-After as delta-seconds or an HTTP date (RFC 9110 10.2.3).
enum RetryAfter {
    static func seconds(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Server address typed by the user or read from a pairing link.
public enum ServerURL {
    /// `https://host[/path]`. A bare host gets https. Plain http is allowed for localhost only.
    public static func parse(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        if scheme == "https" { return url }
        guard scheme == "http", host == "localhost" || host == "127.0.0.1" else { return nil }
        return url
    }
}
