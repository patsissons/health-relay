import CryptoKit
import Foundation
import Testing
@testable import HealthDataRelayKit

private let cal = Calendar.local(T.vancouver)
private let at = T.date("2026-10-25 12:00:00 -0700")

private func handler(_ store: HealthQuerying? = nil) -> MCPHandler {
    MCPHandler(store: store ?? RichData.store(), calendar: cal, device: FixtureTests.device, now: { at })
}

private func call(_ name: String, _ args: JSON = .object([:])) -> JSON {
    ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": args]]
}

@Suite struct MCPHandlerTests {
    @Test func theHandshake() async throws {
        let reply = await handler().handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect(reply?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply?["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply?["result"]?["serverInfo"]?["name"] == "health-data-relay")
        #expect(reply?["id"] == 1)
    }

    @Test func aNotificationGetsNoReply() async {
        #expect(await handler().handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func thereAreEightTools() async throws {
        let reply = await handler().handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        guard case .array(let tools)? = reply?["result"]?["tools"] else {
            Issue.record("no tools")
            return
        }
        #expect(tools.count == 8)
        for t in tools {
            #expect(t["description"]?.stringValue?.isEmpty == false)
            #expect(t["inputSchema"]?["type"] == "object")
        }
    }

    @Test func everyToolAnswersFromItsSection() async throws {
        let cases: [(String, String)] = [("health_metrics", "step_count"), ("workouts", "Outdoor Run"), ("symptoms", "Fever"), ("ecg", "Sinus Rhythm"),
                                         ("heart_rate_notifications", "High Heart Rate"), ("state_of_mind", "Daily Mood"), ("cycle_tracking", "Menstrual Flow"), ("medications", "Vitamin")]
        for (name, want) in cases {
            let reply = await handler().handle(call(name, ["start": "2026-10-20", "end": "2026-10-25"]))
            guard case .array(let content)? = reply?["result"]?["content"], let text = content.first?["text"]?.stringValue else {
                Issue.record("\(name): no content")
                continue
            }
            #expect(text.contains(want), "\(name)")
            #expect(reply?["result"]?["isError"] == nil, "\(name)")
            #expect(JSON.parse(Data(text.utf8)) != nil, "\(name)")
        }
    }

    @Test func metricsCanBeChosenAndGrouped() async throws {
        let reply = await handler().handle(call("health_metrics", ["start": "2026-10-24", "end": "2026-10-24", "metrics": ["weight_body_mass"], "grouping": "hours"]))
        guard case .array(let content)? = reply?["result"]?["content"], let text = content.first?["text"]?.stringValue else { return }
        #expect(text.contains("weight_body_mass"))
        #expect(!text.contains("step_count"))
    }

    @Test func aBadArgumentIsAnAnswerAModelCanRead() async throws {
        for args: JSON in [["start": "yesterday"], ["start": "2026-10-25", "end": "2026-10-01"], ["grouping": "fortnights"]] {
            let reply = await handler().handle(call("health_metrics", args))
            #expect(reply?["result"]?["isError"] == .bool(true))
        }
    }

    @Test func tooMuchAsksForLess() async {
        let store = SyntheticHealthQuerying(start: at.addingTimeInterval(-500_000), count: 400_000)
        let reply = await handler(store).handle(call("health_metrics", ["metrics": ["step_count"], "grouping": "seconds"]))
        // The synthetic store has no buckets, so this only proves it finishes.
        #expect(reply?["result"] != nil)
    }

    @Test func unknownsAreJSONRPCErrors() async {
        #expect(await handler().handle(["jsonrpc": "2.0", "id": 1, "method": "nope"])?["error"]?["code"] == -32601)
        #expect(await handler().handle(call("nope"))?["error"]?["code"] == -32602)
        #expect(await handler().handle("not an object")?["error"]?["code"] == -32600)
    }
}

@Suite struct HTTPParserTests {
    @Test func aRequestParses() {
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .done(let r, let consumed) = HTTPParser.parse(raw) else {
            Issue.record("didn't parse")
            return
        }
        #expect(r.method == "POST")
        #expect(r.path == "/mcp")
        #expect(r.headers["authorization"] == "Bearer t")
        #expect(r.body == Data("{}".utf8))
        #expect(consumed == raw.count)
    }

    @Test func aPartialRequestWaits() {
        #expect(HTTPParser.parse(Data("POST /mcp".utf8)) == .incomplete)
        #expect(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)) == .incomplete)
    }

    @Test func hostileRequestsAreRefused() {
        #expect(HTTPParser.parse(Data(repeating: 65, count: HTTPParser.maxHead + 1)) == .invalid(status: 431))
        #expect(HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == .invalid(status: 413))
        #expect(HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid(status: 411))
        #expect(HTTPParser.parse(Data("nonsense\r\n\r\n".utf8)) == .invalid(status: 400))
        #expect(HTTPParser.parse(Data("POST / HTTP/1.1\r\nbad header\r\n\r\n".utf8)) == .invalid(status: 400))
    }
}

@Suite struct MCPEndpointTests {
    private let endpoint = MCPHTTPEndpoint(handler: handler(), token: "right")

    private func status(_ data: Data) -> Int {
        Int(String(decoding: data.prefix(12), as: UTF8.self).split(separator: " ")[1]) ?? 0
    }

    private func request(token: String?, method: String = "POST", path: String = "/mcp", body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test func aWrongTokenGets401() async {
        #expect(status(await endpoint.respond(request(token: "wrong"))) == 401)
        #expect(status(await endpoint.respond(request(token: nil))) == 401)
        #expect(status(await endpoint.respond(request(token: "righ"))) == 401)
        #expect(status(await endpoint.respond(request(token: "rightt"))) == 401)
    }

    @Test func noTokenConfiguredRefusesEveryone() async {
        let open = MCPHTTPEndpoint(handler: handler(), token: "")
        #expect(status(await open.respond(request(token: ""))) == 401)
    }

    @Test func theRightTokenGetsIn() async {
        let out = await endpoint.respond(request(token: "right"))
        #expect(status(out) == 200)
        #expect(String(decoding: out, as: UTF8.self).contains("\"result\":{}"))
    }

    @Test func otherPathsAndMethodsAreRefused() async {
        #expect(status(await endpoint.respond(request(token: "right", path: "/other"))) == 404)
        #expect(status(await endpoint.respond(request(token: "right", method: "GET"))) == 405)
    }

    @Test func notJSONIsABadRequest() async {
        #expect(status(await endpoint.respond(request(token: "right", body: "{"))) == 400)
    }

    @Test func aNotificationIsAccepted() async {
        #expect(status(await endpoint.respond(request(token: "right", body: #"{"jsonrpc":"2.0","method":"x"}"#))) == 202)
    }
}

/// Over real sockets.
@Suite struct LocalServerTests {
    @Test func httpOverASocket() async throws {
        let server = try LocalServer(kind: .http(MCPHTTPEndpoint(handler: handler(), token: "t"), identity: nil), port: 0)
        let port = try await server.start()
        defer { server.stop() }
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        r.httpMethod = "POST"
        r.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        r.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: r)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        if case .array(let tools)? = JSON.parse(data)?["result"]?["tools"] { #expect(tools.count == 8) } else { Issue.record("no tools") }
        r.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await URLSession(configuration: .ephemeral).data(for: r)
        #expect((refused as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test func tcpLineByLine() async throws {
        let server = try LocalServer(kind: .tcp(handler()), port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let c = MQTTConnection(host: "127.0.0.1", port: Int(port), tls: false)
        defer { c.close() }
        try await c.start()
        try await c.send(Data((#"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\nnot json\n").utf8))
        let out = try await c.readLines(2)
        #expect(JSON.parse(out[0])?["id"] == 7)
        #expect(JSON.parse(out[1])?["error"]?["code"] == -32700)
    }

    /// HDR_MCP_PORT=<port>: stays up on that port for tools/conformance's
    /// official MCP client, until it asks to stop by calling `ping` with id "stop".
    @Test func aServerForAClient() async throws {
        guard let port = ProcessInfo.processInfo.environment["HDR_MCP_PORT"].flatMap({ UInt16($0) }) else { return }
        let server = try LocalServer(kind: .http(MCPHTTPEndpoint(handler: handler(), token: "conformance-token"), identity: nil), port: port)
        _ = try await server.start()
        defer { server.stop() }
        let stopFile = ProcessInfo.processInfo.environment["HDR_MCP_STOP"] ?? ""
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: stopFile) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("The client never finished")
    }
}

extension MQTTConnection {
    /// For tests of line-based protocols.
    func readLines(_ count: Int) async throws -> [Data] {
        var out: [Data] = []
        var current = Data()
        while out.count < count {
            let byte = try await readByte()
            if byte == 10 {
                out.append(current)
                current = Data()
            } else {
                current.append(byte)
            }
        }
        return out
    }
}

#if os(macOS)
@Suite struct LocalCertificateTests {
    private func openssl(_ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func opensslAcceptsIt() throws {
        let cert = try LocalCertificate.make(names: ["localhost", "my-iphone.local"], addresses: ["127.0.0.1", "192.168.1.20"], now: at)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.pem")
        try cert.pem.write(to: file, atomically: true, encoding: .utf8)
        let (status, text) = try openssl(["x509", "-in", file.path, "-noout", "-text", "-fingerprint", "-sha256"])
        #expect(status == 0, "\(text)")
        for want in ["Health Data Relay on this iPhone", "prime256v1", "DNS:localhost", "DNS:my-iphone.local", "IP Address:127.0.0.1", "IP Address:192.168.1.20", "TLS Web Server Authentication", "CA:TRUE", "ecdsa-with-SHA256"] {
            #expect(text.contains(want), "\(want)")
        }
        #expect(text.contains(cert.fingerprint))
    }

    /// LibreSSL's `verify` checks the signature really is this key's.
    @Test func itsSignatureVerifies() throws {
        let cert = try LocalCertificate.make(names: ["localhost"], addresses: ["127.0.0.1"], now: Date())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.pem")
        try cert.pem.write(to: file, atomically: true, encoding: .utf8)
        let (status, text) = try openssl(["verify", "-CAfile", file.path, file.path])
        #expect(status == 0, "\(text)")
    }

    @Test func aMadeCertificateIsNew() throws {
        let a = try LocalCertificate.make(names: ["a"], addresses: [], now: at)
        let b = try LocalCertificate.make(names: ["a"], addresses: [], now: at)
        #expect(a.fingerprint != b.fingerprint)
    }
}
#endif
