import Foundation

/// What started a sync.
public enum Trigger: String, Sendable, Codable {
    case manual
    case foreground
    case refresh
    case observer
}

/// One destination as the screens show it.
public struct DestinationStatus: Sendable, Identifiable, Equatable {
    public var destination: Destination
    public var lane: Lane
    public var hasToken: Bool

    public var id: UUID { destination.id }
}

public struct Snapshot: Sendable, Equatable {
    public var destinations: [DestinationStatus] = []
    public var lastSync: Date?
    public var lastSuccess: Date?
    public var lastSyncMessage: String?
    public var syncing = false
    public var deviceName = "iPhone"

    public init() {}
}

public struct SyncReport: Sendable, Equatable {
    public var trigger: Trigger
    public var startedAt: Date
    /// Destinations that were sent to and are now clean.
    public var delivered: Int = 0
    /// Destinations that failed or were waiting out a backoff.
    public var failed: Int = 0
    public var message: String
}

/// The one serialized sync across all destinations (docs/design.md), and
/// the operations the screens need. All triggers call `sync`.
public actor Engine {
    public struct Environment: Sendable {
        public var store: HealthStore
        public var files: FileStore
        public var tokens: TokenStore
        /// The device block of every push; the name is the user's setting.
        public var device: @Sendable (_ name: String) -> Device
        public var calendar: @Sendable () -> Calendar
        public var now: @Sendable () -> Date
        public var pause: @Sendable (Duration) async -> Void
        public var makeDestination: @Sendable (Destination, String?) -> DestinationType

        public init(store: HealthStore, files: FileStore, tokens: TokenStore,
                    device: @escaping @Sendable (String) -> Device,
                    calendar: @escaping @Sendable () -> Calendar = { .local() },
                    now: @escaping @Sendable () -> Date = { Date() },
                    pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                    makeDestination: @escaping @Sendable (Destination, String?) -> DestinationType = Engine.httpDestination) {
            self.store = store
            self.files = files
            self.tokens = tokens
            self.device = device
            self.calendar = calendar
            self.now = now
            self.pause = pause
            self.makeDestination = makeDestination
        }
    }

    /// Observer wakes within this long of the last sync are dropped.
    public static let wakeThrottle: TimeInterval = 5 * 60
    /// A foreground sync runs when the last success is older than this.
    public static let foregroundAge: TimeInterval = 3600

    public static let httpDestination: @Sendable (Destination, String?) -> DestinationType = { d, token in
        switch d.kind {
        case .http(let endpoint): HTTPEndpointDestination(endpoint: endpoint, token: token)
        }
    }

    let env: Environment
    private(set) var state: EngineState
    private var running: Task<SyncReport, Never>?
    private var observers: [@Sendable (Snapshot) -> Void] = []

    public init(_ env: Environment) {
        self.env = env
        state = env.files.load()
    }

    // MARK: Status

    public var snapshot: Snapshot {
        var s = Snapshot()
        s.destinations = state.destinations.map {
            DestinationStatus(destination: $0, lane: state.lanes[$0.id] ?? Lane(), hasToken: env.tokens.token(for: $0.id) != nil)
        }
        s.lastSync = state.lastSync
        s.lastSuccess = state.lastSuccess
        s.lastSyncMessage = state.lastSyncMessage
        s.syncing = running != nil
        s.deviceName = state.deviceName
        return s
    }

    /// Called with a fresh snapshot after every change.
    public func observe(_ body: @escaping @Sendable (Snapshot) -> Void) {
        observers.append(body)
        body(snapshot)
    }

    private func changed() {
        env.files.save(state)
        let s = snapshot
        for o in observers { o(s) }
    }

    public func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.deviceName = trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(60))
        changed()
    }

    // MARK: Destinations

    /// Adds a destination; its first run sends the last 30 days.
    @discardableResult
    public func add(_ destination: Destination, token: String?) -> Destination {
        state.destinations.append(destination)
        env.tokens.setToken(token, for: destination.id)
        var lane = Lane()
        lane.dirty.mark(readable(DirtyRules.last(DirtyRules.firstRunDays, today: today())), at: env.now())
        state.lanes[destination.id] = lane
        if state.lastSweep == nil { state.lastSweep = env.now() }
        changed()
        return destination
    }

    /// Saves edits; a changed credential or URL clears needs-attention and backoff.
    public func update(_ destination: Destination, token: String?) {
        guard let i = state.destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        state.destinations[i] = destination
        env.tokens.setToken(token, for: destination.id)
        state.lanes[destination.id]?.attention = nil
        state.lanes[destination.id]?.failures = 0
        state.lanes[destination.id]?.retryAfter = nil
        changed()
    }

    public func setPaused(_ id: UUID, _ paused: Bool) {
        guard let i = state.destinations.firstIndex(where: { $0.id == id }) else { return }
        state.destinations[i].paused = paused
        changed()
    }

    /// Removes a destination with its dirty days, queue, log and token;
    /// removing the last one also resets the anchors.
    public func remove(_ id: UUID) {
        state.destinations.removeAll { $0.id == id }
        state.lanes[id] = nil
        env.files.removeLane(id)
        env.tokens.setToken(nil, for: id)
        if state.destinations.isEmpty {
            state.anchors.reset()
            state.lastSweep = nil
        }
        changed()
    }

    public func token(for id: UUID) -> String? { env.tokens.token(for: id) }

    /// Sends the empty push and returns the answer; a pass clears
    /// needs-attention and backoff.
    public func test(_ id: UUID) async -> Delivery {
        guard let d = state.destinations.first(where: { $0.id == id }) else {
            return Delivery(status: nil, verdict: .rejected, message: "No such destination")
        }
        let push = Push.empty(device: env.device(state.deviceName), at: env.now(), timeZone: env.calendar().timeZone)
        let delivery = await env.makeDestination(d, env.tokens.token(for: id)).deliver(push.body)
        if var lane = state.lanes[id] {
            lane.record(LogEntry(at: env.now(), days: [], delivery: delivery))
            if delivery.verdict == .accepted {
                lane.attention = nil
                lane.failures = 0
                lane.retryAfter = nil
            }
            state.lanes[id] = lane
            changed()
        }
        return delivery
    }

    /// Marks the last `n` days dirty for every destination (they go with the next sync).
    public func resend(lastDays n: Int) {
        let days = DirtyRules.last(max(1, n), today: today())
        let at = env.now()
        for id in state.lanes.keys { state.lanes[id]!.dirty.mark(readable(days), at: at) }
        changed()
    }

    // MARK: Sync

    /// For an observer wake: joins a running sync, drops a wake soon after
    /// the last one, otherwise syncs.
    public func wake() async {
        if let running {
            _ = await running.value
            return
        }
        if let last = state.lastSync, env.now().timeIntervalSince(last) < Engine.wakeThrottle { return }
        _ = await sync(.observer)
    }

    /// For coming to the foreground: syncs when the last success is old.
    public func syncIfStale() async {
        if let last = state.lastSuccess, env.now().timeIntervalSince(last) < Engine.foregroundAge { return }
        _ = await sync(.foreground)
    }

    /// The sync. A call while one runs waits for it and returns its report.
    @discardableResult
    public func sync(_ trigger: Trigger) async -> SyncReport {
        if let running { return await running.value }
        let task = Task { await self.run(trigger) }
        running = task
        changed()
        let report = await task.value
        running = nil
        changed()
        return report
    }

    private func today() -> Day { Day(env.now(), calendar: env.calendar()) }

    /// Health access was granted. Since iOS 27 the user may share only the
    /// 30 days before that and later; a listed day is owned by the push, so
    /// a day the app may not be able to read must never be listed, or its
    /// data would be removed at the destination. Kept from the first grant.
    public func noteAuthorized() {
        guard state.readableFrom == nil else { return }
        state.readableFrom = today().adding(-(DirtyRules.firstRunDays - 1))
        for id in state.lanes.keys { state.lanes[id]!.dirty.keep { readable($0) } }
        changed()
    }

    private func readable(_ days: [Day]) -> [Day] {
        guard let from = state.readableFrom else { return days }
        return days.filter { $0 >= from }
    }

    private func readable(_ day: Day) -> Bool { readable([day]) == [day] }

    private func run(_ trigger: Trigger) async -> SyncReport {
        let calendar = env.calendar()
        let started = env.now()
        var report = SyncReport(trigger: trigger, startedAt: started, message: "")
        state.lastSync = started
        guard !state.destinations.isEmpty else {
            report.message = "No destinations"
            state.lastSyncMessage = report.message
            return report
        }

        // 1. What changed since the anchors, today and yesterday, and the
        // weekly sweep: dirty for every destination, paused ones included.
        var marked = Set(DirtyRules.recent(today: Day(started, calendar: calendar)))
        var changedDays = Set<Day>()
        var pending: [String: Data] = [:]
        let windowStart = Day(started, calendar: calendar).adding(-(DirtyRules.changeWindowDays - 1)).start(in: calendar)
        let firstRunStart = Day(started, calendar: calendar).adding(-(DirtyRules.firstRunDays - 1)).start(in: calendar)
        do {
            for type in Catalog.allTypes {
                let anchor = state.anchors.anchor(for: type)
                let changes = try await env.store.changes(type, anchor: anchor, since: anchor == nil ? firstRunStart : windowStart)
                for interval in changes.added where interval.end >= windowStart {
                    changedDays.formUnion(DirtyRules.days(of: interval, calendar: calendar))
                }
                if let a = changes.anchor { pending[type.id] = a }
            }
        } catch {
            report.message = Engine.describe(error)
            state.lastSyncMessage = report.message
            return report
        }
        let today = Day(started, calendar: calendar)
        changedDays = changedDays.filter { $0 <= today }
        marked.formUnion(changedDays)
        if let sweep = state.lastSweep, started.timeIntervalSince(sweep) >= DirtyRules.sweepInterval {
            marked.formUnion(DirtyRules.last(DirtyRules.sweepDays, today: today))
            state.lastSweep = started
        }
        let send = readable(Array(marked))
        for id in state.lanes.keys { state.lanes[id]!.dirty.mark(send, at: started) }
        changed()

        // 2. Each active destination in turn, sharing what was read.
        let reader = DayReader(store: env.store, calendar: calendar)
        var cache: [Day: Content] = [:]
        let deviceName = state.deviceName
        let build: Pusher.Build = { [env] days in
            let missing = days.filter { cache[$0] == nil }
            if !missing.isEmpty {
                for (d, c) in try await reader.read(missing) { cache[d] = c }
            }
            let readAt = env.now()
            let content = Content.merging(days.map { cache[$0] ?? Content() })
            let push = Push(device: env.device(deviceName), exportedAt: readAt, timeZone: calendar.timeZone, days: days, content: content)
            return (push.body, content.recordCount, readAt)
        }
        let pusher = Pusher(files: env.files, now: env.now, pause: env.pause)
        var unreadable: String?
        for d in state.destinations where !d.paused {
            guard var lane = state.lanes[d.id], lane.attention == nil else { continue }
            if let after = lane.retryAfter, after > env.now() {
                report.failed += 1
                continue
            }
            let destination = env.makeDestination(d, env.tokens.token(for: d.id))
            let stop: Pusher.Stop
            (lane, stop) = await pusher.run(lane, lane: d.id, destination: destination, build: build)
            // The destination may have been removed while this one sent.
            if state.lanes[d.id] != nil { state.lanes[d.id] = lane }
            changed()
            switch stop {
            case .done: report.delivered += 1
            case .failed: report.failed += 1
            case .unreadable(let message):
                unreadable = message
            }
            if unreadable != nil { break }
        }

        // 3. Anchors advance when no active destination still has a changed day dirty.
        let active = state.destinations.filter { !$0.paused && state.lanes[$0.id]?.attention == nil }
        let held = active.contains { d in changedDays.contains { state.lanes[d.id]?.dirty.contains($0) ?? false } }
        if !held && unreadable == nil { state.anchors.commit(pending) }

        if let unreadable {
            report.message = unreadable
        } else {
            state.lastSuccess = env.now()
            report.message = report.failed == 0 ? "Up to date" : "\(report.failed) destination\(report.failed == 1 ? "" : "s") will retry"
        }
        state.lastSyncMessage = report.message
        return report
    }

    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("protected health data") {
            return "Health data is unavailable while the phone is locked"
        }
        return text
    }

    // MARK: Types

    /// For each catalog type, the newest sample in the last 30 days (nil:
    /// none, perhaps because reading it was not allowed).
    public func recentData() async -> [(HealthType, Date?)] {
        let since = env.now().addingTimeInterval(-30 * 86400)
        var out: [(HealthType, Date?)] = []
        for type in Catalog.allTypes {
            out.append((type, try? await env.store.newestSample(type, since: since)))
        }
        return out
    }
}
