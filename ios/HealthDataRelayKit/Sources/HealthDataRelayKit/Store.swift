import Foundation

/// Everything the engine remembers between launches.
public struct EngineState: Codable, Sendable {
    public var destinations: [Destination] = []
    public var lanes: [UUID: Lane] = [:]
    public var anchors = AnchorBook()
    public var lastSweep: Date?
    /// The first day Health may let the app read (see Engine.noteAuthorized).
    public var readableFrom: Day?
    public var lastSync: Date?
    /// The last sync that read Health and finished without a read error.
    public var lastSuccess: Date?
    public var lastSyncMessage: String?
    public var deviceName: String = "iPhone"
    /// Whether syncs run without Sync now; nil (never set, or state saved
    /// before the setting existed) means off. Optional so older state.json
    /// still decodes.
    public var autoSync: Bool?
    /// Each pipeline's trigger; missing ones follow `autoSync`. Optional so
    /// older state.json still decodes.
    public var triggers: [UUID: PipelineTrigger]?
    /// What each template pipeline reads and writes; a pipeline missing here
    /// is the native push. Optional so older state.json still decodes.
    public var definitions: [UUID: PipelineDefinition]?
    /// Where each template pipeline has read up to.
    public var cursors: [UUID: ExtractCursor]?
    /// When to notify about each pipeline.
    public var notices: [UUID: PipelineNotices]?

    public init() {}
}

/// The engine's files: `state.json` and one directory of queued batch
/// bodies per destination. Writes are atomic.
public final class FileStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// `state.json` exists but could not be read, so saving would destroy it.
    private var unreadable = false

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Application Support/HealthDataRelay, excluded from backups (the phone's
    /// Health data is the source of truth; queued batches are disposable).
    public static func standard() -> FileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("HealthDataRelay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return FileStore(root: dir)
    }

    private var stateURL: URL { root.appendingPathComponent("state.json") }

    private func laneDir(_ lane: UUID) -> URL {
        root.appendingPathComponent("queue", isDirectory: true).appendingPathComponent(lane.uuidString, isDirectory: true)
    }

    /// The saved state. No file means a first launch. A file that cannot be
    /// read yet (still locked before the first unlock) is left alone and
    /// saves are refused until a later load succeeds. A file that cannot be
    /// decoded is set aside, never overwritten.
    public func load() -> EngineState {
        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            let exists = FileManager.default.fileExists(atPath: stateURL.path)
            lock.withLock { unreadable = exists }
            return EngineState()
        }
        lock.withLock { unreadable = false }
        do {
            return try JSONDecoder().decode(EngineState.self, from: data)
        } catch {
            let aside = root.appendingPathComponent("\(Self.setAsidePrefix)\(UUID().uuidString).json")
            if (try? FileManager.default.moveItem(at: stateURL, to: aside)) == nil {
                lock.withLock { unreadable = true }
            }
            return EngineState()
        }
    }

    /// Whether `state.json` exists but could not be read at the last load.
    public var isUnreadable: Bool { lock.withLock { unreadable } }

    private static let setAsidePrefix = "state-undecodable-"

    /// State files that could not be decoded and were kept.
    public func setAsideStates() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(Self.setAsidePrefix) }
    }

    public func removeSetAsideStates() {
        for file in setAsideStates() { try? FileManager.default.removeItem(at: file) }
    }

    public func save(_ state: EngineState) {
        guard !isUnreadable, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func writeBatch(_ body: Data, lane: UUID, id: UUID) throws {
        let dir = laneDir(lane)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("\(id.uuidString).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func readBatch(lane: UUID, id: UUID) -> Data? {
        try? Data(contentsOf: laneDir(lane).appendingPathComponent("\(id.uuidString).json"))
    }

    public func removeBatch(lane: UUID, id: UUID) {
        try? FileManager.default.removeItem(at: laneDir(lane).appendingPathComponent("\(id.uuidString).json"))
    }

    public func removeLane(_ lane: UUID) {
        try? FileManager.default.removeItem(at: laneDir(lane))
    }
}
