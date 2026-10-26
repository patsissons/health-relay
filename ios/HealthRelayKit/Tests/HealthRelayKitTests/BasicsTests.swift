import Foundation
import Testing
@testable import HealthRelayKit

@Suite struct JSONTests {
    @Test(arguments: [
        (0.0, "0"), (-0.0, "0"), (8000, "8000"), (176.37, "176.37"), (0.1, "0.1"), (-123.12, "-123.12"),
        (1e-5, "0.00001"), (1.5e-7, "1.5e-7"), (1e-6, "0.000001"), (1e16, "10000000000000000"),
        (1e21, "1e+21"), (1.25e22, "1.25e+22"), (123456789.5, "123456789.5"),
    ])
    func numbersAsJavaScriptWritesThem(_ n: Double, _ text: String) {
        #expect(JSON.format(n) == text)
    }

    @Test func keysSortedAndStringsEscapedLikeStringify() {
        let v: JSON = ["b": 1, "a": ["z": "x/y", "B": "quote\" back\\ tab\t nul\u{01} é"], "aa": [.bool(true), .null]]
        #expect(v.canonical == #"{"a":{"B":"quote\" back\\ tab\t nul\u0001 é","z":"x/y"},"aa":[true,null],"b":1}"#)
    }
}

@Suite struct DaysTests {
    let la = Calendar.local(TimeZone(identifier: "America/Los_Angeles")!)

    @Test func daysSpanDaylightSavingChanges() {
        #expect(T.day("2026-03-08").interval(in: la).duration == 23 * 3600)
        #expect(T.day("2026-11-01").interval(in: la).duration == 25 * 3600)
        #expect(T.day("2026-10-24").interval(in: la).duration == 24 * 3600)
    }

    @Test func dayArithmeticAndParsing() {
        #expect(T.day("2026-12-31").adding(1).description == "2027-01-01")
        #expect(T.day("2026-03-01").adding(-1).description == "2026-02-28")
        #expect(Day("2026-13-01") == nil && Day("26-01-01") == nil)
        #expect(T.day("2026-10-30").through(T.day("2026-11-02")).map(\.description) == ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
    }

    @Test func stampsUseTheOffsetInForceThatDay() {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        #expect(Stamp.local(T.date("2026-11-01 00:30:00 -0700"), tz) == "2026-11-01 00:30:00 -0700")
        #expect(Stamp.local(T.date("2026-11-01 12:00:00 -0800"), tz) == "2026-11-01 12:00:00 -0800")
        #expect(Stamp.utc(T.date("2026-10-25 07:00:00 -0700")) == "2026-10-25T14:00:00Z")
    }
}

@Suite struct DayReaderTests {
    let q = "HKQuantityTypeIdentifier"

    @Test func statsRowsPerSourceWithTheModesFields() async throws {
        let s = FakeHealthStore()
        let d = T.date
        s.add(q + "StepCount", source: "iPhone", d("2026-10-24 09:00:00 -0700"), 100)
        s.add(q + "StepCount", source: "iPhone", d("2026-10-24 10:00:00 -0700"), 50)
        s.add(q + "StepCount", source: "Watch", d("2026-10-24 09:00:00 -0700"), 120)
        s.add(q + "RestingHeartRate", source: "Watch", d("2026-10-24 06:00:00 -0700"), 55)
        s.add(q + "RestingHeartRate", source: "Watch", d("2026-10-24 07:00:00 -0700"), 60)
        s.add(q + "Height", source: "iPhone", d("2026-10-24 08:00:00 -0700"), 177)
        s.add(q + "Height", source: "iPhone", d("2026-10-24 20:00:00 -0700"), 178)
        let cal = Calendar.local(T.vancouver)
        let day = T.day("2026-10-24")
        let content = try await DayReader(store: s, calendar: cal).read([day])[day]!
        #expect(content.stats == [
            StatRow(type: q + "Height", day: day, source: "iPhone", unit: "cm", latest: 178, latestAt: "2026-10-24 20:00:00 -0700"),
            StatRow(type: q + "RestingHeartRate", day: day, source: "Watch", unit: "count/min", avg: 57.5, count: 2),
            StatRow(type: q + "StepCount", day: day, source: "Watch", unit: "count", sum: 120),
            StatRow(type: q + "StepCount", day: day, source: "iPhone", unit: "count", sum: 150),
        ])
    }

    @Test func samplesFallOnLocalDaysAcrossTheFallBack() async throws {
        // 2026-11-01 is 25 hours long in Los Angeles: 23:30 that night is
        // still the 1st, and 00:30 on the 2nd is not.
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let cal = Calendar.local(tz)
        let s = FakeHealthStore()
        s.add(q + "HeartRate", source: "Watch", T.date("2026-11-01 00:30:00 -0700"), 60)
        s.add(q + "HeartRate", source: "Watch", T.date("2026-11-01 23:30:00 -0800"), 80)
        s.add(q + "HeartRate", source: "Watch", T.date("2026-11-02 00:30:00 -0800"), 100)
        let days = [T.day("2026-11-01"), T.day("2026-11-02")]
        let read = try await DayReader(store: s, calendar: cal).read(days)
        let first = read[days[0]]!.stats.first!
        #expect((first.count, first.avg, first.min, first.max) == (2, 70, 60, 80))
        #expect(read[days[1]]!.stats.first!.count == 1)
    }

    @Test func aNightSpanningTwoListedDaysIsSentOnce() async throws {
        let s = FakeHealthStore()
        s.addCategory("HKCategoryTypeIdentifierSleepAnalysis", source: "Watch", T.date("2026-10-23 23:00:00 -0700"), T.date("2026-10-24 06:00:00 -0700"), 3)
        let days = [T.day("2026-10-23"), T.day("2026-10-24")]
        let read = try await DayReader(store: s, calendar: .local(T.vancouver)).read(days)
        #expect(read[days[0]]!.samples.count == 1 && read[days[1]]!.samples.count == 1)
        let merged = Content.merging(days.map { read[$0]! })
        #expect(merged.samples.map(\.value) == ["HKCategoryValueSleepAnalysisAsleepCore"])
    }

    @Test func runsGroupConsecutiveDays() {
        let runs = DayReader.runs(["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-07", "2026-10-08"].map(T.day))
        #expect(runs.map { $0.map(\.description) } == [["2026-10-01", "2026-10-02", "2026-10-03"], ["2026-10-07", "2026-10-08"]])
    }

    @Test func categoryValuesByName() {
        #expect(Catalog.categoryValueName(type: "HKCategoryTypeIdentifierAppleStandHour", value: 1) == "HKCategoryValueAppleStandHourIdle")
        #expect(Catalog.categoryValueName(type: "HKCategoryTypeIdentifierMoodChanges", value: 0) == "HKCategoryValuePresencePresent")
        #expect(Catalog.categoryValueName(type: "HKCategoryTypeIdentifierNausea", value: 4) == "HKCategoryValueSeveritySevere")
        #expect(Catalog.categoryValueName(type: "HKCategoryTypeIdentifierMindfulSession", value: 0) == "HKCategoryValueNotApplicable")
    }

    @Test func catalogSendsEveryReceiverTypeOnce() {
        let ids = Catalog.allTypes.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Catalog.stats.contains { $0.id == q + "DietarySelenium" && $0.unit == "mcg" })
        // Sample-only quantities never appear as stats.
        for id in ["EnvironmentalAudioExposure", "HeadphoneAudioExposure", "BloodPressureSystolic", "AppleSleepingWristTemperature"] {
            #expect(!Catalog.stats.contains { $0.id == q + id })
        }
    }
}

@Suite struct DeliveryTests {
    @Test(arguments: [(200, Verdict.accepted), (204, .accepted), (400, .rejected), (401, .authFailed), (403, .authFailed),
                      (404, .rejected), (408, .retry), (429, .retry), (500, .retry), (503, .retry)])
    func statusAloneDecides(_ status: Int, _ verdict: Verdict) {
        #expect(Delivery.verdict(for: status) == verdict)
    }

    @Test func messagesComeFromTheReceiver() {
        #expect(Delivery.message(status: 400, body: Data(#"{"ok":false,"error":"bad_push","message":"schema must be"}"#.utf8)) == "schema must be")
        #expect(Delivery.message(status: 401, body: Data(#"{"ok":false,"error":"token_unknown"}"#.utf8)) == "token_unknown")
        #expect(Delivery.message(status: 200, body: Data(#"{"ok":true,"days":2,"from":"2026-10-24"}"#.utf8)) == "days 2, from 2026-10-24")
        #expect(Delivery.message(status: 502, body: Data()) == HTTPURLResponse.localizedString(forStatusCode: 502))
    }

    @Test func httpRequestCarriesTokenHeadersAndJSON() {
        let endpoint = HTTPEndpoint(url: URL(string: "https://example.test/push")!, headers: [.init(name: "X-Extra", value: "1")])
        let r = HTTPEndpointDestination(endpoint: endpoint, token: "tok").request(Data("{}".utf8))
        #expect(r.httpMethod == "POST" && r.timeoutInterval == 30)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "X-Extra") == "1")
        let bare = HTTPEndpointDestination(endpoint: endpoint, token: nil).request(Data())
        #expect(bare.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Suite struct DirtyTests {
    @Test func aDayMarkedAgainAfterItsReadStaysDirty() {
        var dirty = DirtySet()
        let t0 = Date(timeIntervalSince1970: 1000)
        dirty.mark([T.day("2026-10-24"), T.day("2026-10-25")], at: t0)
        dirty.mark([T.day("2026-10-25")], at: t0.addingTimeInterval(10))
        dirty.clear([T.day("2026-10-24"), T.day("2026-10-25")], readAt: t0.addingTimeInterval(5))
        #expect(dirty.days == [T.day("2026-10-25")])
    }

    @Test func rules() {
        let today = T.day("2026-10-25")
        #expect(DirtyRules.recent(today: today) == [T.day("2026-10-24"), today])
        #expect(DirtyRules.last(35, today: today).first == T.day("2026-09-21"))
        #expect(DirtyRules.last(30, today: today).count == 30)
        let cal = Calendar.local(T.vancouver)
        let night = DateInterval(start: T.date("2026-10-23 23:00:00 -0700"), end: T.date("2026-10-24 06:00:00 -0700"))
        #expect(DirtyRules.days(of: night, calendar: cal) == [T.day("2026-10-23"), T.day("2026-10-24")])
        let toMidnight = DateInterval(start: T.date("2026-10-24 23:00:00 -0700"), end: T.date("2026-10-25 00:00:00 -0700"))
        #expect(DirtyRules.days(of: toMidnight, calendar: cal) == [T.day("2026-10-24")])
        let days = DirtyRules.last(10, today: today)
        #expect(DirtyRules.batches(days.reversed(), firstRun: false).map(\.count) == [7, 3])
        #expect(DirtyRules.batches(days, firstRun: false)[0][0] == days[0])
        #expect(DirtyRules.batches(days, firstRun: true).count == 10)
    }
}

@Suite struct SetupLinkTests {
    @Test func readsWhatAReceiverEncodes() throws {
        // As a receiver builds it with encodeURIComponent.
        let link = try #require(SetupLink(URL(string:
            "healthrelay://destination?name=Cubby%20(Pat)&url=https%3A%2F%2Fcubby.example.com%2Fapi%2Fhealth%2Fpush%3Fx%3D1&token=a%2Bb%2Fc%3D%26d&header=X-Home%3A%20blue&v=1")!))
        #expect(link.endpoint.url.absoluteString == "https://cubby.example.com/api/health/push?x=1")
        #expect(link.token == "a+b/c=&d")
        #expect(link.name == "Cubby (Pat)")
        #expect(link.endpoint.headers == [.init(name: "X-Home", value: "blue")])
        #expect(SetupLink(link.url) == link)
    }

    @Test func onlyTheURLIsRequired() throws {
        let link = try #require(SetupLink(URL(string: "HealthRelay://DESTINATION?url=http%3A%2F%2F192.168.1.5%3A8787&token=")!))
        #expect(link.endpoint == HTTPEndpoint(url: URL(string: "http://192.168.1.5:8787")!))
        #expect(link.token == nil && link.name == nil)
        #expect(link.url.absoluteString == "healthrelay://destination?url=http%3A%2F%2F192.168.1.5%3A8787")
    }

    @Test(arguments: [
        "healthrelay://destination", "healthrelay://destination?token=x", "healthrelay://add?url=https%3A%2F%2Fa.example",
        "https://destination?url=https%3A%2F%2Fa.example", "healthrelay://destination?url=ftp%3A%2F%2Fa.example",
        "healthrelay://destination?url=nohost",
    ])
    func rejectsAnythingElse(_ text: String) {
        #expect(SetupLink(URL(string: text)!) == nil)
    }
}
