import Foundation
import Testing
@testable import HealthDataRelayKit

private let cal = Calendar.local(T.vancouver)
private let at = T.date("2026-10-25 12:00:00 -0700")

@Suite struct PhoneClientTests {
    @Test func aPastedFingerprintIsTidied() {
        #expect(PhoneClient.normalized("ab:cd EF\n01") == "ABCDEF01")
    }

    @Test func aBadAddressIsCaught() {
        #expect(throws: PhoneError.badAddress) { try PhoneClient(address: "not a url", token: "t", fingerprint: "") }
        #expect(throws: PhoneError.badAddress) { try PhoneClient(address: "ftp://x/mcp", token: "t", fingerprint: "") }
    }

    /// The pin is the only trust there is: it must accept the one certificate and nothing else.
    @Test func onlyThePinnedCertificateMatches() throws {
        let cert = try LocalCertificate.make(names: ["localhost"], addresses: ["127.0.0.1"], now: at)
        let other = try LocalCertificate.make(names: ["localhost"], addresses: ["127.0.0.1"], now: at)
        let secCert = try #require(SecCertificateCreateWithData(nil, cert.der as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates(secCert, SecPolicyCreateSSL(true, "localhost" as CFString), &trust)
        let t = try #require(trust)
        #expect(PhoneClient.matches(t, fingerprint: PhoneClient.normalized(cert.fingerprint)))
        #expect(!PhoneClient.matches(t, fingerprint: PhoneClient.normalized(other.fingerprint)))
        #expect(!PhoneClient.matches(t, fingerprint: ""))
    }

    @Test func aToolsTroubleBecomesAnError() {
        let failed: JSON = ["result": ["content": [["type": "text", "text": "too much"]], "isError": .bool(true)]]
        #expect(throws: PhoneError.refused("too much")) { try PhoneClient.unwrap(failed) }
        #expect(throws: PhoneError.refused("nope")) { try PhoneClient.unwrap(["error": ["message": "nope"]]) }
    }

    /// Over a real socket, without TLS: the phone's handler, the Mac's client.
    @Test func theClientReadsARealServer() async throws {
        let store = RichData.store()
        let handler = MCPHandler(store: store, calendar: cal, device: FixtureTests.device, now: { at })
        let server = try LocalServer(kind: .http(MCPHTTPEndpoint(handler: handler, token: "t"), identity: nil), port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let client = try PhoneClient(address: "http://127.0.0.1:\(port)/mcp", token: "t", fingerprint: "")
        let d = try await Dashboard.fetch(from: client, days: 7, now: at, calendar: cal)
        #expect(d.series.contains { $0.name == "step_count" })
        #expect(d.workouts.first?.name == "Yoga")
        let refused = try PhoneClient(address: "http://127.0.0.1:\(port)/mcp", token: "wrong", fingerprint: "")
        await #expect(throws: PhoneError.wrongToken) { _ = try await Dashboard.fetch(from: refused, days: 7, now: at, calendar: cal) }
    }

    @Test func noPhoneSaysSo() async throws {
        let client = try PhoneClient(address: "http://127.0.0.1:1/mcp", token: "t", fingerprint: "")
        do {
            _ = try await client.read(.metrics, start: T.day("2026-10-20"), end: T.day("2026-10-25"), grouping: .days)
            Issue.record("should fail")
        } catch {
            #expect(String(describing: error).contains("Couldn't reach your iPhone"))
        }
    }

    /// HDR_PHONE_FILE=<json with url, token, fingerprint>: against the real app's
    /// server on a simulator, over real TLS. tools/mac-check.sh sets it up.
    @Test func aRealPhone() async throws {
        guard let path = ProcessInfo.processInfo.environment["HDR_PHONE_FILE"] else { return }
        let info = try #require(JSON.parse(Data(contentsOf: URL(fileURLWithPath: path))))
        let client = try PhoneClient(address: info["url"]!.stringValue!, token: info["token"]!.stringValue!, fingerprint: info["fingerprint"]!.stringValue!)
        let d = try await Dashboard.fetch(from: client, days: 7)
        #expect(d.series.contains { $0.name == "step_count" }, "\(d.series.map(\.name))")
        print("REAL PHONE: \(d.series.count) metrics, \(d.workouts.count) workouts")
        // Someone else's certificate is refused before anything is sent.
        let other = try LocalCertificate.make(names: ["x"], addresses: [], now: Date())
        let wrong = try PhoneClient(address: info["url"]!.stringValue!, token: info["token"]!.stringValue!, fingerprint: other.fingerprint)
        await #expect(throws: PhoneError.wrongCertificate) { _ = try await wrong.read(.metrics, start: Day(Date(), calendar: .local()), end: Day(Date(), calendar: .local()), grouping: .days) }
    }
}

@Suite struct DashboardTests {
    @Test func demoDataFillsTheDashboard() async throws {
        let d = try await Dashboard.fetch(from: DemoSource(now: at, calendar: cal), days: 3, now: at, calendar: cal)
        let steps = try #require(d.series.first { $0.name == "step_count" })
        #expect(steps.title == "Steps")
        #expect(steps.bars)
        #expect(steps.points.count == 3)
        let heart = try #require(d.series.first { $0.name == "heart_rate" })
        #expect(!heart.bars)
        #expect(heart.latest?.low != nil)
        #expect(d.series.contains { $0.name == "sleep_analysis" })
        #expect(d.workouts.map(\.name) == ["Outdoor Run"])
        #expect(d.workouts[0].distance == "5.1 km")
    }

    @Test func badRowsAreLeftOut() {
        let metrics: JSON = ["data": ["metrics": [["name": "step_count", "units": "count", "data": [["date": "nonsense", "qty": 1], ["date": "2026-10-25 00:00:00 -0700", "qty": 2]]], ["units": "x"]]]]
        let d = Dashboard.build(metrics: metrics, workouts: .object([:]), fetchedAt: at)
        #expect(d.series.count == 1)
        #expect(d.series[0].points.count == 1)
    }

    @Test func aDashboardSurvivesBeingSaved() throws {
        let d = Dashboard(fetchedAt: at, series: [.init(name: "n", title: "T", group: "g", units: "u", bars: true, points: [.init(date: at, value: 1, low: nil, high: nil)])], workouts: [])
        #expect(try JSONDecoder().decode(Dashboard.self, from: JSONEncoder().encode(d)) == d)
    }
}
