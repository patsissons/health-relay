import Foundation
import Network
import Testing
@testable import HealthDataRelayKit

/// A minimal SMTP server on a local port, so the client is tested over a real socket.
final class FakeSMTP: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-smtp")
    private let lock = NSLock()
    private var inData = false
    private var buffer = Data()
    private(set) var commands: [String] = []
    private(set) var message = Data()
    var capabilities = ["SIZE 1000000", "AUTH PLAIN LOGIN"]
    var answers: [String: String] = [:]

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            c.send(content: Data("220 fake ready\r\n".utf8), completion: .idempotent)
            self.read(c)
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
        var replies: [String] = []
        lock.withLock {
            buffer.append(data)
            while true {
                if inData {
                    let end = Data("\r\n.\r\n".utf8)
                    guard let r = buffer.firstRange(of: end) else { return }
                    message = Data(buffer[buffer.startIndex..<r.lowerBound])
                    buffer = Data(buffer[r.upperBound...])
                    inData = false
                    replies.append(answers["."] ?? "250 queued")
                    continue
                }
                guard let r = buffer.firstRange(of: Data("\r\n".utf8)) else { return }
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer = Data(buffer[r.upperBound...])
                commands.append(line)
                let verb = String(line.prefix { $0 != " " && $0 != ":" }).uppercased()
                if let answer = answers[verb] {
                    replies.append(answer)
                } else {
                    switch verb {
                    case "EHLO":
                        let caps = capabilities.enumerated().map { i, cap in "250\(i == capabilities.count - 1 ? " " : "-")\(cap)" }
                        replies.append((["250-fake"] + caps).joined(separator: "\r\n"))
                    case "AUTH": replies.append("235 ok")
                    case "DATA":
                        replies.append("354 go")
                        inData = true
                    case "QUIT": replies.append("221 bye")
                    default: replies.append("250 ok")
                    }
                }
            }
        }
        defer { for r in replies { c.send(content: Data((r + "\r\n").utf8), completion: .idempotent) } }
    }

    var text: String { lock.withLock { String(decoding: message, as: UTF8.self) } }
}

@Suite(.serialized) struct SMTPTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let date = T.date("2026-10-25 12:00:00 -0700")

    private func message(body: String = "Hello") throws -> EmailMessage {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let attachment = dir.appendingPathComponent("a.csv")
        try Data("date,steps\n2026-10-25,100\n".utf8).write(to: attachment)
        return EmailMessage(from: "Me <me@example.com>", to: ["you@example.com", "them@example.com"], subject: "Steps", body: body, attachment: attachment,
                            attachmentName: "a.csv", attachmentType: "text/csv", messageID: "abc", date: date)
    }

    private func send(_ server: FakeSMTP, username: String = "", password: String? = nil, security: SMTPSettings.Security = .none) async throws -> Delivery {
        let port = await server.start()
        let m = try message()
        let wire = dir.appendingPathComponent("m.eml")
        try MIMEWriter.write(m, to: wire)
        return await SMTPClient(settings: SMTPSettings(host: "127.0.0.1", port: port, security: security, username: username), password: password, timeout: 5).send(m, file: wire)
    }

    @Test func aMessageIsDelivered() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        let d = try await send(server)
        #expect(d.verdict == .accepted, "\(d.message)")
        #expect(server.commands.contains("MAIL FROM:<me@example.com>"))
        #expect(server.commands.contains("RCPT TO:<you@example.com>"))
        #expect(server.commands.contains("RCPT TO:<them@example.com>"))
        #expect(server.text.contains("Subject: Steps\r\n"))
        #expect(server.text.contains("filename=\"a.csv\""))
        let encoded = Data("date,steps\n2026-10-25,100\n".utf8).base64EncodedString()
        #expect(server.text.contains(encoded))
    }

    @Test func signsInWithPlain() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        let d = try await send(server, username: "me", password: "secret")
        #expect(d.verdict == .accepted)
        let token = Data("\u{0}me\u{0}secret".utf8).base64EncodedString()
        #expect(server.commands.contains("AUTH PLAIN \(token)"))
    }

    @Test func signsInWithLoginWhenThatsAllThereIs() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        server.capabilities = ["AUTH LOGIN"]
        server.answers["AUTH"] = "334 VXNlcm5hbWU6"
        server.answers[Data("me".utf8).base64EncodedString().uppercased()] = "334 UGFzc3dvcmQ6"
        server.answers[Data("secret".utf8).base64EncodedString().uppercased()] = "235 ok"
        let d = try await send(server, username: "me", password: "secret")
        #expect(d.verdict == .accepted, "\(d.message)")
    }

    @Test func aRefusedPasswordStopsThePipeline() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        server.answers["AUTH"] = "535 bad credentials"
        let d = try await send(server, username: "me", password: "wrong")
        #expect(d.verdict == .authFailed)
        #expect(server.message.isEmpty)
    }

    @Test func aBusyServerIsARetry() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        server.answers["MAIL"] = "451 try later"
        #expect(try await send(server).verdict == .retry)
    }

    @Test func aRefusedRecipientIsRefused() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        server.answers["RCPT"] = "550 no such user"
        let d = try await send(server)
        #expect(d.verdict == .rejected)
        #expect(d.message.contains("no such user"))
    }

    /// Credentials and health data never go in the clear because a server,
    /// or someone in the middle, said it couldn't do TLS.
    @Test func noStartTLSMeansNothingSent() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        let d = try await send(server, username: "me", password: "secret", security: .startTLS)
        #expect(d.verdict == .rejected)
        #expect(d.message.contains("STARTTLS"))
        #expect(!server.commands.contains { $0.hasPrefix("AUTH") || $0.hasPrefix("MAIL") })
    }

    @Test func noServerIsARetry() async throws {
        let m = try message()
        let wire = dir.appendingPathComponent("m2.eml")
        try MIMEWriter.write(m, to: wire)
        let d = await SMTPClient(settings: SMTPSettings(host: "127.0.0.1", port: 1, security: .none), password: nil, timeout: 2).send(m, file: wire)
        #expect(d.verdict == .retry)
    }

    /// HDR_SMTP_PORT=<port>: against the independent smtp-server in tools/conformance,
    /// with STARTTLS and a password.
    @Test func aRealServer() async throws {
        guard let port = ProcessInfo.processInfo.environment["HDR_SMTP_PORT"].flatMap(Int.init) else { return }
        let m = try message()
        let wire = dir.appendingPathComponent("real.eml")
        try MIMEWriter.write(m, to: wire)
        var client = SMTPClient(settings: SMTPSettings(host: "127.0.0.1", port: port, security: .startTLS, username: "me"), password: "secret", timeout: 10)
        client.trustAnyCertificate = true
        let d = await client.send(m, file: wire)
        #expect(d.verdict == .accepted, "\(d.message)")
    }
}

@Suite struct MIMETests {
    @Test func headersCantBeInjected() {
        #expect(MIMEWriter.headerSafe("x\r\nBcc: evil@example.com") == "x Bcc: evil@example.com")
    }

    @Test func aNonASCIISubjectIsEncoded() {
        #expect(MIMEWriter.encodedHeader("Steps") == "Steps")
        #expect(MIMEWriter.encodedHeader("Données") == "=?UTF-8?B?\(Data("Données".utf8).base64EncodedString())?=")
    }

    @Test func dotsAreStuffed() {
        #expect(MIMEWriter.bodyLines("a\n.b\nc") == "a\r\n..b\r\nc")
    }

    @Test func mailboxesAreBare() {
        #expect(MIMEWriter.mailbox("Me <me@example.com>") == "me@example.com")
        #expect(MIMEWriter.mailbox(" me@example.com ") == "me@example.com")
    }

    @Test func aLargeAttachmentDecodesExactly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a")
        let bytes = Data((0..<500_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: file)
        let out = dir.appendingPathComponent("m")
        try MIMEWriter.write(EmailMessage(from: "a@b.c", to: ["d@e.f"], subject: "s", body: "b", attachment: file, attachmentName: "a", attachmentType: "x/y", messageID: "id", date: Date()), to: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        let marker = "Content-Disposition: attachment; filename=\"a\"\r\n\r\n"
        let start = try #require(text.range(of: marker)).upperBound
        let end = try #require(text.range(of: "--hdr-id--")).lowerBound
        let encoded = text[start..<end].replacingOccurrences(of: "\r\n", with: "")
        #expect(Data(base64Encoded: encoded) == bytes)
        for line in text[start..<end].components(separatedBy: "\r\n") { #expect(line.count <= 76) }
    }
}

@Suite struct MailAPITests {
    private func message() -> EmailMessage {
        EmailMessage(from: "Me <me@example.com>", to: ["you@example.com"], subject: "S", body: "B", attachment: URL(fileURLWithPath: "/dev/null"), attachmentName: "a.csv", attachmentType: "text/csv", messageID: "id-1", date: Date())
    }

    private func body(_ r: URLRequest) throws -> JSON { try #require(JSON.parse(r.httpBody ?? Data())) }

    @Test func resendsRequest() throws {
        let r = MailAPIRequest.make(.resend, key: "k", m: message(), content: Data("hi".utf8))
        #expect(r.url?.absoluteString == "https://api.resend.com/emails")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        // A retry can't send it twice.
        #expect(r.value(forHTTPHeaderField: "Idempotency-Key") == "id-1")
        let b = try body(r)
        #expect(b["from"] == "Me <me@example.com>")
        #expect(b["attachments"] == [["filename": "a.csv", "content": .string(Data("hi".utf8).base64EncodedString())]])
    }

    @Test func sendGridsRequest() throws {
        let r = MailAPIRequest.make(.sendGrid, key: "k", m: message(), content: Data("hi".utf8))
        #expect(r.url?.host() == "api.sendgrid.com")
        let b = try body(r)
        #expect(b["from"]?["email"] == "me@example.com")
        #expect(b["personalizations"] == [["to": [["email": "you@example.com"]]]])
    }

    @Test func postmarksRequest() throws {
        let r = MailAPIRequest.make(.postmark, key: "k", m: message(), content: Data("hi".utf8))
        #expect(r.value(forHTTPHeaderField: "X-Postmark-Server-Token") == "k")
        #expect(try body(r)["TextBody"] == "B")
    }
}

@Suite(.serialized) struct EmailPipelineTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let cal = Calendar.local(T.vancouver)
    private let now = T.date("2026-10-25 12:00:00 -0700")

    private func engine(clock: TestClock? = nil, notify: @escaping @Sendable (PipelineNotice) -> Void = { _ in }) -> Engine {
        let cal = cal
        let clock = clock ?? TestClock(now)
        let queries = RichData.store()
        return Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: MemoryTokenStore(), device: { Device(name: $0, model: "m", os: "o", app: "a") },
                            calendar: { cal }, now: { clock.now }, pause: { _ in }, queries: queries, notify: notify))
    }

    private var definition: PipelineDefinition {
        PipelineDefinition(extract: ExtractSpec(sections: [.metrics, .workouts], range: .fixed(RichData.week), grouping: .days), template: .builtIn(BuiltInTemplates.healthReportMarkdown), templateName: "Markdown")
    }

    @Test func oneEmailPerRunWithAZip() async throws {
        let server = try FakeSMTP()
        defer { server.stop() }
        let port = await server.start()
        let e = engine()
        let target = LoadTarget.email(EmailTarget(method: .smtp(SMTPSettings(host: "127.0.0.1", port: port, security: .none)), from: "me@example.com", to: ["you@example.com"], subject: "From {{ export.start | date: '%Y-%m-%d' }}"))
        let d = await e.add(Destination(name: "Mail", kind: .target(target)), token: nil, definition: definition)
        await e.run(d.id)
        #expect(server.commands.filter { $0 == "DATA" }.count == 1)
        #expect(server.text.contains("Subject: From 2026-10-20"))
        #expect(server.text.contains("application/zip"))
        #expect(await e.snapshot.pipelines[0].destinationSummary == "you@example.com")
        #expect(await e.snapshot.pipelines[0].lane.runs?.count == 1)
    }

    @Test func composeWaitsWithAFileAndTellsYouWhenScheduled() async throws {
        let seen = NoticeBox()
        let clock = TestClock(now)
        let e = engine(clock: clock) { seen.add($0) }
        let target = LoadTarget.email(EmailTarget(method: .compose, to: ["you@example.com"]))
        let d = await e.add(Destination(name: "Mail", kind: .target(target)), token: nil, definition: definition)
        await e.run(d.id)
        #expect(FileStore(root: root).latestExport(d.id) != nil)
        // Tapped Run: they're here already.
        #expect(seen.seen.isEmpty)
        await e.setTrigger(d.id, .every(Schedule(count: 1, unit: .days, since: now)))
        clock.now = now.addingTimeInterval(90000)
        await e.runDue()
        #expect(seen.seen.map(\.body) == ["Your email is ready. Tap to compose it."])
    }
}
