import Foundation

/// What the app did and when, for working out why something didn't happen.
/// It holds no health values, only names, counts and messages.
public struct ActivityEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case run, pipeline, wake, notice
    }

    public var id = UUID()
    public var at: Date
    public var kind: Kind
    public var message: String

    public init(at: Date, kind: Kind, message: String) {
        self.at = at
        self.kind = kind
        self.message = message
    }
}

extension FileStore {
    private var activityURL: URL { root.appendingPathComponent("activity.jsonl") }

    /// Keeps about this many entries.
    public static let activityLimit = 2000

    public func logActivity(_ entry: ActivityEntry) {
        guard let line = try? JSONEncoder().encode(entry) else { return }
        let bytes = line + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: activityURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: activityURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// The newest entries, newest first.
    public func activity(limit: Int = FileStore.activityLimit) -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: activityURL) else { return [] }
        let lines = data.split(separator: 10)
        let decoder = JSONDecoder()
        return lines.suffix(limit).reversed().compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0)) }
    }

    /// Drops all but the newest entries. Run at launch, not on each write.
    public func trimActivity() {
        guard let data = try? Data(contentsOf: activityURL) else { return }
        let lines = data.split(separator: 10)
        guard lines.count > Self.activityLimit else { return }
        var kept = Data()
        for line in lines.suffix(Self.activityLimit) {
            kept.append(line)
            kept.append(10)
        }
        try? kept.write(to: activityURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var activityFile: URL { activityURL }
}

/// A file to attach to a bug report. It's made so it can be shared freely: no
/// health values, tokens, header values, URL paths or template text.
public enum Diagnostics {
    public struct AppInfo: Sendable {
        public var app: String
        public var os: String
        public var model: String

        public init(app: String, os: String, model: String) {
            self.app = app
            self.os = os
            self.model = model
        }
    }

    public static func summary(_ state: EngineState, info: AppInfo, now: Date) -> JSON {
        let pipelines: [JSON] = state.destinations.map { d in
            let lane = state.lanes[d.id]
            let definition = state.definitions?[d.id]
            let host: String
            let target: String
            switch d.kind {
            case .http(let e):
                target = "native http"
                host = e.url.host() ?? ""
            case .target(let t):
                target = t.kindName
                host = t.summary
            }
            return .object([
                "id": .string(d.id.uuidString),
                "target": .string(target),
                "host": .string(host),
                "paused": .bool(d.paused),
                "trigger": .string(String(describing: state.trigger(for: d.id)).components(separatedBy: "(").first ?? ""),
                "template": definition.map { .string($0.templateName) } ?? .null,
                "range": definition.map { .string(String(describing: $0.extract.range).components(separatedBy: "(").first ?? "") } ?? .null,
                "dirtyDays": .number(Double(lane?.dirty.count ?? 0)),
                "failures": .number(Double(lane?.failures ?? 0)),
                "needsAttention": .bool(lane?.attention != nil),
                "lastError": lane?.lastError.map { .string($0) } ?? .null,
                "lastRun": lane?.lastRun.map { .string(Stamp.utc($0)) } ?? .null,
                "lastSuccess": lane?.lastSuccess.map { .string(Stamp.utc($0)) } ?? .null,
            ])
        }
        return .object([
            "generatedAt": .string(Stamp.utc(now)),
            "app": .string(info.app),
            "os": .string(info.os),
            "model": .string(info.model),
            "lastSync": state.lastSync.map { .string(Stamp.utc($0)) } ?? .null,
            "lastSyncMessage": state.lastSyncMessage.map { .string($0) } ?? .null,
            "pipelines": .array(pipelines),
        ])
    }

    /// Writes `diagnostics.zip` into the folder.
    public static func write(files: FileStore, info: AppInfo, now: Date, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let summaryFile = folder.appendingPathComponent("diagnostics.json")
        try summary(files.load(), info: info, now: now).data.write(to: summaryFile)
        let out = folder.appendingPathComponent("health-data-relay-diagnostics.zip")
        try? FileManager.default.removeItem(at: out)
        let zip = try ZipWriter(url: out)
        try zip.add(file: summaryFile, name: "diagnostics.json", date: now)
        if FileManager.default.fileExists(atPath: files.activityFile.path) {
            try zip.add(file: files.activityFile, name: "activity.jsonl", date: now)
        }
        try zip.finish()
        try? FileManager.default.removeItem(at: summaryFile)
        return out
    }
}

/// When to tell the user about a pipeline, by local notification.
public struct PipelineNotices: Codable, Sendable, Equatable {
    public var onFailure: Bool
    public var onSuccess: Bool
    /// Reminds at a scheduled time if the app hasn't been able to run by then.
    public var reminder: Bool

    public init(onFailure: Bool = false, onSuccess: Bool = false, reminder: Bool = false) {
        self.onFailure = onFailure
        self.onSuccess = onSuccess
        self.reminder = reminder
    }

    public var isOn: Bool { onFailure || onSuccess || reminder }
}

/// A notification to show. Never carries a health value.
public struct PipelineNotice: Sendable, Equatable {
    public var pipeline: UUID
    public var title: String
    public var body: String

    public init(pipeline: UUID, title: String, body: String) {
        self.pipeline = pipeline
        self.title = title
        self.body = body
    }
}
