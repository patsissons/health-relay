import BackgroundTasks
import HealthKit
import UserNotifications
import HealthDataRelayKit
import Observation
import SwiftUI

/// The app's state for the screens: the engine's snapshot plus what only
/// the app knows (Health authorization, per-type recency).
@MainActor @Observable
final class AppModel {
    static let refreshTask = "com.patsissons.healthdatarelay.refresh"
    static let processingTask = "com.patsissons.healthdatarelay.processing"

    let engine: Engine
    let health: LiveHealthStore
    private(set) var snapshot = Snapshot()
    private(set) var needsAuthorization = false
    private(set) var recent: [(type: HealthType, newest: Date?)] = []
    /// The answer to the last Test, by destination.
    var tests: [UUID: Delivery] = [:]
    /// Whether Health's change notifications are registered this launch.
    private var observing = false
    /// Runs scheduled pipelines as they come due while the app is open.
    private var watcher: Task<Void, Never>?
    let library: TemplateLibrary
    private let files: FileStore
    private(set) var server: ServerController!
    let uploader: BackgroundUploader
    private(set) var customTemplates: [CustomTemplate] = []
    private(set) var accounts: [ConnectedAccount] = []
    /// A setup link waiting for the user to review and save.
    var setup: PendingSetup?
    var badLink = false

    struct PendingSetup: Identifiable {
        let id = UUID()
        let link: SetupLink
        /// The destination with the same URL, which the link updates.
        let existing: Destination?
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("-reset") { AppModel.resetState() }
        health = LiveHealthStore()
        let model = AppModel.deviceModel
        let os = UIDevice.current.systemVersion
        let app = "Health Data Relay \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        let files = FileStore.standard()
        self.files = files
        library = TemplateLibrary(files: files)
        // Read now, not from the engine later: a background wake needs its
        // observers registered during launch.
        let plan = files.load().backgroundPlan
        files.trimActivity()
        let uploader = BackgroundUploader(folder: files.root.appendingPathComponent("uploads", isDirectory: true))
        self.uploader = uploader
        engine = Engine(.init(
            store: health,
            files: files,
            tokens: KeychainTokenStore(),
            device: { Device(name: $0, model: model, os: os, app: app) },
            queries: health,
            notify: { AppModel.post($0) },
            uploader: uploader,
            calendars: LiveCalendarStore(),
            oauth: { AppModel.oauth($0) }))
        let health = health
        let serverDevice = Device(name: "iPhone", model: model, os: os, app: app)
        server = ServerController(root: files.root, tokens: KeychainTokenStore()) {
            MCPHandler(store: health, calendar: .local(), device: serverDevice)
        }
        let engine = engine
        Task { [weak self] in
            await engine.observe { snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
        }
        // Nothing to observe also clears background delivery an earlier launch turned on.
        if plan.observesHealth { observeHealth() } else if LiveHealthStore.isAvailable { health.stopObserving() }
        Task { await refreshAuthorization() }
        customTemplates = library.custom()
    }

    func reloadTemplates() {
        customTemplates = library.custom()
    }

    /// Removes a template. A pipeline still using it says so on its card.
    func removeTemplate(_ id: UUID) {
        library.remove(id)
        reloadTemplates()
    }

    /// `iPhone17,1`; the simulator reports the model it simulates.
    static var deviceModel: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// For UI tests and screenshots: start from nothing.
    static func resetState() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent("HealthDataRelay"))
    }

    // MARK: Health

    /// Registered on every launch while any pipeline runs on its own:
    /// background delivery wakes the app through these observers.
    private func observeHealth() {
        guard LiveHealthStore.isAvailable else { return }
        observing = true
        let engine = engine
        health.observe { await engine.wake() }
    }

    func refreshAuthorization() async {
        guard LiveHealthStore.isAvailable else { return }
        let status = try? await health.healthStore.statusForAuthorizationRequest(toShare: [], read: LiveHealthStore.readTypes)
        needsAuthorization = status != .unnecessary
        if status == .unnecessary { await engine.noteAuthorized() }
    }

    func authorize() async {
        try? await health.requestAuthorization()
        await refreshAuthorization()
        await loadRecent()
    }

    func loadRecent() async {
        recent = await engine.recentData().map { (type: $0.0, newest: $0.1) }
    }

    // MARK: Running

    /// Runs one pipeline: after whatever is running, whatever its backoff says.
    /// One metric's total or mean for a day.
    struct DayValue: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    /// Every metric's value for today or yesterday, read the way a pipeline
    /// reads them. A failure reads as no data: iOS hides denied reads anyway.
    func dayValues(yesterday: Bool) async -> [DayValue] {
        let calendar = Calendar.local()
        let today = Day(.now, calendar: calendar)
        let day = (yesterday ? today.adding(-1) : today).interval(in: calendar)
        let extractor = Extractor(store: health, spec: ExtractSpec(grouping: .days), calendar: calendar, ranges: [day])
        var out: [DayValue] = []
        for metric in MetricCatalog.metrics {
            var pager = extractor.points(of: metric)
            guard let point = try? await pager.next()?.first else { continue }
            out.append(DayValue(title: metric.title, text: Self.text(point, unit: pager.unitLabel)))
        }
        return out
    }

    private static func text(_ point: MetricPoint, unit: String) -> String {
        func n(_ value: Double?) -> String { (value ?? 0).formatted(.number.precision(.fractionLength(0...1))) }
        if let night = point.sleep { return "\(n(night.totalSleep)) hr" }
        if let systolic = point.systolic { return "\(n(systolic))/\(n(point.diastolic)) \(unit)" }
        if let avg = point.avg { return "\(n(point.min))–\(n(point.max)), avg \(n(avg)) \(unit)" }
        return "\(n(point.qty)) \(unit)"
    }

    /// Asks for every type a pipeline can read. Medications have a sheet of
    /// their own, so a pipeline asks for those when it selects them.
    func allowEveryType() async {
        do {
            try await health.requestAuthorization(types: MetricCatalog.allTypes, extras: [.routes, .heartbeats, .stateOfMind])
        } catch {}
        await refreshAuthorization()
    }

    /// Writes a one-off export to a file for the user to share.
    func export(source: String, spec: ExtractSpec, range: DateInterval) async throws -> ExportedFile {
        var extras: ReadExtras = []
        if spec.sections.contains(.workouts) { extras.insert(.routes) }
        if spec.grouping == nil { extras.insert(.heartbeats) }
        if spec.sections.contains(.stateOfMind) { extras.insert(.stateOfMind) }
        if spec.sections.contains(.medications) { extras.insert(.medications) }
        try? await health.requestAuthorization(types: spec.healthTypes, extras: extras)
        let calendar = Calendar.local()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        let export = ExportInfo(device: Device(name: snapshot.deviceName, model: AppModel.deviceModel, os: UIDevice.current.systemVersion, app: "Health Data Relay"), generatedAt: .now, timeZone: calendar.timeZone)
        return try await OneOffExport(store: health, calendar: calendar, folder: folder).run(source: source, spec: spec, range: range, export: export)
    }

    func recentWorkouts() async -> [WorkoutDetail] {
        try? await health.requestAuthorization(types: [.workout], extras: [.routes])
        let calendar = Calendar.local()
        let spec = ExtractSpec(sections: [.workouts])
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -90, to: .now)!, end: .now)
        var pager = Extractor(store: health, spec: spec, calendar: calendar, ranges: [range]).workouts()
        var out: [WorkoutDetail] = []
        while let page = try? await pager.next() { out += page }
        return out.reversed()
    }

    /// The last export waiting to be shared, from a share pipeline.
    func latestExport(_ id: UUID) -> URL? {
        files.latestExport(id)
    }

    func run(_ id: UUID, answer: DateInterval) async {
        await engine.run(id, answer: answer)
        await applyBackgroundPlan()
    }

    func run(_ id: UUID) async {
        await engine.run(id)
        await applyBackgroundPlan()
    }

    func resend(_ id: UUID, lastDays n: Int) async {
        await engine.resend(id, lastDays: n)
        await run(id)
    }

    func becameActive() async {
        // Woken before the first unlock, the app could not read its settings.
        await engine.reloadIfUnreadable()
        await refreshAuthorization()
        watchSchedules()
        await server.start()
        await engine.syncIfStale()
        await applyBackgroundPlan()
    }

    func leftForeground() {
        watcher?.cancel()
        watcher = nil
        // iOS would suspend it anyway; stopping leaves no half-open port behind.
        server.stop()
    }

    /// A countdown reaching zero on screen runs its pipeline. A pipeline that
    /// cannot finish stays due, so it is tried again only every 30 seconds.
    private func watchSchedules() {
        watcher?.cancel()
        let engine = engine
        watcher = Task {
            while !Task.isCancelled {
                await engine.runDue()
                let remaining = await engine.nextRun?.timeIntervalSinceNow ?? 30
                try? await Task.sleep(for: .seconds(remaining > 0 ? min(remaining, 30) : 30))
            }
        }
    }

    /// Background refresh, run by the system.
    func refresh() async {
        await engine.sync(.refresh)
        await applyBackgroundPlan()
    }

    /// iOS's longer background time, for output a refresh can't finish.
    func process() async {
        await engine.sync(.processing)
        await applyBackgroundPlan()
    }

    // MARK: Notifications

    private nonisolated static func post(_ notice: PipelineNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Accounts

    /// Sign-in details from the build's settings. Nil where it has none.
    nonisolated static func oauth(_ provider: ConnectedAccount.Provider) -> OAuthProvider? {
        func id(_ key: String) -> String? {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            return value?.isEmpty == false ? value : nil
        }
        switch provider {
        case .dropbox: return id("HDRDropboxClientID").map(OAuthProvider.dropbox)
        case .google: return id("HDRGoogleClientID").map(OAuthProvider.google)
        }
    }

    func connect(_ provider: ConnectedAccount.Provider) async throws {
        guard let config = AppModel.oauth(provider) else { return }
        let tokens = try await OAuthSignIn.run(config)
        await engine.addAccount(ConnectedAccount(provider: provider, name: provider.title), tokens: tokens)
        accounts = await engine.accounts
    }

    func disconnect(_ id: UUID) async {
        await engine.removeAccount(id)
        accounts = await engine.accounts
    }

    func reloadAccounts() async {
        accounts = await engine.accounts
    }

    /// Calendars a pipeline could write to, asking for access first.
    func writableCalendars() async -> [(id: String, title: String)] {
        let store = LiveCalendarStore()
        _ = try? await store.requestAccess()
        return store.writableCalendars()
    }

    func notices(for id: UUID) async -> PipelineNotices { await engine.notices(for: id) }

    /// Saves when to notify, asking iOS for permission when it first matters.
    func setNotices(_ id: UUID, _ notices: PipelineNotices) async {
        if notices.isOn { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        await engine.setNotices(id, notices)
        await applyBackgroundPlan()
    }

    /// Reminders for what's scheduled, replacing the last set. Each one lands
    /// a little after its time, and running first moves it to the next time.
    private func scheduleReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("reminder-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for reminder in await engine.reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.name
            content.body = "It's due. Open the app so it can run."
            let wait = max(60, reminder.at.timeIntervalSinceNow + 300)
            let request = UNNotificationRequest(identifier: "reminder-\(reminder.id.uuidString)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
            try? await center.add(request)
        }
    }

    // MARK: Activity

    func activity() -> [ActivityEntry] { files.activity(limit: 500) }

    func makeDiagnostics() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        let info = Diagnostics.AppInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", os: UIDevice.current.systemVersion, model: AppModel.deviceModel)
        return try? Diagnostics.write(files: files, info: info, now: .now, to: folder)
    }

    /// Asks iOS for what the triggers need: Health's change notifications,
    /// and a refresh at the soonest due time or around 06:30.
    func applyBackgroundPlan() async {
        let plan = await engine.snapshot.backgroundPlan
        if plan.observesHealth != observing {
            if plan.observesHealth {
                observeHealth()
            } else {
                observing = false
                health.stopObserving()
            }
        }
        await scheduleReminders()
        var earliest = plan.backgroundRun
        if plan.dailyCatchUp {
            let calendar = Calendar.current
            let now = Date()
            var morning = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: now) ?? now
            if morning <= now { morning = calendar.date(byAdding: .day, value: 1, to: morning) ?? now.addingTimeInterval(86400) }
            earliest = earliest.map { min($0, morning) } ?? morning
        }
        guard let earliest else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppModel.refreshTask)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppModel.processingTask)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTask)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
        if plan.wantsLongRun {
            let long = BGProcessingTaskRequest(identifier: AppModel.processingTask)
            long.earliestBeginDate = earliest
            long.requiresNetworkConnectivity = true
            try? BGTaskScheduler.shared.submit(long)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppModel.processingTask)
        }
    }

    // MARK: Pipelines

    func add(name: String, endpoint: HTTPEndpoint, token: String, trigger: PipelineTrigger) async {
        let added = await engine.add(Destination(name: name, kind: .http(endpoint)), token: token)
        await engine.setTrigger(added.id, trigger)
        await applyBackgroundPlan()
    }

    /// Adds or updates a template pipeline, asking Health for what it reads.
    func save(existing: Destination?, name: String, target: LoadTarget, definition: PipelineDefinition, token: String, trigger: PipelineTrigger) async {
        var extras: ReadExtras = []
        if definition.extract.sections.contains(.workouts) { extras.insert(.routes) }
        if definition.extract.grouping == nil { extras.insert(.heartbeats) }
        if definition.extract.sections.contains(.stateOfMind) { extras.insert(.stateOfMind) }
        if definition.extract.sections.contains(.medications) { extras.insert(.medications) }
        try? await health.requestAuthorization(types: definition.extract.healthTypes, extras: extras)
        let id: UUID
        if var destination = existing {
            destination.name = name
            destination.kind = .target(target)
            await engine.update(destination, token: token, definition: definition)
            id = destination.id
        } else {
            id = await engine.add(Destination(name: name, kind: .target(target)), token: token, definition: definition).id
        }
        await engine.setTrigger(id, trigger)
        await applyBackgroundPlan()
    }

    func update(_ destination: Destination, token: String, trigger: PipelineTrigger) async {
        await engine.update(destination, token: token)
        await engine.setTrigger(destination.id, trigger)
        await applyBackgroundPlan()
    }

    func remove(_ id: UUID) async {
        tests[id] = nil
        await engine.remove(id)
        await applyBackgroundPlan()
    }

    func setPaused(_ id: UUID, _ paused: Bool) async {
        await engine.setPaused(id, paused)
        await applyBackgroundPlan()
    }

    func test(_ id: UUID) async {
        tests[id] = await engine.test(id)
    }

    func token(for id: UUID) async -> String {
        await engine.token(for: id) ?? ""
    }

    /// A setup link opens the editor filled in, for an existing destination
    /// with the same URL if there is one; nothing is saved until the user does.
    func open(_ url: URL) async {
        guard let link = SetupLink(url) else { badLink = true; return }
        // From the engine, not `snapshot`: a link can be what launched the app.
        let existing = await engine.snapshot.destinations.map(\.destination).first {
            if case .http(let e) = $0.kind { e.url == link.endpoint.url } else { false }
        }
        setup = PendingSetup(link: link, existing: existing)
    }

    func dismissSetAsideState() async {
        await engine.dismissSetAsideState()
    }

    func setDeviceName(_ name: String) async {
        await engine.setDeviceName(name)
    }
}
