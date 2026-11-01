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
    public var pipelines: [Pipeline] = []
    public var lastSync: Date?
    public var lastSuccess: Date?
    public var lastSyncMessage: String?
    public var syncing = false
    /// What a running sync is doing; nil when none runs.
    public var progress: SyncProgress?
    /// Off: only Sync now (and Re-send) sync.
    public var autoSync = false
    public var deviceName = "iPhone"
    /// Saved settings could not be decoded, so the app started fresh; the
    /// old file is kept until the user dismisses this.
    public var stateSetAside = false
    public var backgroundPlan = BackgroundPlan()

    public init() {}
}

/// A running sync's current step, how far through that step it is, and how
/// far through the whole sync, each 0 to 1.
public struct SyncProgress: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Asking Health which days changed, one type at a time.
        case checking
        /// Reading days from Health to build a batch.
        case reading([Day])
        /// A batch going to a destination.
        case sending([Day], to: String)
        /// A template writing its output.
        case rendering(String)
        /// One part of a template's output going to its destination.
        case sendingPart(Int, of: Int, to: String)
    }

    public var step: Step
    public var item: Double
    public var overall: Double

    public init(step: Step, item: Double, overall: Double) {
        self.step = step
        self.item = item
        self.overall = overall
    }

    /// Checking for changes takes this share of the whole; delivering the
    /// days takes the rest, by days delivered.
    static let checkingShare = 0.15
    /// Of a batch, reading takes this share; the rest is its delivery.
    static let readingShare = 0.9
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
        /// The richer reads template pipelines use.
        public var queries: HealthQuerying?
        public var makeTransport: @Sendable (LoadTarget, TransportContext) -> ArtifactTransport
        public var templateSource: @Sendable (TemplateRef) -> String?

        public init(store: HealthStore, files: FileStore, tokens: TokenStore,
                    device: @escaping @Sendable (String) -> Device,
                    calendar: @escaping @Sendable () -> Calendar = { .local() },
                    now: @escaping @Sendable () -> Date = { Date() },
                    pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                    makeDestination: @escaping @Sendable (Destination, String?) -> DestinationType = Engine.httpDestination,
                    queries: HealthQuerying? = nil,
                    makeTransport: @escaping @Sendable (LoadTarget, TransportContext) -> ArtifactTransport = Engine.standardTransport,
                    templateSource: @escaping @Sendable (TemplateRef) -> String? = Engine.builtInSource) {
            self.queries = queries
            self.makeTransport = makeTransport
            self.templateSource = templateSource
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
    /// A background sync starts no more work after this long. iOS gives
    /// background work about 30 seconds, and this leaves room for what is
    /// already under way to finish.
    public static let backgroundBudget: TimeInterval = 25
    static let outOfTime = "Stopped at the background time limit; the next sync carries on"
    public static let lockedMessage = "Health data is unavailable while the phone is locked"

    public static let httpDestination: @Sendable (Destination, String?) -> DestinationType = { d, token in
        switch d.kind {
        case .http(let endpoint): HTTPEndpointDestination(endpoint: endpoint, token: token)
        case .target: RefusingDestination()
        }
    }

    public static let standardTransport: @Sendable (LoadTarget, TransportContext) -> ArtifactTransport = { target, context in
        switch target {
        case .web(let web): WebTransport(target: web, context: context)
        }
    }

    public static let builtInSource: @Sendable (TemplateRef) -> String? = { ref in
        guard case .builtIn(let id) = ref else { return nil }
        return BuiltInTemplates.source(id)
    }

    let env: Environment
    private(set) var state: EngineState
    private var running: Task<SyncReport, Never>?
    /// When the running sync stops starting work; nil: when it is done.
    private var limit: Date?
    /// The pipelines the running sync covers; nil: all of them.
    private var chosen: Set<UUID>?
    /// Pipelines waiting for the running sync to finish, oldest first.
    private var queued: [UUID] = []
    private var stateSetAside: Bool
    private var observers: [@Sendable (Snapshot) -> Void] = []
    private var lastSnapshot: Snapshot?
    private var progress: SyncProgress?
    private var published: SyncProgress?
    private var publishedAt = ContinuousClock.now
    /// While delivering: days to deliver, days delivered, and the batch in hand.
    private var plan = (total: 0, done: 0, batch: 0, destination: "")
    /// Ranges picked for asked pipelines about to run.
    private var answers: [UUID: DateInterval] = [:]

    public init(_ env: Environment) {
        self.env = env
        state = env.files.load()
        stateSetAside = !env.files.setAsideStates().isEmpty
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
        s.progress = progress
        s.deviceName = state.deviceName
        s.autoSync = state.autoSync ?? false
        s.stateSetAside = stateSetAside
        s.backgroundPlan = state.backgroundPlan
        s.pipelines = s.destinations.map {
            Pipeline(destination: $0.destination, lane: $0.lane, hasToken: $0.hasToken,
                     trigger: state.trigger(for: $0.id), activity: activity($0.id), definition: state.definitions?[$0.id])
        }
        return s
    }

    /// Called with a fresh snapshot after every change.
    public func observe(_ body: @escaping @Sendable (Snapshot) -> Void) {
        observers.append(body)
        body(snapshot)
    }

    private func activity(_ id: UUID) -> Pipeline.Activity {
        if running != nil, chosen?.contains(id) ?? true { return .running }
        return queued.contains(id) ? .queued : .idle
    }

    /// Loads the saved state if it could not be read earlier (the app woke
    /// before the first unlock). True when it did.
    @discardableResult
    public func reloadIfUnreadable() -> Bool {
        guard running == nil, env.files.isUnreadable else { return false }
        let loaded = env.files.load()
        guard !env.files.isUnreadable else { return false }
        state = loaded
        stateSetAside = !env.files.setAsideStates().isEmpty
        changed()
        return true
    }

    /// The user has seen that saved settings were lost; the old file goes.
    public func dismissSetAsideState() {
        env.files.removeSetAsideStates()
        stateSetAside = false
        changed()
    }

    private func changed() {
        env.files.save(state)
        let s = snapshot
        lastSnapshot = s
        published = progress
        for o in observers { o(s) }
    }

    /// Progress goes to observers without saving state: a new step or a
    /// finished one at once, otherwise at most ten times a second.
    private func show(_ step: SyncProgress.Step, item: Double, overall: Double) {
        let p = SyncProgress(step: step, item: min(max(item, 0), 1), overall: min(max(overall, 0), 1))
        progress = p
        let now = ContinuousClock.now
        if let last = published, last.step == p.step, p.item < 1, now - publishedAt < .milliseconds(100) { return }
        published = p
        publishedAt = now
        var s = lastSnapshot ?? snapshot
        s.progress = p
        lastSnapshot = s
        for o in observers { o(s) }
    }

    /// Delivery progress: the batch in hand counts for `item` of its days.
    private func show(_ step: SyncProgress.Step, item: Double) {
        let total = max(plan.total, 1)
        let days = min(Double(plan.done) + item * Double(plan.batch), Double(total))
        show(step, item: item, overall: SyncProgress.checkingShare + (1 - SyncProgress.checkingShare) * days / Double(total))
    }

    private func reading(_ days: [Day], _ fraction: Double) {
        plan.batch = days.count
        show(.reading(days), item: fraction * SyncProgress.readingShare)
    }

    private func delivering(_ step: Pusher.Step) {
        switch step {
        case .sending(let days):
            plan.batch = days.count
            show(.sending(days, to: plan.destination), item: SyncProgress.readingShare)
        case .accepted(let days):
            show(.sending(days, to: plan.destination), item: 1)
            plan.done += days.count
            plan.batch = 0
        }
    }

    /// Turns syncing on Health's wakes, the morning refresh and coming to
    /// the foreground on or off. Off by default.
    public func setAutoSync(_ on: Bool) {
        state.autoSync = on
        state.triggers = nil
        changed()
    }

    public func setTrigger(_ id: UUID, _ trigger: PipelineTrigger) {
        guard state.lanes[id] != nil else { return }
        state.triggers = (state.triggers ?? [:]).merging([id: trigger]) { _, new in new }
        changed()
    }

    public func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.deviceName = trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(60))
        changed()
    }

    // MARK: Destinations

    /// Adds a destination; its first run sends the last 30 days, unless its
    /// definition asks for some other range.
    @discardableResult
    public func add(_ destination: Destination, token: String?, definition: PipelineDefinition? = nil) -> Destination {
        state.destinations.append(destination)
        env.tokens.setToken(token, for: destination.id)
        var lane = Lane()
        if definition?.usesDirtyDays ?? true {
            lane.dirty.mark(readable(DirtyRules.last(DirtyRules.firstRunDays, today: today())), at: env.now())
        }
        state.lanes[destination.id] = lane
        if let definition { state.definitions = (state.definitions ?? [:]).merging([destination.id: definition]) { _, new in new } }
        if state.lastSweep == nil { state.lastSweep = env.now() }
        changed()
        return destination
    }

    /// Saves edits; a changed credential or URL clears needs-attention and backoff.
    public func update(_ destination: Destination, token: String?, definition: PipelineDefinition? = nil) {
        guard let i = state.destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        state.destinations[i] = destination
        if let definition {
            let old = state.definitions?[destination.id]
            state.definitions = (state.definitions ?? [:]).merging([destination.id: definition]) { _, new in new }
            // A changed range starts over: its saved position meant something else.
            if old?.extract.range != definition.extract.range { state.cursors?[destination.id] = nil }
            if !definition.usesDirtyDays { state.lanes[destination.id]?.dirty = DirtySet() }
        }
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
        state.triggers?[id] = nil
        state.definitions?[id] = nil
        state.cursors?[id] = nil
        env.files.removeLane(id)
        env.files.removePipeline(id)
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
        if case .target(let target) = d.kind, let definition = state.definitions?[id] {
            let delivery = await testTemplate(id: id, destination: d, target: target, definition: definition)
            noteTest(id, delivery)
            return delivery
        }
        let push = Push.empty(device: env.device(state.deviceName), at: env.now(), timeZone: env.calendar().timeZone)
        let delivery = await env.makeDestination(d, env.tokens.token(for: id)).deliver(push.body)
        noteTest(id, delivery)
        return delivery
    }

    private func noteTest(_ id: UUID, _ delivery: Delivery) {
        guard var lane = state.lanes[id] else { return }
        lane.record(LogEntry(at: env.now(), days: [], delivery: delivery))
        if delivery.verdict == .accepted {
            lane.attention = nil
            lane.failures = 0
            lane.retryAfter = nil
        }
        state.lanes[id] = lane
        changed()
    }

    /// The template over no data: the shape a receiver will get, with nothing in it.
    private func testTemplate(id: UUID, destination d: Destination, target: LoadTarget, definition: PipelineDefinition) async -> Delivery {
        guard let queries = env.queries, let source = templateSource(definition.template) else {
            return Delivery(status: nil, verdict: .rejected, message: "Template not found")
        }
        let calendar = env.calendar()
        do {
            let template = try ParsedTemplate(source: source)
            let export = ExportInfo(device: env.device(state.deviceName), generatedAt: env.now(), timeZone: calendar.timeZone)
            let extractor = Extractor(store: queries, spec: definition.extract, calendar: calendar, ranges: [])
            let folder = try env.files.beginArtifact(id)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("test")
            let sink = try FileSink(url: file)
            var firstOnly = template
            firstOnly.onlyFirstPartition = true
            let run = try await TemplateTransformer(template: firstOnly).run(extractor: extractor, export: export) { _, _ in sink }
            try sink.close()
            guard let part = run.parts.first else { return Delivery(status: nil, verdict: .rejected, message: "The template wrote nothing") }
            let address = try await run.destination(0, Engine.addressTemplate(target))
            let info = ArtifactPart(key: part.key, filename: part.filename, file: "test", contentType: part.contentType, bytes: part.bytes, destination: address)
            let context = TransportContext(pipelineID: id, pipelineName: d.name, extract: definition.extract, token: env.tokens.token(for: id))
            return await env.makeTransport(target, context).deliver(part: info, file: file, artifact: Artifact(createdAt: env.now(), days: [], rows: 0, parts: [info]))
        } catch {
            return Delivery(status: nil, verdict: .rejected, message: String(describing: error))
        }
    }

    static func addressTemplate(_ target: LoadTarget) -> String? {
        switch target {
        case .web(let web): web.url
        }
    }

    /// Marks the last `n` days dirty for every destination (they go with the next sync).
    public func resend(lastDays n: Int) {
        let days = DirtyRules.last(max(1, n), today: today())
        let at = env.now()
        for id in state.lanes.keys { state.lanes[id]!.dirty.mark(readable(days), at: at) }
        changed()
    }

    /// Marks the last `n` days dirty for one pipeline.
    public func resend(_ id: UUID, lastDays n: Int) {
        guard state.lanes[id] != nil else { return }
        state.lanes[id]!.dirty.mark(readable(DirtyRules.last(max(1, n), today: today())), at: env.now())
        changed()
    }

    // MARK: Sync

    /// For an observer wake: joins a running sync; otherwise runs what is
    /// due, and what follows Health's changes unless the last sync was just now.
    public func wake() async {
        if let running {
            _ = await running.value
            return
        }
        var ids = dueIDs()
        let recent = state.lastSync.map { env.now().timeIntervalSince($0) < Engine.wakeThrottle } ?? false
        if !recent { ids.formUnion(followingHealthIDs()) }
        guard !ids.isEmpty else { return }
        _ = await start(.observer, ids)
    }

    /// For coming to the foreground: runs what is due, and what follows
    /// Health's changes when the last success is old.
    public func syncIfStale() async {
        var ids = dueIDs()
        let fresh = state.lastSuccess.map { env.now().timeIntervalSince($0) < Engine.foregroundAge } ?? false
        if !fresh { ids.formUnion(followingHealthIDs()) }
        guard !ids.isEmpty else { return }
        _ = await start(.foreground, ids)
    }

    /// For while the app is open: runs scheduled pipelines as they come due.
    public func runDue() async {
        guard running == nil else { return }
        let ids = dueIDs()
        guard !ids.isEmpty else { return }
        _ = await start(.foreground, ids)
    }

    /// The soonest a scheduled pipeline comes due, while the app is open.
    public var nextRun: Date? { state.backgroundPlan.nextRun }

    /// The sync. A call while one runs waits for it and returns its report.
    /// A manual sync covers every pipeline; any other only those whose
    /// trigger wants it.
    @discardableResult
    public func sync(_ trigger: Trigger) async -> SyncReport {
        guard trigger != .manual else { return await start(trigger, nil) }
        let ids = dueIDs().union(followingHealthIDs())
        guard !ids.isEmpty else {
            let any = state.destinations.contains { state.trigger(for: $0.id) != .manual }
            return SyncReport(trigger: trigger, startedAt: env.now(), message: any ? "Nothing is due" : "Automatic sync is off")
        }
        return await start(trigger, ids)
    }

    /// Runs one pipeline because the user asked: after whatever is running,
    /// and whatever its backoff says. A pipeline that needs attention stays
    /// stopped until it is fixed.
    @discardableResult
    public func run(_ id: UUID, answer: DateInterval? = nil) async -> SyncReport {
        queued.append(id)
        changed()
        while let running { _ = await running.value }
        queued.removeAll { $0 == id }
        answers[id] = answer
        defer { answers[id] = nil }
        return await start(.manual, [id], forced: true)
    }

    private func followingHealthIDs() -> Set<UUID> {
        Set(state.destinations.map(\.id).filter { state.trigger(for: $0) == .whenHealthChanges })
    }

    /// Scheduled pipelines past their time, or with a failed delivery whose
    /// backoff is over. Paused ones, ones that need attention and ones still
    /// backing off cannot send, so they are not due.
    private func dueIDs() -> Set<UUID> {
        let now = env.now()
        return Set(state.destinations.filter { d in
            guard !d.paused, case .every(let schedule) = state.trigger(for: d.id) else { return false }
            let lane = state.lanes[d.id]
            guard lane?.attention == nil else { return false }
            if let after = lane?.retryAfter {
                if after > now { return false }
                if lane?.dirty.isEmpty == false || !env.files.artifacts(d.id).isEmpty { return true }
            }
            return schedule.next(after: lane?.lastRun) <= now
        }.map(\.id))
    }

    private func start(_ trigger: Trigger, _ ids: Set<UUID>?, forced: Bool = false) async -> SyncReport {
        let background = trigger == .observer || trigger == .refresh
        if let running {
            // Someone is waiting on this sync now, so it finishes.
            if !background { limit = nil }
            return await running.value
        }
        limit = background ? env.now().addingTimeInterval(Engine.backgroundBudget) : nil
        chosen = ids
        let task = Task { () -> SyncReport in
            let report = await self.run(trigger, only: ids, forced: forced)
            self.finished()
            return report
        }
        running = task
        changed()
        // iOS cancels a background task when its time is up.
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            if background { Task { await self.stopEarly() } }
        }
    }

    private func finished() {
        running = nil
        chosen = nil
        limit = nil
        progress = nil
        changed()
    }

    private func stopEarly() {
        if limit != nil { limit = .distantPast }
    }

    private var limitReached: Bool {
        limit.map { env.now() >= $0 } ?? false
    }

    private func lane(_ id: UUID) -> Lane? { state.lanes[id] }

    /// Saved as it happens, so an app killed mid-sync does not forget what
    /// was already delivered. Screens hear with the next progress.
    private func updateLane(_ id: UUID, _ body: @Sendable (inout Lane) -> Void) {
        guard state.lanes[id] != nil else { return }
        body(&state.lanes[id]!)
        env.files.save(state)
        lastSnapshot = nil
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

    private func run(_ trigger: Trigger, only ids: Set<UUID>?, forced: Bool) async -> SyncReport {
        let inRun: @Sendable (UUID) -> Bool = { ids?.contains($0) ?? true }
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
        // Far enough back for the pipeline that has gone longest without a
        // delivery: the anchors move on without it, and its days must be marked.
        let idleDays = state.lanes.values.compactMap(\.lastSuccess).min().map { Int(started.timeIntervalSince($0) / 86400) + 2 } ?? 0
        let windowDays = max(DirtyRules.changeWindowDays, idleDays)
        let windowStart = Day(started, calendar: calendar).adding(-(windowDays - 1)).start(in: calendar)
        let firstRunStart = Day(started, calendar: calendar).adding(-(DirtyRules.firstRunDays - 1)).start(in: calendar)
        do {
            for (i, type) in Catalog.allTypes.enumerated() {
                if limitReached {
                    report.message = Engine.outOfTime
                    state.lastSyncMessage = report.message
                    note(report.message, only: ids)
                    return report
                }
                let done = Double(i) / Double(Catalog.allTypes.count)
                show(.checking, item: done, overall: SyncProgress.checkingShare * done)
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
            note(report.message, only: ids)
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
        // A pipeline with a range of its own has no use for dirty days.
        for id in state.lanes.keys where state.definitions?[id]?.usesDirtyDays ?? true { state.lanes[id]!.dirty.mark(send, at: started) }
        changed()

        // 2. Each active destination in turn, sharing what was read.
        let sending = state.destinations.filter { d in
            guard !d.paused, inRun(d.id), let lane = state.lanes[d.id], lane.attention == nil else { return false }
            return forced || (lane.retryAfter.map { $0 <= env.now() } ?? true)
        }
        plan = (sending.reduce(0) { $0 + (state.lanes[$1.id]?.dirty.days.count ?? 0) }, 0, 0, "")
        let reader = DayReader(store: env.store, calendar: calendar)
        var cache: [Day: Content] = [:]
        let deviceName = state.deviceName
        let onRead: @Sendable ([Day], Double) async -> Void = { days, fraction in await self.reading(days, fraction) }
        let build: Pusher.Build = { [env] days in
            let missing = days.filter { cache[$0] == nil }
            if !missing.isEmpty {
                for (d, c) in try await reader.read(missing, progress: { await onRead(days, $0) }) { cache[d] = c }
            }
            let readAt = env.now()
            let content = Content.merging(days.map { cache[$0] ?? Content() })
            let push = Push(device: env.device(deviceName), exportedAt: readAt, timeZone: calendar.timeZone, days: days, content: content)
            return (push.body, content.recordCount, readAt)
        }
        let pusher = Pusher(files: env.files, now: env.now, pause: env.pause)
        var unreadable: String?
        var stopped = false
        for d in state.destinations where !d.paused && inRun(d.id) {
            guard let lane = state.lanes[d.id], lane.attention == nil else { continue }
            if !forced, let after = lane.retryAfter, after > env.now() {
                report.failed += 1
                continue
            }
            plan.destination = d.name
            let id = d.id
            let access = Pusher.LaneAccess(read: { await self.lane(id) },
                                           update: { body in await self.updateLane(id, body) },
                                           shouldStop: { await self.limitReached })
            let stop: Pusher.Stop
            if case .target(let target) = d.kind, let definition = state.definitions?[id] {
                stop = await runTemplate(d, target: target, definition: definition, access: access, calendar: calendar, deviceName: deviceName)
            } else {
                let destination = env.makeDestination(d, env.tokens.token(for: d.id))
                stop = await pusher.run(lane: id, access: access, destination: destination, build: build,
                                        progress: { await self.delivering($0) })
            }
            // Removed while it sent: a batch written since must not linger.
            if state.lanes[id] == nil { env.files.removeLane(id) }
            switch stop {
            case .done, .failed:
                if stop == .done { report.delivered += 1 } else { report.failed += 1 }
                state.lanes[id]?.lastRun = env.now()
                state.lanes[id]?.lastMessage = nil
            case .unreadable(let message):
                unreadable = Engine.describe(message)
                state.lanes[id]?.lastMessage = unreadable
            case .stopped:
                stopped = true
                state.lanes[id]?.lastMessage = Engine.outOfTime
            }
            changed()
            if unreadable != nil || stopped { break }
        }

        // 3. Anchors advance when no destination in this run still has a
        // changed day dirty. The others keep their marks, so waiting on one
        // that runs only when tapped would hold the anchors for nothing.
        let active = state.destinations.filter { !$0.paused && inRun($0.id) && state.lanes[$0.id]?.attention == nil }
        let held = active.contains { d in changedDays.contains { state.lanes[d.id]?.dirty.contains($0) ?? false } }
        if !held && unreadable == nil { state.anchors.commit(pending) }

        if let unreadable {
            report.message = unreadable
        } else if stopped {
            report.message = Engine.outOfTime
        } else {
            state.lastSuccess = env.now()
            report.message = report.failed == 0 ? "Up to date" : "\(report.failed) destination\(report.failed == 1 ? "" : "s") will retry"
        }
        state.lastSyncMessage = report.message
        return report
    }

    private func runTemplate(_ d: Destination, target: LoadTarget, definition: PipelineDefinition, access: Pusher.LaneAccess, calendar: Calendar, deviceName: String) async -> Pusher.Stop {
        let id = d.id
        guard let queries = env.queries, let source = templateSource(definition.template) else {
            await access.update { $0.attention = "This pipeline's template is gone. Choose another." }
            return .failed
        }
        let template: ParsedTemplate
        do {
            template = try ParsedTemplate(source: source)
        } catch {
            let message = String(describing: error)
            await access.update {
                $0.attention = message
                $0.lastError = message
            }
            return .failed
        }
        let name = d.name
        let env = env
        let runner = ArtifactRunner(files: env.files, store: queries, calendar: calendar, now: env.now, pause: env.pause,
                                    export: { ExportInfo(device: env.device(deviceName), generatedAt: env.now(), timeZone: calendar.timeZone) },
                                    limits: TemplateLimits(deadline: limit))
        let cursor = ArtifactRunner.CursorAccess(read: { await self.cursor(id) }, write: { await self.setCursor(id, $0) })
        // The native format's data, for a template that writes it: see `Template.usesPush`.
        let store = env.store
        let pushData: ArtifactRunner.PushData = { days in
            let read = try await DayReader(store: store, calendar: calendar).read(days)
            let content = Content.merging(days.map { read[$0] ?? Content() })
            return Push(device: env.device(deviceName), exportedAt: env.now(), timeZone: calendar.timeZone, days: days, content: content).json
        }
        let context = TransportContext(pipelineID: id, pipelineName: name, extract: definition.extract, token: env.tokens.token(for: id))
        return await runner.run(id: id, definition: definition, template: template, destinationTemplate: Engine.addressTemplate(target), access: access, cursor: cursor, answer: answers[id], pushData: pushData,
                                transport: env.makeTransport(target, context), progress: { await self.templateStep($0, name: name) })
    }

    /// A user's template, from the library, or whatever the environment supplies.
    private func templateSource(_ ref: TemplateRef) -> String? {
        env.templateSource(ref) ?? TemplateLibrary(files: env.files).source(ref)
    }

    private func cursor(_ id: UUID) -> ExtractCursor { state.cursors?[id] ?? ExtractCursor() }

    private func setCursor(_ id: UUID, _ cursor: ExtractCursor) {
        state.cursors = (state.cursors ?? [:]).merging([id: cursor]) { _, new in new }
        env.files.save(state)
    }

    private func templateStep(_ step: ArtifactRunner.Step, name: String) {
        let overall = progress?.overall ?? SyncProgress.checkingShare
        switch step {
        case .rendering:
            show(.rendering(name), item: 0, overall: overall)
        case .sending(let part, let total):
            show(.sendingPart(part, of: total, to: name), item: Double(part - 1) / Double(max(total, 1)), overall: overall)
        }
    }

    /// Records why a run could not finish on the pipelines it covered.
    private func note(_ message: String, only ids: Set<UUID>?) {
        for id in state.lanes.keys where ids?.contains(id) ?? true { state.lanes[id]?.lastMessage = message }
    }

    static func describe(_ error: Error) -> String { describe(error.localizedDescription) }

    static func describe(_ text: String) -> String {
        text.localizedCaseInsensitiveContains("protected health data") ? lockedMessage : text
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
