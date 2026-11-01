import Foundation

/// A JSON value that serializes to canonical JSON (docs/schema.md): keys
/// sorted by UTF-16 code unit at every level, no whitespace, strings and
/// numbers written exactly as JavaScript's JSON.stringify writes them. The
/// fixtures are compared byte for byte, so JSONEncoder (whose number and
/// escaping rules vary by OS version) is not used for pushes.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public var canonical: String {
        var out = ""
        write(into: &out)
        return out
    }

    public var data: Data { Data(canonical.utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSON.format(n)
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            let keys = fields.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                JSON.quote(key, into: &out)
                out += ":"
                fields[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    /// A string as JSON.stringify quotes it: only `"`, `\` and control
    /// characters are escaped.
    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    /// A number as JavaScript's Number.prototype.toString writes it: the
    /// shortest round-trip digits (Swift's description has the same digits),
    /// laid out decimally for 1e-7 <= |n| < 1e21 and in exponent form outside.
    public static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == 0 { return "0" }
        let text = n.magnitude.description
        let sign = n < 0 ? "-" : ""
        // text is "ddd.ddd" or "d.ddde±xx"; reduce it to digits and the
        // position of the decimal point (value = 0.digits × 10^point).
        let parts = text.split(separator: "e")
        let mantissa = String(parts[0])
        let exp = parts.count > 1 ? Int(parts[1])! : 0
        let halves = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(halves[0])
        let frac = halves.count > 1 ? String(halves[1]) : ""
        var digits = Array(whole + frac)
        var point = whole.count + exp
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let ds = String(digits)
        if k <= point && point <= 21 {
            return sign + ds + String(repeating: "0", count: point - k)
        }
        if 0 < point && point <= 21 {
            return sign + String(digits[..<point]) + "." + String(digits[point...])
        }
        if -6 < point && point <= 0 {
            return sign + "0." + String(repeating: "0", count: -point) + ds
        }
        let e = point - 1
        let es = e < 0 ? "-\(-e)" : "+\(e)"
        return sign + (k == 1 ? ds : "\(digits[0]).\(String(digits[1...]))") + "e" + es
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements) { _, last in last }) }
}

extension JSON {
    /// Parses JSON text (for reading answers and stored batches; not canonical).
    public static func parse(_ data: Data) -> JSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return from(any)
    }

    private static func from(_ any: Any) -> JSON {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(from))
        case let o as [String: Any]: return .object(o.mapValues(from))
        default: return .null
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
