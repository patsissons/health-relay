import Foundation

/// Uploads a part with iOS's background transfer service, so a large part keeps
/// going after the app is suspended. The answer waits in a small file for the
/// next run, so nothing is sent twice because the app went away.
public final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Outcome: Codable, Sendable, Equatable {
        public var status: Int?
        public var body: Data
        public var error: String?
    }

    public static let identifier = "com.patsissons.healthdatarelay.uploads"

    private let lock = NSLock()
    private let folder: URL
    private var session: URLSession!
    private var bodies: [Int: Data] = [:]
    private var waiting: [String: CheckedContinuation<Outcome?, Never>] = [:]
    private var finishEvents: (@Sendable () -> Void)?

    public init(folder: URL, configuration: URLSessionConfiguration? = nil) {
        self.folder = folder
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = configuration ?? {
            let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            c.isDiscretionary = false
            c.sessionSendsLaunchEvents = true
            return c
        }()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// iOS finished uploads while the app was away, and wants to know when
    /// their answers have been recorded.
    public func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = completion }
    }

    private func outcomeURL(_ key: String) -> URL {
        folder.appendingPathComponent(key + ".json")
    }

    private func saved(_ key: String) -> Outcome? {
        (try? Data(contentsOf: outcomeURL(key))).flatMap { try? JSONDecoder().decode(Outcome.self, from: $0) }
    }

    /// Uploads, or picks up an upload already under way or finished for this
    /// key. Nil means it's still going after `wait`, and the next run asks again.
    public func upload(_ request: URLRequest, file: URL, key: String, wait: Duration) async -> Outcome? {
        if let done = saved(key) { return done }
        let tasks = await session.allTasks
        let already = tasks.contains { $0.taskDescription == key && $0.state != .completed }
        if !already {
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = key
            task.resume()
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome?, Never>) in
            lock.withLock { waiting[key] = c }
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                self?.resume(key, with: nil)
            }
        }
    }

    private func resume(_ key: String, with outcome: Outcome?) {
        let c: CheckedContinuation<Outcome?, Never>? = lock.withLock { waiting.removeValue(forKey: key) }
        c?.resume(returning: outcome)
    }

    /// Forgets an answer once the run has acted on it.
    public func clear(key: String) {
        try? FileManager.default.removeItem(at: outcomeURL(key))
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            // An answer's message is all that's wanted; a huge body isn't kept.
            if (bodies[dataTask.taskIdentifier]?.count ?? 0) < 64 * 1024 {
                bodies[dataTask.taskIdentifier, default: Data()].append(data)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let body: Data = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) ?? Data() }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let outcome = Outcome(status: status, body: body, error: error?.localizedDescription)
        if let data = try? JSONEncoder().encode(outcome) {
            try? data.write(to: outcomeURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        resume(key, with: outcome)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done: (@Sendable () -> Void)? = lock.withLock {
            defer { finishEvents = nil }
            return finishEvents
        }
        done?()
    }
}
