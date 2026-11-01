import Foundation
import Testing
@testable import HealthDataRelayKit

private let vancouver = T.vancouver
private let calendar = Calendar.local(vancouver)
private let now = T.date("2026-10-25 12:00:00 -0700")

/// Records every part it's given and answers as it's told.
final class RecordingTransport: ArtifactTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Verdict]
    private(set) var bodies: [Data] = []
    private(set) var parts: [ArtifactPart] = []

    init(answers: [Verdict] = []) {
        self.answers = answers
    }

    func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        lock.withLock {
            bodies.append((try? Data(contentsOf: file)) ?? Data())
            parts.append(part)
            let verdict = answers.isEmpty ? .accepted : answers.removeFirst()
            return Delivery(status: verdict == .accepted ? 200 : 500, verdict: verdict, message: "\(verdict)")
        }
    }

    var texts: [String] { lock.withLock { bodies.map { String(decoding: $0, as: UTF8.self) } } }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    var current: T {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite struct TemplatePipelineTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let clock = Box(now)
    private let queries = FakeHealthQuerying(calendar: calendar)
    private let target = LoadTarget.web(WebTarget(url: "https://example.com/in"))

    private func engine(transport: ArtifactTransport, source: String? = nil, native: FakeHealthStore = FakeHealthStore()) -> Engine {
        let clock = clock
        return Engine(.init(store: native, files: FileStore(root: root), tokens: MemoryTokenStore(),
                            device: { Device(name: $0, model: "m", os: "o", app: "a") },
                            calendar: { calendar }, now: { clock.current }, pause: { _ in },
                            queries: queries, makeTransport: { _, _ in transport },
                            templateSource: { ref in
            if let source { return source }
            return Engine.builtInSource(ref)
        }))
    }

    private func definition(_ spec: ExtractSpec) -> PipelineDefinition {
        PipelineDefinition(extract: spec, template: .builtIn(BuiltInTemplates.metricsJSONv2), templateName: "Metrics JSON v2")
    }

    private let csv = """
    ---
    name: Steps
    format: csv
    ---
    {% for p in metrics.step_count.data %}{{ p.qty }}
    {% endfor %}
    """

    @Test func aRunRendersAndDelivers() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 10)
        let transport = RecordingTransport()
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today, grouping: .days)))
        await engine.run(d.id)
        #expect(transport.texts == [#"{"data":{"metrics":[{"data":[{"date":"2026-10-25 00:00:00 -0700","qty":10,"source":"Watch"}],"name":"step_count","units":"count"}]}}"#])
        let lane = await engine.snapshot.pipelines[0].lane
        #expect(lane.lastSuccess == now)
        #expect(lane.log.first?.delivery.verdict == .accepted)
        #expect(FileStore(root: root).artifacts(d.id).isEmpty)
    }

    @Test func theCardKnowsItsTemplateAndDestination() async throws {
        let engine = engine(transport: RecordingTransport())
        _ = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today)))
        let p = await engine.snapshot.pipelines[0]
        #expect(p.transform == .template(.builtIn("metrics-json-v2"), name: "Metrics JSON v2"))
        #expect(p.destinationSummary == "example.com")
        #expect(p.endpoint == nil)
    }

    @Test func aRetrySendsTheSameBytesEvenAfterNewDataArrives() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 10)
        let transport = RecordingTransport(answers: [.retry, .accepted])
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today, grouping: .days)))
        await engine.run(d.id)
        #expect(await engine.snapshot.pipelines[0].lane.retryAfter != nil)
        queries.add("step_count", at: T.date("2026-10-25 10:00:00 -0700"), 99)
        await engine.run(d.id)
        #expect(transport.bodies.count >= 2)
        #expect(transport.bodies[0] == transport.bodies[1])
    }

    @Test func aKilledAppRetriesTheSameBytes() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 10)
        let first = RecordingTransport(answers: [.retry])
        let id: UUID
        do {
            let engine = engine(transport: first)
            let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today, grouping: .days)))
            id = d.id
            await engine.run(id)
        }
        queries.add("step_count", at: T.date("2026-10-25 10:00:00 -0700"), 99)
        // A new launch: nothing shared but the files.
        let second = RecordingTransport()
        let reopened = engine(transport: second)
        await reopened.run(id)
        #expect(second.bodies.first == first.bodies[0])
    }

    @Test func aHalfWrittenArtifactIsNeverSent() async throws {
        let transport = RecordingTransport()
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today, grouping: .days)))
        let files = FileStore(root: root)
        let dir = try files.beginArtifact(d.id)
        try Data("half".utf8).write(to: dir.appendingPathComponent("part-0"))
        #expect(files.artifacts(d.id).isEmpty)
        await engine.run(d.id)
        #expect(!transport.texts.contains("half"))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func multiplePartsResumeWhereTheyStopped() async throws {
        queries.add("step_count", at: T.date("2026-10-24 09:00:00 -0700"), 1)
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 2)
        let transport = RecordingTransport(answers: [.accepted, .retry, .accepted])
        let engine = engine(transport: transport, source: """
        ---
        name: Daily
        format: csv
        partition: day
        ---
        {% for p in metrics.step_count.data %}{{ p.qty }}{% endfor %}
        """)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .lastDays(2), grouping: .days)))
        await engine.run(d.id)
        #expect(transport.texts == ["1", "2"])
        await engine.run(d.id)
        // The first part isn't sent again.
        #expect(transport.texts == ["1", "2", "2"])
        #expect(FileStore(root: root).artifacts(d.id).isEmpty)
    }

    @Test func aRefusedArtifactIsDropped() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 1)
        let transport = RecordingTransport(answers: [.rejected])
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today, grouping: .days)))
        await engine.run(d.id)
        #expect(FileStore(root: root).artifacts(d.id).isEmpty)
        #expect(await engine.snapshot.pipelines[0].lane.retryAfter != nil)
    }

    @Test func aRefusedCredentialStopsThePipeline() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 1)
        let transport = RecordingTransport(answers: [.authFailed])
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today, grouping: .days)))
        await engine.run(d.id)
        #expect(await engine.snapshot.pipelines[0].lane.attention != nil)
        #expect(FileStore(root: root).artifacts(d.id).count == 1)
    }

    @Test func aBadTemplateFailsItsOwnRunOnly() async throws {
        let transport = RecordingTransport()
        let engine = engine(transport: transport, source: "---\nname: Bad\nformat: json\n---\n{\"a\":}")
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today)))
        await engine.run(d.id)
        let lane = await engine.snapshot.pipelines[0].lane
        #expect(transport.bodies.isEmpty)
        #expect(lane.attention?.contains("valid JSON") == true)
        #expect(FileStore(root: root).artifacts(d.id).isEmpty)
    }

    @Test func sinceLastRunMovesForwardAndSkipsNothingNew() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 1)
        let transport = RecordingTransport()
        let engine = engine(transport: transport, source: csv)
        let spec = ExtractSpec(metrics: .only(["step_count"]), range: .sinceLastRun, grouping: nil)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(spec))
        await engine.run(d.id)
        #expect(transport.texts == ["1\n"])

        clock.current = now.addingTimeInterval(3600)
        await engine.run(d.id)
        // Nothing new: nothing sent.
        #expect(transport.texts.count == 1)

        queries.add("step_count", at: now.addingTimeInterval(4000), 2)
        clock.current = now.addingTimeInterval(7200)
        await engine.run(d.id)
        #expect(transport.texts == ["1\n", "2\n"])

        // Recorded earlier, arrived later: picked up as late.
        queries.add("step_count", at: now.addingTimeInterval(-7200), 3)
        clock.current = now.addingTimeInterval(10800)
        await engine.run(d.id)
        #expect(transport.texts.last == "3\n")
    }

    @Test func aFailedSinceLastRunDoesntLoseItsData() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 1)
        let transport = RecordingTransport(answers: [.retry])
        let engine = engine(transport: transport, source: csv)
        let spec = ExtractSpec(metrics: .only(["step_count"]), range: .sinceLastRun, grouping: nil)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(spec))
        await engine.run(d.id)
        clock.current = now.addingTimeInterval(3600)
        await engine.run(d.id)
        #expect(transport.texts == ["1\n", "1\n"])
    }

    @Test func changedDaysFollowsDirtyDaysAndClearsThem() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 1)
        let transport = RecordingTransport()
        let engine = engine(transport: transport, source: csv)
        let spec = ExtractSpec(metrics: .only(["step_count"]), range: .changedDays, grouping: .days)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(spec))
        #expect(await engine.snapshot.pipelines[0].lane.dirty.days.count == 30)
        await engine.run(d.id)
        #expect(transport.texts == ["1\n"])
        #expect(await engine.snapshot.pipelines[0].lane.dirty.isEmpty)
    }

    @Test func anOtherRangeNeverCollectsDirtyDaysOrHoldsAnchors() async throws {
        let native = FakeHealthStore()
        native.add("HKQuantityTypeIdentifierStepCount", source: "Watch", T.date("2026-10-25 09:00:00 -0700"), 5)
        let transport = RecordingTransport(answers: [.retry])
        let engine = engine(transport: transport, native: native)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today)))
        await engine.run(d.id)
        #expect(await engine.snapshot.pipelines[0].lane.dirty.isEmpty)
    }

    @Test func aRangeThatsAskedForFailsWithoutAnAnswer() async throws {
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 7)
        let transport = RecordingTransport()
        let engine = engine(transport: transport, source: csv)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .askAtRun, grouping: .days)))
        await engine.run(d.id)
        #expect(transport.bodies.isEmpty)
        await engine.run(d.id, answer: T.day("2026-10-25").interval(in: calendar))
        #expect(transport.texts == ["7\n"])
    }

    @Test func removingAPipelineRemovesItsFiles() async throws {
        let transport = RecordingTransport(answers: [.retry])
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today)))
        await engine.run(d.id)
        #expect(FileStore(root: root).artifacts(d.id).count == 1)
        await engine.remove(d.id)
        #expect(FileStore(root: root).artifacts(d.id).isEmpty)
        #expect(await engine.snapshot.pipelines.isEmpty)
    }

    @Test func aTestSendsTheEmptyShape() async throws {
        let transport = RecordingTransport()
        let engine = engine(transport: transport)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .today)))
        let answer = await engine.test(d.id)
        #expect(answer.verdict == .accepted)
        #expect(transport.texts == [#"{"data":{"metrics":[]}}"#])
    }

    @Test func aSkippedPartLeavesTheRestDeliverable() async throws {
        let run = WorkoutDetail(activityType: "Yoga", name: "Yoga", source: "Watch", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-6000), duration: 1200)
        let walk = WorkoutDetail(activityType: "Walking", name: "Walk", source: "Watch", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000), duration: 600, hasRoute: true)
        queries.add(run)
        queries.add(walk, route: [RoutePoint(timestamp: now.addingTimeInterval(-3600), latitude: 1, longitude: 2)])
        let transport = RecordingTransport()
        let engine = engine(transport: transport)
        let spec = ExtractSpec(sections: [.workouts], range: .today)
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: PipelineDefinition(extract: spec, template: .builtIn(BuiltInTemplates.workoutRoutesGPX), templateName: "GPX"))
        await engine.run(d.id)
        #expect(transport.parts.map(\.contentType) == ["application/gpx+xml"])
        #expect(transport.texts[0].contains("lat=\"1\""))
    }

    @Test func oldStateStillLoadsAsNativePipelines() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/state-0.1.json")
        let state = try JSONDecoder().decode(EngineState.self, from: Data(contentsOf: url))
        #expect(state.definitions == nil)
        #expect(state.cursors == nil)
    }

    @Test func aDefinitionSurvivesBeingSaved() async throws {
        let engine = engine(transport: RecordingTransport())
        let d = await engine.add(Destination(name: "Web", kind: .target(target)), token: nil, definition: definition(ExtractSpec(range: .previousDays(7), grouping: .hours, units: .imperial)))
        let reopened = self.engine(transport: RecordingTransport())
        let p = await reopened.snapshot.pipelines[0]
        #expect(p.id == d.id)
        #expect(p.extract.range == .previousDays(7))
        #expect(p.extract.units == .imperial)
        #expect(p.destination.kind == .target(target))
    }
}

@Suite struct WebTransportTests {
    private func context(_ spec: ExtractSpec = ExtractSpec()) -> TransportContext {
        TransportContext(pipelineID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, pipelineName: "Mine", extract: spec, token: "tok")
    }

    private let part = ArtifactPart(key: "all", filename: "a.json", file: "part-0", contentType: "application/json", bytes: 2)

    @Test func theRequestCarriesEverythingAsked() throws {
        let t = WebTransport(target: WebTarget(url: "https://example.com/x", method: .put, headers: [.init(name: "X-A", value: "b")], timeout: 5), context: context(ExtractSpec(range: .previousDays(7), grouping: .automatic)))
        let r = try #require(t.request(part: part, contentType: "application/json"))
        #expect(r.httpMethod == "PUT")
        #expect(r.timeoutInterval == 5)
        #expect(r.value(forHTTPHeaderField: "X-A") == "b")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "automation-name") == "Mine")
        #expect(r.value(forHTTPHeaderField: "automation-id") == "00000000-0000-4000-8000-000000000001")
        #expect(r.value(forHTTPHeaderField: "automation-aggregation") == "Default")
        #expect(r.value(forHTTPHeaderField: "automation-period") == "Previous7Days")
        #expect(r.value(forHTTPHeaderField: "session-id") != nil)
    }

    @Test func automationHeadersCanBeOff() throws {
        let t = WebTransport(target: WebTarget(url: "https://example.com/x", automationHeaders: false), context: context())
        #expect(t.request(part: part, contentType: "x")?.value(forHTTPHeaderField: "automation-name") == nil)
    }

    @Test func aPartsOwnAddressWins() {
        var p = part
        p.destination = "https://example.com/day/2026-10-24"
        let t = WebTransport(target: WebTarget(url: "https://example.com/day/{{ partition.key }}"), context: context())
        #expect(t.request(part: p, contentType: "x")?.url?.absoluteString == "https://example.com/day/2026-10-24")
    }

    @Test func onlyHTTPSchemesAreAllowed() {
        let t = WebTransport(target: WebTarget(url: "file:///etc/passwd"), context: context())
        #expect(t.request(part: part, contentType: "x") == nil)
    }

    @Test func multipartWrapsTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("in")
        try Data("hello".utf8).write(to: file)
        let out = dir.appendingPathComponent("out")
        try WebTransport.writeMultipart(file: file, field: "export", filename: "a\"b.json", contentType: "application/json", boundary: "B", to: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text == "--B\r\nContent-Disposition: form-data; name=\"export\"; filename=\"a'b.json\"\r\nContent-Type: application/json\r\n\r\nhello\r\n--B--\r\n")
    }
}

@Suite struct AddressTemplateTests {
    @Test func aTargetAddressRendersPerPart() async throws {
        let queries = FakeHealthQuerying(calendar: calendar)
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 1)
        let t = try ParsedTemplate(source: "---\nname: D\nformat: csv\npartition: day\n---\nx")
        let e = Extractor(store: queries, spec: ExtractSpec(grouping: .days), calendar: calendar, ranges: [T.day("2026-10-25").interval(in: calendar)])
        let run = try await TemplateTransformer(template: t).run(extractor: e, export: ExportInfo(device: FixtureTests.device, generatedAt: now, timeZone: vancouver)) { _, _ in MemorySink() }
        #expect(try await run.destination(0, "https://x.test/{{ partition.key }}") == "https://x.test/2026-10-25")
        #expect(try await run.destination(0, "https://x.test/plain") == "https://x.test/plain")
    }
}

/// A rich week across every section, in the fake store.
enum RichData {
    static func store() -> FakeHealthQuerying {
        let s = FakeHealthQuerying(calendar: calendar)
        let noon = T.date("2026-10-24 12:00:00 -0700")
        s.add("step_count", source: "Watch", at: noon, end: noon.addingTimeInterval(60), 100)
        s.add("step_count", source: "iPhone", at: noon, end: noon.addingTimeInterval(60), 50)
        s.add(MetricCatalog.metric(named: "heart_rate")!.identifiers[0], DetailedQuantity(source: "Watch", start: noon, end: noon.addingTimeInterval(60), value: 70, min: 60, max: 90, context: "Active"))
        s.add(MetricCatalog.metric(named: "heart_rate")!.identifiers[0], DetailedQuantity(source: "Watch", start: noon.addingTimeInterval(120), end: noon.addingTimeInterval(180), value: 75))
        s.add("heart_rate_variability", at: noon, end: noon.addingTimeInterval(60), 40)
        s.heartbeatSeries = [HeartbeatSeries(start: noon, end: noon.addingTimeInterval(60), beats: [.init(timeSinceStart: 1, precededByGap: false)])]
        s.add("weight_body_mass", source: "Scale", at: noon, 80)
        let sleep = MetricCatalog.metric(named: "sleep_analysis")!.identifiers[0]
        for (start, end, stage) in [("2026-10-23 23:00:00", "2026-10-24 01:00:00", 3), ("2026-10-24 01:00:00", "2026-10-24 02:00:00", 4), ("2026-10-24 02:00:00", "2026-10-24 06:00:00", 5)] {
            s.addCategory(sleep, DetailedCategory(source: "Watch", start: T.date(start + " -0700"), end: T.date(end + " -0700"), value: stage))
        }
        let fever = MetricCatalog.symptoms.first { $0.id.hasSuffix("Fever") }!
        s.addCategory(fever.id, DetailedCategory(source: "Health", start: noon, end: noon.addingTimeInterval(3600), value: 3, userEntered: true))
        let flow = MetricCatalog.cycleTracking.first { $0.id.hasSuffix("MenstrualFlow") }!
        s.addCategory(flow.id, DetailedCategory(source: "Health", start: noon, end: noon.addingTimeInterval(3600), value: 3, cycleStart: true))
        let high = MetricCatalog.notifications.first { $0.id.hasSuffix("HighHeartRateEvent") }!
        s.addCategory(high.id, DetailedCategory(source: "Watch", start: noon, end: noon.addingTimeInterval(600), value: 0))
        s.add(ECGDetail(source: "ECG", start: noon, end: noon.addingTimeInterval(30), classification: "Sinus Rhythm", samplingFrequency: 512, averageHeartRate: 61, numberOfVoltageMeasurements: 3))
        s.moods = [StateOfMindRecord(id: "m", source: "Health", start: noon, end: noon, kind: "Daily Mood", valence: 0.5, valenceClassification: "pleasant", labels: ["calm"], associations: ["health"])]
        s.doses = [MedicationDose(id: "d", name: "Vitamin", source: "Health", start: noon, end: noon, status: "Taken", quantity: 1, unit: "count")]

        let start = T.date("2026-10-24 17:00:00 -0700")
        let end = start.addingTimeInterval(1800)
        s.add("active_energy", source: "Watch", at: start, end: end, 300)
        s.add("basal_energy_burned", source: "Watch", at: start, end: end, 40)
        s.add("walking_running_distance", source: "Watch", at: start, end: end, 2.5)
        let run = WorkoutDetail(id: "11111111-1111-4111-8111-111111111111", activityType: "Running", activityTypeCode: 37, name: "Outdoor Run", source: "Watch", sourceIdentifier: "com.apple.health", start: start, end: end, duration: 1700, isIndoor: false,
                                statistics: ["activeEnergy": .init(unit: "kcal", sum: 300), "basalEnergy": .init(unit: "kcal", sum: 40), "heartRate": .init(unit: "count/min", avg: 150, min: 90, max: 170),
                                             "walkingAndRunningDistance": .init(unit: "km", sum: 2.5), "stepCount": .init(unit: "count", sum: 3000), "flightsClimbed": .init(unit: "count", sum: 2)],
                                activities: [.init(id: "33333333-3333-4333-8333-333333333333", activityType: "Running", activityTypeCode: 37, isIndoor: false, start: start, end: end, duration: 1700, statistics: ["activeEnergy": .init(unit: "kcal", sum: 300), "walkingAndRunningDistance": .init(unit: "km", sum: 2.5), "heartRate": .init(unit: "count/min", avg: 150, min: 90, max: 170)])],
                                events: [.init(type: "pause", typeCode: 1, start: start.addingTimeInterval(600), end: start.addingTimeInterval(600)),
                                         .init(type: "resume", typeCode: 2, start: start.addingTimeInterval(700), end: start.addingTimeInterval(700)),
                                         .init(type: "segment", typeCode: 7, start: start, end: start.addingTimeInterval(900))],
                                metadata: ["key": "value"], temperature: 12, humidity: 80, elevationAscended: 30, averageSpeed: 1.5, maximumSpeed: 3, averageMETs: 8, estimatedEffort: 6, hasRoute: true)
        s.add(run, route: [RoutePoint(timestamp: start, latitude: 49.28, longitude: -123.12, altitude: 10, course: 90, courseAccuracy: 1, horizontalAccuracy: 3, verticalAccuracy: 4, speed: 2.5, speedAccuracy: 0.5)])
        s.add(WorkoutDetail(id: "22222222-2222-4222-8222-222222222222", activityType: "Yoga", name: "Yoga", source: "Watch", start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000), duration: 1800))
        return s
    }

    static let week = DateInterval(start: T.day("2026-10-20").start(in: calendar), end: T.day("2026-10-27").start(in: calendar))
    static let all = ExtractSpec(sections: Set(ExtractSpec.Section.allCases), range: .fixed(week), grouping: .days)
    static let export = ExportInfo(device: FixtureTests.device, generatedAt: now, timeZone: vancouver)

    /// Renders a built-in, returning each part's name and text.
    static func render(_ id: String, spec: ExtractSpec = all) async throws -> [(name: String, text: String)] {
        let e = Extractor(store: store(), spec: spec, calendar: calendar, ranges: [week])
        var sinks: [String: MemorySink] = [:]
        let run = try await TemplateTransformer(template: BuiltInTemplates.template(id)).run(extractor: e, export: export) { _, name in
            let sink = MemorySink()
            sinks[name] = sink
            return sink
        }
        return run.parts.map { ($0.filename, sinks[$0.filename]!.string) }
    }
}

@Suite struct BuiltInFormatTests {
    private func json(_ text: String) throws -> JSON { try #require(JSON.parse(Data(text.utf8))) }

    @Test func jsonHasEverySectionWithData() async throws {
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2)
        let data = try json(parts[0].text)["data"]
        for key in ["metrics", "workouts", "symptoms", "ecg", "heartRateNotifications", "stateOfMind", "cycleTracking", "medications"] {
            #expect(data?[key] != nil, "\(key)")
        }
    }

    @Test func aSectionWithNoDataIsLeftOutButMetricsAlwaysStays() async throws {
        var spec = RichData.all
        spec.sections = [.medications]
        let store = FakeHealthQuerying(calendar: calendar)
        let e = Extractor(store: store, spec: spec, calendar: calendar, ranges: [RichData.week])
        let sink = MemorySink()
        _ = try await TemplateTransformer(template: BuiltInTemplates.template(BuiltInTemplates.metricsJSONv2)).run(extractor: e, export: RichData.export) { _, _ in sink }
        #expect(sink.string == #"{"data":{"metrics":[]}}"#)
    }

    @Test func aWorkoutHasItsWholeShape() async throws {
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2)
        guard case .array(let workouts)? = try json(parts[0].text)["data"]?["workouts"], let w = workouts.first else {
            Issue.record("no workouts")
            return
        }
        for key in ["activeEnergy", "activeEnergyBurned", "activities", "avgHeartRate", "avgSpeed", "basalEnergy", "distance", "duration", "elevationUp", "end", "estimatedEffortScore", "events",
                    "flightsClimbed", "heartRate", "heartRateData", "heartRateRecovery", "humidity", "id", "intensity", "isIndoor", "location", "maxHeartRate", "maxSpeed", "metadata", "name", "route",
                    "segments", "source", "speed", "splits", "start", "stepCadence", "temperature", "totalEnergy", "walkingAndRunningDistance"] {
            #expect(w[key] != nil, "\(key)")
        }
        #expect(w["totalEnergy"]?["qty"] == .number(340))
        #expect(w["distance"]?["units"] == "km")
        #expect(w["speed"]?["qty"] != nil)
        #expect(w["heartRate"]?["max"]?["qty"] == .number(170))
        #expect(w["location"] == "Outdoor")
        #expect(w["source"]?["identifier"] == "com.apple.health")
    }

    @Test func aSimpleWorkoutLeavesOutWhatItDoesntHave() async throws {
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2)
        guard case .array(let workouts)? = try json(parts[0].text)["data"]?["workouts"] else {
            Issue.record("no workouts")
            return
        }
        let yoga = workouts[1]
        #expect(yoga["name"] == "Yoga")
        for key in ["route", "distance", "splits", "segments", "isIndoor"] { #expect(yoga[key] == nil, "\(key)") }
    }

    @Test func unitsAreChosenInWorkoutsToo() async throws {
        var spec = RichData.all
        spec.units = UnitPreferences(byDimension: [.distance: "mi", .energy: "kJ", .speed: "mi/hr", .temperature: "degF"])
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2, spec: spec)
        guard case .array(let workouts)? = try json(parts[0].text)["data"]?["workouts"], let w = workouts.first else { return }
        #expect(w["distance"]?["units"] == "mi")
        #expect(w["activeEnergyBurned"]?["units"] == "kJ")
        #expect(w["activeEnergyBurned"]?["qty"] == .number(300 * 4.184))
        #expect(w["temperature"]?["qty"] == .number(53.6))
        #expect(w["avgSpeed"]?["units"] == "mi/hr")
    }

    @Test func aSeriesCanBeLeftOut() async throws {
        var spec = RichData.all
        spec.workouts.series = false
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2, spec: spec)
        guard case .array(let workouts)? = try json(parts[0].text)["data"]?["workouts"], let w = workouts.first else { return }
        #expect(w["heartRateData"] == nil)
        #expect(w["activeEnergy"] == nil)
    }

    @Test func unsummarizedPointsHaveTheirLongForms() async throws {
        var spec = RichData.all
        spec.grouping = nil
        spec.sections = [.metrics]
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2, spec: spec)
        #expect(parts[0].text.contains("\"context\":\"Active\""))
        #expect(parts[0].text.contains("\"heartbeatSeries\":["))
        #expect(parts[0].text.contains("\"startDate\":"))
        #expect(parts[0].text.contains("\"value\":\"REM\""))
    }

    @Test func aRunningTotalsSamplesStayShortInJSON() async throws {
        var spec = RichData.all
        spec.grouping = nil
        spec.sections = [.metrics]
        spec.metrics = .only(["step_count"])
        let parts = try await RichData.render(BuiltInTemplates.metricsJSONv2, spec: spec)
        #expect(parts[0].text.contains(#"{"date":"2026-10-24 12:00:00 -0700","qty":100,"source":"Watch"}"#))
    }

    @Test func aTemplateCanStillAskForACompactPointsBounds() async throws {
        let store = RichData.store()
        let spec = ExtractSpec(metrics: .only(["step_count"]), range: .fixed(RichData.week), grouping: nil)
        let e = Extractor(store: store, spec: spec, calendar: calendar, ranges: [RichData.week])
        let sink = MemorySink()
        let t = try ParsedTemplate(source: "---\nname: n\n---\n{% for p in metrics.step_count.data limit:1 %}{{ p.end | date: '%H:%M' }}{% endfor %}")
        _ = try await TemplateTransformer(template: t).run(extractor: e, export: RichData.export) { _, _ in sink }
        #expect(sink.string == "12:01")
    }

    @Test func gpxMakesOneFilePerRoute() async throws {
        let parts = try await RichData.render(BuiltInTemplates.workoutRoutesGPX)
        #expect(parts.count == 1)
        #expect(parts[0].name == "Outdoor Run-Route-2026-10-24_17-00-00.gpx")
        let t = parts[0].text
        #expect(t.contains(#"<trkpt lat="49.28" lon="-123.12">"#))
        #expect(t.contains("<ele>10</ele>"))
        #expect(t.contains("<speed>2.5</speed>"))
        #expect(t.contains("<hAcc>3</hAcc>"))
        #expect(t.contains("<time>2026-10-25T00:00:00.000Z</time>"))
    }

    @Test func markdownHasOneFilePerSection() async throws {
        var spec = RichData.all
        spec.sections = [.metrics, .workouts]
        let parts = try await RichData.render(BuiltInTemplates.healthReportMarkdown, spec: spec)
        #expect(parts.map(\.name) == ["HealthMetrics-2026-10-20-2026-10-27.md", "Workouts-2026-10-20-2026-10-27.md"])
        let metrics = parts[0].text
        #expect(metrics.hasPrefix("---\ntags:\n  - health-data-relay\n"))
        #expect(metrics.contains("health_data_type: healthMetrics"))
        #expect(metrics.contains("# Health Metrics"))
        #expect(metrics.contains("## step_count"))
        #expect(metrics.contains("### Summary"))
        #expect(metrics.contains("| date | qty | source |"))
        #expect(metrics.contains("| Avg | Max | Min | date |"))
        #expect(metrics.contains("| asleep | awake | core | date |"))
        #expect(metrics.contains("| 2026-10-24T07:00:00.000Z | 150 | Watch\\|iPhone |"))
        let workouts = parts[1].text
        #expect(workouts.contains("## Outdoor Run"))
        #expect(workouts.contains("\n### Summary\n"))
        #expect(workouts.contains("\n### Active Energy Burned\n\n#### Summary\n\n| Field | Value |\n|---|---|\n| qty | 300 |\n| units | kcal |"))
        #expect(workouts.contains("\n#### Avg\n\n##### Summary\n"))
        #expect(workouts.contains("\n### Route\n\n```csv\naltitude,course,courseAccuracy,horizontalAccuracy,latitude,longitude,speed,speedAccuracy,timestamp,verticalAccuracy\n10,90,1,3,49.28,-123.12,2.5,0.5,2026-10-25T00:00:00.000Z,4\n```"))
        #expect(workouts.contains("\n#### 2026-10-25T00:00:00.000Z\n\n##### Summary\n"))
        #expect(workouts.contains("\n###### Summary\n"))
    }

    @Test func splitsLandOnEachMark() {
        let start = T.date("2026-10-24 12:00:00 -0700")
        let samples = [DetailedQuantity(source: "Watch", start: start, end: start.addingTimeInterval(500), value: 2500)]
        let marks = WorkoutSplits.marks(samples, every: 1000, workoutStart: start, workoutEnd: start.addingTimeInterval(500))
        #expect(marks.count == 3)
        #expect(marks[0].end == start.addingTimeInterval(200))
        #expect(marks[1].end == start.addingTimeInterval(400))
        #expect(!marks[0].isPartial)
        #expect(marks[2].isPartial)
        #expect(marks[2].end == start.addingTimeInterval(500))
    }

    @Test func dumpForTheStructureComparer() async throws {
        // HDR_DUMP=<dir>: writes output in the layout tools/hae/compare.mjs reads.
        guard let dir = ProcessInfo.processInfo.environment["HDR_DUMP"] else { return }
        let manager = FileManager.default
        func write(_ row: String, _ parts: [(name: String, text: String)]) throws {
            let folder = URL(fileURLWithPath: dir).appendingPathComponent(row).appendingPathComponent("files")
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for p in parts { try p.text.write(to: folder.appendingPathComponent(p.name), atomically: true, encoding: .utf8) }
        }
        try write("summarized", try await RichData.render(BuiltInTemplates.metricsJSONv2))
        var raw = RichData.all
        raw.grouping = nil
        try write("unsummarized", try await RichData.render(BuiltInTemplates.metricsJSONv2, spec: raw))
        try write("gpx", try await RichData.render(BuiltInTemplates.workoutRoutesGPX))
        var md = RichData.all
        md.sections = [.metrics, .workouts]
        try write("markdown", try await RichData.render(BuiltInTemplates.healthReportMarkdown, spec: md))
    }
}
