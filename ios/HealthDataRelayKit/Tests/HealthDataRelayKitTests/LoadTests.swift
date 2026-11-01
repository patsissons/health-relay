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
