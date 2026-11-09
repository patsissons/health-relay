import Foundation
import Testing
@testable import HealthDataRelayKit

@Suite struct AccessTests {
    private let start = T.date("2026-11-01 09:00:00 -0700")

    @Test func nothingBoughtAndNoTrialIsFree() {
        let a = Access.resolve(lifetime: false, subscription: nil, trialStartedAt: nil, now: start)
        #expect(a == .free)
        #expect(!a.allowsAutomation && !a.allowsServer && !a.allowsCustomTemplates)
    }

    @Test func theTrialLastsSevenDays() {
        let end = start.addingTimeInterval(7 * 86400)
        #expect(Access.resolve(lifetime: false, subscription: nil, trialStartedAt: start, now: start) == .trial(endsAt: end))
        let lastMoment = Access.resolve(lifetime: false, subscription: nil, trialStartedAt: start, now: end.addingTimeInterval(-1))
        #expect(lastMoment == .trial(endsAt: end))
        #expect(lastMoment.allowsAutomation)
        #expect(Access.resolve(lifetime: false, subscription: nil, trialStartedAt: start, now: end) == .free)
    }

    @Test func daysLeftRoundUp() {
        let a = Access.resolve(lifetime: false, subscription: nil, trialStartedAt: start, now: start)
        #expect(a.trialDaysLeft(now: start) == 7)
        #expect(a.trialDaysLeft(now: start.addingTimeInterval(6.5 * 86400)) == 1)
        #expect(Access.free.trialDaysLeft(now: start) == nil)
    }

    @Test func aPurchaseWinsOverTheTrial() {
        #expect(Access.resolve(lifetime: true, subscription: nil, trialStartedAt: start, now: start) == .full(.lifetime))
        #expect(Access.resolve(lifetime: false, subscription: .monthly, trialStartedAt: start, now: start) == .full(.monthly))
        #expect(Access.resolve(lifetime: true, subscription: .yearly, trialStartedAt: nil, now: start) == .full(.lifetime))
    }

    @Test func anExpiredSubscriptionAfterTheTrialIsFree() {
        // StoreKit drops an expired subscription from current entitlements.
        let later = start.addingTimeInterval(40 * 86400)
        #expect(Access.resolve(lifetime: false, subscription: nil, trialStartedAt: start, now: later) == .free)
    }

    @Test func theTrialStartsAtTheFirstDownload() {
        let downloaded = start.addingTimeInterval(-3 * 86400)
        #expect(Access.trialStart(firstDownload: downloaded, fromAppStore: true, firstLaunch: start) == downloaded)
        // A reinstall months later finds the trial long over.
        let reinstalled = Access.resolve(lifetime: false, subscription: nil,
                                         trialStartedAt: Access.trialStart(firstDownload: downloaded, fromAppStore: true, firstLaunch: start.addingTimeInterval(90 * 86400)),
                                         now: start.addingTimeInterval(90 * 86400))
        #expect(reinstalled == .free)
    }

    @Test func outsideTheAppStoreItStartsAtFirstLaunch() {
        let sandboxDate = Date(timeIntervalSinceReferenceDate: 397033200)
        #expect(Access.trialStart(firstDownload: sandboxDate, fromAppStore: false, firstLaunch: start) == start)
        #expect(Access.trialStart(firstDownload: nil, fromAppStore: true, firstLaunch: start) == start)
    }

    @Test func roundTripsForTheCache() throws {
        for a in [Access.free, .trial(endsAt: start), .full(.yearly)] {
            #expect(try JSONDecoder().decode(Access.self, from: JSONEncoder().encode(a)) == a)
        }
    }
}

@Suite struct EngineAutomationTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let start = T.date("2026-10-20 12:00:00 -0400")
    private let newYork = Calendar.local(TimeZone(identifier: "America/New_York")!)

    private func make(_ clock: TestClock, transport: ArtifactTransport) -> Engine {
        let calendar = newYork
        return Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: MemoryTokenStore(), device: { Device(name: $0, model: "m", os: "o", app: "a") },
                            calendar: { calendar }, now: { clock.now }, pause: { _ in }, queries: FakeHealthQuerying(calendar: calendar),
                            makeTransport: { _, _ in transport }))
    }

    private func pipeline(_ engine: Engine) async -> UUID {
        await engine.add(Destination(name: "Morning", kind: .target(.web(WebTarget(url: "https://e.test")))), token: nil,
                         definition: PipelineDefinition(extract: ExtractSpec(range: .today, grouping: .days), template: .builtIn(BuiltInTemplates.metricsJSONv2), templateName: "JSON")).id
    }

    @Test func withoutAutomationNothingRunsByItself() async {
        let clock = TestClock(start)
        let transport = RecordingTransport()
        let engine = make(clock, transport: transport)
        let scheduled = await pipeline(engine)
        let following = await pipeline(engine)
        await engine.setTrigger(scheduled, .at(TimeOfDay(hour: 18, minute: 0, since: start)))
        await engine.setTrigger(following, .whenHealthChanges)
        await engine.setAutomation(false)

        clock.now = T.date("2026-10-20 18:00:01 -0400")
        await engine.runDue()
        await engine.wake()
        await engine.syncIfStale()
        await engine.sync(.refresh)
        await engine.sync(.processing)
        #expect(transport.bodies.isEmpty)

        let snapshot = await engine.snapshot
        #expect(snapshot.backgroundPlan == BackgroundPlan())
        #expect(!snapshot.automation)
        #expect(await engine.nextRun == nil)
        #expect(snapshot.pipelines.allSatisfy { $0.timing(now: clock.now) == .needsFullAccess })
        // Triggers stay saved, so paying later picks up where it was.
        #expect(snapshot.pipelines.first { $0.id == scheduled }?.trigger == .at(TimeOfDay(hour: 18, minute: 0, since: start)))
    }

    @Test func aTapStillRuns() async {
        let clock = TestClock(start)
        let transport = RecordingTransport()
        let engine = make(clock, transport: transport)
        let id = await pipeline(engine)
        await engine.setAutomation(false)
        await engine.run(id)
        #expect(transport.bodies.count == 1)
        #expect(await engine.snapshot.pipelines[0].timing(now: clock.now) == .whenTapped)
    }

    @Test func turningItBackOnResumesWhatIsDue() async {
        let clock = TestClock(start)
        let transport = RecordingTransport()
        let engine = make(clock, transport: transport)
        let id = await pipeline(engine)
        await engine.setTrigger(id, .at(TimeOfDay(hour: 18, minute: 0, since: start)))
        await engine.setAutomation(false)
        clock.now = T.date("2026-10-20 18:00:01 -0400")
        await engine.runDue()
        #expect(transport.bodies.isEmpty)

        await engine.setAutomation(true)
        #expect(await engine.snapshot.backgroundPlan.nextRun != nil)
        await engine.runDue()
        #expect(transport.bodies.count == 1)
    }
}
