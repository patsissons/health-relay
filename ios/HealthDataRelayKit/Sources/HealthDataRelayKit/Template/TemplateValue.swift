import Foundation

/// A value inside a template.
public enum TemplateValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    /// Text that's written as it is, whatever the format's escaping.
    case safe(String)
    case date(Date)
    case array([TemplateValue])
    case object(any TemplateObject)
    /// A list that's read from Health as a loop reaches it.
    case lazy(LazyList)
}

/// Something with named fields. Its `keys` are what it writes as JSON, in
/// order; a field outside them can still be read by name.
public protocol TemplateObject: Sendable {
    func value(_ key: String) -> TemplateValue?
    var keys: [String] { get }
    /// What a `for` loop over the object walks, when not its fields.
    var list: TemplateValue? { get }
}

extension TemplateObject {
    public var list: TemplateValue? { nil }
}

/// Plain named fields.
public struct DictionaryObject: TemplateObject {
    public let fields: [String: TemplateValue]
    public let keys: [String]

    public init(_ fields: [String: TemplateValue], keys: [String]? = nil) {
        self.fields = fields
        self.keys = keys ?? fields.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    public func value(_ key: String) -> TemplateValue? { fields[key] }
}

/// A list read page by page. A loop asks `make` for a fresh reader, so the
/// same list can be walked twice. Only a filter that truly needs every row,
/// like `sort`, loads it all, and that's capped.
public final class LazyList: @unchecked Sendable {
    /// One walk through the list.
    public typealias Pages = @Sendable () -> PageReader

    /// True when the list's rows hold no lazy lists themselves, so a loop body
    /// can run without suspending between rows.
    public let plainItems: Bool
    public let make: Pages
    private let lock = NSLock()
    private var loaded: [TemplateValue]?

    public init(plainItems: Bool, make: @escaping Pages) {
        self.plainItems = plainItems
        self.make = make
    }

    /// Every row, up to `limit`.
    func materialize(limit: Int) async throws -> [TemplateValue] {
        if let done = lock.withLock({ loaded }) { return done }
        let reader = make()
        var rows: [TemplateValue] = []
        while let page = try await reader.next() {
            rows += page
            if rows.count > limit {
                throw TemplateError(message: "This list has more than \(limit) rows, too many to sort or group. Narrow what's extracted.")
            }
        }
        lock.withLock { loaded = rows }
        return rows
    }
}

/// Reads the next page of a lazy list; nil at the end.
public final class PageReader: @unchecked Sendable {
    private let body: () async throws -> [TemplateValue]?

    public init(_ body: @escaping () async throws -> [TemplateValue]?) {
        self.body = body
    }

    public func next() async throws -> [TemplateValue]? {
        try await body()
    }
}

/// What went wrong in a template, with where when it's known.
public struct TemplateError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
    }

    public var description: String {
        guard let line else { return message }
        if let column { return "Line \(line), column \(column): \(message)" }
        return "Line \(line): \(message)"
    }
}

extension TemplateValue {
    /// Liquid's rule: only nil and false are false.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        default: true
        }
    }

    var isEmptyish: Bool {
        switch self {
        case .null: false
        case .string(let s), .safe(let s): s.isEmpty
        case .array(let a): a.isEmpty
        case .object(let o): o.keys.isEmpty
        default: false
        }
    }

    public init(json: JSON) {
        switch json {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let n): self = .number(n)
        case .string(let s): self = .string(s)
        case .array(let items): self = .array(items.map(TemplateValue.init(json:)))
        case .object(let fields): self = .object(DictionaryObject(fields.mapValues(TemplateValue.init(json:))))
        }
    }
}

/// Dates to local text without Calendar, which is too slow to call millions
/// of times. Not thread-safe: each render has its own.
final class LocalClock {
    let timeZone: TimeZone
    private var offset = 0
    private var validFrom = Date.distantFuture
    private var validUntil = Date.distantPast

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// The offset at a date. It stays the same until the next clock change.
    func secondsFromGMT(_ date: Date) -> Int {
        if date >= validFrom && date < validUntil { return offset }
        offset = timeZone.secondsFromGMT(for: date)
        // The window starts here and runs to the next change, so going back
        // in time asks again.
        validFrom = date
        validUntil = timeZone.nextDaylightSavingTimeTransition(after: date) ?? date.addingTimeInterval(86400 * 365)
        return offset
    }

    struct Fields {
        var year, month, day, hour, minute, second, millisecond, offset: Int
        var weekday: Int
        var dayOfYear: Int
    }

    func fields(_ date: Date) -> Fields {
        let offset = secondsFromGMT(date)
        let t = date.timeIntervalSince1970
        let whole = t.rounded(.down)
        let local = Int(whole) + offset
        var days = local / 86400
        var rest = local % 86400
        if rest < 0 {
            rest += 86400
            days -= 1
        }
        // Howard Hinnant's civil-from-days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        let weekday = ((days % 7) + 11) % 7 // 0 is Sunday; 1970-01-01 was a Thursday.
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][month - 1]
        return Fields(year: year, month: month, day: day, hour: rest / 3600, minute: rest % 3600 / 60, second: rest % 60,
                      millisecond: Int((t - whole) * 1000), offset: offset, weekday: weekday,
                      dayOfYear: before + day + (leap && month > 2 ? 1 : 0))
    }

    /// `2026-10-24 17:00:00 -0700`, the export's date form.
    func stamp(_ date: Date) -> String {
        let f = fields(date)
        var b = [UInt8](repeating: 0, count: 25)
        func put(_ n: Int, _ at: Int, _ width: Int) {
            var n = n
            var i = at + width - 1
            while i >= at {
                b[i] = UInt8(48 + n % 10)
                n /= 10
                i -= 1
            }
        }
        put(f.year, 0, 4)
        b[4] = 45
        put(f.month, 5, 2)
        b[7] = 45
        put(f.day, 8, 2)
        b[10] = 32
        put(f.hour, 11, 2)
        b[13] = 58
        put(f.minute, 14, 2)
        b[16] = 58
        put(f.second, 17, 2)
        b[19] = 32
        b[20] = f.offset < 0 ? 45 : 43
        let off = abs(f.offset) / 60
        put(off / 60, 21, 2)
        put(off % 60, 23, 2)
        return String(decoding: b, as: UTF8.self)
    }

    /// strftime's common conversions, the same ones Liquid's `date` documents.
    func format(_ date: Date, _ pattern: String) -> String {
        if pattern == "%Y-%m-%d %H:%M:%S %z" { return stamp(date) }
        let f = fields(date)
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        func pad(_ n: Int, _ width: Int = 2, _ with: Character = "0") -> String {
            let s = String(n)
            return String(repeating: with, count: Swift.max(0, width - s.count)) + s
        }
        func offsetText(colon: Bool) -> String {
            let minutes = abs(f.offset) / 60
            return (f.offset < 0 ? "-" : "+") + pad(minutes / 60) + (colon ? ":" : "") + pad(minutes % 60)
        }
        var out = ""
        var chars = pattern.makeIterator()
        while let c = chars.next() {
            guard c == "%", var code = chars.next() else {
                out.append(c)
                continue
            }
            var colon = false
            if code == ":" , let next = chars.next() {
                colon = true
                code = next
            }
            switch code {
            case "Y": out += String(f.year)
            case "y": out += pad(f.year % 100)
            case "m": out += pad(f.month)
            case "d": out += pad(f.day)
            case "e": out += pad(f.day, 2, " ")
            case "j": out += pad(f.dayOfYear, 3)
            case "H": out += pad(f.hour)
            case "I": out += pad(f.hour % 12 == 0 ? 12 : f.hour % 12)
            case "M": out += pad(f.minute)
            case "S": out += pad(f.second)
            case "L": out += pad(f.millisecond, 3)
            case "p": out += f.hour < 12 ? "AM" : "PM"
            case "P": out += f.hour < 12 ? "am" : "pm"
            case "z": out += offsetText(colon: colon)
            case "Z": out += timeZone.abbreviation(for: date) ?? ""
            case "A": out += weekdays[f.weekday]
            case "a": out += String(weekdays[f.weekday].prefix(3))
            case "B": out += months[f.month - 1]
            case "b", "h": out += String(months[f.month - 1].prefix(3))
            case "u": out += String(f.weekday == 0 ? 7 : f.weekday)
            case "w": out += String(f.weekday)
            case "s": out += String(Int(date.timeIntervalSince1970))
            case "F": out += "\(f.year)-\(pad(f.month))-\(pad(f.day))"
            case "T": out += "\(pad(f.hour)):\(pad(f.minute)):\(pad(f.second))"
            case "D": out += "\(pad(f.month))/\(pad(f.day))/\(pad(f.year % 100))"
            case "%": out += "%"
            default:
                out += "%"
                out.append(code)
            }
        }
        return out
    }

    /// ISO 8601 in UTC with milliseconds.
    func isoUTC(_ date: Date) -> String {
        let saved = (offset, validFrom, validUntil)
        defer { (offset, validFrom, validUntil) = saved }
        (offset, validFrom, validUntil) = (0, .distantPast, .distantFuture)
        let f = fields(date)
        func pad(_ n: Int, _ width: Int = 2) -> String {
            let s = String(n)
            return String(repeating: "0", count: Swift.max(0, width - s.count)) + s
        }
        return "\(f.year)-\(pad(f.month))-\(pad(f.day))T\(pad(f.hour)):\(pad(f.minute)):\(pad(f.second)).\(pad(f.millisecond, 3))Z"
    }
}
