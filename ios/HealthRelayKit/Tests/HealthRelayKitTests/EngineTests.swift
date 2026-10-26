import Foundation
import Testing
@testable import HealthRelayKit

/// A destination that records what it was sent and answers from a script
/// (then 200 for ever).
final class FakeDestination: DestinationType, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Int]
    private(set) var bodies: [Data] = []

    init(_ script: [Int] = []) { self.script = script }

    func answer(_ statuses: [Int]) {
        lock.lock()
        script = statuses
        lock.unlock()
    }

    var pushes: [JSON] {
        lock.lock()
        defer { lock.unlock() }
        return bodies.compactMap(JSON.parse)
    }

    /// The `days` of each push sent.
    var sentDays: [[String]] {
        pushes.map { p in
            if case .array(let a)? = p["days"] { return a.compactMap(\.stringValue) }
            return []
        }
    }

    func deliver(_ body: Data) async -> Delivery {
        let status = lock.withLock {
            bodies.append(body)
            return script.isEmpty ? 200 : script.removeFirst()
        }
        return Delivery(status: status, verdict: Delivery.verdict(for: status), message: "status \(status)")
    }
}

/// A clock the test moves by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date

    init(_ start: Date) { t = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return t
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        t = t.addingTimeInterval(seconds)
        lock.unlock()
    }
}

struct Rig {
    let store = FakeHealthStore()
    let clock = Clock(T.date("2026-10-25 12:00:00 -0700"))
    let files: FileStore
    let tokens = MemoryTokenStore()
    let destinations: [UUID: FakeDestination]
    let engine: Engine

    /// An engine with one fake destination per name in `named`.
    init(_ fakes: [FakeDestination] = [FakeDestination()]) {
        files = FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("hr-tests-\(UUID().uuidString)"))
        let ids = fakes.map { _ in UUID() }
        destinations = Dictionary(uniqueKeysWithValues: zip(ids, fakes))
        let byID = destinations
        let clock = clock
        engine = Engine(.init(
            store: store, files: files, tokens: tokens,
            device: { Device(name: $0, model: "iPhone17,1", os: "26.0", app: "Health Relay test") },
            calendar: { .local(T.vancouver) },
            now: { clock.now },
            pause: { _ in },
            makeDestination: { d, _ in byID[d.id]! }))
        self.ids = ids
    }

    let ids: [UUID]

    func addAll() async {
        for (i, id) in ids.enumerated() {
            await engine.add(Destination(id: id, name: "dest \(i)", kind: .http(HTTPEndpoint(url: URL(string: "https://example.test/\(i)")!))), token: "t\(i)")
        }
    }

    func lane(_ i: Int = 0) async -> Lane {
        await engine.snapshot.destinations.first { $0.id == ids[i] }!.lane
    }
}

@Suite struct EngineTests {
    @Test func firstRunSendsThirtyDaysOldestFirstOneDayPerBatch() async {
        let rig = Rig()
        await rig.addAll()
        let report = await rig.engine.sync(.manual)
        let sent = rig.destinations[rig.ids[0]]!.sentDays
        #expect(report.delivered == 1 && report.message == "Up to date")
        #expect(sent.count == 30)
        #expect(sent.first == ["2026-09-26"] && sent.last == ["2026-10-25"])
        let lane = await rig.lane()
        #expect(lane.dirty.isEmpty && !lane.firstRun && lane.queue.isEmpty)
    }

    @Test func afterTheFirstRunTodayYesterdayAndChangedDaysGoInOneBatch() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.sync(.manual)
        let fake = rig.destinations[rig.ids[0]]!
        rig.clock.advance(3600)
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-10-20 09:00:00 -0700"), 10)
        await rig.engine.sync(.manual)
        #expect(fake.sentDays.last == ["2026-10-20", "2026-10-24", "2026-10-25"])
    }

    @Test func theWeeklySweepMarksThirtyFiveDays() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.sync(.manual)
        let fake = rig.destinations[rig.ids[0]]!
        rig.clock.advance(7 * 86400)
        await rig.engine.sync(.manual)
        let after = fake.sentDays.dropFirst(30)
        #expect(after.flatMap { $0 }.count == 35)
        #expect(after.map(\.count) == [7, 7, 7, 7, 7])
        // A day later the sweep does not repeat.
        rig.clock.advance(86400)
        await rig.engine.sync(.manual)
        #expect(fake.sentDays.last?.count == 2)
    }

    @Test func serverErrorsKeepTheBatchOnDiskAndBackOff() async {
        let fake = FakeDestination([503])
        let rig = Rig([fake])
        await rig.addAll()
        let report = await rig.engine.sync(.manual)
        #expect(report.failed == 1)
        var lane = await rig.lane()
        #expect(lane.queue.count == 1 && lane.dirty.count == 30 && lane.failures == 1)
        #expect(lane.retryAfter == rig.clock.now.addingTimeInterval(60))
        // Inside the backoff nothing is sent.
        await rig.engine.sync(.manual)
        #expect(fake.bodies.count == 1)
        // After it, the same bytes go again first.
        rig.clock.advance(61)
        await rig.engine.sync(.manual)
        #expect(fake.bodies[1] == fake.bodies[0])
        lane = await rig.lane()
        #expect(lane.dirty.isEmpty && lane.failures == 0 && lane.retryAfter == nil)
    }

    @Test func backoffDoublesToSixHours() {
        var lane = Lane()
        let t = Date(timeIntervalSince1970: 0)
        for _ in 0..<12 { lane.backOff(now: t) }
        #expect(lane.retryAfter == t.addingTimeInterval(6 * 3600))
        lane = Lane()
        lane.backOff(now: t)
        lane.backOff(now: t)
        #expect(lane.retryAfter == t.addingTimeInterval(120))
    }

    @Test func aRefusedCredentialStopsTheDestinationUntilATestPasses() async {
        let fake = FakeDestination([401])
        let rig = Rig([fake])
        await rig.addAll()
        await rig.engine.sync(.manual)
        #expect(await rig.lane().attention == "status 401")
        rig.clock.advance(86400)
        await rig.engine.sync(.manual)
        #expect(fake.bodies.count == 1)
        let test = await rig.engine.test(rig.ids[0])
        #expect(test.verdict == .accepted)
        #expect(fake.pushes.last?["days"] == .array([]) && fake.pushes.last?["stats"] == nil)
        #expect(await rig.lane().attention == nil)
        await rig.engine.sync(.manual)
        #expect(await rig.lane().dirty.isEmpty)
    }

    @Test func aRejectedBatchIsDroppedButItsDaysStayDirty() async {
        let fake = FakeDestination([400])
        let rig = Rig([fake])
        await rig.addAll()
        await rig.engine.sync(.manual)
        let lane = await rig.lane()
        #expect(lane.queue.isEmpty && lane.dirty.count == 30 && lane.lastError == "status 400" && lane.retryAfter != nil)
    }

    @Test func anchorsWaitForEveryActiveDestination() async {
        let good = FakeDestination()
        let bad = FakeDestination()
        let rig = Rig([good, bad])
        await rig.addAll()
        await rig.engine.sync(.manual)
        let committed = await rig.engine.anchorsForTesting
        rig.clock.advance(3600)
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-10-20 09:00:00 -0700"), 10)
        bad.answer([500])
        await rig.engine.sync(.manual)
        #expect(await rig.engine.anchorsForTesting == committed, "held while one destination still has the changed day")
        #expect(good.sentDays.last == ["2026-10-20", "2026-10-24", "2026-10-25"])
        rig.clock.advance(120)
        await rig.engine.sync(.manual)
        #expect(await rig.engine.anchorsForTesting != committed)
        #expect(bad.sentDays.last == ["2026-10-20", "2026-10-24", "2026-10-25"])
    }

    @Test func pausedDestinationsAccumulateWithoutHoldingAnchors() async {
        let rig = Rig([FakeDestination(), FakeDestination()])
        await rig.addAll()
        await rig.engine.sync(.manual)
        await rig.engine.setPaused(rig.ids[1], true)
        let before = await rig.engine.anchorsForTesting
        rig.clock.advance(3600)
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-10-20 09:00:00 -0700"), 10)
        await rig.engine.sync(.manual)
        #expect(await rig.engine.anchorsForTesting != before)
        #expect(await rig.lane(1).dirty.days.map(\.description) == ["2026-10-20", "2026-10-24", "2026-10-25"])
    }

    @Test func resendMarksTheLastDays() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.sync(.manual)
        rig.clock.advance(3600)
        await rig.engine.resend(lastDays: 1)
        let lane = await rig.lane()
        #expect(lane.dirty.days.map(\.description) == ["2026-10-25"])
    }

    @Test func removingADestinationWipesItAndTheLastResetsAnchors() async {
        let rig = Rig([FakeDestination([503]), FakeDestination()])
        await rig.addAll()
        await rig.engine.sync(.manual)
        #expect(await rig.lane(0).queue.count == 1)
        await rig.engine.remove(rig.ids[0])
        #expect(rig.tokens.token(for: rig.ids[0]) == nil)
        #expect(rig.files.readBatch(lane: rig.ids[0], id: UUID()) == nil)
        #expect(await rig.engine.snapshot.destinations.map(\.id) == [rig.ids[1]])
        #expect(await rig.engine.anchorsForTesting.isEmpty == false)
        await rig.engine.remove(rig.ids[1])
        #expect(await rig.engine.anchorsForTesting.isEmpty)
    }

    @Test func stateSurvivesARelaunch() async {
        let rig = Rig([FakeDestination([503])])
        await rig.addAll()
        await rig.engine.sync(.manual)
        let again = Engine(.init(store: rig.store, files: rig.files, tokens: rig.tokens,
                                 device: { Device(name: $0, model: "", os: "", app: "") }))
        let lane = await again.snapshot.destinations.first!.lane
        #expect(lane.queue.count == 1 && lane.dirty.count == 30 && lane.failures == 1)
    }

    @Test func bigBatchesAreSplit() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.sync(.manual)
        // About 0.6 MB of sound level samples per day on three days.
        for day in ["2026-10-21", "2026-10-22", "2026-10-23"] {
            for i in 0..<4000 {
                rig.store.add("HKQuantityTypeIdentifierEnvironmentalAudioExposure", source: "Watch",
                              T.date("\(day) 00:00:00 -0700").addingTimeInterval(Double(i) * 20), 60)
            }
        }
        rig.clock.advance(3600)
        await rig.engine.sync(.manual)
        let fake = rig.destinations[rig.ids[0]]!
        let recent = fake.bodies.dropFirst(30)
        #expect(recent.allSatisfy { $0.count <= Pusher.maxBytes })
        #expect(fake.sentDays.dropFirst(30).flatMap { $0 }.sorted() == ["2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
    }

    @Test func wakesJoinOrAreThrottled() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.setAutoSync(true)
        await rig.engine.sync(.manual)
        let fake = rig.destinations[rig.ids[0]]!
        let count = fake.bodies.count
        rig.clock.advance(60)
        await rig.engine.wake()
        #expect(fake.bodies.count == count, "inside five minutes")
        rig.clock.advance(300)
        await rig.engine.wake()
        #expect(fake.bodies.count == count + 1)
    }

    @Test func automaticSyncIsOffUntilTurnedOn() async throws {
        let rig = Rig()
        await rig.addAll()
        let fake = rig.destinations[rig.ids[0]]!
        #expect(await rig.engine.snapshot.autoSync == false)

        rig.clock.advance(2 * 3600)
        await rig.engine.wake()
        await rig.engine.syncIfStale()
        let refresh = await rig.engine.sync(.refresh)
        #expect(fake.bodies.isEmpty && refresh.message == "Automatic sync is off")
        #expect(await rig.engine.snapshot.lastSync == nil)

        await rig.engine.sync(.manual)
        #expect(fake.sentDays.count == 30)

        await rig.engine.setAutoSync(true)
        let count = fake.bodies.count
        rig.clock.advance(2 * 3600)
        await rig.engine.syncIfStale()
        #expect(fake.bodies.count > count)
        #expect(await Engine(rig.engine.env).snapshot.autoSync, "kept across a relaunch")
    }

    @Test func stateSavedBeforeTheSettingStillLoads() throws {
        let files = FileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("hr-tests-\(UUID().uuidString)"))
        var old = EngineState()
        old.destinations = [Destination(name: "Kept", kind: .http(HTTPEndpoint(url: URL(string: "https://example.test")!)))]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["autoSync"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: files.root.appendingPathComponent("state.json"))
        let loaded = files.load()
        #expect(loaded.destinations.map(\.name) == ["Kept"] && loaded.autoSync == nil)
    }

    @Test func aReadFailureStopsTheSyncAndKeepsTheDays() async {
        let rig = Rig()
        await rig.addAll()
        rig.store.failReads = true
        let report = await rig.engine.sync(.manual)
        #expect(report.delivered == 0 && !report.message.isEmpty)
        #expect(await rig.lane().dirty.count == 30)
        #expect(rig.destinations[rig.ids[0]]!.bodies.isEmpty)
    }
}

extension Engine {
    var anchorsForTesting: [String: Data] { state.anchors.committed }
}

@Suite struct SyncProgressTests {
    /// Every progress a sync reported to observers, in order.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [SyncProgress?] = []
        var all: [SyncProgress?] { lock.withLock { seen } }
        func add(_ p: SyncProgress?) { lock.withLock { seen.append(p) } }
    }

    @Test func checksThenReadsAndSendsEachBatchWithOverallRisingToDone() async {
        let rig = Rig([FakeDestination(), FakeDestination()])
        await rig.addAll()
        let recorder = Recorder()
        await rig.engine.observe { recorder.add($0.progress) }
        await rig.engine.sync(.manual)

        let steps = recorder.all.compactMap { $0 }
        #expect(steps.first?.step == .checking)
        #expect(steps.contains { if case .reading(let days) = $0.step { days.count == 1 } else { false } })
        let sends = Set(steps.compactMap { if case .sending(_, let to) = $0.step { to } else { nil } })
        #expect(sends == ["dest 0", "dest 1"])
        // Overall never goes back, and ends complete; items stay in range.
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.overall <= $1.overall + 1e-9 })
        #expect(steps.last?.overall == 1 && steps.last?.item == 1)
        #expect(steps.allSatisfy { (0...1).contains($0.item) })
        // Both destinations get 30 one-day batches: well under one update per percent.
        #expect(steps.count < 400)
        #expect(recorder.all.last! == nil)
        #expect(await rig.engine.snapshot.progress == nil)
    }
}

@Suite struct ReadableWindowTests {
    @Test func daysBeforeTheGrantWindowAreNeverListed() async {
        let rig = Rig()
        await rig.engine.noteAuthorized()
        await rig.addAll()
        await rig.engine.sync(.manual)
        // A week later the sweep covers 35 days, but only 30 before the grant are readable.
        rig.clock.advance(7 * 86400)
        await rig.engine.sync(.manual)
        let fake = rig.destinations[rig.ids[0]]!
        let earliest = fake.sentDays.flatMap { $0 }.min()
        #expect(earliest == "2026-09-26", "the grant was 2026-10-25, so 2026-09-26 is the first readable day")
        // Re-sending further back is clipped the same way.
        await rig.engine.resend(lastDays: 60)
        #expect(await rig.lane().dirty.days.first?.description == "2026-09-26")
    }

    @Test func theWindowIsSetOnce() async {
        let rig = Rig()
        await rig.engine.noteAuthorized()
        rig.clock.advance(10 * 86400)
        await rig.engine.noteAuthorized()
        #expect(await rig.engine.state.readableFrom?.description == "2026-09-26")
    }
}
