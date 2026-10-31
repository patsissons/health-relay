import Foundation
import Testing
@testable import HealthRelayKit

@Suite struct PipelineMigrationTests {
    static func goldenFiles() throws -> FileStore {
        let files = StateFileTests.emptyFiles()
        try Data(contentsOf: GoldenTests.dir.appendingPathComponent("state-0.1.json")).write(to: StateFileTests.stateFile(files))
        return files
    }

    @Test func aSavedDestinationIsAPipelineWithItsOwnIdLaneAndToken() async throws {
        let files = try Self.goldenFiles()
        let id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let tokens = MemoryTokenStore()
        tokens.setToken("saved", for: id)
        let engine = Engine(.init(store: FakeHealthStore(), files: files, tokens: tokens,
                                  device: { Device(name: $0, model: "", os: "", app: "") }))
        let pipeline = try #require(await engine.snapshot.pipelines.first { $0.id == id })
        #expect(pipeline.name == "Paused one" && pipeline.destination.paused && pipeline.hasToken)
        #expect(pipeline.lane.dirty.count == 2 && pipeline.lane.queue.count == 1)
        #expect(pipeline.extract == .changedDays && pipeline.transform == .healthRelayPush)
    }

    @Test func automaticSyncBecomesWhenHealthChangesAndOffBecomesManual() throws {
        let id = UUID()
        var state = EngineState()
        #expect(state.trigger(for: id) == .manual)
        state.autoSync = false
        #expect(state.trigger(for: id) == .manual)
        state.autoSync = true
        #expect(state.trigger(for: id) == .whenHealthChanges)
    }

    @Test func aChosenTriggerWinsAndLeavesTheOldStateFileShapeAlone() async throws {
        let files = try Self.goldenFiles()
        #expect(files.load().triggers == nil, "nothing is rewritten until the user chooses")
        let engine = Engine(.init(store: FakeHealthStore(), files: files, tokens: MemoryTokenStore(),
                                  device: { Device(name: $0, model: "", os: "", app: "") }))
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        #expect(await engine.snapshot.pipelines.first { $0.id == id }?.trigger == .whenHealthChanges)
        await engine.setTrigger(id, .manual)
        #expect(files.load().trigger(for: id) == .manual)
        #expect(files.load().trigger(for: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!) == .whenHealthChanges)
    }
}

@Suite struct RunningOnePipelineTests {
    @Test func runSendsOnlyThatPipeline() async {
        let a = FakeDestination()
        let b = FakeDestination()
        let rig = Rig([a, b])
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        #expect(a.sentDays.count == 30 && b.bodies.isEmpty)
        #expect(await rig.lane(0).lastRun != nil)
        #expect(await rig.lane(1).lastRun == nil)
    }

    @Test func anIdleManualPipelineDoesNotHoldTheAnchorsAndMissesNothing() async {
        let used = FakeDestination()
        let idle = FakeDestination()
        let rig = Rig([used, idle])
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        let before = await rig.engine.anchorsForTesting
        #expect(!before.isEmpty, "the idle pipeline's 30 waiting days do not hold them")

        rig.clock.advance(3600)
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-10-20 09:00:00 -0700"), 10)
        await rig.engine.run(rig.ids[0])
        #expect(await rig.engine.anchorsForTesting != before)

        await rig.engine.run(rig.ids[1])
        #expect(idle.sentDays.flatMap { $0 }.contains("2026-10-20"))
        #expect(await rig.lane(1).dirty.isEmpty)
    }

    @Test func aFailedRunStillHoldsTheAnchorsForItsOwnRetry() async {
        let fake = FakeDestination()
        let rig = Rig([fake])
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        let committed = await rig.engine.anchorsForTesting
        rig.clock.advance(3600)
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-10-20 09:00:00 -0700"), 10)
        fake.answer([500])
        await rig.engine.run(rig.ids[0])
        #expect(await rig.engine.anchorsForTesting == committed)
    }

    @Test func tappingRunOverridesABackoff() async {
        let fake = FakeDestination([503])
        let rig = Rig([fake])
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        #expect(await rig.lane().retryAfter != nil && fake.bodies.count == 1)
        await rig.engine.run(rig.ids[0])
        #expect(fake.bodies.count > 1 && fake.bodies[1] == fake.bodies[0], "the same bytes, without waiting")
        #expect(await rig.lane().dirty.isEmpty)
    }

    @Test func runNeverSendsToAPipelineThatNeedsAttention() async {
        let fake = FakeDestination([401])
        let rig = Rig([fake])
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        let sent = fake.bodies.count
        await rig.engine.run(rig.ids[0])
        #expect(fake.bodies.count == sent)
        #expect(await rig.lane().attention != nil)
    }

    @Test func aPipelineUnusedForMonthsStillGetsChangesOlderThanTheWindow() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        let fake = rig.destinations[rig.ids[0]]!
        let sent = fake.bodies.count
        rig.clock.advance(90 * 86400)
        // Recorded while idle, and a long way outside the 40-day window by the time it runs.
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-11-01 09:00:00 -0800"), 10)
        await rig.engine.run(rig.ids[0])
        #expect(fake.sentDays.dropFirst(sent).flatMap { $0 }.contains("2026-11-01"))
    }

    @Test func activeUseStillIgnoresOldImports() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.run(rig.ids[0])
        let fake = rig.destinations[rig.ids[0]]!
        let sent = fake.bodies.count
        rig.clock.advance(3600)
        // A new app backfilling a year ago must not mark that day.
        rig.store.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2025-10-25 09:00:00 -0700"), 10)
        await rig.engine.run(rig.ids[0])
        #expect(!fake.sentDays.dropFirst(sent).flatMap { $0 }.contains("2025-10-25"))
    }

    @Test func aTapDuringAnotherRunIsQueuedThenRuns() async {
        let rig = await HookRig()
        let second = UUID()
        await rig.engine.add(Destination(id: second, name: "second", kind: .http(HTTPEndpoint(url: URL(string: "https://example.test/2")!))), token: nil)
        let engine = rig.engine
        let id = rig.id
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var activities: [(Pipeline.Activity, Pipeline.Activity)] = []
        }
        let seen = Seen()
        rig.destination.during { count in
            guard count == 1 else { return }
            let tap = Task { await engine.run(second) }
            try? await Task.sleep(for: .milliseconds(50))
            let pipelines = await engine.snapshot.pipelines
            let pair = (pipelines.first { $0.id == id }!.activity, pipelines.first { $0.id == second }!.activity)
            seen.lock.withLock { seen.activities.append(pair) }
            _ = tap
        }
        await rig.engine.run(rig.id)
        // Let the queued run take its turn.
        for _ in 0..<200 where await rig.engine.snapshot.pipelines.first(where: { $0.id == second })!.lane.lastRun == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let first = seen.lock.withLock { seen.activities.first }
        #expect(first?.0 == .running && first?.1 == .queued)
        let pipelines = await rig.engine.snapshot.pipelines
        #expect(pipelines.allSatisfy { $0.activity == .idle || $0.lane.lastRun != nil })
        #expect(pipelines.first { $0.id == second }?.lane.lastRun != nil)
    }

    @Test func aCardsWaitingDaysFallAsItRuns() async {
        let rig = Rig()
        await rig.addAll()
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var waiting: [Int] = []
        }
        let counts = Counts()
        await rig.engine.observe { snapshot in
            guard snapshot.progress != nil, let lane = snapshot.pipelines.first?.lane else { return }
            counts.lock.withLock { counts.waiting.append(lane.dirty.count) }
        }
        await rig.engine.run(rig.ids[0])
        let seen = counts.lock.withLock { Set(counts.waiting) }
        #expect(seen.contains(15), "seen partway, not only at the start and end: \(seen.sorted())")
    }

    @Test func resendingOnePipelineLeavesTheOtherAlone() async {
        let rig = Rig([FakeDestination(), FakeDestination()])
        await rig.addAll()
        await rig.engine.sync(.manual)
        rig.clock.advance(3600)
        await rig.engine.resend(rig.ids[0], lastDays: 3)
        #expect(await rig.lane(0).dirty.count == 3)
        #expect(await rig.lane(1).dirty.isEmpty)
    }

    @Test func removingAPipelineForgetsItsTrigger() async {
        let rig = Rig()
        await rig.addAll()
        await rig.engine.setTrigger(rig.ids[0], .whenHealthChanges)
        await rig.engine.remove(rig.ids[0])
        #expect(await rig.engine.state.triggers?[rig.ids[0]] == nil)
    }
}

@Suite struct ScheduledPipelineTests {
    static func hourly(_ rig: Rig, _ i: Int = 0) async {
        await rig.engine.setTrigger(rig.ids[i], .every(Schedule(count: 1, unit: .hours, since: rig.clock.now)))
    }

    @Test func notDueUntilItsTime() async {
        let rig = Rig()
        await rig.addAll()
        await Self.hourly(rig)
        let fake = rig.destinations[rig.ids[0]]!

        rig.clock.advance(3599)
        let early = await rig.engine.sync(.refresh)
        await rig.engine.wake()
        await rig.engine.syncIfStale()
        await rig.engine.runDue()
        #expect(fake.bodies.isEmpty && early.message == "Nothing is due")

        rig.clock.advance(1)
        await rig.engine.sync(.refresh)
        #expect(fake.sentDays.count == 30)
        // Due again an hour after that run, not before.
        rig.clock.advance(3599)
        await rig.engine.runDue()
        #expect(fake.sentDays.count == 30)
        rig.clock.advance(1)
        await rig.engine.runDue()
        #expect(fake.sentDays.count == 31)
    }

    @Test func anyTriggerRunsWhatIsDueAndOnlyThat() async {
        let scheduled = FakeDestination()
        let manual = FakeDestination()
        let rig = Rig([scheduled, manual])
        await rig.addAll()
        await Self.hourly(rig)
        rig.clock.advance(3600)
        await rig.engine.wake()
        #expect(scheduled.sentDays.count == 30 && manual.bodies.isEmpty)
    }

    @Test func aFailedDeliveryRetriesWhenItsBackoffEndsWithoutWaitingForTheNextInterval() async {
        let fake = FakeDestination([503])
        let rig = Rig([fake])
        await rig.addAll()
        await Self.hourly(rig)
        rig.clock.advance(3600)
        await rig.engine.runDue()
        #expect(fake.bodies.count == 1)
        rig.clock.advance(30)
        await rig.engine.runDue()
        #expect(fake.bodies.count == 1, "still backing off")
        rig.clock.advance(31)
        await rig.engine.runDue()
        #expect(fake.bodies.count > 1)
    }

    @Test func aRunStoppedOrUnreadableStaysDue() async {
        let rig = Rig()
        await rig.addAll()
        await Self.hourly(rig)
        rig.clock.advance(3600)
        rig.store.failReads = true
        await rig.engine.sync(.refresh)
        let lane = await rig.lane()
        #expect(lane.lastRun == nil && lane.lastMessage != nil)
        rig.store.failReads = false
        await rig.engine.runDue()
        let after = await rig.lane()
        #expect(after.lastRun != nil && after.lastMessage == nil)
    }

    @Test func manualPipelinesNeverRunThemselves() async {
        let fake = FakeDestination()
        let rig = Rig([fake])
        await rig.addAll()
        await rig.engine.setTrigger(rig.ids[0], .manual)
        rig.clock.advance(30 * 86400)
        await rig.engine.wake()
        await rig.engine.syncIfStale()
        await rig.engine.runDue()
        await rig.engine.sync(.refresh)
        #expect(fake.bodies.isEmpty)
    }

    @Test func timingForTheCard() {
        let now = T.date("2026-10-25 12:00:00 -0700")
        var pipeline = Pipeline(destination: Destination(name: "x", kind: .http(HTTPEndpoint(url: URL(string: "https://example.test")!))),
                                lane: Lane(), hasToken: false, trigger: .manual, activity: .idle)
        #expect(pipeline.timing(now: now) == .whenTapped)
        pipeline.trigger = .whenHealthChanges
        #expect(pipeline.timing(now: now) == .whenHealthChanges)
        pipeline.trigger = .every(Schedule(count: 2, unit: .hours, since: now))
        #expect(pipeline.timing(now: now) == .next(now.addingTimeInterval(7200)))
        #expect(pipeline.timing(now: now.addingTimeInterval(7200)) == .due(.waitingForIOS))
        pipeline.lane.lastMessage = Engine.lockedMessage
        #expect(pipeline.timing(now: now.addingTimeInterval(7200)) == .due(.unlockIPhone))
        pipeline.lane.lastRun = now.addingTimeInterval(7000)
        #expect(pipeline.timing(now: now.addingTimeInterval(7200)) == .next(now.addingTimeInterval(14200)))
    }

    @Test(arguments: [(0.0, "0s"), (5, "5s"), (59.2, "1m 00s"), (65, "1m 05s"), (3600, "1h 00m 00s"),
                      (11525, "3h 12m 05s"), (86400, "1d 0h 00m 00s"), (-4, "0s")])
    func countdownText(_ remaining: TimeInterval, _ text: String) {
        #expect(Countdown.text(remaining) == text)
    }

    @Test func aScheduleIsNeverShorterThanOneUnit() {
        #expect(Schedule(count: 0, unit: .minutes, since: Date()).interval == 60)
    }

    @Test func theBackgroundPlanFollowsTheTriggers() async {
        let rig = Rig([FakeDestination(), FakeDestination()])
        await rig.addAll()
        var plan = await rig.engine.snapshot.backgroundPlan
        #expect(plan == BackgroundPlan(), "nothing to ask iOS for while everything is manual")
        await Self.hourly(rig)
        plan = await rig.engine.snapshot.backgroundPlan
        #expect(plan.observesHealth && !plan.dailyCatchUp && plan.nextRun == rig.clock.now.addingTimeInterval(3600))
        await rig.engine.setTrigger(rig.ids[1], .whenHealthChanges)
        plan = await rig.engine.snapshot.backgroundPlan
        #expect(plan.observesHealth && plan.dailyCatchUp)
    }
}
