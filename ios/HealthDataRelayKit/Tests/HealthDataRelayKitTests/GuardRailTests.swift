import Foundation
import Testing
@testable import HealthDataRelayKit

/// A destination that runs a hook during each delivery, while the engine is
/// suspended, then accepts.
final class HookDestination: DestinationType, @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable (Int) async -> Void)?
    private var delivered: [Data] = []

    func during(_ hook: @escaping @Sendable (Int) async -> Void) {
        lock.withLock { self.hook = hook }
    }

    var bodies: [Data] { lock.withLock { delivered } }

    var sentDays: [[String]] {
        bodies.compactMap(JSON.parse).map { p in
            if case .array(let a)? = p["days"] { return a.compactMap(\.stringValue) }
            return []
        }
    }

    func deliver(_ body: Data) async -> Delivery {
        let (count, hook) = lock.withLock {
            delivered.append(body)
            return (delivered.count, self.hook)
        }
        await hook?(count)
        return Delivery(status: 200, verdict: .accepted, message: "ok")
    }
}

/// An engine with one HookDestination added.
struct HookRig {
    let store = FakeHealthStore()
    let clock = Clock(T.date("2026-10-25 12:00:00 -0700"))
    let files = FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("hr-tests-\(UUID().uuidString)"))
    let destination = HookDestination()
    let id = UUID()
    let engine: Engine

    init() async {
        let destination = destination
        let clock = clock
        engine = Engine(.init(
            store: store, files: files, tokens: MemoryTokenStore(),
            device: { Device(name: $0, model: "iPhone17,1", os: "26.0", app: "Health Data Relay test") },
            calendar: { .local(T.vancouver) },
            now: { clock.now },
            pause: { _ in },
            makeDestination: { _, _ in destination }))
        await engine.add(Destination(id: id, name: "dest", kind: .http(HTTPEndpoint(url: URL(string: "https://example.test")!))), token: nil)
    }

    var lane: Lane {
        get async { await engine.snapshot.destinations.first { $0.id == id }!.lane }
    }
}

@Suite struct StateFileTests {
    static func emptyFiles() -> FileStore {
        FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("hr-tests-\(UUID().uuidString)"))
    }

    static func engine(_ files: FileStore) -> Engine {
        Engine(.init(store: FakeHealthStore(), files: files, tokens: MemoryTokenStore(),
                     device: { Device(name: $0, model: "", os: "", app: "") }))
    }

    static func stateFile(_ files: FileStore) -> URL { files.root.appendingPathComponent("state.json") }

    @Test func noFileIsAFirstLaunch() async {
        let files = Self.emptyFiles()
        #expect(files.load().destinations.isEmpty && !files.isUnreadable)
        #expect(await Self.engine(files).snapshot.stateSetAside == false)
    }

    @Test func undecodableStateIsSetAsideNotOverwritten() async throws {
        let files = Self.emptyFiles()
        let bad = Data(#"{"destinations":7,"written":"by a newer build"}"#.utf8)
        try bad.write(to: Self.stateFile(files))

        let engine = Self.engine(files)
        #expect(await engine.snapshot.destinations.isEmpty)
        #expect(await engine.snapshot.stateSetAside)
        await engine.setDeviceName("Saved after")
        let aside = try #require(files.setAsideStates().first)
        #expect(try Data(contentsOf: aside) == bad)
        #expect(files.load().deviceName == "Saved after")

        await engine.dismissSetAsideState()
        #expect(await engine.snapshot.stateSetAside == false)
        #expect(files.setAsideStates().isEmpty)
    }

    @Test func stateThatCannotBeReadYetIsNeverOverwritten() async throws {
        let files = Self.emptyFiles()
        var saved = EngineState()
        saved.deviceName = "Real phone"
        saved.destinations = [Destination(name: "Kept", kind: .http(HTTPEndpoint(url: URL(string: "https://example.test")!)))]
        files.save(saved)
        let url = Self.stateFile(files)
        let before = try Data(contentsOf: url)
        let manager = FileManager.default

        // As before the first unlock: the file is there but cannot be read.
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let engine = Self.engine(files)
        #expect(files.isUnreadable)
        await engine.setDeviceName("Would wipe it")
        #expect(await engine.reloadIfUnreadable() == false)

        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)
        #expect(await engine.reloadIfUnreadable())
        #expect(await engine.snapshot.destinations.map(\.destination.name) == ["Kept"])
        #expect(await engine.snapshot.deviceName == "Real phone")
    }
}

/// Files written by 0.1's own code before anything changed.
@Suite struct GoldenTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")

    /// The state as plain JSON. `lanes` encodes as a flat [key, value, ...]
    /// list in dictionary order, which differs per run, so it becomes a map.
    static func comparable(_ data: Data) throws -> NSDictionary {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let flat = try #require(object["lanes"] as? [Any])
        var lanes: [String: Any] = [:]
        for i in stride(from: 0, to: flat.count, by: 2) { lanes[try #require(flat[i] as? String)] = flat[i + 1] }
        object["lanes"] = lanes
        return object as NSDictionary
    }

    @Test func stateFromVersion01StillLoadsCompletely() async throws {
        let files = StateFileTests.emptyFiles()
        let golden = try Data(contentsOf: Self.dir.appendingPathComponent("state-0.1.json"))
        try golden.write(to: StateFileTests.stateFile(files))

        let state = files.load()
        #expect(files.setAsideStates().isEmpty, "0.1's state must decode")
        let good = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let stuck = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        #expect(state.destinations.map(\.name) == ["Home server", "Paused one"])
        #expect(state.destinations[1].paused)
        guard case .http(let endpoint) = state.destinations[0].kind else { Issue.record("not http"); return }
        #expect(endpoint.url.absoluteString == "https://example.test/push")
        #expect(endpoint.headers == [.init(name: "X-Home", value: "blue")])
        #expect(state.lanes[good]?.firstRun == false && state.lanes[good]?.log.first?.delivery.message == "days 2")
        let lane = try #require(state.lanes[stuck])
        #expect(lane.dirty.days.map(\.description) == ["2026-10-20", "2026-10-21"])
        #expect(lane.queue.first?.bytes == 1234 && lane.queue.first?.records == 5)
        #expect(lane.failures == 2 && lane.attention == "token_unknown" && lane.retryAfter != nil)
        #expect(state.anchors.committed["HKQuantityTypeIdentifierStepCount"] == Data([1, 2, 3, 4]))
        #expect(state.readableFrom?.description == "2026-09-26")
        #expect(state.deviceName == "Test iPhone" && state.autoSync == true)
        #expect(state.lastSyncMessage == "1 destination will retry" && state.lastSweep != nil)

        // Saving it again loses nothing.
        files.save(state)
        let saved = try Self.comparable(Data(contentsOf: StateFileTests.stateFile(files)))
        #expect(saved == (try Self.comparable(golden)))
    }

    /// A type added to `Catalog` reaches every existing user: a first scan
    /// resends 30 days, Health asks again, and a denied type reads as empty
    /// on days the receiver owns. New types go in their own catalog.
    @Test func theCatalogIsPinned() throws {
        var lines = Catalog.stats.map { "stat \($0.id) \($0.mode.rawValue) \($0.unit) \($0.healthKitUnit)" }
        lines += Catalog.samples.map { s -> String in
            let frequency = s.frequency == .daily ? "daily" : "hourly"
            switch s.value {
            case .quantity(let unit, let hk): return "sample \(s.id) quantity \(unit) \(hk) \(frequency)"
            case .category: return "sample \(s.id) category \(frequency)"
            }
        }
        lines += ["type \(HealthType.workout.id)", "type \(HealthType.ecg.id)"]
        let pinned = try String(contentsOf: Self.dir.appendingPathComponent("catalog-0.1.txt"), encoding: .utf8)
        #expect(lines.joined(separator: "\n") + "\n" == pinned)
        #expect(Catalog.allTypes.count == 122)
    }
}

@Suite struct LiveLaneTests {
    @Test func aResendDuringASyncIsNotLost() async {
        let rig = await HookRig()
        await rig.engine.sync(.manual)
        rig.clock.advance(3600)
        let engine = rig.engine
        let clock = rig.clock
        let sentBefore = rig.destination.bodies.count
        rig.destination.during { count in
            guard count == sentBefore + 1 else { return }
            clock.advance(1)
            await engine.resend(lastDays: 5)
        }
        await rig.engine.sync(.manual)
        // The days not yet tried go in this sync; the two in flight were
        // read before the re-send, so they stay dirty for the next.
        #expect(rig.destination.sentDays.dropFirst(sentBefore).map { $0 } == [["2026-10-24", "2026-10-25"], ["2026-10-21", "2026-10-22", "2026-10-23"]])
        #expect(await rig.lane.dirty.days.map(\.description) == ["2026-10-24", "2026-10-25"])
    }

    @Test func aDestinationRemovedWhileSendingStaysGone() async {
        let rig = await HookRig()
        let engine = rig.engine
        let id = rig.id
        rig.destination.during { count in
            if count == 2 { await engine.remove(id) }
        }
        await rig.engine.sync(.manual)
        #expect(rig.destination.bodies.count == 2)
        #expect(await rig.engine.snapshot.destinations.isEmpty)
        #expect(await rig.engine.state.lanes[id] == nil)
        let queue = rig.files.root.appendingPathComponent("queue").appendingPathComponent(id.uuidString)
        #expect(!FileManager.default.fileExists(atPath: queue.path))
    }

    @Test func deliveredBatchesAreSavedAsTheyHappen() async {
        let rig = await HookRig()
        let files = rig.files
        let id = rig.id
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var dirty: [Int] = []
        }
        let seen = Seen()
        rig.destination.during { _ in
            let count = files.load().lanes[id]?.dirty.count ?? -1
            seen.lock.withLock { seen.dirty.append(count) }
        }
        await rig.engine.sync(.manual)
        let counts = seen.lock.withLock { seen.dirty }
        // On disk, while each batch is in flight: only the batches before it are gone.
        #expect(counts.prefix(3) == [30, 29, 28])
    }
}

@Suite struct DeadlineTests {
    static func spending(_ seconds: TimeInterval, on rig: HookRig) {
        let clock = rig.clock
        rig.destination.during { _ in clock.advance(seconds) }
    }

    @Test func aBackgroundSyncStopsStartingWorkAtTheLimit() async {
        let rig = await HookRig()
        await rig.engine.setAutoSync(true)
        Self.spending(Engine.backgroundBudget + 1, on: rig)

        let report = await rig.engine.sync(.refresh)
        #expect(rig.destination.bodies.count == 1)
        #expect(report.message == Engine.outOfTime)
        #expect(await rig.lane.dirty.count == 29)
        #expect(await rig.lane.failures == 0, "running out of time is not the destination's failure")
        #expect(await rig.engine.snapshot.lastSuccess == nil, "it did not finish")

        await rig.engine.sync(.refresh)
        #expect(rig.destination.bodies.count == 2, "the next one carries on")
    }

    @Test func aPersonIsNeverCutOff() async {
        let rig = await HookRig()
        Self.spending(Engine.backgroundBudget + 1, on: rig)
        let report = await rig.engine.sync(.manual)
        #expect(rig.destination.bodies.count == 30 && report.message == "Up to date")
    }

    @Test func joiningManuallyLiftsTheLimit() async {
        let rig = await HookRig()
        await rig.engine.setAutoSync(true)
        let engine = rig.engine
        let clock = rig.clock
        rig.destination.during { count in
            if count == 1 {
                Task { await engine.sync(.manual) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            clock.advance(Engine.backgroundBudget + 1)
        }
        await rig.engine.sync(.refresh)
        #expect(rig.destination.bodies.count == 30)
    }

    @Test func cancellingABackgroundSyncStopsIt() async {
        let rig = await HookRig()
        await rig.engine.setAutoSync(true)
        let engine = rig.engine
        final class Holder: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<SyncReport, Never>?
        }
        let holder = Holder()
        rig.destination.during { count in
            guard count == 1 else { return }
            while holder.lock.withLock({ holder.task }) == nil { await Task.yield() }
            holder.lock.withLock { holder.task }?.cancel()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let task = Task { await engine.sync(.refresh) }
        holder.lock.withLock { holder.task = task }
        let report = await task.value
        #expect(rig.destination.bodies.count == 1 && report.message == Engine.outOfTime)
    }
}
