import Foundation
import Network
import Testing
@testable import HealthDataRelayKit

/// A minimal broker on a local port, so publishing is tested over a real socket.
final class FakeBroker: @unchecked Sendable {
    struct Message: Equatable {
        var topic: String
        var payload: Data
        var qos: Int
        var retain: Bool
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-broker")
    private let lock = NSLock()
    private var buffers: [ObjectIdentifier: Data] = [:]
    private(set) var messages: [Message] = []
    private(set) var connects: [Data] = []
    var refuseWith: UInt8 = 0
    var neverAcknowledge = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: self?.queue ?? .main)
            self?.read(c)
        }
    }

    func start() async -> Int {
        await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            let once = NSLock()
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state {
                    once.withLock {
                        if !done {
                            done = true
                            c.resume(returning: Int(listener.port?.rawValue ?? 0))
                        }
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.feed(data, c) }
            if !done && error == nil { self.read(c) }
        }
    }

    private func feed(_ data: Data, _ c: NWConnection) {
        lock.lock()
        let id = ObjectIdentifier(c)
        buffers[id, default: Data()].append(data)
        var buf = Data(buffers[id]!)
        var replies: [Data] = []
        while buf.count >= 2 {
            var length = 0
            var shift = 0
            var at = 1
            var complete = false
            while at < buf.count {
                let b = buf[buf.startIndex + at]
                length |= Int(b & 0x7F) << shift
                at += 1
                if b & 0x80 == 0 {
                    complete = true
                    break
                }
                shift += 7
            }
            guard complete, buf.count >= at + length else { break }
            let first = buf[buf.startIndex]
            let body = Data(buf[(buf.startIndex + at)..<(buf.startIndex + at + length)])
            buf = Data(buf.dropFirst(at + length))
            switch first & 0xF0 {
            case 0x10:
                connects.append(body)
                replies.append(Data([0x20, 2, 0, refuseWith]))
            case 0x30:
                let qos = Int((first >> 1) & 3)
                let topicLength = Int(body[0]) << 8 | Int(body[1])
                let topic = String(decoding: body[2..<(2 + topicLength)], as: UTF8.self)
                var offset = 2 + topicLength
                var idBytes = Data()
                if qos > 0 {
                    idBytes = Data(body[offset..<(offset + 2)])
                    offset += 2
                }
                messages.append(Message(topic: topic, payload: Data(body[offset...]), qos: qos, retain: first & 1 == 1))
                if !neverAcknowledge {
                    if qos == 1 { replies.append(Data([0x40, 2]) + idBytes) }
                    if qos == 2 { replies.append(Data([0x50, 2]) + idBytes) }
                }
            case 0x60:
                replies.append(Data([0x70, 2]) + body)
            default:
                break
            }
        }
        buffers[id] = buf
        lock.unlock()
        for r in replies { c.send(content: r, completion: .idempotent) }
    }
}

@Suite struct MQTTPacketTests {
    @Test func lengthsUseMQTTsEncoding() {
        #expect(MQTTPacket.remainingLength(0) == Data([0]))
        #expect(MQTTPacket.remainingLength(127) == Data([0x7F]))
        #expect(MQTTPacket.remainingLength(128) == Data([0x80, 0x01]))
        #expect(MQTTPacket.remainingLength(16383) == Data([0xFF, 0x7F]))
        #expect(MQTTPacket.remainingLength(16384) == Data([0x80, 0x80, 0x01]))
    }

    @Test func aPublishIsExact() {
        let p = MQTTPacket.publish(topic: "a/b", payload: Data("hi".utf8), qos: 1, retain: true, packetID: 7)
        #expect(p == Data([0x33, 9, 0, 3]) + Data("a/b".utf8) + Data([0, 7]) + Data("hi".utf8))
    }

    @Test func aConnectCarriesItsCredentials() {
        let c = MQTTPacket.connect(clientID: "id", username: "u", password: "p")
        #expect(c[0] == 0x10)
        // Clean session, username and password.
        #expect(c[9] == 0xC2)
        #expect(c.suffix(3) == Data([0, 1]) + Data("p".utf8))
        #expect(MQTTPacket.connect(clientID: "id", username: "", password: "ignored")[9] == 0x02)
    }

    @Test func topicsAreChecked() {
        #expect(MQTTPacket.topicIsValid("health/steps"))
        for bad in ["", "a/+/b", "a/#"] { #expect(!MQTTPacket.topicIsValid(bad)) }
    }

    @Test func refusalsMeanTheRightThing() {
        #expect(MQTTPacket.connectVerdict(4).verdict == .authFailed)
        #expect(MQTTPacket.connectVerdict(5).verdict == .authFailed)
        #expect(MQTTPacket.connectVerdict(3).verdict == .retry)
        #expect(MQTTPacket.connectVerdict(2).verdict == .rejected)
    }
}

@Suite(.serialized) struct MQTTTransportTests {
    private func transport(_ port: Int, qos: Int = 1, retain: Bool = false, password: String? = nil) -> MQTTTransport {
        MQTTTransport(target: MQTTTarget(host: "127.0.0.1", port: port, topic: "t", username: password == nil ? "" : "me", qos: qos, retain: retain), password: password)
    }

    @Test(arguments: [0, 1, 2]) func publishesAtEachQoS(qos: Int) async throws {
        let broker = try FakeBroker()
        let port = await broker.start()
        defer { broker.stop() }
        let d = await transport(port, qos: qos, retain: true).publish(topic: "health/steps", payload: Data("42".utf8))
        #expect(d.verdict == .accepted, "\(d.message)")
        try await Task.sleep(for: .milliseconds(100))
        #expect(broker.messages == [.init(topic: "health/steps", payload: Data("42".utf8), qos: qos, retain: true)])
    }

    @Test func aLargeMessageGoesThrough() async throws {
        let broker = try FakeBroker()
        let port = await broker.start()
        defer { broker.stop() }
        let payload = Data(repeating: 7, count: 300_000)
        let d = await transport(port).publish(topic: "big", payload: payload)
        #expect(d.verdict == .accepted, "\(d.message)")
        #expect(broker.messages.first?.payload == payload)
    }

    @Test func aRefusedPasswordStopsThePipeline() async throws {
        let broker = try FakeBroker()
        broker.refuseWith = 5
        let port = await broker.start()
        defer { broker.stop() }
        let d = await transport(port, password: "wrong").publish(topic: "t", payload: Data())
        #expect(d.verdict == .authFailed)
        #expect(broker.messages.isEmpty)
    }

    @Test func noBrokerIsARetry() async {
        let d = await transport(1).publish(topic: "t", payload: Data())
        #expect(d.verdict == .retry)
    }

    @Test func aBrokerThatNeverConfirmsTimesOut() async throws {
        let broker = try FakeBroker()
        broker.neverAcknowledge = true
        let port = await broker.start()
        defer { broker.stop() }
        var t = transport(port)
        t.timeout = .milliseconds(300)
        let d = await t.publish(topic: "t", payload: Data("x".utf8))
        #expect(d.verdict == .retry)
    }

    @Test func aBadTopicIsRefusedBeforeConnecting() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let part = ArtifactPart(key: "k", filename: "f", file: "f", contentType: "x", bytes: 1, destination: "a/#")
        let d = await transport(1).deliver(part: part, file: file, artifact: Artifact(createdAt: Date(), days: [], rows: 0, parts: [part]))
        #expect(d.verdict == .rejected)
    }

    /// A real run: one message per metric, each on its own topic.
    @Test func aPipelinePublishesAPartPerMetric() async throws {
        let broker = try FakeBroker()
        let port = await broker.start()
        defer { broker.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cal = Calendar.local(T.vancouver)
        let now = T.date("2026-10-25 12:00:00 -0700")
        let queries = FakeHealthQuerying(calendar: cal)
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 10)
        queries.add("weight_body_mass", at: T.date("2026-10-25 08:00:00 -0700"), 80)
        let engine = Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: MemoryTokenStore(), device: { Device(name: $0, model: "m", os: "o", app: "a") },
                                  calendar: { cal }, now: { now }, pause: { _ in }, queries: queries,
                                  templateSource: { _ in "---\nname: M\nformat: json\npartition: metric\nskip_empty: true\n---\n{% assign m = metrics[partition.metric] %}{% for p in m.data %}{{ p.qty }}{% endfor %}" }))
        let target = LoadTarget.mqtt(MQTTTarget(host: "127.0.0.1", port: port, topic: "health/{{ partition.key }}"))
        let d = await engine.add(Destination(name: "Broker", kind: .target(target)), token: nil,
                                 definition: PipelineDefinition(extract: ExtractSpec(range: .today, grouping: .days), template: .builtIn("x"), templateName: "M"))
        await engine.run(d.id)
        try await Task.sleep(for: .milliseconds(100))
        let got = Dictionary(broker.messages.map { ($0.topic, String(decoding: $0.payload, as: UTF8.self)) }) { a, _ in a }
        #expect(got == ["health/step_count": "10", "health/weight_body_mass": "80"])
        #expect(await engine.snapshot.pipelines[0].destinationSummary == "127.0.0.1")
    }
}

/// HDR_MQTT_HOST=<host> HDR_MQTT_PORT=<port>: against a real broker, run with
/// `docker run -p 1883:1883 eclipse-mosquitto`. tools/mqtt-check.sh does it all.
@Suite struct RealBrokerTests {
    @Test func publishesToARealBroker() async throws {
        guard let host = ProcessInfo.processInfo.environment["HDR_MQTT_HOST"] else { return }
        let port = Int(ProcessInfo.processInfo.environment["HDR_MQTT_PORT"] ?? "") ?? 1883
        for qos in 0...2 {
            let t = MQTTTransport(target: MQTTTarget(host: host, port: port, topic: "t", qos: qos, retain: true), password: nil)
            let d = await t.publish(topic: "hdr/check/\(qos)", payload: Data("qos \(qos)".utf8))
            #expect(d.verdict == .accepted, "\(d.message)")
        }
    }
}

final class FakeCalendar: CalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String: CalendarEvent] = [:]
    private var next = 0
    var allowed = true

    func requestAccess() async throws -> Bool { allowed }

    func save(_ event: CalendarEvent, existing: String?, calendarID: String?) async throws -> String {
        lock.withLock {
            if let existing, events[existing] != nil {
                events[existing] = event
                return existing
            }
            next += 1
            let id = "event-\(next)"
            events[id] = event
            return id
        }
    }

    func deleteAll() {
        lock.withLock { events = [:] }
    }
}

@Suite struct CalendarTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let cal = Calendar.local(T.vancouver)
    private let now = T.date("2026-10-25 12:00:00 -0700")

    private func engine(_ calendars: CalendarStore, queries: HealthQuerying) -> Engine {
        let (cal, now) = (cal, now)
        return Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: MemoryTokenStore(), device: { Device(name: $0, model: "m", os: "o", app: "a") },
                            calendar: { cal }, now: { now }, pause: { _ in }, queries: queries, calendars: calendars))
    }

    private func pipeline(_ engine: Engine) async -> UUID {
        await engine.add(Destination(name: "Workouts", kind: .target(.calendar(CalendarTarget(calendarID: nil, calendarName: "Home")))), token: nil,
                         definition: PipelineDefinition(extract: ExtractSpec(sections: [.workouts], range: .previousDays(7), grouping: .days), template: .builtIn(BuiltInTemplates.workoutsCalendar), templateName: "W")).id
    }

    private func store() -> FakeHealthQuerying {
        let s = FakeHealthQuerying(calendar: cal)
        let start = T.date("2026-10-24 09:00:00 -0700")
        s.add(WorkoutDetail(id: "w1", activityType: "Running", name: "Outdoor Run", source: "Watch", start: start, end: start.addingTimeInterval(1800), duration: 1800, isIndoor: false,
                            statistics: ["walkingAndRunningDistance": .init(unit: "km", sum: 5), "activeEnergy": .init(unit: "kcal", sum: 300)]))
        return s
    }

    @Test func aWorkoutBecomesAnEvent() async throws {
        let calendar = FakeCalendar()
        let engine = engine(calendar, queries: store())
        await engine.run(await pipeline(engine))
        let event = try #require(calendar.events.values.first)
        #expect(event.title == "Outdoor Run")
        #expect(event.key == "w1")
        #expect(event.start == T.date("2026-10-24 09:00:00 -0700"))
        #expect(event.end == T.date("2026-10-24 09:30:00 -0700"))
        #expect(event.notes == "30 minutes, 5 km, 300 kcal")
        #expect(event.location == "Outdoor")
    }

    @Test func runningAgainCreatesNoDuplicates() async throws {
        let calendar = FakeCalendar()
        let engine = engine(calendar, queries: store())
        let id = await pipeline(engine)
        await engine.run(id)
        await engine.run(id)
        await engine.run(id)
        #expect(calendar.events.count == 1)
    }

    @Test func anEventDeletedByTheUserIsMadeAgain() async throws {
        let calendar = FakeCalendar()
        let engine = engine(calendar, queries: store())
        let id = await pipeline(engine)
        await engine.run(id)
        calendar.deleteAll()
        await engine.run(id)
        #expect(calendar.events.count == 1)
    }

    @Test func noCalendarAccessNeedsAttention() async throws {
        let calendar = FakeCalendar()
        calendar.allowed = false
        let engine = engine(calendar, queries: store())
        await engine.run(await pipeline(engine))
        #expect(await engine.snapshot.pipelines[0].lane.attention?.contains("Calendar access") == true)
    }

    @Test func aBadEventIsRefusedWithAReason() {
        #expect(throws: TemplateError.self) { try CalendarEvent.parse(Data("{\"events\":[{\"title\":\"no key\"}]}".utf8)) }
        #expect(throws: TemplateError.self) { try CalendarEvent.parse(Data("[]".utf8)) }
    }

    @Test func anEventsEndNeverComesBeforeItsStart() throws {
        let out = try CalendarEvent.parse(Data(#"{"events":[{"key":"k","title":"t","start":"2026-10-24 09:00:00 -0700","end":"2026-10-24 08:00:00 -0700","allDay":true}]}"#.utf8))
        #expect(out[0].end == out[0].start)
        #expect(out[0].allDay)
    }
}

@Suite struct HomeAssistantTests {
    private let cal = Calendar.local(T.vancouver)

    @Test func eachMetricBecomesASensor() async throws {
        let queries = FakeHealthQuerying(calendar: cal)
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 10)
        queries.add("heart_rate", at: T.date("2026-10-25 09:00:00 -0700"), 60)
        let range = T.day("2026-10-25").interval(in: cal)
        let spec = ExtractSpec(metrics: .only(["step_count", "heart_rate", "weight_body_mass"]), range: .today, grouping: .days)
        let e = Extractor(store: queries, spec: spec, calendar: cal, ranges: [range])
        var sinks: [MemorySink] = []
        let run = try await TemplateTransformer(template: BuiltInTemplates.template(BuiltInTemplates.homeAssistantStates)).run(extractor: e, export: RichData.export) { _, _ in
            let sink = MemorySink()
            sinks.append(sink)
            return sink
        }
        // A metric with no data makes no request.
        #expect(run.parts.map(\.key) == ["step_count", "heart_rate"])
        let steps = sinks[run.parts[0].index].string
        #expect(steps.contains(#""state":10"#))
        #expect(steps.contains(#""friendly_name":"Steps""#))
        #expect(steps.contains(#""unit_of_measurement":"count""#))
        #expect(try await run.destination(0, "http://ha.local:8123/api/states/sensor.health_{{ partition.key }}") == "http://ha.local:8123/api/states/sensor.health_step_count")
        let heart = sinks[run.parts[1].index].string
        #expect(heart.contains(#""state":60"#))
    }

    @Test func thePresetFillsInItsDestination() {
        let preset = PipelinePreset.all().first { $0.template == BuiltInTemplates.homeAssistantStates }
        guard case .web(let web)? = preset?.target else {
            Issue.record("no target")
            return
        }
        #expect(web.url.contains("/api/states/sensor.health_{{ partition.key }}"))
        #expect(!web.automationHeaders)
    }
}
