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

    public init() {}
}

/// The engine's files: `state.json` and one directory of queued batch
/// bodies per destination. Writes are atomic.
public final class FileStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Application Support/HealthRelay, excluded from backups (the phone's
    /// Health data is the source of truth; queued batches are disposable).
    public static func standard() -> FileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("HealthRelay", isDirectory: true)
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

    public func load() -> EngineState {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(EngineState.self, from: data) else {
            return EngineState()
        }
        return state
    }

    public func save(_ state: EngineState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
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
