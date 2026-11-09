import Foundation

/// What started a sync.
public enum Trigger: String, Sendable, Codable {
    case manual
    case foreground
    case refresh
    case observer
    /// iOS's longer background processing time.
    case processing
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

/// How far a run is through delivering, counted in days so it only moves
/// forward: a read batch the pusher then splits into smaller sends must not
/// pull it back. Each pipeline has a slot of its dirty days, at least one so
/// a template with a range of its own still counts. A day is worth
/// `readingShare` once read and the rest once delivered.
struct DeliveryPlan {
    private var slots: [UUID: (start: Double, size: Double)] = [:]
    private var total = 1.0
    private var slot = (start: 0.0, size: 0.0)
    private var readDays = 0.0
    private var deliveredDays = 0.0
    /// The pipeline being delivered.
    private(set) var destination = ""

    init() {}

    init(_ pipelines: [(id: UUID, days: Int)]) {
        var start = 0.0
        for p in pipelines {
            let size = Double(max(p.days, 1))
            slots[p.id] = (start, size)
            start += size
        }
        total = max(start, 1)
    }

    /// A pipeline starts: whatever the ones before it left undelivered
    /// (a failure, days already covered) counts as passed.
    mutating func begin(_ id: UUID, name: String) {
        destination = name
        guard let s = slots[id] else { return }
        slot = s
        readDays = max(readDays, s.start)
        deliveredDays = max(deliveredDays, s.start)
    }

    private var slotEnd: Double { slot.start + slot.size }

    /// `days` past those delivered have been read.
    mutating func read(_ days: Double) {
        readDays = max(readDays, min(deliveredDays + days, slotEnd))
    }

    mutating func delivered(_ days: Double) {
        deliveredDays = min(deliveredDays + days, slotEnd)
        readDays = max(readDays, deliveredDays)
    }

    /// The pipeline is `fraction` done, for one that isn't counted in days.
    mutating func fillSlot(_ fraction: Double) {
        let at = slot.start + slot.size * min(max(fraction, 0), 1)
        readDays = max(readDays, at)
        deliveredDays = max(deliveredDays, at)
    }

    var overall: Double {
        let days = SyncProgress.readingShare * readDays + (1 - SyncProgress.readingShare) * deliveredDays
        return SyncProgress.checkingShare + (1 - SyncProgress.checkingShare) * days / total
    }
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
        public var notify: @Sendable (PipelineNotice) -> Void
        /// Uploads large parts with iOS's background transfer service.
        public var uploader: BackgroundUploader?
        public var calendars: CalendarStore?
        /// Sign-in details for cloud accounts. Nil where no client is set up.
        public var oauth: @Sendable (ConnectedAccount.Provider) -> OAuthProvider?

        public init(store: HealthStore, files: FileStore, tokens: TokenStore,
                    device: @escaping @Sendable (String) -> Device,
                    calendar: @escaping @Sendable () -> Calendar = { .local() },
                    now: @escaping @Sendable () -> Date = { Date() },
                    pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                    makeDestination: @escaping @Sendable (Destination, String?) -> DestinationType = Engine.httpDestination,
                    queries: HealthQuerying? = nil,
                    makeTransport: @escaping @Sendable (LoadTarget, TransportContext) -> ArtifactTransport = Engine.standardTransport,
                    templateSource: @escaping @Sendable (TemplateRef) -> String? = Engine.builtInSource,
                    notify: @escaping @Sendable (PipelineNotice) -> Void = { _ in },
                    uploader: BackgroundUploader? = nil,
                    calendars: CalendarStore? = nil,
                    oauth: @escaping @Sendable (ConnectedAccount.Provider) -> OAuthProvider? = { _ in nil }) {
            self.oauth = oauth
            self.calendars = calendars
            self.notify = notify
            self.uploader = uploader
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
    /// The same for iOS's processing time, which runs to minutes.
    public static let processingBudget: TimeInterval = 240
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
        case .mqtt(let mqtt): MQTTTransport(target: mqtt, password: context.token)
        // The engine makes these itself: they need its file store or calendars.
        case .share, .calendar, .email, .file: RefusingTransport()
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
    /// While delivering: how far through the run's days.
    private var plan = DeliveryPlan()
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
        // The whole run only ever moves forward.
        let overall = max(overall, progress?.overall ?? 0)
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

    private func reading(_ days: [Day], _ fraction: Double) {
        plan.read(Double(days.count) * fraction)
        show(.reading(days), item: fraction * SyncProgress.readingShare, overall: plan.overall)
    }

    private func delivering(_ step: Pusher.Step) {
        switch step {
        case .sending(let days):
            // Days another pipeline already read come from the cache unread.
            plan.read(Double(days.count))
            show(.sending(days, to: plan.destination), item: SyncProgress.readingShare, overall: plan.overall)
        case .accepted(let days):
            plan.delivered(Double(days.count))
            show(.sending(days, to: plan.destination), item: 1, overall: plan.overall)
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

    public func setNotices(_ id: UUID, _ notices: PipelineNotices) {
        guard state.lanes[id] != nil else { return }
        state.notices = (state.notices ?? [:]).merging([id: notices]) { _, new in new }
        changed()
    }

    public func notices(for id: UUID) -> PipelineNotices { state.notices?[id] ?? PipelineNotices() }

    /// Pipelines to remind about, and when: scheduled, with reminders on.
    public var reminders: [(id: UUID, name: String, at: Date)] {
        let calendar = env.calendar()
        return state.destinations.compactMap { d in
            guard !d.paused, state.notices?[d.id]?.reminder == true,
                  let next = state.trigger(for: d.id).next(after: state.lanes[d.id]?.lastRun, calendar: calendar) else { return nil }
            return (d.id, d.name, next)
        }
    }

    private func log(_ kind: ActivityEntry.Kind, _ message: String) {
        env.files.logActivity(ActivityEntry(at: env.now(), kind: kind, message: message))
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
        } else if case .http = destination.kind {
            // Back to the native push: a template's settings no longer apply.
            state.definitions?[destination.id] = nil
            state.cursors?[destination.id] = nil
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
        state.notices?[id] = nil
        env.files.removeLane(id)
        env.files.removePipeline(id)
        try? FileManager.default.removeItem(at: env.files.exportFolder(id))
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
            // Nothing to reach out to: rendering it was the test.
            if case .share = target { return Delivery(status: nil, verdict: .accepted, message: "The template works") }
            if case .email(let email) = target, case .compose = email.method { return Delivery(status: nil, verdict: .accepted, message: "The template works") }
            // A test file in someone's cloud would be a nuisance.
            if case .file = target { return Delivery(status: nil, verdict: .accepted, message: "The template works") }
            // An empty message on a real topic would reach whatever's listening,
            // and a calendar needs no test event: writing the shape was the test.
            if case .calendar = target {
                _ = try CalendarEvent.parse(try Data(contentsOf: file))
                return Delivery(status: nil, verdict: .accepted, message: "The template works")
            }
            return await transport(target, context).deliver(part: info, file: file, artifact: Artifact(createdAt: env.now(), days: [], rows: 0, parts: [info]))
        } catch {
            return Delivery(status: nil, verdict: .rejected, message: String(describing: error))
        }
    }

    private func accountTokens(_ id: UUID, _ provider: ConnectedAccount.Provider) -> AccountTokens {
        AccountTokens(store: env.tokens, account: id, provider: env.oauth(provider), now: env.now)
    }

    // MARK: Accounts

    public var accounts: [ConnectedAccount] { state.accounts ?? [] }

    public func addAccount(_ account: ConnectedAccount, tokens: OAuthTokens) {
        AccountTokens(store: env.tokens, account: account.id, provider: nil).save(tokens)
        state.accounts = (state.accounts ?? []) + [account]
        changed()
    }

    /// Removes an account's sign-in. Pipelines using it say so on their cards.
    public func removeAccount(_ id: UUID) {
        env.tokens.setToken(nil, for: id)
        state.accounts?.removeAll { $0.id == id }
        changed()
    }

    static func addressTemplate(_ target: LoadTarget) -> String? {
        switch target {
        case .web(let web): web.url
        case .mqtt(let mqtt): mqtt.topic
        case .email(let email): email.subject
        case .share, .calendar, .file: nil
        }
    }

    private func transport(_ target: LoadTarget, _ context: TransportContext) -> ArtifactTransport {
        if case .share = target { return ShareTransport(files: env.files, context: context) }
        if case .email(let email) = target {
            // Composing takes a person: it's ready to share, and they're told.
            if case .compose = email.method { return ShareTransport(files: env.files, context: context) }
            return EmailTransport(target: email, files: env.files, context: context)
        }
        if case .file(let file) = target {
            switch file.location {
            case .folder(let bookmark, _):
                return FolderTransport(bookmark: bookmark, overwrite: file.overwrite)
            case .dropbox(let account, let path):
                return DropboxTransport(path: path, overwrite: file.overwrite, tokens: accountTokens(account, .dropbox))
            case .googleDrive(let account, let folder, let sheets):
                return GoogleDriveTransport(folderName: folder, sheets: sheets, overwrite: file.overwrite, tokens: accountTokens(account, .google),
                                            folderCache: env.files.pipelineFile(context.pipelineID, "drive-folder.txt"))
            }
        }
        if case .calendar(let calendar) = target, let store = env.calendars {
            return CalendarTransport(target: calendar, store: store, keysFile: env.files.pipelineFile(context.pipelineID, "calendar-keys.json"))
        }
        if case .web(let web) = target, let uploader = env.uploader {
            return WebTransport(target: web, context: context, uploader: uploader, waitForUpload: limit == nil ? .seconds(600) : .seconds(15))
        }
        return env.makeTransport(target, context)
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
        let calendar = env.calendar()
        return Set(state.destinations.filter { d in
            let trigger = state.trigger(for: d.id)
            guard !d.paused, let next = trigger.next(after: state.lanes[d.id]?.lastRun, calendar: calendar) else { return false }
            let lane = state.lanes[d.id]
            guard lane?.attention == nil else { return false }
            if let after = lane?.retryAfter {
                if after > now { return false }
                if lane?.dirty.isEmpty == false || !env.files.artifacts(d.id).isEmpty { return true }
            }
            return next <= now
        }.map(\.id))
    }

    private func start(_ trigger: Trigger, _ ids: Set<UUID>?, forced: Bool = false) async -> SyncReport {
        let background = trigger == .observer || trigger == .refresh || trigger == .processing
        if let running {
            // Someone is waiting on this sync now, so it finishes.
            if !background { limit = nil }
            return await running.value
        }
        limit = background ? env.now().addingTimeInterval(trigger == .processing ? Engine.processingBudget : Engine.backgroundBudget) : nil
        log(.run, "Run started: \(trigger.rawValue)\(forced ? ", from a tap" : "")")
        chosen = ids
        let task = Task { () -> SyncReport in
            let report = await self.run(trigger, only: ids, forced: forced)
            await self.noteFinished(report)
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

    private func noteFinished(_ report: SyncReport) {
        log(.run, "Run finished: \(report.message.isEmpty ? "done" : report.message)")
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
        let from = today().adding(-(DirtyRules.firstRunDays - 1))
        state.readableFrom = from
        // The test can't read `state`: `keep` is already writing to it.
        for id in state.lanes.keys { state.lanes[id]!.dirty.keep { $0 >= from } }
        changed()
    }

    private func readable(_ days: [Day]) -> [Day] {
        guard let from = state.readableFrom else { return days }
        return days.filter { $0 >= from }
    }

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
        plan = DeliveryPlan(sending.map { ($0.id, state.lanes[$0.id]?.dirty.days.count ?? 0) })
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
            let id = d.id
            plan.begin(id, name: d.name)
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
            announce(d, stop)
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

    /// Records one pipeline's result and tells the user if they asked.
    private func announce(_ d: Destination, _ stop: Pusher.Stop) {
        let notices = state.notices?[d.id] ?? PipelineNotices()
        let lane = state.lanes[d.id]
        switch stop {
        case .done:
            log(.pipeline, "\(d.name): finished")
            if notices.onSuccess { env.notify(PipelineNotice(pipeline: d.id, title: d.name, body: "Finished.")) }
            // Nobody tapped Run, and an email to compose is waiting for someone.
            if case .target(.email(let email)) = d.kind, case .compose = email.method, state.trigger(for: d.id) != .manual {
                env.notify(PipelineNotice(pipeline: d.id, title: d.name, body: "Your email is ready. Tap to compose it."))
            }
        case .failed:
            let why = lane?.attention ?? lane?.lastError ?? "It didn't finish."
            log(.pipeline, "\(d.name): failed: \(why)")
            if notices.onFailure { env.notify(PipelineNotice(pipeline: d.id, title: d.name, body: "Didn't finish: \(why)")) }
        case .unreadable(let why):
            log(.pipeline, "\(d.name): couldn't read Health: \(why)")
        case .stopped:
            log(.pipeline, "\(d.name): stopped at the time limit")
        }
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
                                    limits: TemplateLimits(deadline: limit, stop: { await self.limitReached }))
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
                                transport: transport(target, context), progress: { await self.templateStep($0, name: name) })
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

    /// A template's steps fill its pipeline's share of the run.
    private func templateStep(_ step: ArtifactRunner.Step, name: String) {
        switch step {
        case .rendering:
            show(.rendering(name), item: 0, overall: plan.overall)
        case .sending(let part, let total):
            let item = Double(part - 1) / Double(max(total, 1))
            plan.fillSlot(item)
            show(.sendingPart(part, of: total, to: name), item: item, overall: plan.overall)
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
