import Foundation

/// One run's output, on disk: every part already rendered, so retries send the
/// same bytes and a killed app carries on where it stopped.
public struct Artifact: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    /// The days it covers in full, for a pipeline that follows dirty days.
    public var days: [Day]
    public var rows: Int
    public var parts: [ArtifactPart]

    public init(id: UUID = UUID(), createdAt: Date, days: [Day], rows: Int, parts: [ArtifactPart]) {
        self.id = id
        self.createdAt = createdAt
        self.days = days
        self.rows = rows
        self.parts = parts
    }

    public var isDelivered: Bool { parts.allSatisfy(\.delivered) }
    public var bytes: Int { parts.reduce(0) { $0 + $1.bytes } }
}

public struct ArtifactPart: Codable, Sendable, Equatable {
    public var key: String
    /// What it's called where it's going.
    public var filename: String
    /// Its file in the artifact's folder.
    public var file: String
    public var contentType: String
    public var bytes: Int
    public var delivered = false
    /// Where this part goes, when the target's address is a template.
    public var destination: String?

    public init(key: String, filename: String, file: String, contentType: String, bytes: Int, destination: String? = nil) {
        self.key = key
        self.filename = filename
        self.file = file
        self.contentType = contentType
        self.bytes = bytes
        self.destination = destination
    }
}

/// `pipelines/<id>/queue/<artifact>/`: the manifest and the part files. A folder
/// appears under its final name only once complete, so one half-written by a
/// killed app is never sent and is cleared at the next run.
extension FileStore {
    static var partAttributes: [FileAttributeKey: Any] { [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }

    private func queueDir(_ pipeline: UUID) -> URL {
        root.appendingPathComponent("pipelines", isDirectory: true).appendingPathComponent(pipeline.uuidString, isDirectory: true).appendingPathComponent("queue", isDirectory: true)
    }

    private func artifactDir(_ pipeline: UUID, _ id: UUID) -> URL {
        queueDir(pipeline).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// A new folder to render into.
    func beginArtifact(_ pipeline: UUID) throws -> URL {
        let dir = queueDir(pipeline).appendingPathComponent("rendering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the manifest and gives the folder its final name.
    func commitArtifact(_ artifact: Artifact, from dir: URL, pipeline: UUID) throws {
        try manifest(artifact).write(to: dir.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.moveItem(at: dir, to: artifactDir(pipeline, artifact.id))
    }

    private func manifest(_ artifact: Artifact) throws -> Data {
        try JSONEncoder().encode(artifact)
    }

    /// Finished artifacts, oldest first. Also clears any left half-rendered.
    public func artifacts(_ pipeline: UUID) -> [Artifact] {
        let dir = queueDir(pipeline)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [Artifact] = []
        for name in names {
            let folder = dir.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix("rendering-") { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let artifact = try? JSONDecoder().decode(Artifact.self, from: data) else { continue }
            out.append(artifact)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes folders a killed run left half-rendered. Call only between runs.
    func clearUnfinishedArtifacts(_ pipeline: UUID) {
        let dir = queueDir(pipeline)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("rendering-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    public func partFile(_ part: ArtifactPart, artifact: UUID, pipeline: UUID) -> URL {
        artifactDir(pipeline, artifact).appendingPathComponent(part.file)
    }

    /// Saves which parts have been delivered.
    func updateArtifact(_ artifact: Artifact, pipeline: UUID) {
        guard let data = try? manifest(artifact) else { return }
        try? data.write(to: artifactDir(pipeline, artifact.id).appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeArtifact(_ id: UUID, pipeline: UUID) {
        try? FileManager.default.removeItem(at: artifactDir(pipeline, id))
    }

    /// Removes everything a pipeline left on disk.
    public func removePipeline(_ pipeline: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("pipelines", isDirectory: true).appendingPathComponent(pipeline.uuidString, isDirectory: true))
    }
}
