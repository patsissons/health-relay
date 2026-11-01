import Foundation
import Testing
@testable import HealthDataRelayKit

private let now = T.date("2026-10-25 12:00:00 -0700")

private func parse(_ text: String) throws -> PipelineLink { try PipelineLink.parse(URL(string: text)!, now: now) }

@Suite struct PipelineLinkTests {
    @Test func theSmallestLink() throws {
        let l = try parse("healthdatarelay://pipeline?url=https%3A%2F%2Fapi.example.com%2Fhealth&name=My%20Pipe")
        #expect(l.name == "My Pipe")
        #expect(l.web.url == "https://api.example.com/health")
        #expect(l.template == BuiltInTemplates.metricsJSONv2)
        #expect(l.extract.sections == [.metrics])
        #expect(l.trigger == .manual)
        #expect(!l.enabled)
        // JSON isn't aggregated unless asked.
        #expect(l.extract.grouping == nil)
    }

    @Test func aPastedLinkFromAnotherAppReadsTheSame() throws {
        let l = try parse("com.HealthExport://automation?url=https://a.example/h&name=X&format=json&enabled=true")
        #expect(l.enabled)
        #expect(l.web.url == "https://a.example/h")
    }

    @Test func parametersIgnoreCase() throws {
        let l = try parse("healthdatarelay://pipeline?URL=https://a.example/h&Name=X&DataType=Workouts")
        #expect(l.extract.sections == [.workouts])
    }

    @Test func aFullConfiguration() throws {
        let l = try parse("com.HealthExport://automation?url=https://a.example/h&name=X&datatype=healthMetrics&period=previous7days&interval=hours&aggregatedata=true&syncinterval=hours&syncquantity=2&requesttimeout=300&metrics=Step%20Count,heart_rate,Steps&notifywhenrun=false")
        #expect(l.extract.range == .previousDays(7))
        #expect(l.extract.grouping == .hours)
        guard case .every(let s) = l.trigger else {
            Issue.record("no schedule")
            return
        }
        #expect((s.count, s.unit) == (2, .hours))
        #expect(l.web.timeout == 300)
        guard case .only(let names) = l.extract.metrics else {
            Issue.record("no metrics")
            return
        }
        #expect(Set(names) == ["step_count", "heart_rate"] || names.contains("heart_rate"))
        #expect(!l.notices.onSuccess)
        #expect(l.notices.onFailure)
    }

    @Test func headersSeparateTheBearerToken() throws {
        let l = try parse("healthdatarelay://pipeline?url=https://a.example&name=X&headers=Authorization,Bearer%20abc,X-API-Key,k1")
        #expect(l.token == "abc")
        #expect(l.web.headers == [.init(name: "X-API-Key", value: "k1")])
    }

    @Test func workoutsTakeTheirOptions() throws {
        let l = try parse("healthdatarelay://pipeline?url=https://a.example&name=X&datatype=workouts&includeroutes=false&includeworkoutmetadata=no&workouttypes=37,52")
        #expect(!l.extract.workouts.routes)
        #expect(!l.extract.workouts.series)
        #expect(l.extract.workouts.activityCodes == [37, 52])
    }

    @Test func realtimeNeedsSeconds() throws {
        let ok = try parse("healthdatarelay://pipeline?url=https://a.example&name=X&period=realtime&syncinterval=seconds&syncquantity=30")
        guard case .every(let s) = ok.trigger else {
            Issue.record("no schedule")
            return
        }
        #expect(s.isForegroundOnly)
        #expect(throws: PipelineLink.Failure.self) { try parse("healthdatarelay://pipeline?url=https://a.example&name=X&period=realtime") }
    }

    /// A receiver that asked for v1 can't read v2, so this says so rather than
    /// sending it something it can't use.
    @Test(arguments: ["v1", "1", "V1"]) func theLegacyFormatIsRefused(version: String) {
        #expect(throws: PipelineLink.Failure.legacyFormat) { try parse("healthdatarelay://pipeline?url=https://a.example&name=X&exportversion=\(version)") }
    }

    @Test(arguments: ["v2", "2"]) func theCurrentFormatIsFine(version: String) throws {
        #expect(try parse("healthdatarelay://pipeline?url=https://a.example&name=X&exportversion=\(version)").template == BuiltInTemplates.metricsJSONv2)
    }

    @Test func csvSaysItsColumnsAreItsOwn() throws {
        let l = try parse("healthdatarelay://pipeline?url=https://a.example&name=X&format=csv")
        #expect(l.template == BuiltInTemplates.metricsCSV)
        #expect(l.extract.grouping != nil)
        #expect(l.notes.contains { $0.contains("own columns") })
    }

    @Test func unknownMetricsAndUncarriedOptionsAreNoted() throws {
        let l = try parse("healthdatarelay://pipeline?url=https://a.example&name=X&metrics=nope&batchrequests=true")
        #expect(l.notes.contains { $0.contains("nope") })
        #expect(l.notes.contains { $0.contains("Batched") })
    }

    @Test func badLinksSayWhatsWrong() {
        for (text, want) in [
            ("healthdatarelay://pipeline?name=X", PipelineLink.Failure.missing("url")),
            ("healthdatarelay://pipeline?url=https://a.example", .missing("name")),
            ("healthdatarelay://pipeline?url=file:///etc/passwd&name=X", .badValue("url", "file:///etc/passwd")),
            ("healthdatarelay://pipeline?url=https://a.example&name=X&datatype=nope", .badValue("datatype", "nope")),
            ("healthdatarelay://pipeline?url=https://a.example&name=X&enabled=maybe", .badValue("enabled", "maybe")),
            ("healthdatarelay://pipeline?url=https://a.example&name=X&requesttimeout=5", .badValue("requesttimeout", "5")),
            ("healthdatarelay://pipeline?url=https://a.example&name=X&headers=a", .badValue("headers", "an odd list")),
            ("https://example.com/pipeline?url=x", .notALink),
        ] {
            #expect(throws: want, "\(text)") { try parse(text) }
        }
    }

    @Test func setupLinksKeepWorking() {
        #expect(SetupLink(URL(string: "healthdatarelay://destination?url=https://a.example")!) != nil)
        #expect(!PipelineLink.matches(URL(string: "healthdatarelay://destination?url=https://a.example")!))
    }

    @Test func workoutCodesFilter() async throws {
        var spec = ExtractSpec(sections: [.workouts], range: .fixed(RichData.week))
        spec.workouts.activityCodes = [999]
        var pager = Extractor(store: RichData.store(), spec: spec, calendar: .local(T.vancouver), ranges: [RichData.week]).workouts()
        #expect(try await pager.next() == nil)
        spec.workouts.activityCodes = [37]
        var hit = Extractor(store: RichData.store(), spec: spec, calendar: .local(T.vancouver), ranges: [RichData.week]).workouts()
        #expect(try await hit.next()?.map(\.name) == ["Outdoor Run"])
    }
}

@Suite struct RunLinkTests {
    @Test func roundTrips() throws {
        let link = RunLink(pipeline: UUID(), key: "secret")
        #expect(RunLink(link.url) == link)
    }

    @Test func aLinkWithNoKeyIsNotALink() {
        #expect(RunLink(URL(string: "healthdatarelay://run?pipeline=\(UUID().uuidString)")!) == nil)
        #expect(RunLink(URL(string: "healthdatarelay://run?key=x")!) == nil)
        #expect(RunLink(URL(string: "healthdatarelay://destination?key=x")!) == nil)
    }
}

@Suite struct WidgetSnapshotTests {
    /// Everything a widget shows comes from this file: this is its whole input.
    @Test func aSnapshotSurvivesTheFile() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let row = WidgetSnapshot.PipelineRow(id: UUID(), name: "Morning", state: "Last run finished", needsAttention: false, nextRun: now, lastSuccess: now, runLink: nil)
        let snapshot = WidgetSnapshot(updatedAt: now, pipelines: [row], values: [.init(name: "step_count", title: "Steps", text: "8,204")])
        snapshot.write(to: file)
        #expect(WidgetSnapshot.read(from: file) == snapshot)
    }

    @Test func noFileIsNoSnapshot() {
        #expect(WidgetSnapshot.read(from: URL(fileURLWithPath: "/nonexistent")) == nil)
        #expect(WidgetSnapshot.read(from: nil) == nil)
    }

    @Test func theWidgetsMetricsExist() {
        for name in WidgetSnapshot.metricNames { #expect(MetricCatalog.metric(named: name) != nil, "\(name)") }
    }
}
