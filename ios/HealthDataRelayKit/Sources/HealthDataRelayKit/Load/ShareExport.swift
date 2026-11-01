import Foundation

/// A finished export waiting to be handed to the user: one file, or a ZIP when
/// a run wrote several.
public struct ExportedFile: Sendable, Equatable {
    public var url: URL
    public var name: String
    public var bytes: Int
    public var rows: Int
}

/// Makes a one-off export: no pipeline, nothing remembered, a file to share.
public struct OneOffExport: Sendable {
    public let store: HealthQuerying
    public let calendar: Calendar
    public let folder: URL

    public init(store: HealthQuerying, calendar: Calendar, folder: URL) {
        self.store = store
        self.calendar = calendar
        self.folder = folder
    }

    /// Renders and packages. A failure leaves nothing behind.
    public func run(source: String, spec: ExtractSpec, range: DateInterval, export: ExportInfo, limits: TemplateLimits = TemplateLimits(materializedRows: 500_000)) async throws -> ExportedFile {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let template = try ParsedTemplate(source: source)
        let extractor = Extractor(store: store, spec: spec, calendar: calendar, ranges: [range])
        let parts = folder.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        do {
            var counter = 0
            var sinks: [FileSink] = []
            let run = try await TemplateTransformer(template: template, limits: limits).run(extractor: extractor, export: export) { _, _ in
                let sink = try FileSink(url: parts.appendingPathComponent("part-\(counter)"), attributes: FileStore.partAttributes)
                counter += 1
                sinks.append(sink)
                return sink
            }
            for sink in sinks { try sink.close() }
            let rows = run.parts.reduce(0) { $0 + $1.rows }
            let files = run.parts.map { (url: parts.appendingPathComponent("part-\($0.index)"), name: $0.filename) }
            let made = try SharePackager.package(files, into: folder, zipName: Self.zipName(template.header.name, range: range, calendar: calendar))
            try? FileManager.default.removeItem(at: parts)
            return ExportedFile(url: made, name: made.lastPathComponent, bytes: (try? made.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, rows: rows)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func zipName(_ name: String, range: DateInterval, calendar: Calendar) -> String {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return "\(safe)-\(Day(range.start, calendar: calendar)).zip"
    }
}

enum SharePackager {
    /// One file keeps its name; several go in a ZIP, with repeated names numbered.
    static func package(_ files: [(url: URL, name: String)], into folder: URL, zipName: String) throws -> URL {
        if files.count == 1 {
            let out = folder.appendingPathComponent(safeName(files[0].name))
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: files[0].url, to: out)
            return out
        }
        let out = folder.appendingPathComponent(zipName)
        try? FileManager.default.removeItem(at: out)
        let zip = try ZipWriter(url: out, attributes: FileStore.partAttributes)
        var seen: [String: Int] = [:]
        for file in files {
            var name = safeName(file.name)
            let n = seen[name, default: 0]
            seen[name] = n + 1
            if n > 0 {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(stem)~\(n + 1)" : "\(stem)~\(n + 1).\(ext)"
            }
            try zip.add(file: file.url, name: name)
        }
        try zip.finish()
        return out
    }

    private static func safeName(_ name: String) -> String {
        let flat = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return flat.isEmpty || flat == "." || flat == ".." ? "export" : flat
    }
}

/// Leaves a run's output in `exports/<pipeline>/` for the user to share. A
/// person has to tap, so "delivered" means it's ready for them.
public struct ShareTransport: ArtifactTransport {
    public let files: FileStore
    public let context: TransportContext

    public init(files: FileStore, context: TransportContext) {
        self.files = files
        self.context = context
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        // Only the last part does anything: every part is on disk by then, and
        // doing it all at once means a retry repeats nothing.
        guard part.file == artifact.parts.last?.file else {
            return Delivery(status: nil, verdict: .accepted, message: "Packaged with the rest")
        }
        do {
            let folder = files.exportFolder(context.pipelineID)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let all = artifact.parts.map { (url: files.partFile($0, artifact: artifact.id, pipeline: context.pipelineID), name: $0.filename) }
            // Copied, so the queue's files stay valid if packaging is retried.
            var copies: [(url: URL, name: String)] = []
            for (i, f) in all.enumerated() {
                let copy = folder.appendingPathComponent("copy-\(i)")
                try FileManager.default.copyItem(at: f.url, to: copy)
                copies.append((copy, f.name))
            }
            let range = DateInterval(start: artifact.createdAt, duration: 0)
            let made = try SharePackager.package(copies, into: folder, zipName: OneOffExport.zipName(context.pipelineName, range: range, calendar: .local()))
            for c in copies { try? FileManager.default.removeItem(at: c.url) }
            let size = (try? made.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Delivery(status: nil, verdict: .accepted, message: "\(made.lastPathComponent) is ready to share (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        } catch {
            return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
        }
    }
}

extension FileStore {
    func exportFolder(_ pipeline: UUID) -> URL {
        root.appendingPathComponent("exports", isDirectory: true).appendingPathComponent(pipeline.uuidString, isDirectory: true)
    }

    /// The last export waiting to be shared, if there is one.
    public func latestExport(_ pipeline: UUID) -> URL? {
        let folder = exportFolder(pipeline)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { !$0.hasPrefix("copy-") }.map { folder.appendingPathComponent($0) }
    }
}
