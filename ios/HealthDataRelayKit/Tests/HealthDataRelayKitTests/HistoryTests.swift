import Foundation
import Testing
@testable import HealthDataRelayKit

private let zone = Calendar.local(T.vancouver)
private let noon = T.date("2026-10-25 12:00:00 -0700")
private let floor7 = T.date("2026-10-18 00:00:00 -0700")

@Suite struct HistoryLimitTests {
    @Test func theLimitIsSevenDaysBeforeTodayAndFourteenToCompare() {
        let limit = HistoryLimit.capped
        #expect(limit.firstDay(now: noon, calendar: zone) == T.day("2026-10-18"))
        #expect(limit.floor(now: noon, calendar: zone) == floor7)
        #expect(limit.floor(now: noon, calendar: zone, comparison: true) == T.date("2026-10-11 00:00:00 -0700"))
        #expect(HistoryLimit.unlimited.floor(now: noon, calendar: zone) == nil)
    }

    @Test func theFloorIsLocalMidnightAcrossAClockChange() {
        // Clocks go back on 2026-11-01 and forward on 2026-03-08.
        #expect(HistoryLimit.capped.floor(now: T.date("2026-11-04 08:00:00 -0800"), calendar: zone) == T.date("2026-10-28 00:00:00 -0700"))
        #expect(HistoryLimit.capped.floor(now: T.date("2026-03-10 08:00:00 -0700"), calendar: zone) == T.date("2026-03-03 00:00:00 -0800"))
        // The same instant is a different day somewhere else.
        let tokyo = Calendar.local(TimeZone(identifier: "Asia/Tokyo")!)
        #expect(HistoryLimit.capped.firstDay(now: noon, calendar: tokyo) == T.day("2026-10-19"))
    }

    @Test func everySevenDayChoiceFitsWhole() throws {
        let limit = HistoryLimit.capped
        let planner = RangePlanner(calendar: zone)
        let last = DateRangePreset.last7Days.interval(now: noon, calendar: zone)
        #expect(limit.clamp(last, now: noon, calendar: zone) == last)
        let previous = try planner.ranges(.previousDays(7), now: noon, floor: floor7)
        #expect(previous == [DateInterval(start: floor7, end: T.date("2026-10-25 00:00:00 -0700"))])
        #expect(try planner.ranges(.sinceLastRun, now: noon, floor: floor7) == [DateInterval(start: floor7, end: noon)])
        #expect(limit.allows(lastDays: 7) && !limit.allows(lastDays: 30))
        #expect(HistoryLimit.unlimited.allows(lastDays: 365))
    }

    @Test func aLongerRangeIsCutAndAnOlderOneRefused() throws {
        let planner = RangePlanner(calendar: zone)
        #expect(try planner.ranges(.previousDays(30), now: noon, floor: floor7).first?.start == floor7)
        #expect(try planner.ranges(.lastDays(90), now: noon, floor: floor7) == [DateInterval(start: floor7, end: noon)])
        let old = DateInterval(start: T.date("2026-09-01 00:00:00 -0700"), end: T.date("2026-09-08 00:00:00 -0700"))
        #expect(throws: RangePlanner.Failure.beyondHistory) { try planner.ranges(.fixed(old), now: noon, floor: floor7) }
        #expect(throws: RangePlanner.Failure.beyondHistory) { try planner.ranges(.askAtRun, now: noon, answer: old, floor: floor7) }
        // Late samples from before the floor are left out; the run goes on.
        let cursor = ExtractCursor(lastEnd: T.date("2026-10-24 12:00:00 -0700"))
        #expect(try planner.ranges(.sinceLastRun, now: noon, cursor: cursor, late: [old], floor: floor7).count == 1)
        #expect(try planner.ranges(.previousDays(30), now: noon).first?.start == T.date("2026-09-25 00:00:00 -0700"))
    }

    @Test func aSavedRangeKnowsWhenItAsksForTooMuch() {
        let limit = HistoryLimit.capped
        #expect(limit.exceeds(.previousDays(30), now: noon, calendar: zone))
        #expect(!limit.exceeds(.previousDays(7), now: noon, calendar: zone))
        #expect(!limit.exceeds(.sinceLastRun, now: noon, calendar: zone))
        #expect(limit.exceeds(.fixed(DateInterval(start: floor7.addingTimeInterval(-1), end: noon)), now: noon, calendar: zone))
        #expect(!HistoryLimit.unlimited.exceeds(.previousDays(365), now: noon, calendar: zone))
    }

    @Test func whatEachPlanAllows() {
        let trial = Access.trial(endsAt: noon)
        #expect(Access.free.history == .capped && trial.history == .capped)
        #expect(Access.full(.monthly).history == .unlimited)
        #expect(!Access.free.allowsPipelineRuns && !Access.free.allowsReports)
        #expect(trial.allowsPipelineRuns && trial.allowsReports)
        #expect(Access.free.enginePolicy == EnginePolicy(automation: false, manualRuns: false, history: .capped))
        #expect(trial.enginePolicy == EnginePolicy(history: .capped))
        #expect(Access.full(.lifetime).enginePolicy == .unrestricted)
    }
}

@Suite struct CappedHealthQueryingTests {
    private let fake = FakeHealthQuerying(calendar: zone)
    private let box = HistoryLimitBox(.capped)
    private let october = DateInterval(start: T.date("2026-10-01 00:00:00 -0700"), end: noon)

    private func capped(_ scope: CappedHealthQuerying.Scope = .standard) -> CappedHealthQuerying {
        CappedHealthQuerying(fake, box: box, scope: scope, calendar: { zone }, now: { noon })
    }

    private func steps(_ store: HealthQuerying, _ range: DateInterval) async throws -> [Double] {
        try await store.quantityPage("HKQuantityTypeIdentifierStepCount", unit: "count", in: range, after: nil, limit: 100).items.map(\.value)
    }

    @Test func nothingOlderThanTheLimitIsRead() async throws {
        fake.add("step_count", at: T.date("2026-10-05 09:00:00 -0700"), 1)
        fake.add("step_count", at: T.date("2026-10-12 09:00:00 -0700"), 2)
        fake.add("step_count", at: T.date("2026-10-20 09:00:00 -0700"), 3)
        #expect(try await steps(capped(), october) == [3])
        #expect(try await steps(capped(.comparison), october) == [2, 3])
        box.limit = .unlimited
        #expect(try await steps(capped(), october) == [1, 2, 3])
    }

    @Test func aRangeWhollyTooOldNeverReachesHealth() async throws {
        fake.add("step_count", at: T.date("2026-10-05 09:00:00 -0700"), 1)
        let old = DateInterval(start: october.start, end: floor7)
        let store = capped()
        #expect(try await steps(store, old).isEmpty)
        #expect(try await store.workoutPage(in: old, after: nil, limit: 10).items.isEmpty)
        #expect(try await store.ecgPage(in: old, after: nil, limit: 10).items.isEmpty)
        #expect(try await store.statesOfMind(in: old).isEmpty)
        #expect(try await store.medicationDoses(in: old).isEmpty)
        #expect(try await store.heartbeats(in: old).isEmpty)
        let plan = BucketPlanner(grouping: .days, calendar: zone).plans(old)[0]
        #expect(try await store.buckets(BucketQuery(type: "HKQuantityTypeIdentifierStepCount", unit: "count", style: .sum, plan: plan)).isEmpty)
        #expect(fake.pageReads == 0 && fake.bucketQueries.isEmpty)
    }

    @Test func aYearBucketHoldsOnlyTheDaysInReach() async throws {
        fake.add("step_count", at: T.date("2026-03-01 09:00:00 -0800"), 100)
        fake.add("step_count", at: T.date("2026-10-20 09:00:00 -0700"), 5)
        let spec = ExtractSpec(metrics: .only(["step_count"]), range: .lastDays(7), grouping: .years)
        let range = RangePlanner(calendar: zone).lastDays(7, now: noon)
        var pager = Extractor(store: capped(), spec: spec, calendar: zone, ranges: [range]).points(of: MetricCatalog.metric(named: "step_count")!)
        let points = try #require(try await pager.next())
        #expect(points.map(\.qty) == [5])
        #expect(fake.bucketQueries.last?.from == floor7)
        // The bucket still starts where a year does.
        #expect(points[0].date == T.date("2026-01-01 00:00:00 -0800"))
    }

    @Test func sleepReachesTheEveningBeforeTheFirstDay() async throws {
        let sleep = CappedHealthQuerying.sleepType
        fake.addCategory(sleep, DetailedCategory(id: "night", source: "Watch", start: T.date("2026-10-17 23:00:00 -0700"), end: T.date("2026-10-18 06:00:00 -0700"), value: 3))
        fake.addCategory(sleep, DetailedCategory(id: "older", source: "Watch", start: T.date("2026-10-15 23:00:00 -0700"), end: T.date("2026-10-16 06:00:00 -0700"), value: 3))
        fake.addCategory("HKCategoryTypeIdentifierHeadache", DetailedCategory(id: "ache", source: "iPhone", start: T.date("2026-10-17 12:00:00 -0700"), end: T.date("2026-10-17 13:00:00 -0700"), value: 2))
        let store = capped()
        #expect(try await store.categoryPage(sleep, in: october, after: nil, limit: 10).items.map(\.id) == ["night"])
        #expect(try await store.categoryPage("HKCategoryTypeIdentifierHeadache", in: october, after: nil, limit: 10).items.isEmpty)
    }

    @Test func lateSamplesFromBeforeTheLimitAreNotReported() async throws {
        fake.add("step_count", at: T.date("2026-10-05 09:00:00 -0700"), 1)
        fake.add("step_count", at: T.date("2026-10-20 09:00:00 -0700"), 3)
        let type = HealthType(.quantity, "HKQuantityTypeIdentifierStepCount")
        let changes = try await capped().additions(type, anchor: nil, since: october.start)
        #expect(changes.added.map(\.start) == [T.date("2026-10-20 09:00:00 -0700")])
    }
}

@Suite struct EngineHistoryTests {
    @Test func aNewPipelineListsOnlyTheDaysInReach() async {
        let rig = Rig()
        await rig.engine.setPolicy(EnginePolicy(history: .capped))
        await rig.addAll()
        await rig.engine.sync(.manual)
        let sent = rig.destinations[rig.ids[0]]!.sentDays.flatMap { $0 }
        #expect(sent.first == "2026-10-18" && sent.last == "2026-10-25" && sent.count == 8)
        await rig.engine.resend(lastDays: 35)
        #expect(await rig.lane().dirty.days.first?.description == "2026-10-18")
    }

    @Test func aLimitSetLaterDropsOlderDays() async {
        let rig = Rig()
        await rig.addAll()
        #expect(await rig.lane().dirty.count == 30)
        await rig.engine.setPolicy(EnginePolicy(history: .capped))
        #expect(await rig.lane().dirty.days.first?.description == "2026-10-18")
    }

    @Test func aDayPassingMovesTheLimit() async {
        let rig = Rig()
        await rig.engine.setPolicy(EnginePolicy(history: .capped))
        await rig.addAll()
        rig.clock.advance(86400)
        await rig.engine.sync(.manual)
        #expect(rig.destinations[rig.ids[0]]!.sentDays.flatMap { $0 }.min() == "2026-10-19")
    }

    @Test func buyingSendsWhatWasHeldBack() async {
        let rig = Rig()
        await rig.engine.setPolicy(EnginePolicy(history: .capped))
        await rig.addAll()
        await rig.engine.sync(.manual)
        #expect(await rig.lane().dirty.isEmpty)
        await rig.engine.setPolicy(.unrestricted)
        let days = await rig.lane().dirty.days
        #expect(days.count == DirtyRules.sweepDays && days.first?.description == "2026-09-21")
        // Only once.
        await rig.engine.sync(.manual)
        await rig.engine.setPolicy(.unrestricted)
        #expect(await rig.lane().dirty.isEmpty)
    }

    @Test func aPurchaseFoundAtLaunchSendsWhatWasHeldBackToo() async {
        let rig = Rig()
        await rig.engine.setPolicy(EnginePolicy(history: .capped))
        await rig.addAll()
        await rig.engine.sync(.manual)
        let clock = rig.clock
        let relaunched = Engine(.init(store: rig.store, files: rig.files, tokens: rig.tokens, device: { Device(name: $0, model: "m", os: "o", app: "a") },
                                      calendar: { .local(T.vancouver) }, now: { clock.now }, pause: { _ in }), policy: .unrestricted)
        #expect(await relaunched.snapshot.destinations[0].lane.dirty.count == DirtyRules.sweepDays)
    }

    @Test func theLimitIsInForceFromTheStart() async {
        let rig = Rig()
        await rig.addAll()
        let clock = rig.clock
        let relaunched = Engine(.init(store: rig.store, files: rig.files, tokens: rig.tokens, device: { Device(name: $0, model: "m", os: "o", app: "a") },
                                      calendar: { .local(T.vancouver) }, now: { clock.now }, pause: { _ in }), policy: EnginePolicy(history: .capped))
        #expect(await relaunched.snapshot.destinations[0].lane.dirty.days.first?.description == "2026-10-18")
    }

    @Test func withoutManualRunsATapRunsNothing() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.setPolicy(Access.free.enginePolicy)
        let all = await rig.engine.sync(.manual)
        let one = await rig.engine.run(rig.ids[0])
        #expect(all.message == Engine.needsFullMessage && one.message == Engine.needsFullMessage)
        #expect(rig.destinations[rig.ids[0]]!.bodies.isEmpty)
        let before = await rig.lane().dirty.days
        await rig.engine.resend(lastDays: 3)
        await rig.engine.resend(rig.ids[0], lastDays: 3)
        #expect(await rig.lane().dirty.days == before)
        let snapshot = await rig.engine.snapshot
        #expect(!snapshot.manualRuns)
        #expect(snapshot.pipelines.allSatisfy { !$0.runnable && $0.timing(now: rig.clock.now) == .needsFullAccess })
        // A test sends no Health data, so it still answers.
        #expect(await rig.engine.test(rig.ids[0]).verdict == .accepted)
    }
}

@Suite struct TemplateHistoryTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let queries = FakeHealthQuerying(calendar: zone)
    private let csv = """
    ---
    name: Steps
    format: csv
    ---
    {% for p in metrics.step_count.data %}{{ p.date | date: '%Y-%m-%d' }} {{ p.qty }}
    {% endfor %}
    """

    private func engine(_ transport: ArtifactTransport, policy: EnginePolicy) -> Engine {
        let source = csv
        let box = HistoryLimitBox(policy.history)
        return Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: MemoryTokenStore(),
                            device: { Device(name: $0, model: "m", os: "o", app: "a") },
                            calendar: { zone }, now: { noon }, pause: { _ in },
                            queries: CappedHealthQuerying(queries, box: box, calendar: { zone }, now: { noon }),
                            makeTransport: { _, _ in transport }, templateSource: { _ in source }), policy: policy)
    }

    private func add(_ engine: Engine, _ range: RangeSpec) async -> UUID {
        let spec = ExtractSpec(metrics: .only(["step_count"]), range: range, grouping: .days)
        return await engine.add(Destination(name: "Web", kind: .target(.web(WebTarget(url: "https://example.com/in")))), token: nil,
                                definition: PipelineDefinition(extract: spec, template: .builtIn(BuiltInTemplates.metricsJSONv2), templateName: "Steps")).id
    }

    private func seed() {
        queries.add("step_count", at: T.date("2026-10-10 09:00:00 -0700"), 5)
        queries.add("step_count", at: T.date("2026-10-20 09:00:00 -0700"), 1)
    }

    @Test func aChangedDaysPipelineNeverListsADayOutOfReach() async {
        seed()
        let transport = RecordingTransport()
        let engine = engine(transport, policy: EnginePolicy(history: .capped))
        let id = await add(engine, .changedDays)
        #expect(await engine.snapshot.pipelines[0].lane.dirty.days.first?.description == "2026-10-18")
        await engine.run(id)
        #expect(transport.texts == ["2026-10-20 1\n"])
    }

    @Test func aLongerRangeSendsTheDaysInReach() async {
        seed()
        let transport = RecordingTransport()
        let engine = engine(transport, policy: EnginePolicy(history: .capped))
        let id = await add(engine, .previousDays(30))
        await engine.run(id)
        #expect(transport.texts == ["2026-10-20 1\n"])
    }

    @Test func aRangeWhollyOutOfReachSaysSo() async {
        seed()
        let transport = RecordingTransport()
        let engine = engine(transport, policy: EnginePolicy(history: .capped))
        let id = await add(engine, .askAtRun)
        await engine.run(id, answer: DateInterval(start: T.date("2026-10-01 00:00:00 -0700"), end: T.date("2026-10-11 00:00:00 -0700")))
        #expect(transport.texts.isEmpty)
        #expect(await engine.snapshot.pipelines[0].lane.lastError == Engine.beyondHistoryMessage)
    }

    @Test func fullSendsAllOfIt() async {
        seed()
        let transport = RecordingTransport()
        let engine = engine(transport, policy: .unrestricted)
        let id = await add(engine, .previousDays(30))
        await engine.run(id)
        #expect(transport.texts == ["2026-10-10 5\n2026-10-20 1\n"])
    }
}

@Suite struct MCPHistoryTests {
    private func call(_ args: JSON) async -> JSON? {
        let handler = MCPHandler(store: RichData.store(), calendar: zone, device: FixtureTests.device, now: { noon }, history: { .capped })
        return await handler.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "health_metrics", "arguments": args]])
    }

    @Test func anAnswerSaysWhenItWasCutShort() async throws {
        let reply = await call(["start": "2026-10-01", "end": "2026-10-25"])
        guard case .array(let content)? = reply?["result"]?["content"] else {
            Issue.record("no content")
            return
        }
        #expect(content.count == 2)
        #expect(content[0]["text"]?.stringValue?.contains("step_count") == true)
        #expect(content[1]["text"]?.stringValue?.contains("2026-10-18") == true)
        #expect(reply?["result"]?["isError"] == nil)
    }

    @Test func theDefaultWeekIsWhole() async throws {
        guard case .array(let content)? = await call(.object([:]))?["result"]?["content"] else {
            Issue.record("no content")
            return
        }
        #expect(content.count == 1)
    }

    @Test func datesWhollyOutOfReachAreAnErrorAModelCanRead() async throws {
        let reply = await call(["start": "2026-09-01", "end": "2026-09-10"])
        #expect(reply?["result"]?["isError"] == .bool(true))
        guard case .array(let content)? = reply?["result"]?["content"] else { return }
        #expect(content.first?["text"]?.stringValue?.contains("2026-10-18") == true)
    }
}
