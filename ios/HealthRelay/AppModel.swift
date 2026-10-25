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

    init() {
        if ProcessInfo.processInfo.arguments.contains("-reset") { AppModel.resetState() }
        health = LiveHealthStore()
        let model = AppModel.deviceModel
        let os = UIDevice.current.systemVersion
        let app = "Health Relay \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        engine = Engine(.init(
            store: health,
            files: .standard(),
            tokens: KeychainTokenStore(),
            device: { Device(name: $0, model: model, os: os, app: app) }))
        let engine = engine
        Task { [weak self] in
            await engine.observe { snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
        }
        if LiveHealthStore.isAvailable {
            // Registered on every launch: background delivery wakes the app
            // through these observers.
            health.observe { await engine.wake() }
        }
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

    // MARK: Sync

    func syncNow() async {
        await engine.sync(.manual)
        scheduleRefresh()
    }

    func resend(lastDays n: Int) async {
        await engine.resend(lastDays: n)
        await syncNow()
    }

    func becameActive() async {
        await refreshAuthorization()
        await engine.syncIfStale()
        scheduleRefresh()
    }

    /// Background refresh, run by the system around 06:30.
    func refresh() async {
        await engine.sync(.refresh)
        scheduleRefresh()
    }

    /// Asks for the daily catch-up around 06:30 tomorrow (or today, if earlier).
    func scheduleRefresh() {
        let calendar = Calendar.current
        let now = Date()
        var next = calendar.date(bySettingHour: 6, minute: 30, second: 0, of: now) ?? now
        if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? now.addingTimeInterval(86400) }
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTask)
        request.earliestBeginDate = next
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Destinations

    func add(name: String, endpoint: HTTPEndpoint, token: String) async {
        await engine.add(Destination(name: name, kind: .http(endpoint)), token: token)
    }

    func update(_ destination: Destination, token: String) async {
        await engine.update(destination, token: token)
    }

    func remove(_ id: UUID) async {
        tests[id] = nil
        await engine.remove(id)
    }

    func setPaused(_ id: UUID, _ paused: Bool) async {
        await engine.setPaused(id, paused)
    }

    func test(_ id: UUID) async {
        tests[id] = await engine.test(id)
    }

    func token(for id: UUID) async -> String {
        await engine.token(for: id) ?? ""
    }

    func setDeviceName(_ name: String) async {
        await engine.setDeviceName(name)
    }
}
