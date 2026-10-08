#if canImport(Darwin)
import Foundation
import Synchronization

/// Uploads batch files on a background URLSession (PLAN.md 11.2). The system finishes an upload while the app is
/// suspended, and the app may be relaunched for it. Each finished upload leaves a result file for the engine to
/// settle on its next run. The app delegate passes `handleEvents` on relaunch.
public final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = "com.cnbrown04.icarus.upload"

    /// Completion from the system's relaunch event, held until the session reports it has finished delivering.
    private static let pendingCompletion = Mutex<PendingCompletion?>(nil)

    /// UIKit hands over a plain closure; it is only stored here and called once on the main queue.
    private struct PendingCompletion: @unchecked Sendable {
        let run: () -> Void
    }

    private let outbox: Outbox
    private var session: URLSession!

    /// The session is created at launch. The system reconnects a background session only if it exists.
    public init(outbox: Outbox) {
        self.outbox = outbox
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Queues an upload from `file`. The task's description carries the batch id back to the delegate.
    public func enqueue(batchID: String, file: URL, request: HTTPRequest) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: urlRequest, fromFile: file)
        task.taskDescription = batchID
        task.resume()
    }

    /// Called by the app delegate when the system relaunches the app for this session. The handler runs once the
    /// session has delivered its events.
    public static func handleEvents(completion: @escaping () -> Void) {
        let pending = PendingCompletion(run: completion)
        pendingCompletion.withLock { $0 = pending }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let batchID = task.taskDescription else { return }
        let http = task.response as? HTTPURLResponse
        let retryAfter = http.flatMap { RetryAfter.seconds($0.value(forHTTPHeaderField: "Retry-After"), now: Date()) }
        let result = BackgroundResult(
            status: http?.statusCode,
            message: error == nil ? nil : "Upload failed",
            retryAfter: retryAfter
        )
        try? outbox.writeResult(result, id: batchID)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = Self.pendingCompletion.withLock { value -> PendingCompletion? in
            let pending = value
            value = nil
            return pending
        }
        DispatchQueue.main.async { handler?.run() }
    }
}
#endif
