import Foundation

/// Where a pipeline's output goes. The native push still uses
/// `Destination.Kind.http`; everything a template writes comes through here.
public enum LoadTarget: Codable, Sendable, Equatable {
    case web(WebTarget)
    /// Written to a file for the user to send on with the share sheet.
    case share

    /// What the screens call its destination.
    public var summary: String {
        switch self {
        case .web(let web):
            URL(string: web.url)?.host() ?? web.url
        case .share:
            "Share sheet"
        }
    }
}

/// An HTTP request per part. Its bearer token lives in the Keychain, with the
/// pipeline's id, like a destination's.
public struct WebTarget: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        case post = "POST", put = "PUT", patch = "PATCH"
    }

    public enum Body: Codable, Sendable, Equatable {
        /// The part as the request body.
        case raw
        /// The part as a file in a multipart form, under this field.
        case multipart(field: String)
    }

    /// May be a template, rendered per part: `.../{{ partition.key }}.json`.
    public var url: String
    public var method: Method
    public var headers: [HTTPEndpoint.Header]
    public var timeout: TimeInterval
    public var body: Body
    /// Sends `automation-name`, `automation-id`, `automation-aggregation`,
    /// `automation-period` and `session-id`, which some receivers read.
    public var automationHeaders: Bool

    public init(url: String, method: Method = .post, headers: [HTTPEndpoint.Header] = [], timeout: TimeInterval = 60, body: Body = .raw, automationHeaders: Bool = true) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
        self.body = body
        self.automationHeaders = automationHeaders
    }
}

/// Which template a pipeline uses.
public enum TemplateRef: Codable, Sendable, Equatable, Hashable {
    case builtIn(String)
    case custom(UUID)
}

/// What a pipeline reads and how it writes it, for a pipeline that isn't the
/// native push. Saved beside its destination, under the same id.
public struct PipelineDefinition: Codable, Sendable, Equatable {
    public var extract: ExtractSpec
    public var template: TemplateRef
    /// The template's name, kept so a card can show it without parsing.
    public var templateName: String

    public init(extract: ExtractSpec, template: TemplateRef, templateName: String) {
        self.extract = extract
        self.template = template
        self.templateName = templateName
    }

    /// Whether it follows dirty days, as the native push does.
    public var usesDirtyDays: Bool { extract.range == .changedDays }
}

/// Delivers one finished part.
public protocol ArtifactTransport: Sendable {
    func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery
}

/// For a target the engine handles itself.
struct RefusingTransport: ArtifactTransport {
    func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        Delivery(status: nil, verdict: .rejected, message: "This target can't send from here")
    }
}

/// What a transport needs to know about the pipeline.
public struct TransportContext: Sendable {
    public var pipelineID: UUID
    public var pipelineName: String
    public var extract: ExtractSpec
    public var token: String?

    public init(pipelineID: UUID, pipelineName: String, extract: ExtractSpec, token: String?) {
        self.pipelineID = pipelineID
        self.pipelineName = pipelineName
        self.extract = extract
        self.token = token
    }
}

/// Sends parts over HTTP, streaming each from its file so its size costs no memory.
public struct WebTransport: ArtifactTransport {
    public let target: WebTarget
    public let context: TransportContext
    public let session: URLSession

    public init(target: WebTarget, context: TransportContext, session: URLSession = .shared) {
        self.target = target
        self.context = context
        self.session = session
    }

    func request(part: ArtifactPart, contentType: String) -> URLRequest? {
        guard let url = URL(string: part.destination ?? target.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: target.timeout)
        r.httpMethod = target.method.rawValue
        for h in target.headers where !h.name.isEmpty { r.setValue(h.value, forHTTPHeaderField: h.name) }
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token = context.token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if target.automationHeaders {
            r.setValue(context.pipelineName, forHTTPHeaderField: "automation-name")
            r.setValue(context.pipelineID.uuidString, forHTTPHeaderField: "automation-id")
            r.setValue(Self.aggregation(context.extract.grouping), forHTTPHeaderField: "automation-aggregation")
            r.setValue(Self.period(context.extract.range), forHTTPHeaderField: "automation-period")
            r.setValue(UUID().uuidString, forHTTPHeaderField: "session-id")
        }
        return r
    }

    static func aggregation(_ grouping: TimeGrouping?) -> String {
        switch grouping {
        case nil: "None"
        case .automatic?: "Default"
        case .seconds?: "Seconds"
        case .minutes?: "Minutes"
        case .hours?: "Hours"
        case .days?: "Days"
        case .weeks?: "Weeks"
        case .months?: "Months"
        case .years?: "Years"
        }
    }

    static func period(_ range: RangeSpec) -> String {
        switch range {
        case .changedDays: "Default"
        case .sinceLastRun: "SinceLastSync"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previousDays(let n): n == 7 ? "Previous7Days" : "Previous\(n)Days"
        case .lastDays(let n): "Last\(n)Days"
        case .fixed, .askAtRun: "Custom"
        }
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        var upload = file
        var contentType = part.contentType
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        if case .multipart(let field) = target.body {
            // The same boundary on every attempt, since a retry sends the same bytes.
            let boundary = "hdr-\(artifact.id.uuidString)"
            let wrapped = file.appendingPathExtension("multipart")
            do {
                try Self.writeMultipart(file: file, field: field, filename: part.filename, contentType: part.contentType, boundary: boundary, to: wrapped)
            } catch {
                return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
            }
            upload = wrapped
            cleanup = wrapped
            contentType = "multipart/form-data; boundary=\(boundary)"
        }
        guard let request = request(part: part, contentType: contentType) else {
            return Delivery(status: nil, verdict: .rejected, message: "That isn't an http or https URL: \(part.destination ?? target.url)")
        }
        do {
            let (data, response) = try await session.upload(for: request, fromFile: upload)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Delivery(status: status, verdict: Delivery.verdict(for: status), message: Delivery.message(status: status, body: data))
        } catch {
            return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
        }
    }

    /// Writes a one-file multipart form, streaming the file through.
    static func writeMultipart(file: URL, field: String, filename: String, contentType: String, boundary: String, to out: URL) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: FileStore.partAttributes)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        let safeName = filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        try writer.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 16), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
