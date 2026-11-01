#if os(iOS) || os(visionOS) || os(visionOS)
import EventKit
import Foundation

/// Events in the phone's calendars.
public final class LiveCalendarStore: CalendarStore, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Calendars an event can be written to.
    public func writableCalendars() -> [(id: String, title: String)] {
        store.calendars(for: .event).filter(\.allowsContentModifications).map { ($0.calendarIdentifier, $0.title) }
    }

    public func save(_ event: CalendarEvent, existing: String?, calendarID: String?) async throws -> String {
        let row: EKEvent
        if let existing, let found = store.event(withIdentifier: existing) {
            row = found
        } else {
            row = EKEvent(eventStore: store)
            let chosen = calendarID.flatMap(store.calendar(withIdentifier:))
            guard let calendar = chosen ?? store.defaultCalendarForNewEvents else {
                throw TemplateError(message: "There's no calendar to write to.")
            }
            row.calendar = calendar
        }
        row.title = event.title
        row.startDate = event.start
        row.endDate = event.end
        row.isAllDay = event.allDay
        row.notes = event.notes
        row.location = event.location
        try store.save(row, span: .thisEvent, commit: true)
        return row.eventIdentifier
    }
}
#endif
