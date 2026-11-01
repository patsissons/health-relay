import CryptoKit
import Foundation

/// Where a Mac gets the phone's data: its server over the network, or sample
/// data to look at before there's a phone to connect to.
public protocol PhoneSource: Sendable {
    /// A tool's JSON, for a section over some days.
    func read(_ section: ExtractSpec.Section, start: Day, end: Day, grouping: TimeGrouping?) async throws -> JSON
}

public enum PhoneError: Error, Equatable, CustomStringConvertible {
    case badAddress
    case unreachable(String)
    case wrongToken
    case wrongCertificate
    case refused(String)

    public var description: String {
        switch self {
        case .badAddress: "That address doesn't look right. Copy it from Settings › Server on your iPhone."
        case .unreachable(let why): "Couldn't reach your iPhone: \(why) Is Health Data Relay open on it, on the same network?"
        case .wrongToken: "Your iPhone refused that token. Copy it again from Settings › Server."
        case .wrongCertificate: "This server's certificate doesn't match the fingerprint. Check it in Settings › Server on your iPhone: if they differ, this isn't your iPhone, or its address has changed."
        case .refused(let why): why
        }
    }
}

/// Talks to the phone's server, trusting its certificate only by fingerprint.
public final class PhoneClient: NSObject, PhoneSource, URLSessionDelegate, @unchecked Sendable {
    public let url: URL
    public let token: String
    public let fingerprint: String
    private var session: URLSession!
    private let lock = NSLock()
    private var mismatch = false

    public init(address: String, token: String, fingerprint: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { throw PhoneError.badAddress }
        self.url = url
        self.token = token
        self.fingerprint = Self.normalized(fingerprint)
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// However a fingerprint was pasted: colons or not, either case.
    static func normalized(_ text: String) -> String {
        text.uppercased().filter { $0.isHexDigit }
    }

    /// Whether a certificate is the one that was pinned. There's no public
    /// authority to ask on a home network, so this is the whole of the trust.
    static func matches(_ trust: SecTrust, fingerprint: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let hash = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined()
        return !fingerprint.isEmpty && hash == fingerprint
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if Self.matches(trust, fingerprint: fingerprint) { return (.useCredential, URLCredential(trust: trust)) }
        lock.withLock { mismatch = true }
        return (.cancelAuthenticationChallenge, nil)
    }

    private func post(_ message: JSON) async throws -> JSON {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = message.data
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch {
            if lock.withLock({ mismatch }) { throw PhoneError.wrongCertificate }
            throw PhoneError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw PhoneError.wrongToken }
        guard status == 200, let json = JSON.parse(data) else { throw PhoneError.refused("Your iPhone answered with status \(status).") }
        return json
    }

    public func read(_ section: ExtractSpec.Section, start: Day, end: Day, grouping: TimeGrouping?) async throws -> JSON {
        guard let tool = MCPHandler.tools.first(where: { $0.section == section }) else { throw PhoneError.refused("No tool for that.") }
        var args: [String: JSON] = ["start": .string(start.description), "end": .string(end.description)]
        if section == .metrics, let grouping { args["grouping"] = .string(grouping.rawValue) }
        let reply = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool.name), "arguments": .object(args)]])
        return try Self.unwrap(reply)
    }

    /// The JSON a tool wrote, out of JSON-RPC's envelope.
    static func unwrap(_ reply: JSON) throws -> JSON {
        if let message = reply["error"]?["message"]?.stringValue { throw PhoneError.refused(message) }
        guard case .array(let content)? = reply["result"]?["content"], let text = content.first?["text"]?.stringValue else { throw PhoneError.refused("Your iPhone's answer was empty.") }
        if case .bool(true)? = reply["result"]?["isError"] { throw PhoneError.refused(text) }
        guard let json = JSON.parse(Data(text.utf8)) else { throw PhoneError.refused("Your iPhone's answer didn't parse.") }
        return json
    }
}

/// Sample data through the same code, to try the dashboard with no phone.
public struct DemoSource: PhoneSource {
    private let handler: MCPHandler

    public init(now: Date = Date(), calendar: Calendar = .local()) {
        handler = MCPHandler(store: SampleHealth(now: now, calendar: calendar), calendar: calendar, device: Device(name: "Sample", model: "", os: "", app: ""), now: { now })
    }

    public func read(_ section: ExtractSpec.Section, start: Day, end: Day, grouping: TimeGrouping?) async throws -> JSON {
        guard let tool = MCPHandler.tools.first(where: { $0.section == section }) else { return .object([:]) }
        var args: [String: JSON] = ["start": .string(start.description), "end": .string(end.description)]
        if let grouping, section == .metrics { args["grouping"] = .string(grouping.rawValue) }
        let reply = await handler.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool.name), "arguments": .object(args)]])
        return try PhoneClient.unwrap(reply ?? .null)
    }
}

/// What the dashboard shows, read from a tool's JSON. Saved between launches,
/// so it opens with the last data even when the phone can't be reached.
public struct Dashboard: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable, Identifiable {
        public var date: Date
        public var value: Double
        public var low: Double?
        public var high: Double?

        public var id: Date { date }
    }

    public struct Series: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var title: String
        public var group: String
        public var units: String
        public var bars: Bool
        public var points: [Point]

        public var id: String { name }
        public var latest: Point? { points.last }
    }

    public struct Workout: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var start: Date
        public var duration: Double
        public var distance: String?
        public var energy: String?
    }

    public var fetchedAt: Date
    public var series: [Series]
    public var workouts: [Workout]

    /// Reads what the tools wrote. A row it can't read is left out rather than
    /// failing the whole dashboard.
    public static func build(metrics: JSON, workouts: JSON, fetchedAt: Date) -> Dashboard {
        var series: [Series] = []
        if case .array(let rows)? = metrics["data"]?["metrics"] {
            for row in rows {
                guard let name = row["name"]?.stringValue, case .array(let data)? = row["data"] else { continue }
                let metric = MetricCatalog.metric(named: name)
                let points = data.compactMap(point).sorted { $0.date < $1.date }
                guard !points.isEmpty else { continue }
                let form = metric?.form
                series.append(Series(name: name, title: metric?.title ?? name, group: metric?.group.rawValue ?? "other", units: row["units"]?.stringValue ?? "",
                                     bars: form == .total || form == .eventCount || form == .eventMinutes, points: points))
            }
        }
        var list: [Workout] = []
        if case .array(let rows)? = workouts["data"]?["workouts"] {
            for row in rows {
                guard let id = row["id"]?.stringValue, let name = row["name"]?.stringValue, let start = date(row["start"]) else { continue }
                var duration = 0.0
                if case .number(let d)? = row["duration"] { duration = d }
                list.append(Workout(id: id, name: name, start: start, duration: duration, distance: quantity(row["distance"]), energy: quantity(row["activeEnergyBurned"])))
            }
        }
        return Dashboard(fetchedAt: fetchedAt, series: series, workouts: list.sorted { $0.start > $1.start })
    }

    private static func number(_ v: JSON?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }

    private static func date(_ v: JSON?) -> Date? {
        v?.stringValue.flatMap { TemplateFilters.date(.string($0)) }
    }

    private static func quantity(_ v: JSON?) -> String? {
        guard let qty = number(v?["qty"]) else { return nil }
        return "\(qty.formatted(.number.precision(.fractionLength(0...1)))) \(v?["units"]?.stringValue ?? "")"
    }

    private static func point(_ row: JSON) -> Point? {
        guard let at = date(row["date"]) else { return nil }
        if let avg = number(row["Avg"]) { return Point(date: at, value: avg, low: number(row["Min"]), high: number(row["Max"])) }
        if let sleep = number(row["totalSleep"]) { return Point(date: at, value: sleep) }
        if let systolic = number(row["systolic"]) { return Point(date: at, value: systolic, low: number(row["diastolic"]), high: systolic) }
        if let qty = number(row["qty"]) { return Point(date: at, value: qty) }
        return nil
    }

    /// Fetches days' metrics by day, and workouts.
    public static func fetch(from source: PhoneSource, days: Int, now: Date = Date(), calendar: Calendar = .local()) async throws -> Dashboard {
        let today = Day(now, calendar: calendar)
        let start = today.adding(1 - max(days, 1))
        let metrics = try await source.read(.metrics, start: start, end: today, grouping: .days)
        let workouts = try await source.read(.workouts, start: start, end: today, grouping: nil)
        return build(metrics: metrics, workouts: workouts, fetchedAt: now)
    }
}
