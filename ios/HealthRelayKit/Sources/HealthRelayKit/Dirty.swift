import Foundation

/// A destination's days that need sending, each with when it was last
/// marked. A day is cleared by a delivery only if it was not marked again
/// after that delivery's content was read (docs/design.md).
public struct DirtySet: Codable, Sendable, Equatable {
    private var marks: [String: Date] = [:]

    public init() {}

    public var days: [Day] { marks.keys.compactMap(Day.init).sorted() }
    public var count: Int { marks.count }
    public var isEmpty: Bool { marks.isEmpty }

    public func contains(_ day: Day) -> Bool { marks[day.description] != nil }
    public func markedAt(_ day: Day) -> Date? { marks[day.description] }

    public mutating func mark(_ days: some Sequence<Day>, at date: Date) {
        for d in days { marks[d.description] = date }
    }

    /// Clears the days that were last marked at or before `readAt`.
    public mutating func clear(_ days: some Sequence<Day>, readAt: Date) {
        for d in days where (marks[d.description].map { $0 <= readAt } ?? false) {
            marks[d.description] = nil
        }
    }

    public mutating func removeAll() { marks = [:] }
}

/// Which days are dirty, by rule (docs/design.md, Which days to send).
public enum DirtyRules {
    /// Days per batch, and per batch during a first run.
    public static let batchDays = 7
    public static let firstRunBatchDays = 1
    public static let firstRunDays = 30
    public static let sweepDays = 35
    public static let sweepInterval: TimeInterval = 7 * 86400
    /// How far back a change to old data is still noticed.
    public static let changeWindowDays = 40

    /// Today and yesterday: dirty on every sync.
    public static func recent(today: Day) -> [Day] { [today.adding(-1), today] }

    /// The last `n` days through today.
    public static func last(_ n: Int, today: Day) -> [Day] { today.adding(-(n - 1)).through(today) }

    /// The local days a sample touches (start day through end day; at most
    /// three, since a sample longer than that is not one day's data).
    public static func days(of interval: DateInterval, calendar: Calendar) -> [Day] {
        let first = Day(interval.start, calendar: calendar)
        let end = interval.end > interval.start ? interval.end.addingTimeInterval(-0.001) : interval.end
        let last = Swift.min(Day(end, calendar: calendar), first.adding(2))
        return first.through(Swift.max(first, last))
    }

    /// Batches of dirty days, oldest first.
    public static func batches(_ days: [Day], firstRun: Bool) -> [[Day]] {
        let size = firstRun ? firstRunBatchDays : batchDays
        let sorted = days.sorted()
        return stride(from: 0, to: sorted.count, by: size).map { Array(sorted[$0..<Swift.min($0 + size, sorted.count)]) }
    }
}
