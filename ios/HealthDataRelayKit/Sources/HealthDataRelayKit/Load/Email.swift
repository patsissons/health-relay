import Foundation

/// Emailing a run's output. SMTP and mail APIs run unattended with the user's
/// own account, and there's no server of ours in between. Compose hands it to
/// the user. A password or API key lives in the Keychain, with the pipeline's id.
public struct EmailTarget: Codable, Sendable, Equatable {
    public enum Method: Codable, Sendable, Equatable {
        case smtp(SMTPSettings)
        case api(MailAPI)
        /// The user sends it from Mail, Gmail or anything else, by tapping.
        case compose
    }

    public var method: Method
    public var from: String
    public var to: [String]
    /// A template, rendered once per run.
    public var subject: String
    public var body: String

    public init(method: Method, from: String = "", to: [String], subject: String = "Health data for {{ export.start | date: '%B %e' }}", body: String = "Your Health Data Relay export is attached.") {
        self.method = method
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
    }
}

public struct SMTPSettings: Codable, Sendable, Equatable {
    public enum Security: String, Codable, Sendable, CaseIterable {
        /// Starts plain, then upgrades. Refuses to go on if the server won't.
        case startTLS
        /// TLS from the first byte.
        case tls
        /// Nothing is encrypted: only for a server on your own network.
        case none
    }

    public var host: String
    public var port: Int
    public var security: Security
    public var username: String

    public init(host: String, port: Int = 587, security: Security = .startTLS, username: String = "") {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}

public enum MailAPI: String, Codable, Sendable, CaseIterable {
    case resend, sendGrid, postmark

    public var title: String {
        switch self {
        case .resend: "Resend"
        case .sendGrid: "SendGrid"
        case .postmark: "Postmark"
        }
    }
}

/// An email to send, with one file attached.
struct EmailMessage: Sendable {
    var from: String
    var to: [String]
    var subject: String
    var body: String
    var attachment: URL
    var attachmentName: String
    var attachmentType: String
    /// Stable across retries, so a server can recognise a repeat.
    var messageID: String
    var date: Date
}

/// RFC 5322 and MIME, streamed so a large attachment isn't held in memory.
enum MIMEWriter {
    /// Removes what could start a new header.
    static func headerSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
    }

    /// RFC 2047 for a header with anything but plain ASCII.
    static func encodedHeader(_ s: String) -> String {
        let safe = headerSafe(s)
        guard safe.utf8.contains(where: { $0 >= 0x80 }) else { return safe }
        return "=?UTF-8?B?\(Data(safe.utf8).base64EncodedString())?="
    }

    static func dateHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return f.string(from: date)
    }

    /// Lines beginning with a dot get another, as SMTP's DATA needs, and all
    /// line endings become CRLF.
    static func bodyLines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix(".") ? "." + $0 : String($0) }.joined(separator: "\r\n")
    }

    /// Writes the message to `out`, ready to send after DATA, without the end marker.
    static func write(_ m: EmailMessage, to out: URL) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: FileStore.partAttributes)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        let boundary = "hdr-\(m.messageID)"
        let name = headerSafe(m.attachmentName).replacingOccurrences(of: "\"", with: "'")
        var head = ""
        head += "From: \(headerSafe(m.from))\r\n"
        head += "To: \(m.to.map(headerSafe).joined(separator: ", "))\r\n"
        head += "Subject: \(encodedHeader(m.subject))\r\n"
        head += "Date: \(dateHeader(m.date))\r\n"
        head += "Message-ID: <\(m.messageID)@health-data-relay>\r\n"
        head += "MIME-Version: 1.0\r\n"
        head += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        head += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        head += bodyLines(m.body)
        head += "\r\n--\(boundary)\r\nContent-Type: \(headerSafe(m.attachmentType)); name=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\n\r\n"
        try writer.write(contentsOf: Data(head.utf8))
        let reader = try FileHandle(forReadingFrom: m.attachment)
        defer { try? reader.close() }
        // Whole multiples of 3 keep the base64 continuous; 57 bytes make a 76-column line.
        while let chunk = try reader.read(upToCount: 57 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            try writer.write(contentsOf: Data("\r\n".utf8))
        }
        try writer.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }

    /// An address's bare mailbox, for SMTP's envelope: `Name <a@b.c>` -> `a@b.c`.
    static func mailbox(_ address: String) -> String {
        if let open = address.lastIndex(of: "<"), let close = address.lastIndex(of: ">"), open < close {
            return String(address[address.index(after: open)..<close])
        }
        return address.trimmingCharacters(in: .whitespaces)
    }
}

/// Sends one message over SMTP.
struct SMTPClient: Sendable {
    struct Reply: Equatable {
        var code: Int
        var text: String
    }

    let settings: SMTPSettings
    let password: String?
    /// Tests only: a local check has a self-signed certificate. Not reachable from a target.
    var trustAnyCertificate = false
    var timeout: TimeInterval = 60

    private func delivery(_ reply: Reply, doing: String) -> Delivery {
        let message = "\(doing): \(reply.code) \(reply.text)"
        // Auth refused, however the server words it.
        if reply.code == 535 || reply.code == 534 || reply.code == 530 { return Delivery(status: reply.code, verdict: .authFailed, message: message) }
        if (400..<500).contains(reply.code) { return Delivery(status: reply.code, verdict: .retry, message: message) }
        return Delivery(status: reply.code, verdict: .rejected, message: message)
    }

    func send(_ m: EmailMessage, file: URL) async -> Delivery {
        let stream = SMTPStream(host: settings.host, port: settings.port, trustAnyCertificate: trustAnyCertificate, timeout: timeout)
        defer { stream.close() }
        do {
            if settings.security == .tls { stream.startTLS() }
            var r = try await stream.reply()
            guard r.code == 220 else { return delivery(r, doing: "Connecting") }
            let name = "health-data-relay.local"
            r = try await stream.command("EHLO \(name)")
            guard r.code == 250 else { return delivery(r, doing: "Greeting") }
            if settings.security == .startTLS {
                // Never fall back to sending a password or health data in the clear.
                guard r.text.uppercased().contains("STARTTLS") else {
                    return Delivery(status: nil, verdict: .rejected, message: "This server doesn't offer STARTTLS, so nothing was sent.")
                }
                r = try await stream.command("STARTTLS")
                guard r.code == 220 else { return delivery(r, doing: "Starting TLS") }
                stream.startTLS()
                r = try await stream.command("EHLO \(name)")
                guard r.code == 250 else { return delivery(r, doing: "Greeting") }
            }
            if !settings.username.isEmpty {
                let caps = r.text.uppercased()
                if caps.contains("PLAIN") {
                    let token = Data("\u{0}\(settings.username)\u{0}\(password ?? "")".utf8).base64EncodedString()
                    r = try await stream.command("AUTH PLAIN \(token)")
                } else if caps.contains("LOGIN") {
                    r = try await stream.command("AUTH LOGIN")
                    guard r.code == 334 else { return delivery(r, doing: "Signing in") }
                    r = try await stream.command(Data(settings.username.utf8).base64EncodedString())
                    guard r.code == 334 else { return delivery(r, doing: "Signing in") }
                    r = try await stream.command(Data((password ?? "").utf8).base64EncodedString())
                } else {
                    return Delivery(status: nil, verdict: .rejected, message: "This server has no sign-in method the app supports.")
                }
                guard r.code == 235 else { return delivery(r, doing: "Signing in") }
            }
            r = try await stream.command("MAIL FROM:<\(MIMEWriter.mailbox(m.from))>")
            guard r.code == 250 else { return delivery(r, doing: "Sender") }
            for address in m.to {
                r = try await stream.command("RCPT TO:<\(MIMEWriter.mailbox(address))>")
                guard r.code == 250 || r.code == 251 else { return delivery(r, doing: "Recipient \(address)") }
            }
            r = try await stream.command("DATA")
            guard r.code == 354 else { return delivery(r, doing: "Sending") }
            try await stream.send(file: file)
            try await stream.write(Data(".\r\n".utf8))
            r = try await stream.reply()
            guard r.code == 250 else { return delivery(r, doing: "Sending") }
            _ = try? await stream.command("QUIT")
            return Delivery(status: 250, verdict: .accepted, message: "Emailed to \(m.to.joined(separator: ", "))")
        } catch {
            return Delivery(status: nil, verdict: .retry, message: "Couldn't reach the mail server: \(error.localizedDescription)")
        }
    }
}

/// SMTP over URLSession's stream task, which alone can upgrade to TLS midway.
final class SMTPStream: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let task: URLSessionStreamTask
    private let trustAnyCertificate: Bool
    private let timeout: TimeInterval
    private var pending = Data()

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    init(host: String, port: Int, trustAnyCertificate: Bool, timeout: TimeInterval) {
        self.trustAnyCertificate = trustAnyCertificate
        self.timeout = timeout
        let holder = DelegateHolder()
        session = URLSession(configuration: .ephemeral, delegate: holder, delegateQueue: nil)
        task = session.streamTask(withHostName: host, port: port)
        super.init()
        holder.trustAny = trustAnyCertificate
        task.resume()
    }

    private final class DelegateHolder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var trustAny = false

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if trustAny, let trust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }
    }

    func startTLS() {
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.closeRead()
        session.invalidateAndCancel()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: timeout) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func send(file: URL) async throws {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 16), !chunk.isEmpty {
            try await write(chunk)
        }
    }

    private func readSome() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            task.readData(ofMinLength: 1, maxLength: 1 << 16, timeout: timeout) { data, eof, error in
                if let error {
                    c.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if eof {
                    c.resume(throwing: Failure(errorDescription: "The server closed the connection"))
                } else {
                    c.resume(returning: Data())
                }
            }
        }
    }

    private func line() async throws -> String {
        while true {
            if let at = pending.firstRange(of: Data("\r\n".utf8)) {
                let out = String(decoding: pending[pending.startIndex..<at.lowerBound], as: UTF8.self)
                pending = Data(pending[at.upperBound...])
                return out
            }
            pending.append(try await readSome())
        }
    }

    /// One reply, however many lines. Their text is joined with spaces.
    func reply() async throws -> SMTPClient.Reply {
        var text: [String] = []
        while true {
            let l = try await line()
            guard l.count >= 3, let code = Int(l.prefix(3)) else { throw Failure(errorDescription: "That doesn't look like a mail server") }
            text.append(String(l.dropFirst(4)))
            if l.dropFirst(3).first != "-" { return SMTPClient.Reply(code: code, text: text.joined(separator: " ")) }
        }
    }

    func command(_ text: String) async throws -> SMTPClient.Reply {
        try await write(Data((text + "\r\n").utf8))
        return try await reply()
    }
}

/// Requests for the mail APIs. Each takes the file base64-encoded in JSON, so
/// it's capped at the size they accept anyway.
enum MailAPIRequest {
    static let maxBytes = 25 << 20

    static func make(_ api: MailAPI, key: String, m: EmailMessage, content: Data) -> URLRequest {
        let attachment = content.base64EncodedString()
        var r: URLRequest
        let body: JSON
        let toList: [JSON] = m.to.map { .string($0) }
        switch api {
        case .resend:
            r = URLRequest(url: URL(string: "https://api.resend.com/emails")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.setValue(m.messageID, forHTTPHeaderField: "Idempotency-Key")
            body = .object(["from": .string(m.from), "to": .array(toList), "subject": .string(m.subject), "text": .string(m.body),
                            "attachments": .array([.object(["filename": .string(m.attachmentName), "content": .string(attachment)])])])
        case .sendGrid:
            r = URLRequest(url: URL(string: "https://api.sendgrid.com/v3/mail/send")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = .object(["personalizations": .array([.object(["to": .array(m.to.map { .object(["email": .string(MIMEWriter.mailbox($0))]) })])]),
                            "from": .object(["email": .string(MIMEWriter.mailbox(m.from))]), "subject": .string(m.subject),
                            "content": .array([.object(["type": "text/plain", "value": .string(m.body)])]),
                            "attachments": .array([.object(["filename": .string(m.attachmentName), "content": .string(attachment), "type": .string(m.attachmentType), "disposition": "attachment"])])])
        case .postmark:
            r = URLRequest(url: URL(string: "https://api.postmarkapp.com/email")!)
            r.setValue(key, forHTTPHeaderField: "X-Postmark-Server-Token")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            body = .object(["From": .string(m.from), "To": .string(m.to.joined(separator: ",")), "Subject": .string(m.subject), "TextBody": .string(m.body),
                            "Attachments": .array([.object(["Name": .string(m.attachmentName), "Content": .string(attachment), "ContentType": .string(m.attachmentType)])])])
        }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body.data
        return r
    }
}

/// Sends a run's output by email, once all its parts are ready: one file, or a ZIP.
public struct EmailTransport: ArtifactTransport {
    public let target: EmailTarget
    public let files: FileStore
    public let context: TransportContext
    public let session: URLSession
    var trustAnyCertificate = false

    public init(target: EmailTarget, files: FileStore, context: TransportContext, session: URLSession = .shared) {
        self.target = target
        self.files = files
        self.context = context
        self.session = session
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        // Only the last part sends: one email per run, with everything in it.
        guard part.file == artifact.parts.last?.file else {
            return Delivery(status: nil, verdict: .accepted, message: "Packaged with the rest")
        }
        let folder = file.deletingLastPathComponent()
        do {
            let packaged = folder.appendingPathComponent("email", isDirectory: true)
            try? FileManager.default.removeItem(at: packaged)
            try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: packaged) }
            var copies: [(url: URL, name: String)] = []
            for (i, p) in artifact.parts.enumerated() {
                let copy = packaged.appendingPathComponent("copy-\(i)")
                try FileManager.default.copyItem(at: files.partFile(p, artifact: artifact.id, pipeline: context.pipelineID), to: copy)
                copies.append((copy, p.filename))
            }
            let range = DateInterval(start: artifact.createdAt, duration: 0)
            let attachment = try SharePackager.package(copies, into: packaged, zipName: OneOffExport.zipName(context.pipelineName, range: range, calendar: .local()))
            let isZip = artifact.parts.count > 1
            let message = EmailMessage(from: target.from, to: target.to, subject: part.destination ?? target.subject, body: target.body, attachment: attachment,
                                       attachmentName: attachment.lastPathComponent, attachmentType: isZip ? "application/zip" : part.contentType,
                                       messageID: artifact.id.uuidString.lowercased(), date: artifact.createdAt)
            switch target.method {
            case .smtp(let settings):
                let wire = packaged.appendingPathComponent("message.eml")
                try MIMEWriter.write(message, to: wire)
                var client = SMTPClient(settings: settings, password: context.token)
                client.trustAnyCertificate = trustAnyCertificate
                return await client.send(message, file: wire)
            case .api(let api):
                let size = (try? attachment.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= MailAPIRequest.maxBytes else {
                    return Delivery(status: nil, verdict: .rejected, message: "The attachment is over 25 MB, more than mail APIs accept.")
                }
                let request = MailAPIRequest.make(api, key: context.token ?? "", m: message, content: try Data(contentsOf: attachment))
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return Delivery(status: status, verdict: Delivery.verdict(for: status), message: Delivery.message(status: status, body: data))
            case .compose:
                return Delivery(status: nil, verdict: .rejected, message: "Compose needs a tap, so it doesn't send from here.")
            }
        } catch {
            return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
        }
    }
}
