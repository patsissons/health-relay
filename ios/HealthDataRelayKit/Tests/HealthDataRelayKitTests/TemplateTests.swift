import Foundation
import Testing
@testable import HealthDataRelayKit

private let vancouver = T.vancouver
private let calendar = Calendar.local(vancouver)

/// A body with no header, rendered in a format over JSON data.
private func render(_ source: String, format: OutputFormat = .text, data: JSON = .object([:]), timeZone: TimeZone = vancouver, limits: TemplateLimits = TemplateLimits()) async throws -> String {
    let body = try TemplateParser.parse(source)
    var globals: [String: TemplateValue] = [:]
    if case .object(let fields) = data { globals = fields.mapValues(TemplateValue.init(json:)) }
    let sink = MemorySink()
    try await TemplateRenderer(format: format, timeZone: timeZone, globals: globals, sink: sink, limits: limits).run(body)
    return sink.string
}

@Suite struct TemplateConformanceTests {
    /// The cases liquidjs passes too: tools/conformance runs the same file.
    @Test func agreesWithLiquid() async throws {
        let url = FixtureTests.fixtures.appendingPathComponent("templates/conformance.json")
        let file = try #require(JSON.parse(Data(contentsOf: url)))
        guard case .array(let cases)? = file["cases"] else {
            Issue.record("no cases")
            return
        }
        #expect(cases.count > 50)
        for c in cases {
            let source = try #require(c["t"]?.stringValue)
            let want = try #require(c["want"]?.stringValue)
            var zone = TimeZone(identifier: "UTC")!
            if case .number(let minutes)? = c["tz"] { zone = TimeZone(secondsFromGMT: Int(minutes) * 60)! }
            do {
                var got = try await render(source, data: c["data"] ?? .object([:]), timeZone: zone)
                var expected = want
                if case .bool(true)? = c["skipSpaces"] {
                    got = got.filter { !$0.isWhitespace }
                    expected = want.filter { !$0.isWhitespace }
                }
                #expect(got == expected, "\(source)")
            } catch {
                Issue.record("\(source): \(error)")
            }
        }
    }
}

@Suite struct TemplateTwinTests {
    /// The shipped template writes the native push byte for byte: the same
    /// data, encoded by the engine rather than by Push.
    @Test func theBuiltInMatchesTheFixture() async throws {
        let days = [T.day("2026-10-24"), T.day("2026-10-25")]
        let read = try await DayReader(store: FixtureTests.store(), calendar: calendar).read(days)
        let push = Push(device: FixtureTests.device, exportedAt: T.date("2026-10-25 07:00:00 -0700"), timeZone: vancouver, days: days, content: .merging(days.map { read[$0]! }))
        let template = try BuiltInTemplates.template(BuiltInTemplates.healthDataRelay)
        #expect(template.header.format == .json)
        let store = FakeHealthQuerying(calendar: calendar)
        let extractor = Extractor(store: store, spec: ExtractSpec(), calendar: calendar, ranges: [])
        let sink = MemorySink()
        let parts = try await TemplateTransformer(template: template).run(
            extractor: extractor, export: ExportInfo(device: FixtureTests.device, generatedAt: push.exportedAt, timeZone: vancouver), push: push.json) { _, _ in sink }
        let want = try String(contentsOf: FixtureTests.fixtures.appendingPathComponent("push-two-days.json"), encoding: .utf8)
        if sink.string != want {
            let prefix = zip(sink.string, want).prefix { $0 == $1 }.count
            Issue.record("differs at \(prefix): got …\(sink.string.dropFirst(max(0, prefix - 80)).prefix(200))… want …\(want.dropFirst(max(0, prefix - 80)).prefix(200))…")
        }
        #expect(parts.parts[0].bytes == want.utf8.count)
    }
}

@Suite struct TemplateFormatTests {
    @Test func jsonValuesAreAlwaysValid() async throws {
        let data: JSON = ["s": "a\"b\n", "n": 1.5, "o": ["k": 1], "l": [1, 2], "z": .null, "b": .bool(true)]
        #expect(try await render("{{ s }}", format: .json, data: data) == "\"a\\\"b\\n\"")
        #expect(try await render("[{{ n }},{{ o }},{{ l }},{{ z }},{{ b }},{{ missing }}]", format: .json, data: data) == "[1.5,{\"k\":1},[1,2],null,true,null]")
    }

    @Test func rawOptsOutInsideItsOwnQuotes() async throws {
        #expect(try await render("\"id-{{ a | raw }}\"", format: .json, data: ["a": "x"]) == "\"id-x\"")
    }

    @Test func csvQuotesFieldsThatNeedIt() async throws {
        let data: JSON = ["a": "x,y", "b": "say \"hi\"", "c": "plain", "n": 2]
        #expect(try await render("{{ a }},{{ b }},{{ c }},{{ n }}", format: .csv, data: data) == "\"x,y\",\"say \"\"hi\"\"\",plain,2")
    }

    @Test func csvNeutralizesFormulas() async throws {
        #expect(try await render("{{ a }}", format: .csv, data: ["a": "=SUM(A1)"]) == "\"'=SUM(A1)\"")
        // A negative number is data, not a formula.
        #expect(try await render("{{ n }}", format: .csv, data: ["n": -2]) == "-2")
    }

    @Test func markupIsEscaped() async throws {
        #expect(try await render("<p>{{ a }}</p>", format: .html, data: ["a": "<b>&'\""]) == "<p>&lt;b&gt;&amp;&#39;&quot;</p>")
        #expect(try await render("<a>{{ a }}</a>", format: .xml, data: ["a": "1<2"]) == "<a>1&lt;2</a>")
        #expect(try await render("<p>{{ a | raw }}</p>", format: .html, data: ["a": "<b>"]) == "<p><b></p>")
        #expect(try await render("<p>{{ a | escape }}</p>", format: .html, data: ["a": "<b>"]) == "<p>&lt;b&gt;</p>")
    }

    @Test func markdownKeepsATableIntact() async throws {
        #expect(try await render("| {{ a }} |", format: .markdown, data: ["a": "x|y\nz"]) == "| x\\|y z |")
    }

    @Test func aCaptureIsEscapedOnlyWhenWritten() async throws {
        let data: JSON = ["a": "x\"y", "b": "<b>"]
        #expect(try await render("{% capture c %}{{ a }}!{% endcapture %}{{ c }}", format: .json, data: data) == #""x\"y!""#)
        #expect(try await render("{% capture c %}{{ b }}{% endcapture %}{{ c }}", format: .html, data: data) == "&lt;b&gt;")
    }

    @Test func invalidJSONFailsTheRun() async throws {
        for bad in ["{\"a\":1,}", "[1 2]", "{\"a\" 1}", "01", "{", "tru", "\"unterminated", "{\"a\":1}x", ""] {
            await #expect(throws: TemplateError.self, "\(bad)") { _ = try await render(bad, format: .json) }
        }
        for good in ["{\"a\":[1,2.5e3,{\"b\":null}]}", " [ ] ", "\"s\\u00e9\"", "-0.5", "true"] {
            #expect(try await render(good, format: .json) == good)
        }
    }

    @Test func invalidXMLFailsTheRun() async throws {
        for bad in ["<a><b></a></b>", "<a>", "text", "<a attr=\"1>", "<a></b>"] {
            await #expect(throws: TemplateError.self, "\(bad)") { _ = try await render(bad, format: .xml) }
        }
        for good in ["<?xml version=\"1.0\"?><a x=\"1\"><b/>text<!-- c --></a>", "<gpx><trk/></gpx>"] {
            #expect(try await render(good, format: .gpx) == good)
        }
    }

    @Test func aFileStreamsWhatItsGiven() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try FileSink(url: url)
        let body = try TemplateParser.parse("{% for i in (1..50000) %}0123456789{% endfor %}")
        try await TemplateRenderer(format: .text, timeZone: vancouver, globals: [:], sink: sink, limits: TemplateLimits()).run(body)
        try sink.close()
        #expect(try Data(contentsOf: url).count == 500_000)
    }
}

@Suite struct TemplateErrorTests {
    private func parseError(_ source: String) -> TemplateError? {
        do {
            _ = try TemplateParser.parse(source)
            return nil
        } catch {
            return error as? TemplateError
        }
    }

    @Test func errorsSayWhere() {
        let e = parseError("line one\nline two {{ a | nope }}")
        #expect(e?.line == 2)
        #expect(e?.column == 10)
        #expect(e?.description.contains("nope") == true)
    }

    @Test func unclosedThingsAreFound() {
        #expect(parseError("{{ a")?.message.contains("never closed") == true)
        #expect(parseError("{% if a %}")?.message.contains("never closed") == true)
        #expect(parseError("{% for x in y %}")?.message.contains("never closed") == true)
        #expect(parseError("{% endif %}") != nil)
        #expect(parseError("{% raw %}") != nil)
    }

    @Test func nothingCanReachOutside() {
        #expect(parseError("{% include 'x' %}")?.message.contains("can't include") == true)
        #expect(parseError("{% render 'x' %}") != nil)
        #expect(parseError("{% nonsense %}")?.message.contains("Unknown tag") == true)
    }

    @Test func runtimeErrorsSayTheLine() async {
        do {
            _ = try await render("a\n{{ 1 | divided_by: 0 }}")
            Issue.record("should fail")
        } catch {
            #expect((error as? TemplateError)?.line == 2)
        }
    }

    @Test func aHeaderCountsTowardLines() {
        do {
            _ = try ParsedTemplate(source: "---\nname: x\nformat: text\n---\nfine\n{{ a | nope }}")
            Issue.record("should fail")
        } catch {
            #expect((error as? TemplateError)?.line == 6)
        }
    }

    @Test func limitsStopARunawayTemplate() async {
        await #expect(throws: TemplateError.self) {
            _ = try await render("{% for i in (1..100000) %}x{% endfor %}", limits: TemplateLimits(outputBytes: 1000))
        }
        await #expect(throws: TemplateError.self) {
            _ = try await render("{% for i in (1..5000) %}x{% endfor %}", limits: TemplateLimits(loopRows: 100))
        }
        await #expect(throws: TemplateError.self) {
            _ = try await render("{% for i in (1..20000) %}{% endfor %}", limits: TemplateLimits(deadline: Date.distantPast))
        }
        // A range too long to hold.
        await #expect(throws: TemplateError.self) {
            _ = try await render("{% for i in (1..99999999) %}{% endfor %}", limits: TemplateLimits(materializedRows: 1000))
        }
    }
}

@Suite struct TemplateHeaderTests {
    @Test func headersParse() throws {
        let t = try ParsedTemplate(source: """
        ---
        # A comment
        name: "Daily steps"
        description: One file a day
        format: csv
        data: [metrics, heart_rate_notifications]
        partition: day
        filename: "steps-{{ partition.key }}.csv"
        content_type: text/csv
        ---
        body
        """)
        #expect(t.header.name == "Daily steps")
        #expect(t.header.format == .csv)
        #expect(t.header.data == [.metrics, .heartRateNotifications])
        #expect(t.header.partition == .day)
        #expect(t.header.filename == "steps-{{ partition.key }}.csv")
        #expect(t.header.contentType == "text/csv")
    }

    @Test func badHeadersSaySo() {
        #expect(throws: TemplateError.self) { try ParsedTemplate(source: "---\nname: x\nformat: docx\n---\n") }
        #expect(throws: TemplateError.self) { try ParsedTemplate(source: "---\nname: x\npartition: hour\n---\n") }
        #expect(throws: TemplateError.self) { try ParsedTemplate(source: "---\nname: x\ndata: [nothing]\n---\n") }
        #expect(throws: TemplateError.self) { try ParsedTemplate(source: "---\nname: x\nwhat: y\n---\n") }
        #expect(throws: TemplateError.self) { try ParsedTemplate(source: "---\nformat: text\n---\n") }
    }
}

@Suite struct LocalClockTests {
    @Test func stampMatchesTheSlowWay() {
        let clock = LocalClock(timeZone: vancouver)
        var date = T.date("2019-01-01 00:00:00 -0800")
        // Across several years, including every clock change.
        for _ in 0..<3000 {
            #expect(clock.stamp(date) == Stamp.local(date, vancouver))
            date = date.addingTimeInterval(86400 * 0.73)
        }
    }

    @Test func goingBackInTimeReadsTheRightOffset() {
        let clock = LocalClock(timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(clock.stamp(T.date("2026-07-01 12:00:00 -0400")).hasSuffix("-0400"))
        #expect(clock.stamp(T.date("2026-01-01 12:00:00 -0500")).hasSuffix("-0500"))
        #expect(clock.stamp(T.date("2026-07-01 12:00:00 -0400")).hasSuffix("-0400"))
    }

    @Test func beforeTheEpochStillWorks() {
        let clock = LocalClock(timeZone: TimeZone(identifier: "UTC")!)
        #expect(clock.stamp(T.date("1969-12-31 23:59:59 +0000")) == "1969-12-31 23:59:59 +0000")
    }

    @Test func formatsCommonConversions() {
        let clock = LocalClock(timeZone: vancouver)
        let d = T.date("2026-10-24 17:05:09 -0700")
        #expect(clock.format(d, "%Y-%m-%dT%H:%M:%S%:z") == "2026-10-24T17:05:09-07:00")
        #expect(clock.format(d, "%F %T %s") == "2026-10-24 17:05:09 \(Int(d.timeIntervalSince1970))")
        #expect(clock.isoUTC(d) == "2026-10-25T00:05:09.000Z")
    }
}

@Suite struct TemplateDataTests {
    private let noon = T.date("2026-10-24 12:00:00 -0700")
    private var day: DateInterval { T.day("2026-10-24").interval(in: calendar) }

    private func export() -> ExportInfo { ExportInfo(device: FixtureTests.device, generatedAt: noon, timeZone: vancouver) }

    private func run(_ source: String, store: HealthQuerying, spec: ExtractSpec = ExtractSpec(grouping: .days)) async throws -> (String, RenderedRun) {
        let extractor = Extractor(store: store, spec: spec, calendar: calendar, ranges: [day])
        let sink = MemorySink()
        let parts = try await TemplateTransformer(template: ParsedTemplate(source: source)).run(extractor: extractor, export: export()) { _, _ in sink }
        return (sink.string, parts)
    }

    @Test func aPlanTemplateWritesCSVFromMetrics() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 100)
        let (out, _) = try await run("""
        ---
        name: Steps
        format: csv
        ---
        date,steps,source
        {% for p in metrics.step_count.data %}{{ p.date | date: '%Y-%m-%d' }},{{ p.qty }},{{ p.source }}
        {% endfor %}
        """, store: store)
        #expect(out == "date,steps,source\n2026-10-24,100,Watch\n")
    }

    @Test func aMetricWritesItsJSONForm() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 100)
        store.add("heart_rate", source: "Watch", at: noon, 60)
        store.add("heart_rate", source: "Watch", at: noon, 80)
        let (out, _) = try await run("""
        ---
        name: V2
        format: json
        ---
        {"data":{"metrics":[{% for m in metrics %}{{ m }}{% unless forloop.last %},{% endunless %}{% endfor %}]}}
        """, store: store)
        #expect(out.contains(#"{"data":[{"Avg":70,"Max":80,"Min":60,"date":"2026-10-24 00:00:00 -0700"}],"name":"heart_rate","units":"count/min"}"#))
        #expect(out.contains(#"{"data":[{"date":"2026-10-24 00:00:00 -0700","qty":100,"source":"Watch"}],"name":"step_count","units":"count"}"#))
    }

    @Test func emptyMetricsAreLeftOutOfALoop() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: noon, 1)
        let (out, _) = try await run("---\nname: n\n---\n{% for m in metrics %}{{ m.name }} {% endfor %}", store: store)
        #expect(out == "step_count ")
    }

    @Test func aLastRowIsKnownAcrossPages() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let count = Extractor.pageSize + 3
        for i in 0..<count { store.add("step_count", at: noon.addingTimeInterval(Double(i)), 1) }
        let (out, _) = try await run("---\nname: n\n---\n{% for p in metrics.step_count.data %}{% if forloop.last %}L{% else %}.{% endif %}{% endfor %}", store: store, spec: ExtractSpec(grouping: nil))
        #expect(out == String(repeating: ".", count: count - 1) + "L")
    }

    @Test func loopsTakeLimitAndOffsetOnLazyLists() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        for i in 0..<10 { store.add("step_count", at: noon.addingTimeInterval(Double(i)), Double(i)) }
        let spec = ExtractSpec(grouping: nil)
        let (a, _) = try await run("---\nname: n\n---\n{% for p in metrics.step_count.data limit:2 offset:3 %}{{ p.qty }}{% if forloop.last %}!{% endif %}{% endfor %}", store: store, spec: spec)
        #expect(a == "34!")
        let (b, _) = try await run("---\nname: n\n---\n{% for p in metrics.step_count.data %}{% if p.qty == 1 %}{% break %}{% endif %}{{ p.qty }}{% endfor %}", store: store, spec: spec)
        #expect(b == "0")
    }

    @Test func listFiltersLoadWhatTheyNeed() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: noon, 2)
        store.add("step_count", at: noon.addingTimeInterval(1), 1)
        let spec = ExtractSpec(grouping: nil)
        let (a, _) = try await run("---\nname: n\n---\n{{ metrics.step_count.data | map: 'qty' | sort | join: ',' }}", store: store, spec: spec)
        #expect(a == "1,2")
        let (b, _) = try await run("---\nname: n\n---\n{{ metrics.step_count.data.size }} {{ metrics.step_count.data.first.qty }}", store: store, spec: spec)
        #expect(b == "2 2")
        let (c, _) = try await run("---\nname: n\n---\n{{ metrics.step_count.data | map: 'qty' | sum }}", store: store, spec: spec)
        #expect(c == "3")
        // Group a list by a field; every row is in memory, so it's capped.
        let (d, _) = try await run("---\nname: n\n---\n{% assign g = metrics.step_count.data | group_by: 'source' %}{% for x in g %}{{ x.name }}={{ x.items.size }}{% endfor %}", store: store, spec: spec)
        #expect(d == "Watch=2")
    }

    @Test func tooManyRowsToSortFailsItsRun() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        for i in 0..<10 { store.add("step_count", at: noon.addingTimeInterval(Double(i)), 1) }
        let extractor = Extractor(store: store, spec: ExtractSpec(grouping: nil), calendar: calendar, ranges: [day])
        let t = try ParsedTemplate(source: "---\nname: n\n---\n{{ metrics.step_count.data | sort: 'qty' | size }}")
        await #expect(throws: TemplateError.self) {
            _ = try await TemplateTransformer(template: t, limits: TemplateLimits(materializedRows: 5)).run(extractor: extractor, export: export()) { _, _ in MemorySink() }
        }
    }

    @Test func sectionsAreEmptyUnlessAskedFor() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let fever = MetricCatalog.symptoms.first { $0.id.hasSuffix("Fever") }!
        store.addCategory(fever.id, DetailedCategory(source: "Health", start: noon, end: noon, value: 4))
        let source = "---\nname: n\n---\n{% for s in symptoms %}{{ s.name }}:{{ s.severity }}{% else %}none{% endfor %}"
        #expect(try await run(source, store: store).0 == "none")
        #expect(try await run(source, store: store, spec: ExtractSpec(sections: [.symptoms])).0 == "Fever:Severe")
    }

    @Test func aDayPartitionMakesOneFilePerDay() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: noon, 1)
        store.add("step_count", at: noon.addingTimeInterval(86400), 2)
        let t = try ParsedTemplate(source: """
        ---
        name: Daily
        format: csv
        partition: day
        filename: "steps-{{ partition.key }}.csv"
        ---
        {% for p in metrics.step_count.data %}{{ p.qty }}{% endfor %}
        """)
        let two = DateInterval(start: day.start, end: T.day("2026-10-26").start(in: calendar))
        let extractor = Extractor(store: store, spec: ExtractSpec(grouping: .days), calendar: calendar, ranges: [two])
        var files: [String: MemorySink] = [:]
        let parts = try await TemplateTransformer(template: t).run(extractor: extractor, export: export()) { _, name in
            let sink = MemorySink()
            files[name] = sink
            return sink
        }
        #expect(parts.parts.map(\.filename) == ["steps-2026-10-24.csv", "steps-2026-10-25.csv"])
        #expect(files["steps-2026-10-24.csv"]?.string == "1")
        #expect(files["steps-2026-10-25.csv"]?.string == "2")
    }

    @Test func aDaylightSavingDayIsOnePart() async throws {
        let newYork = Calendar.local(TimeZone(identifier: "America/New_York")!)
        let store = FakeHealthQuerying(calendar: newYork)
        let e = Extractor(store: store, spec: ExtractSpec(), calendar: newYork, ranges: [T.day("2026-11-01").interval(in: newYork)])
        let parts = try await PartitionPlanner(calendar: newYork).partitions(.day, extractor: e)
        #expect(parts.count == 1)
        #expect(parts[0].end!.timeIntervalSince(parts[0].start!) == 25 * 3600)
    }

    @Test func aMetricPartitionMakesOnePerMetricAndAWorkoutPartitionOnePerWorkout() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let run = WorkoutDetail(id: "w1", activityType: "Running", name: "Outdoor Run", source: "Watch", start: noon, end: noon.addingTimeInterval(600), duration: 600, hasRoute: true)
        store.add(run, route: [RoutePoint(timestamp: noon, latitude: 49.5, longitude: -123.25, altitude: 10)])
        let spec = ExtractSpec(sections: [.metrics, .workouts], metrics: .only(["step_count", "heart_rate"]))
        let e = Extractor(store: store, spec: spec, calendar: calendar, ranges: [day])
        #expect(try await PartitionPlanner(calendar: calendar).partitions(.metric, extractor: e).map(\.key) == ["step_count", "heart_rate"])
        #expect(try await PartitionPlanner(calendar: calendar).partitions(.section, extractor: e).map(\.key) == ["metrics", "workouts"])

        let t = try ParsedTemplate(source: """
        ---
        name: Route
        format: gpx
        partition: workout
        filename: "{{ workout.name }}-{{ partition.key }}.gpx"
        ---
        <gpx><trk><name>{{ workout.name }}</name><trkseg>{% for p in workout.route %}<trkpt lat="{{ p.latitude }}" lon="{{ p.longitude }}"><ele>{{ p.altitude }}</ele></trkpt>{% endfor %}</trkseg></trk></gpx>
        """)
        let sink = MemorySink()
        let parts = try await TemplateTransformer(template: t).run(extractor: e, export: export()) { _, name in
            #expect(name == "Outdoor Run-w1.gpx")
            return sink
        }
        #expect(parts.parts.count == 1)
        #expect(sink.string == #"<gpx><trk><name>Outdoor Run</name><trkseg><trkpt lat="49.5" lon="-123.25"><ele>10</ele></trkpt></trkseg></trk></gpx>"#)
    }

    @Test func aFileNameCantLeaveItsFolder() async throws {
        let t = try ParsedTemplate(source: "---\nname: n\nfilename: \"../{{ partition.key }}/x.txt\"\n---\nx")
        let e = Extractor(store: FakeHealthQuerying(calendar: calendar), spec: ExtractSpec(), calendar: calendar, ranges: [day])
        let parts = try await TemplateTransformer(template: t).run(extractor: e, export: export()) { _, _ in MemorySink() }
        #expect(!parts.parts[0].filename.contains("/"))
    }

    @Test func aSleepPointWritesEveryField() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let id = MetricCatalog.metric(named: "sleep_analysis")!.identifiers[0]
        store.addCategory(id, DetailedCategory(source: "Watch", start: T.date("2026-10-23 23:00:00 -0700"), end: T.date("2026-10-24 07:00:00 -0700"), value: 3))
        let (out, _) = try await run("---\nname: n\nformat: json\n---\n{{ metrics.sleep_analysis.data | first }}", store: store)
        #expect(out == #"{"asleep":0,"awake":0,"core":8,"date":"2026-10-24 00:00:00 -0700","deep":0,"inBed":0,"inBedEnd":"2026-10-24 07:00:00 -0700","inBedStart":"2026-10-23 23:00:00 -0700","rem":0,"sleepEnd":"2026-10-24 07:00:00 -0700","sleepStart":"2026-10-23 23:00:00 -0700","source":"Watch","totalSleep":8}"#)
    }

    @Test func exportInfoIsAvailable() async throws {
        let (out, _) = try await run("---\nname: n\n---\n{{ export.device.name }} {{ export.time_zone }} {{ export.format }} {{ export.generated_at | date: '%F' }}", store: FakeHealthQuerying(calendar: calendar))
        #expect(out == "Test iPhone America/Vancouver text 2026-10-24")
    }
}

@Suite struct TemplateSpeedTests {
    /// Not a pass/fail test: `HDR_BENCH=1 swift test --filter TemplateSpeedTests`
    /// prints rows a second through the shapes that matter. The worst case in
    /// practice is 604,800 rows: one metric, a week, one row a second.
    @Test func speed() async throws {
        guard ProcessInfo.processInfo.environment["HDR_BENCH"] != nil else { return }
        let rows = 604_800
        for (label, source) in [
            ("csv fields", "---\nname: n\nformat: csv\n---\n{% for p in metrics.step_count.data %}{{ p.date }},{{ p.qty }},{{ p.source }}\n{% endfor %}"),
            ("json object", "---\nname: n\nformat: json\n---\n[{% for p in metrics.step_count.data %}{{ p }}{% unless forloop.last %},{% endunless %}{% endfor %}]"),
        ] {
            let start = T.date("2026-01-01 00:00:00 -0800")
            let store = SyntheticHealthQuerying(start: start, count: rows)
            let e = Extractor(store: store, spec: ExtractSpec(grouping: nil), calendar: calendar, ranges: [DateInterval(start: start, duration: Double(rows))])
            let sink = NullSink()
            let export = ExportInfo(device: FixtureTests.device, generatedAt: start, timeZone: vancouver)
            let clock = ContinuousClock.now
            let parts = try await TemplateTransformer(template: ParsedTemplate(source: source)).run(extractor: e, export: export) { _, _ in sink }
            let seconds = Double((ContinuousClock.now - clock).components.seconds) + Double((ContinuousClock.now - clock).components.attoseconds) / 1e18
            print("BENCH \(label): \(rows) rows, \(parts.parts[0].bytes / 1_000_000) MB in \(String(format: "%.2f", seconds))s = \(Int(Double(rows) / seconds)) rows/s")
        }
    }
}

@Suite struct TemplateMemoryTests {
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Output as large as the memory limit, or larger, costs only a buffer and
    /// a page. Holding what's read as well would pass the limit many times over.
    @Test func renderingStreams() async throws {
        let rows = 1_000_000
        let start = T.date("2026-01-01 00:00:00 -0800")
        let t = try ParsedTemplate(source: "---\nname: n\nformat: json\n---\n[{% for p in metrics.step_count.data %}{{ p }}{% unless forloop.last %},{% endunless %}{% endfor %}]")
        // Other suites allocate alongside this, so a spike can be theirs. A leak
        // of its own would fail every attempt.
        var grew = Int.max
        for _ in 0..<3 where grew >= 128 * 1024 * 1024 {
            let store = SyntheticHealthQuerying(start: start, count: rows)
            let e = Extractor(store: store, spec: ExtractSpec(grouping: nil), calendar: calendar, ranges: [DateInterval(start: start, duration: Double(rows))])
            let sink = PeakSink { self.footprint() }
            let before = footprint()
            let parts = try await TemplateTransformer(template: t).run(extractor: e, export: ExportInfo(device: FixtureTests.device, generatedAt: start, timeZone: vancouver)) { _, _ in sink }
            #expect(parts.parts[0].bytes > 50_000_000)
            grew = min(grew, sink.peak - before)
        }
        #expect(grew < 128 * 1024 * 1024, "grew by \(grew / 1024 / 1024) MB")
    }
}

final class PeakSink: OutputSink {
    private let measure: () -> Int
    private(set) var peak = 0

    init(_ measure: @escaping () -> Int) {
        self.measure = measure
    }

    func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        peak = max(peak, measure())
    }
}

final class NullSink: OutputSink {
    func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {}
}

@Suite struct TemplateLibraryTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var library: TemplateLibrary { TemplateLibrary(files: FileStore(root: root)) }
    private let good = "---\nname: Mine\nformat: csv\n---\n{% for p in metrics.step_count.data %}{{ p.qty }}\n{% endfor %}"

    @Test func everyBuiltInParsesAndHasADescription() throws {
        #expect(BuiltInTemplates.all.count >= 6)
        for id in BuiltInTemplates.all {
            let t = try BuiltInTemplates.template(id)
            #expect(t.header.description != nil, "\(id)")
        }
    }

    @Test func aTemplateCanBeSavedListedAndRemoved() throws {
        let id = try library.save(good)
        #expect(library.custom().map(\.name) == ["Mine"])
        #expect(library.source(.custom(id)) == good)
        #expect(library.entries().contains { $0.ref == .custom(id) && $0.format == .csv })
        library.remove(id)
        #expect(library.custom().isEmpty)
    }

    @Test func theNativeTwinIsOnlyATransformForOneUsingIt() throws {
        let twin = TemplateRef.builtIn(BuiltInTemplates.healthDataRelay)
        let id = try library.save(good)
        #expect(library.entries().contains { $0.ref == twin })
        #expect(!library.transforms().contains { $0.ref == twin })
        #expect(!library.transforms(selected: .builtIn(BuiltInTemplates.metricsCSV)).contains { $0.ref == twin })
        #expect(library.transforms(selected: twin).contains { $0.ref == twin })
        #expect(library.transforms().contains { $0.ref == .custom(id) })
        #expect(library.transforms().first?.ref == .builtIn(BuiltInTemplates.metricsJSONv2))
    }

    @Test func aBadEditKeepsTheOldTemplate() throws {
        let id = try library.save(good)
        #expect(throws: TemplateError.self) { try library.save("---\nname: Mine\n---\n{{ oops", id: id) }
        #expect(library.source(.custom(id)) == good)
    }

    @Test func importRefusesWhatIsntATemplate() throws {
        let file = root.appendingPathExtension("bin")
        try Data([0xFF, 0xFE, 0x00]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: TemplateError.self) { try library.importFile(file) }
        try Data(good.utf8).write(to: file)
        let id = try library.importFile(file)
        #expect(library.source(.custom(id)) == good)
    }

    @Test func exportNamesAreSafe() {
        #expect(TemplateLibrary.exportName("Daily / Steps!") == "daily---steps-.liquid")
    }

    /// From import to delivery.
    @Test func anImportedTemplateDelivers() async throws {
        let cal = calendar
        let now = T.date("2026-10-25 12:00:00 -0700")
        let files = FileStore(root: root)
        let file = root.appendingPathExtension("liquid")
        try Data(good.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try TemplateLibrary(files: files).importFile(file)
        let queries = FakeHealthQuerying(calendar: cal)
        queries.add("step_count", at: T.date("2026-10-25 09:00:00 -0700"), 42)
        let transport = RecordingTransport()
        let engine = Engine(.init(store: FakeHealthStore(), files: files, tokens: MemoryTokenStore(), device: { Device(name: $0, model: "m", os: "o", app: "a") },
                                  calendar: { cal }, now: { now }, pause: { _ in }, queries: queries, makeTransport: { _, _ in transport }))
        let d = await engine.add(Destination(name: "Mine", kind: .target(.web(WebTarget(url: "https://example.com")))), token: nil,
                                 definition: PipelineDefinition(extract: ExtractSpec(range: .today, grouping: .days), template: .custom(id), templateName: "Mine"))
        await engine.run(d.id)
        #expect(transport.texts == ["42\n"])
    }

    /// A pipeline copied from the native format's twin runs for real, and its
    /// data is the native push's.
    @Test func theTwinRunsAsAPipeline() async throws {
        let cal = calendar
        let now = T.date("2026-10-25 07:00:00 -0700")
        let transport = RecordingTransport()
        let engine = Engine(.init(store: FixtureTests.store(), files: FileStore(root: root), tokens: MemoryTokenStore(), device: { _ in FixtureTests.device },
                                  calendar: { cal }, now: { now }, pause: { _ in }, queries: FakeHealthQuerying(calendar: cal), makeTransport: { _, _ in transport }))
        let range = DateInterval(start: T.day("2026-10-24").start(in: cal), end: T.day("2026-10-26").start(in: cal))
        let d = await engine.add(Destination(name: "Copy", kind: .target(.web(WebTarget(url: "https://example.com")))), token: nil,
                                 definition: PipelineDefinition(extract: ExtractSpec(range: .fixed(range)), template: .builtIn(BuiltInTemplates.healthDataRelay), templateName: "Twin"))
        await engine.run(d.id)
        let want = try String(contentsOf: FixtureTests.fixtures.appendingPathComponent("push-two-days.json"), encoding: .utf8)
        #expect(transport.texts == [want])
    }
}

@Suite struct TemplatePreviewTests {
    private let cal = calendar
    private let now = T.date("2026-10-25 12:00:00 -0700")

    @Test func everyBuiltInPreviewsOnSampleData() async throws {
        for id in BuiltInTemplates.all where id != BuiltInTemplates.healthDataRelay {
            let out = await TemplatePreview.render(source: BuiltInTemplates.source(id)!, calendar: cal, now: now)
            #expect(out.error == nil, "\(id): \(out.error ?? "")")
            #expect(!out.parts.isEmpty, "\(id)")
            #expect(out.parts[0].text.count > 20, "\(id)")
        }
    }

    @Test func anErrorSaysWhere() async {
        let out = await TemplatePreview.render(source: "---\nname: n\n---\nfine\n{{ a | nope }}", calendar: cal, now: now)
        #expect(out.error?.contains("nope") == true)
        #expect(out.line == 5)
        #expect(out.parts.isEmpty)
    }

    @Test func invalidOutputIsAnError() async {
        let out = await TemplatePreview.render(source: "---\nname: n\nformat: json\n---\n{\"a\":", calendar: cal, now: now)
        #expect(out.error?.contains("valid JSON") == true)
    }

    @Test func longOutputIsCutForShowing() async {
        let out = await TemplatePreview.render(source: "---\nname: n\n---\n{% for i in (1..20000) %}0123456789{% endfor %}", calendar: cal, now: now)
        #expect(out.parts[0].isTruncated)
        #expect(out.parts[0].text.utf8.count == TemplatePreview.shownBytes)
    }

    @Test func aRunawayStopsQuickly() async {
        let out = await TemplatePreview.render(source: "---\nname: n\n---\n{% for i in (1..400) %}{% for j in (1..400) %}{% for k in (1..400) %}x{% endfor %}{% endfor %}{% endfor %}", calendar: cal, now: now)
        #expect(out.error != nil)
    }

    @Test func csvAndHtmlBuiltInsLookRight() async {
        let csv = await TemplatePreview.render(source: BuiltInTemplates.source(BuiltInTemplates.metricsCSV)!, calendar: cal, now: now)
        #expect(csv.parts[0].text.hasPrefix("date,metric,value,min,max,units,source\n"))
        #expect(csv.parts[0].text.contains(",step_count,"))
        #expect(csv.parts[0].filename.hasSuffix(".csv"))
        let html = await TemplatePreview.render(source: BuiltInTemplates.source(BuiltInTemplates.healthSummaryHTML)!, calendar: cal, now: now)
        #expect(html.parts[0].text.contains("<h2>Steps</h2>"))
        #expect(html.parts[0].text.contains("Outdoor Run"))
    }
}
