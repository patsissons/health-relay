import Foundation

/// Answers questions about Health from tools on the same network, over MCP or
/// plain JSON-RPC. There's one tool per kind of data, and each returns the same
/// JSON a pipeline writes, so anything that reads one reads the other.
public struct MCPHandler: Sendable {
    public struct Tool: Sendable, Equatable {
        public let name: String
        public let section: ExtractSpec.Section
        public let about: String
    }

    public static let tools: [Tool] = [
        Tool(name: "health_metrics", section: .metrics, about: "Health metrics such as steps, heart rate, sleep and weight, grouped over time."),
        Tool(name: "workouts", section: .workouts, about: "Workouts with their statistics, activities and events."),
        Tool(name: "symptoms", section: .symptoms, about: "Logged symptoms with their severity."),
        Tool(name: "ecg", section: .ecg, about: "ECG recordings with their classification."),
        Tool(name: "heart_rate_notifications", section: .heartRateNotifications, about: "High and low heart rate and irregular rhythm notifications."),
        Tool(name: "state_of_mind", section: .stateOfMind, about: "Logged moods and emotions."),
        Tool(name: "cycle_tracking", section: .cycleTracking, about: "Cycle tracking entries."),
        Tool(name: "medications", section: .medications, about: "Medication doses, for medications shared with this app."),
    ]

    /// Output is held in memory to answer, so a tool's answer stops here.
    public static let maxOutput = 8 << 20
    public static let protocolVersion = "2025-06-18"

    public let store: HealthQuerying
    public let calendar: Calendar
    public let device: Device
    public let now: @Sendable () -> Date
    /// How far back an answer may reach (see `HistoryLimit`).
    public let history: @Sendable () -> HistoryLimit

    public init(store: HealthQuerying, calendar: Calendar, device: Device, now: @escaping @Sendable () -> Date = { Date() },
                history: @escaping @Sendable () -> HistoryLimit = { .unlimited }) {
        self.store = store
        self.calendar = calendar
        self.device = device
        self.now = now
        self.history = history
    }

    /// One JSON-RPC message in; the reply, or nil for a notification.
    public func handle(_ message: JSON) async -> JSON? {
        let id = message["id"]
        guard case .object = message, let method = message["method"]?.stringValue else {
            return Self.failure(id ?? .null, -32600, "That isn't a JSON-RPC request.")
        }
        // A message with no id expects no reply, whatever it asks.
        guard let id else { return nil }
        switch method {
        case "initialize":
            let asked = message["params"]?["protocolVersion"]?.stringValue
            return Self.success(id, .object([
                "protocolVersion": .string(asked ?? Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": "health-data-relay", "version": .string(device.app)]),
            ]))
        case "ping":
            return Self.success(id, .object([:]))
        case "tools/list":
            return Self.success(id, .object(["tools": .array(Self.tools.map(Self.describe))]))
        case "tools/call":
            guard let name = message["params"]?["name"]?.stringValue, let tool = Self.tools.first(where: { $0.name == name }) else {
                return Self.failure(id, -32602, "There's no tool by that name.")
            }
            return Self.success(id, await call(tool, message["params"]?["arguments"] ?? .object([:])))
        default:
            return Self.failure(id, -32601, "There's no method by that name.")
        }
    }

    private static func success(_ id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(_ id: JSON, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private static func describe(_ tool: Tool) -> JSON {
        var properties: [String: JSON] = [
            "start": ["type": "string", "description": "From this date, as yyyy-MM-dd. Defaults to 7 days ago."],
            "end": ["type": "string", "description": "Through this date, as yyyy-MM-dd. Defaults to today."],
        ]
        if tool.section == .metrics {
            properties["metrics"] = ["type": "array", "items": ["type": "string"], "description": "Metric names like step_count. Defaults to all of them."]
            properties["grouping"] = ["type": "string", "enum": .array(TimeGrouping.allCases.map { .string($0.rawValue) }), "description": "How values combine. Defaults to days."]
        }
        if tool.section == .workouts {
            properties["routes"] = ["type": "boolean", "description": "Include each workout's GPS route, which is long. Defaults to false."]
            properties["detail"] = ["type": "boolean", "description": "Include each workout's activities, events, segments and splits, which are long. Defaults to false."]
        }
        return .object(["name": .string(tool.name), "description": .string(tool.about), "inputSchema": ["type": "object", "properties": .object(properties)]])
    }

    /// A tool's trouble is its answer, flagged, so a model can read and fix it.
    private func call(_ tool: Tool, _ args: JSON) async -> JSON {
        func problem(_ text: String) -> JSON {
            ["content": [["type": "text", "text": .string(text)]], "isError": .bool(true)]
        }
        let today = Day(now(), calendar: calendar)
        func day(_ key: String, _ fallback: Day) -> Day? {
            guard let text = args[key]?.stringValue else { return fallback }
            return Day(text)
        }
        guard let start = day("start", today.adding(-7)), let end = day("end", today) else {
            return problem("Dates are written yyyy-MM-dd.")
        }
        guard start <= end else { return problem("The start date is after the end date.") }
        let asked = DateInterval(start: start.start(in: calendar), end: end.adding(1).start(in: calendar))
        let limit = history()
        guard let range = limit.clamp(asked, now: now(), calendar: calendar) else {
            let first = limit.firstDay(now: now(), calendar: calendar).map(\.description) ?? ""
            return problem("This plan reads the last \(limit.days ?? 0) days. Ask for dates from \(first) on, or unlock Health Data Relay Full in the app for older data.")
        }
        var spec = ExtractSpec(sections: [tool.section], range: .fixed(range), grouping: .days)
        spec.workouts.series = false
        spec.workouts.routes = false
        if case .bool(true)? = args["routes"] { spec.workouts.routes = true }
        spec.workouts.summaryOnly = true
        if case .bool(true)? = args["detail"] { spec.workouts.summaryOnly = false }
        if case .array(let names)? = args["metrics"] { spec.metrics = .only(names.compactMap(\.stringValue)) }
        if let text = args["grouping"]?.stringValue {
            guard let grouping = TimeGrouping(rawValue: text) else { return problem("Grouping is one of \(TimeGrouping.allCases.map(\.rawValue).joined(separator: ", ")).") }
            spec.grouping = grouping
        }
        do {
            let extractor = Extractor(store: store, spec: spec, calendar: calendar, ranges: [range])
            let sink = MemorySink()
            let export = ExportInfo(device: device, generatedAt: now(), timeZone: calendar.timeZone)
            let limits = TemplateLimits(outputBytes: Self.maxOutput, deadline: Date().addingTimeInterval(60))
            _ = try await TemplateTransformer(template: BuiltInTemplates.template(BuiltInTemplates.metricsJSONv2), limits: limits).run(extractor: extractor, export: export) { _, _ in sink }
            var content: [JSON] = [["type": "text", "text": .string(sink.string)]]
            if range != asked {
                // After the data, so a client that reads only the first item still gets it.
                content.append(["type": "text", "text": .string("Only dates from \(Day(range.start, calendar: calendar)) on are included: this plan reads the last \(limit.days ?? 0) days. Health Data Relay Full reads older data.")])
            }
            return ["content": .array(content)]
        } catch let error as TemplateError where error.message.contains("size limit") {
            return problem("That's too much for one answer. Ask for fewer days, fewer metrics or a coarser grouping.")
        } catch {
            return problem(String(describing: error))
        }
    }
}

/// What a request looked like, as far as this server cares.
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

enum HTTPParser {
    static let maxBody = 1 << 20
    static let maxHead = 16 << 10

    enum Result: Equatable {
        case incomplete
        case done(HTTPRequest, consumed: Int)
        case invalid(status: Int)
    }

    static func parse(_ data: Data) -> Result {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead ? .invalid(status: 431) : .incomplete
        }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard first.count == 3 else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Chunked bodies aren't needed by any client seen, and would only add risk.
        if headers["transfer-encoding"] != nil { return .invalid(status: 411) }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length >= 0, length <= maxBody else { return .invalid(status: 413) }
        let total = (end.upperBound - data.startIndex) + length
        guard data.count >= total else { return .incomplete }
        let body = Data(data[end.upperBound..<(data.startIndex + total)])
        return .done(HTTPRequest(method: first[0], path: first[1], headers: headers, body: body), consumed: total)
    }

    static func response(status: Int, json: Data? = nil, headers: [String: String] = [:]) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error"][status] ?? "Error"
        let body = json ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// HTTP in front of the handler, requiring a bearer token. The comparison takes
/// the same time however much of a wrong token is right.
public struct MCPHTTPEndpoint: Sendable {
    public let handler: MCPHandler
    public let token: String

    public init(handler: MCPHandler, token: String) {
        self.handler = handler
        self.token = token
    }

    static func sameToken(_ a: String, _ b: String) -> Bool {
        let (x, y) = (Array(a.utf8), Array(b.utf8))
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            difference |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return difference == 0
    }

    func respond(_ request: HTTPRequest) async -> Data {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard path == "/mcp" else { return HTTPParser.response(status: 404) }
        guard let auth = request.headers["authorization"], auth.hasPrefix("Bearer "), Self.sameToken(String(auth.dropFirst(7)), token), !token.isEmpty else {
            return HTTPParser.response(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        // A page in a browser can reach a local server but can't set this bearer
        // token without a preflight this server never approves.
        guard request.method == "POST" else { return HTTPParser.response(status: 405, headers: ["Allow": "POST"]) }
        guard let message = JSON.parse(request.body) else {
            return HTTPParser.response(status: 400, json: JSON.object(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "That isn't JSON."]]).data)
        }
        guard let reply = await handler.handle(message) else { return HTTPParser.response(status: 202) }
        return HTTPParser.response(status: 200, json: reply.data)
    }
}
