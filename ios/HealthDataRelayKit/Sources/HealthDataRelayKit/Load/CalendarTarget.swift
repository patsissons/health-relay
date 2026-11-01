import Foundation

/// A calendar to write events to. A template writes them as JSON, each with
/// its own `key`, so running again updates an event rather than adding one.
public struct CalendarTarget: Codable, Sendable, Equatable {
    /// The calendar's identifier; nil is the phone's default.
    public var calendarID: String?
    public var calendarName: String

    public init(calendarID: String?, calendarName: String) {
        self.calendarID = calendarID
        self.calendarName = calendarName
    }
}

/// An event a template wrote.
public struct CalendarEvent: Sendable, Equatable {
    public var key: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var notes: String?
    public var location: String?

    /// `{"events": [{"key", "title", "start", "end", "allDay", "notes", "location"}]}`
    /// A row missing its key, title or start is an error, not a skipped event.
    static func parse(_ data: Data) throws -> [CalendarEvent] {
        guard let json = JSON.parse(data), case .array(let rows)? = json["events"] else {
            throw TemplateError(message: "A calendar template writes {\"events\": [...]}.")
        }
        return try rows.enumerated().map { i, row in
            guard let key = row["key"]?.stringValue, let title = row["title"]?.stringValue, let startText = row["start"]?.stringValue, let start = TemplateFilters.date(.string(startText)) else {
                throw TemplateError(message: "Event \(i + 1) needs a key, a title and a start.")
            }
            let end = row["end"]?.stringValue.flatMap { TemplateFilters.date(.string($0)) } ?? start
            var allDay = false
            if case .bool(true)? = row["allDay"] { allDay = true }
            return CalendarEvent(key: key, title: title, start: start, end: max(end, start), allDay: allDay, notes: row["notes"]?.stringValue, location: row["location"]?.stringValue)
        }
    }
}

/// The calendar the events go to.
public protocol CalendarStore: Sendable {
    /// Creates or updates an event, returning its identifier. `existing` is the
    /// one from last time, which may since have been deleted by the user.
    func save(_ event: CalendarEvent, existing: String?, calendarID: String?) async throws -> String
    func requestAccess() async throws -> Bool
}

/// Writes events, remembering which event each key became, so a rerun or a
/// retry changes nothing but what's different.
public struct CalendarTransport: ArtifactTransport {
    public let target: CalendarTarget
    public let store: CalendarStore
    public let keysFile: URL

    public init(target: CalendarTarget, store: CalendarStore, keysFile: URL) {
        self.target = target
        self.store = store
        self.keysFile = keysFile
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        do {
            guard try await store.requestAccess() else {
                return Delivery(status: nil, verdict: .authFailed, message: "Calendar access is off. Turn it on in Settings › Privacy & Security › Calendars.")
            }
            let events = try CalendarEvent.parse(try Data(contentsOf: file))
            var keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: keysFile))) ?? [:]
            for event in events {
                keys[event.key] = try await store.save(event, existing: keys[event.key], calendarID: target.calendarID)
                // Saved after each, so a failure partway doesn't lose what's done.
                try JSONEncoder().encode(keys).write(to: keysFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return Delivery(status: nil, verdict: .accepted, message: events.count == 1 ? "1 event in \(target.calendarName)" : "\(events.count) events in \(target.calendarName)")
        } catch let error as TemplateError {
            return Delivery(status: nil, verdict: .rejected, message: error.description)
        } catch {
            return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
        }
    }
}
