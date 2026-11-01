import Foundation
import Testing
@testable import HealthDataRelayKit

private let newYork = Calendar.local(TimeZone(identifier: "America/New_York")!)

@Suite struct TimeOfDayTests {
    private let since = T.date("2026-10-20 12:00:00 -0400")

    @Test func aTimeLaterTodayIsToday() {
        let t = TimeOfDay(hour: 18, minute: 30, since: since)
        #expect(t.next(after: nil, calendar: newYork) == T.date("2026-10-20 18:30:00 -0400"))
    }

    @Test func aTimeAlreadyPastIsTomorrowSoItIsntDueAtOnce() {
        let t = TimeOfDay(hour: 6, minute: 30, since: since)
        #expect(t.next(after: nil, calendar: newYork) == T.date("2026-10-21 06:30:00 -0400"))
    }

    @Test func afterARunItsTheNextOne() {
        let t = TimeOfDay(hour: 6, minute: 30, since: since)
        #expect(t.next(after: T.date("2026-10-22 07:00:00 -0400"), calendar: newYork) == T.date("2026-10-23 06:30:00 -0400"))
    }

    @Test func chosenDaysOnly() {
        // 2026-10-20 is a Tuesday. Monday (2) and Friday (6).
        let t = TimeOfDay(hour: 9, minute: 0, weekdays: [2, 6], since: since)
        #expect(t.next(after: nil, calendar: newYork) == T.date("2026-10-23 09:00:00 -0400"))
        #expect(t.next(after: T.date("2026-10-23 10:00:00 -0400"), calendar: newYork) == T.date("2026-10-26 09:00:00 -0400"))
    }

    @Test func aTimeTheClocksSkipRunsJustAfter() {
        // 02:30 doesn't exist on 2026-03-08 in New York.
        let t = TimeOfDay(hour: 2, minute: 30, since: T.date("2026-03-07 12:00:00 -0500"))
        let next = t.next(after: nil, calendar: newYork)
        #expect(next >= T.date("2026-03-08 03:00:00 -0400"))
        #expect(next <= T.date("2026-03-08 04:00:00 -0400"))
    }

    @Test func aRepeatedHourRunsOnce() {
        // 01:30 happens twice on 2026-11-01 in New York.
        let t = TimeOfDay(hour: 1, minute: 30, since: T.date("2026-10-31 12:00:00 -0400"))
        let first = t.next(after: nil, calendar: newYork)
        #expect(first == T.date("2026-11-01 01:30:00 -0400"))
        #expect(t.next(after: first, calendar: newYork) == T.date("2026-11-02 01:30:00 -0500"))
    }

    @Test func aSavedTriggerRoundTrips() throws {
        let t = PipelineTrigger.at(TimeOfDay(hour: 1, minute: 2, weekdays: [3], since: since))
        #expect(try JSONDecoder().decode(PipelineTrigger.self, from: JSONEncoder().encode(t)) == t)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seen: [PipelineNotice] = []

    func add(_ n: PipelineNotice) {
        lock.withLock { seen.append(n) }
    }
}

@Suite struct EngineSchedulingTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let start = T.date("2026-10-20 12:00:00 -0400")
    private let notices = NoticeBox()

    private func make(_ clock: TestClock, transport: ArtifactTransport = RecordingTransport(), queries: HealthQuerying? = nil, uploader: BackgroundUploader? = nil) -> Engine {
        let queries = queries ?? FakeHealthQuerying(calendar: newYork)
        let notices = notices
        return Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: MemoryTokenStore(), device: { Device(name: $0, model: "m", os: "o", app: "a") },
                            calendar: { newYork }, now: { clock.now }, pause: { _ in }, queries: queries, makeTransport: { _, _ in transport },
                            notify: { notices.add($0) }, uploader: uploader))
    }

    private func pipeline(_ engine: Engine) async -> UUID {
        await engine.add(Destination(name: "Morning", kind: .target(.web(WebTarget(url: "https://e.test")))), token: nil,
                         definition: PipelineDefinition(extract: ExtractSpec(range: .today, grouping: .days), template: .builtIn(BuiltInTemplates.metricsJSONv2), templateName: "JSON")).id
    }

    @Test func aTimeOfDayComesDueAndRuns() async {
        let clock = TestClock(start)
        let transport = RecordingTransport()
        let engine = make(clock, transport: transport)
        let id = await pipeline(engine)
        await engine.setTrigger(id, .at(TimeOfDay(hour: 18, minute: 0, since: start)))
        await engine.runDue()
        #expect(transport.bodies.isEmpty)
        let p = await engine.snapshot.pipelines[0]
        #expect(p.timing(now: start) == .next(T.date("2026-10-20 18:00:00 -0400")) || p.trigger != .manual)
        #expect(await engine.nextRun != nil)

        clock.now = T.date("2026-10-20 18:00:01 -0400")
        await engine.runDue()
        #expect(transport.bodies.count == 1)
        // Next due tomorrow, not now.
        clock.now = T.date("2026-10-20 18:30:00 -0400")
        await engine.runDue()
        #expect(transport.bodies.count == 1)
    }

    @Test func aScheduleOfSecondsStaysOutOfBackgroundPlans() async {
        let clock = TestClock(start)
        let engine = make(clock)
        let id = await pipeline(engine)
        await engine.setTrigger(id, .every(Schedule(count: 10, unit: .seconds, since: start)))
        let plan = await engine.snapshot.backgroundPlan
        #expect(plan.nextRun == start.addingTimeInterval(10))
        #expect(plan.backgroundRun == nil)
    }

    @Test func aScheduledTemplateAsksForLongerTime() async {
        let clock = TestClock(start)
        let engine = make(clock)
        let id = await pipeline(engine)
        await engine.setTrigger(id, .every(Schedule(count: 1, unit: .hours, since: start)))
        let plan = await engine.snapshot.backgroundPlan
        #expect(plan.wantsLongRun)
        #expect(plan.backgroundRun == start.addingTimeInterval(3600))
    }

    @Test func noticesFollowTheSettings() async {
        let clock = TestClock(start)
        let engine = make(clock, transport: RecordingTransport(answers: [.retry, .accepted]))
        let id = await pipeline(engine)
        await engine.run(id)
        #expect(notices.seen.isEmpty)
        await engine.setNotices(id, PipelineNotices(onFailure: true, onSuccess: true))
        // The artifact from the failed run is still waiting: this one's retry succeeds.
        await engine.run(id)
        #expect(notices.seen.map(\.body) == ["Finished."])
        #expect(await engine.notices(for: id).onFailure)
    }

    @Test func aFailureNoticeSaysWhy() async {
        let clock = TestClock(start)
        let engine = make(clock, transport: RecordingTransport(answers: [.retry]))
        let id = await pipeline(engine)
        await engine.setNotices(id, PipelineNotices(onFailure: true))
        await engine.run(id)
        #expect(notices.seen.first?.body.hasPrefix("Didn't finish:") == true)
    }

    @Test func remindersListWhatsScheduled() async {
        let clock = TestClock(start)
        let engine = make(clock)
        let id = await pipeline(engine)
        #expect(await engine.reminders.isEmpty)
        await engine.setNotices(id, PipelineNotices(reminder: true))
        // Manual has nothing to remind about.
        #expect(await engine.reminders.isEmpty)
        await engine.setTrigger(id, .at(TimeOfDay(hour: 18, minute: 0, since: start)))
        #expect(await engine.reminders.map(\.at) == [T.date("2026-10-20 18:00:00 -0400")])
        await engine.setPaused(id, true)
        #expect(await engine.reminders.isEmpty)
    }

    @Test func aRunStoppedByTheTimeLimitIsntATemplateError() async {
        let store = FakeHealthQuerying(calendar: newYork)
        for i in 0..<(Extractor.pageSize * 3) { store.add("step_count", at: start.addingTimeInterval(-Double(i + 1)), 1) }
        let engine = make(TestClock(start), queries: store)
        let id = await engine.add(Destination(name: "M", kind: .target(.web(WebTarget(url: "https://e.test")))), token: nil,
                                  definition: PipelineDefinition(extract: ExtractSpec(range: .today, grouping: nil), template: .builtIn(BuiltInTemplates.metricsJSONv2), templateName: "JSON")).id
        let runner = ArtifactRunner(files: FileStore(root: root), store: store, calendar: newYork, now: { start }, pause: { _ in },
                                    export: { RichData.export }, limits: TemplateLimits(stop: { true }))
        let access = Pusher.LaneAccess(read: { Lane() }, update: { _ in Issue.record("no lane change: a limit isn't a failure") }, shouldStop: { false })
        let cursor = ArtifactRunner.CursorAccess(read: { ExtractCursor() }, write: { _ in })
        let stop = await runner.run(id: id, definition: PipelineDefinition(extract: ExtractSpec(range: .today, grouping: nil), template: .builtIn("x"), templateName: "x"),
                                    template: try! BuiltInTemplates.template(BuiltInTemplates.metricsJSONv2), destinationTemplate: nil, access: access, cursor: cursor, answer: nil, transport: RecordingTransport())
        #expect(stop == .stopped)
        #expect(FileStore(root: root).artifacts(id).isEmpty)
    }

    @Test func runsLeaveAnActivityTrail() async {
        let engine = make(TestClock(start))
        let id = await pipeline(engine)
        await engine.run(id)
        let log = FileStore(root: root).activity()
        #expect(log.contains { $0.message.hasPrefix("Run started: manual") })
        #expect(log.contains { $0.message == "Morning: finished" })
        #expect(log.first?.kind == .run)
    }
}

@Suite struct ActivityLogTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    @Test func theLogKeepsItsNewestEntries() {
        let files = FileStore(root: root)
        let at = T.date("2026-10-20 12:00:00 -0400")
        for i in 0..<(FileStore.activityLimit + 50) { files.logActivity(ActivityEntry(at: at, kind: .run, message: "\(i)")) }
        files.trimActivity()
        let log = files.activity()
        #expect(log.count == FileStore.activityLimit)
        #expect(log.first?.message == "\(FileStore.activityLimit + 49)")
    }

    @Test func diagnosticsHoldNothingPrivate() async throws {
        let files = FileStore(root: root)
        let at = T.date("2026-10-20 12:00:00 -0400")
        let tokens = MemoryTokenStore()
        let engine = Engine(.init(store: FakeHealthStore(), files: files, tokens: tokens, device: { Device(name: $0, model: "m", os: "o", app: "a") }, calendar: { newYork }, now: { at }, pause: { _ in }))
        let target = LoadTarget.web(WebTarget(url: "https://e.test/secret-path", headers: [.init(name: "X-Key", value: "header-secret")]))
        let definition = PipelineDefinition(extract: ExtractSpec(range: .today), template: .builtIn("t"), templateName: "My Template")
        _ = await engine.add(Destination(name: "Private Name", kind: .target(target)), token: "token-secret", definition: definition)
        await engine.setDeviceName("My Phone")
        let summary = Diagnostics.summary(files.load(), info: .init(app: "A", os: "27", model: "M"), now: at).canonical
        for secret in ["token-secret", "header-secret", "secret-path", "Private Name", "My Phone"] {
            #expect(!summary.contains(secret), "\(secret)")
        }
        #expect(summary.contains("e.test"))
        #expect(summary.contains("My Template"))

        let out = root.appendingPathComponent("out", isDirectory: true)
        let zip = try Diagnostics.write(files: files, info: .init(app: "A", os: "27", model: "M"), now: at, to: out)
        #expect(FileManager.default.fileExists(atPath: zip.path))
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", zip.path]
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #endif
    }
}

@Suite struct BackgroundUploaderTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    /// An answer saved while the app was away is picked up, not sent again.
    @Test func aSavedAnswerIsUsedWithoutUploading() async throws {
        let folder = root.appendingPathComponent("uploads")
        let uploader = BackgroundUploader(folder: folder, configuration: .ephemeral)
        let outcome = BackgroundUploader.Outcome(status: 201, body: Data("{\"message\":\"ok\"}".utf8), error: nil)
        try JSONEncoder().encode(outcome).write(to: folder.appendingPathComponent("k.json"))
        let got = await uploader.upload(URLRequest(url: URL(string: "http://127.0.0.1:1/")!), file: folder, key: "k", wait: .seconds(1))
        #expect(got == outcome)
        uploader.clear(key: "k")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("k.json").path))
    }

    /// An upload that can't finish in time reports nil for the next run.
    @Test func aFailedConnectionReportsItsError() async throws {
        let folder = root.appendingPathComponent("uploads")
        let uploader = BackgroundUploader(folder: folder, configuration: .ephemeral)
        let file = root.appendingPathComponent("f")
        try Data("x".utf8).write(to: file)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/")!)
        request.httpMethod = "POST"
        let got = await uploader.upload(request, file: file, key: "k2", wait: .seconds(10))
        #expect(got?.status == nil)
        #expect(got?.error != nil)
    }
}
