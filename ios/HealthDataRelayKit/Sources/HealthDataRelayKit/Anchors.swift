import Foundation

/// The persisted change anchor per type. A sync reads changes from the
/// committed anchors and holds the new ones as pending; they are committed
/// only after every active destination has accepted the days those changes
/// touched, so an unsent change is always asked for again.
public struct AnchorBook: Codable, Sendable, Equatable {
    public private(set) var committed: [String: Data] = [:]

    public init() {}

    public func anchor(for type: HealthType) -> Data? { committed[type.id] }

    public mutating func commit(_ pending: [String: Data]) {
        committed.merge(pending) { _, new in new }
    }

    public mutating func reset() { committed = [:] }
}
