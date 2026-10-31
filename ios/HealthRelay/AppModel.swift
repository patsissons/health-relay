import BackgroundTasks
import HealthKit
import HealthRelayKit
import Observation
import SwiftUI

/// The app's state for the screens: the engine's snapshot plus what only
/// the app knows (Health authorization, per-type recency).
@MainActor @Observable
final class AppModel {
    static let refreshTask = "com.patsissons.healthrelay.refresh"

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
        let app = "Health Relay \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        let files = FileStore.standard()
        // Read now, not from the engine later: a background wake needs its
        // observers registered during launch.
        let plan = files.load().backgroundPlan
        engine = Engine(.init(
            store: health,
            files: files,
            tokens: KeychainTokenStore(),
            device: { Device(name: $0, model: model, os: os, app: app) }))
        let engine = engine
        Task { [weak self] in
            await engine.observe { snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
        }
        // Nothing to observe also clears background delivery an earlier launch turned on.
        if plan.observesHealth { observeHealth() } else if LiveHealthStore.isAvailable { health.stopObserving() }
        Task { await refreshAuthorization() }
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
        try? FileManager.default.removeItem(at: support.appendingPathComponent("HealthRelay"))
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
        await engine.syncIfStale()
        await applyBackgroundPlan()
    }

    func leftForeground() {
        watcher?.cancel()
        watcher = nil
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
        var earliest = plan.nextRun
        if plan.dailyCatchUp {
            let calendar = Calendar.current
            let now = Date()
            var morning = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: now) ?? now
            if morning <= now { morning = calendar.date(byAdding: .day, value: 1, to: morning) ?? now.addingTimeInterval(86400) }
            earliest = earliest.map { min($0, morning) } ?? morning
        }
        guard let earliest else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppModel.refreshTask)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTask)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Pipelines

    func add(name: String, endpoint: HTTPEndpoint, token: String, trigger: PipelineTrigger) async {
        let added = await engine.add(Destination(name: name, kind: .http(endpoint)), token: token)
        await engine.setTrigger(added.id, trigger)
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
