import Foundation

/// A local calendar date, `yyyy-MM-dd`. Which instants it covers depends on
/// the calendar's time zone: midnight to midnight, so 23 or 25 hours across a
/// daylight saving change.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`.
    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard text.count == 10, parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The local date of an instant.
    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// The first instant of the day in the calendar's time zone.
    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Midnight to the next midnight.
    public func interval(in calendar: Calendar) -> DateInterval {
        DateInterval(start: start(in: calendar), end: adding(1).start(in: calendar))
    }

    /// The date `n` days later (earlier when negative); time zones play no part.
    public func adding(_ n: Int) -> Day {
        let date = Day.utc.date(from: DateComponents(year: year, month: month, day: day + n))!
        return Day(date, calendar: Day.utc)
    }

    /// Every day from `self` through `last`, inclusive.
    public func through(_ last: Day) -> [Day] {
        var out: [Day] = []
        var d = self
        while d <= last {
            out.append(d)
            d = d.adding(1)
        }
        return out
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

extension Day: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = Day(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a yyyy-MM-dd day: \(text)"))
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension Calendar {
    /// A Gregorian calendar in the given time zone, POSIX locale: what every
    /// day computation in the kit uses.
    public static func local(_ timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
}

/// Timestamp text in the schema's two forms, without DateFormatter (which
/// is slow to make and not Sendable).
public enum Stamp {
    /// export.xml form, local with offset: `2026-10-24 17:00:00 -0700`.
    public static func local(_ date: Date, _ timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date) / 60
        let sign = offset < 0 ? "-" : "+"
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d %@%02d%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, sign, abs(offset) / 60, abs(offset) % 60)
    }

    /// UTC, ISO 8601, whole seconds: `2026-10-25T14:00:00Z`.
    public static func utc(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
