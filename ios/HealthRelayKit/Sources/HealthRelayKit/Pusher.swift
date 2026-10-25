import Foundation

/// A destination's delivery state: its dirty days, its queue of batches on
/// disk, its backoff and its log.
public struct Lane: Codable, Sendable, Equatable {
    public var dirty = DirtySet()
    /// Until the first run's days are delivered, batches hold one day.
    public var firstRun = true
    public var queue: [QueuedBatch] = []
    public var failures = 0
    public var retryAfter: Date?
    /// Set when the destination refused the credential; nothing is sent
    /// until the user edits the destination or a Test passes.
    public var attention: String?
    public var lastError: String?
    public var lastSuccess: Date?
    public var log: [LogEntry] = []

    public init() {}

    public static let logLimit = 50

    mutating func record(_ entry: LogEntry) {
        log.insert(entry, at: 0)
        if log.count > Lane.logLimit { log.removeLast(log.count - Lane.logLimit) }
    }

    /// Exponential backoff after a failure: 1 minute doubling to 6 hours.
    mutating func backOff(now: Date) {
        failures += 1
        let delay = Swift.min(60 * pow(2, Double(failures - 1)), 6 * 3600)
        retryAfter = now.addingTimeInterval(delay)
    }

    mutating func succeeded(now: Date) {
        failures = 0
        retryAfter = nil
        lastError = nil
        attention = nil
        lastSuccess = now
    }

    /// Whether a day is already in a queued batch read after its last mark.
    func covered(_ day: Day) -> Bool {
        guard let mark = dirty.markedAt(day) else { return true }
        return queue.contains { $0.days.contains(day) && mark <= $0.readAt }
    }
}

/// A batch written to disk before it is sent; retries send the same bytes.
public struct QueuedBatch: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var days: [Day]
    /// When its content was read from Health.
    public var readAt: Date
    public var bytes: Int
    public var records: Int
}

public struct LogEntry: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var at: Date
    public var days: [Day]
    public var delivery: Delivery
}

/// Sends a lane's batches, one in flight, a pause between them. It never
/// speaks HTTP: a DestinationType delivers.
struct Pusher {
    /// Batches above this many bytes are split (when they hold more than one day).
    static let maxBytes = 1_000_000
    static let spacing: Duration = .seconds(1)

    let files: FileStore
    let now: @Sendable () -> Date
    let pause: @Sendable (Duration) async -> Void

    /// Builds the push for some days: its body, and how many records it holds.
    typealias Build = ([Day]) async throws -> (body: Data, records: Int, readAt: Date)

    enum Stop: Equatable {
        /// Everything dirty was delivered.
        case done
        /// The destination failed; the lane is backing off or needs attention.
        case failed
        /// Reading Health failed; try again on the next trigger.
        case unreadable(String)
    }

    /// Sends the queue, then batches of the remaining dirty days, until the
    /// lane is clean or a delivery fails.
    func run(_ start: Lane, lane id: UUID, destination: DestinationType, build: Build) async -> (Lane, Stop) {
        var lane = start
        var sent = 0
        var attempted = Set<Day>()
        while true {
            if lane.queue.isEmpty {
                let pending = lane.dirty.days.filter { !attempted.contains($0) && !lane.covered($0) }
                guard let days = DirtyRules.batches(pending, firstRun: lane.firstRun).first else { break }
                attempted.formUnion(days)
                do {
                    for batch in try await split(days, build: build) {
                        try files.writeBatch(batch.body, lane: id, id: batch.meta.id)
                        lane.queue.append(batch.meta)
                    }
                } catch {
                    return (lane, .unreadable(error.localizedDescription))
                }
                continue
            }
            let batch = lane.queue[0]
            guard let body = files.readBatch(lane: id, id: batch.id) else {
                lane.queue.removeFirst()
                continue
            }
            if sent > 0 { await pause(Pusher.spacing) }
            let delivery = await destination.deliver(body)
            sent += 1
            let at = now()
            lane.record(LogEntry(at: at, days: batch.days, delivery: delivery))
            switch delivery.verdict {
            case .accepted:
                lane.queue.removeFirst()
                files.removeBatch(lane: id, id: batch.id)
                lane.dirty.clear(batch.days, readAt: batch.readAt)
                lane.succeeded(now: at)
            case .authFailed:
                lane.attention = delivery.message
                lane.lastError = delivery.message
                return (lane, .failed)
            case .rejected:
                // The same bytes would be refused again: drop them, keep the
                // days dirty for a fixed app or receiver, and back off.
                lane.queue.removeFirst()
                files.removeBatch(lane: id, id: batch.id)
                lane.lastError = delivery.message
                lane.backOff(now: at)
                return (lane, .failed)
            case .retry:
                lane.lastError = delivery.message
                lane.backOff(now: at)
                return (lane, .failed)
            }
        }
        if lane.dirty.isEmpty { lane.firstRun = false }
        return (lane, .done)
    }

    /// One batch for the days, or several when it would pass maxBytes.
    private func split(_ days: [Day], build: Build) async throws -> [(meta: QueuedBatch, body: Data)] {
        let made = try await build(days)
        if made.body.count > Pusher.maxBytes && days.count > 1 {
            let half = days.count / 2
            return try await split(Array(days[..<half]), build: build) + split(Array(days[half...]), build: build)
        }
        return [(QueuedBatch(id: UUID(), days: days, readAt: made.readAt, bytes: made.body.count, records: made.records), made.body)]
    }
}
