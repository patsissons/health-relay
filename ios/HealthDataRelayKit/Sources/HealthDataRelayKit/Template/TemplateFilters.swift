import Foundation

/// Liquid's standard filters, plus `json`, `raw`, `iso8601` and `group_by`.
enum TemplateFilters {
    /// Filters that need every row of a list in hand.
    static let takesLists: Set<String> = ["sort", "sort_natural", "map", "where", "group_by", "join", "first", "last", "size", "reverse", "uniq", "compact", "concat", "slice", "sum"]

    static let names: Set<String> = takesLists.union([
        "default", "date", "iso8601", "json", "raw", "escape", "escape_once", "url_encode", "url_decode",
        "round", "ceil", "floor", "abs", "plus", "minus", "times", "divided_by", "modulo", "at_least", "at_most",
        "upcase", "downcase", "capitalize", "append", "prepend", "replace", "replace_first", "remove", "remove_first",
        "split", "strip", "lstrip", "rstrip", "strip_newlines", "newline_to_br", "strip_html", "truncate", "truncatewords",
    ])

    static func apply(_ name: String, _ value: TemplateValue, _ args: [TemplateValue], renderer r: TemplateRenderer) throws -> TemplateValue {
        func text(_ v: TemplateValue) -> String { r.text(v) }
        func arg(_ i: Int) -> TemplateValue { i < args.count ? args[i] : .null }
        func num(_ v: TemplateValue) -> Double { r.number(v) ?? 0 }
        func list(_ v: TemplateValue) -> [TemplateValue] {
            switch v {
            case .array(let a): a
            case .null: []
            default: [v]
            }
        }
        func field(_ item: TemplateValue, _ key: TemplateValue) -> TemplateValue {
            guard case .object(let o) = item else { return .null }
            return o.value(text(key)) ?? .null
        }
        func order(_ a: TemplateValue, _ b: TemplateValue) -> Bool {
            switch (a, b) {
            case (.number(let x), .number(let y)): x < y
            case (.date(let x), .date(let y)): x < y
            case (.null, _): false
            case (_, .null): true
            default: text(a) < text(b)
            }
        }

        switch name {
        // Values
        case "default":
            let fallback = !value.isTruthy || value.isEmptyish
            return fallback ? arg(0) : value
        case "raw":
            return .safe(text(value))
        case "json":
            var out = ""
            try TemplateRenderer.writeJSON(value, into: &out, clock: LocalClock(timeZone: r.timeZone))
            return .safe(out)
        case "size":
            switch value {
            case .array(let a): return .number(Double(a.count))
            case .string(let s), .safe(let s): return .number(Double(s.count))
            case .object(let o): return .number(Double(o.keys.count))
            default: return .number(0)
            }

        // Dates
        case "date":
            guard let date = date(value) else { return value }
            return .string(r.dateText(date, text(arg(0))))
        case "iso8601":
            guard let date = date(value) else { return value }
            return .string(r.iso(date))

        // Numbers
        case "round":
            let places = Int(num(arg(0)))
            let scale = pow(10, Double(places))
            return .number((num(value) * scale).rounded(.toNearestOrAwayFromZero) / scale)
        case "ceil": return .number(num(value).rounded(.up))
        case "floor": return .number(num(value).rounded(.down))
        case "abs": return .number(abs(num(value)))
        case "plus": return .number(num(value) + num(arg(0)))
        case "minus": return .number(num(value) - num(arg(0)))
        case "times": return .number(num(value) * num(arg(0)))
        case "divided_by":
            guard num(arg(0)) != 0 else { throw TemplateError(message: "divided_by: can't divide by zero") }
            return .number(num(value) / num(arg(0)))
        case "modulo":
            guard num(arg(0)) != 0 else { throw TemplateError(message: "modulo: can't divide by zero") }
            return .number(num(value).truncatingRemainder(dividingBy: num(arg(0))))
        case "at_least": return .number(max(num(value), num(arg(0))))
        case "at_most": return .number(min(num(value), num(arg(0))))
        case "sum":
            return .number(list(value).reduce(0) { $0 + num(args.isEmpty ? $1 : field($1, arg(0))) })

        // Text
        case "upcase": return .string(text(value).uppercased())
        case "downcase": return .string(text(value).lowercased())
        case "capitalize":
            let s = text(value)
            return .string(s.prefix(1).uppercased() + s.dropFirst().lowercased())
        case "append": return .string(text(value) + text(arg(0)))
        case "prepend": return .string(text(arg(0)) + text(value))
        case "replace": return .string(text(value).replacingOccurrences(of: text(arg(0)), with: text(arg(1))))
        case "replace_first": return .string(replaceFirst(text(value), text(arg(0)), text(arg(1))))
        case "remove": return .string(text(value).replacingOccurrences(of: text(arg(0)), with: ""))
        case "remove_first": return .string(replaceFirst(text(value), text(arg(0)), ""))
        case "split":
            let parts = text(value).components(separatedBy: text(arg(0)))
            return .array(parts.map { .string($0) })
        case "strip": return .string(text(value).trimmingCharacters(in: .whitespacesAndNewlines))
        case "lstrip": return .string(String(text(value).drop { $0.isWhitespace }))
        case "rstrip":
            var s = text(value)
            while s.last?.isWhitespace == true { s.removeLast() }
            return .string(s)
        case "strip_newlines": return .string(text(value).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: ""))
        case "newline_to_br": return .string(text(value).replacingOccurrences(of: "\n", with: "<br />\n"))
        case "strip_html": return .string(text(value).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression))
        case "truncate":
            let s = text(value)
            let limit = args.isEmpty ? 50 : Int(num(arg(0)))
            let tail = args.count > 1 ? text(arg(1)) : "..."
            guard s.count > limit else { return .string(s) }
            return .string(String(s.prefix(max(0, limit - tail.count))) + tail)
        case "truncatewords":
            let words = text(value).split(whereSeparator: \.isWhitespace)
            let limit = max(1, args.isEmpty ? 15 : Int(num(arg(0))))
            let tail = args.count > 1 ? text(arg(1)) : "..."
            guard words.count > limit else { return .string(text(value)) }
            return .string(words.prefix(limit).joined(separator: " ") + tail)
        case "escape", "escape_once":
            return .safe(OutputFormat.escapeMarkup(text(value)))
        case "url_encode":
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-_.~")
            let encoded = text(value).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return .string(encoded.replacingOccurrences(of: "%20", with: "+"))
        case "url_decode":
            return .string(text(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text(value))

        // Lists
        case "join": return .string(list(value).map(text).joined(separator: args.isEmpty ? " " : text(arg(0))))
        case "first":
            if case .string(let s) = value { return s.first.map { .string(String($0)) } ?? .null }
            return list(value).first ?? .null
        case "last":
            if case .string(let s) = value { return s.last.map { .string(String($0)) } ?? .null }
            return list(value).last ?? .null
        case "reverse": return .array(list(value).reversed())
        case "sort":
            let items = list(value)
            if args.isEmpty { return .array(items.sorted(by: order)) }
            return .array(items.sorted { order(field($0, arg(0)), field($1, arg(0))) })
        case "sort_natural":
            let items = list(value)
            func key(_ v: TemplateValue) -> String { text(args.isEmpty ? v : field(v, arg(0))).lowercased() }
            return .array(items.sorted { key($0) < key($1) })
        case "map": return .array(list(value).map { field($0, arg(0)) })
        case "where":
            return .array(list(value).filter { item in
                let v = field(item, arg(0))
                return args.count > 1 ? r.equal(v, arg(1)) : v.isTruthy
            })
        case "compact":
            return .array(list(value).filter {
                if case .null = $0 { return false }
                return true
            })
        case "uniq":
            var seen = Set<String>()
            return .array(list(value).filter { seen.insert(text($0)).inserted })
        case "concat": return .array(list(value) + list(arg(0)))
        case "slice":
            if case .string(let s) = value {
                let chars = Array(s)
                let start = Int(num(arg(0)))
                let from = start < 0 ? max(0, chars.count + start) : start
                let length = args.count > 1 ? Int(num(arg(1))) : 1
                guard from < chars.count else { return .string("") }
                return .string(String(chars[from..<min(chars.count, from + length)]))
            }
            let items = list(value)
            let start = Int(num(arg(0)))
            let from = start < 0 ? max(0, items.count + start) : start
            let length = args.count > 1 ? Int(num(arg(1))) : 1
            guard from < items.count else { return .array([]) }
            return .array(Array(items[from..<min(items.count, from + length)]))
        case "group_by":
            var order: [String] = []
            var groups: [String: [TemplateValue]] = [:]
            for item in list(value) {
                let key = text(field(item, arg(0)))
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(item)
            }
            return .array(order.map { key in
                .object(DictionaryObject(["name": .string(key), "items": .array(groups[key]!)], keys: ["name", "items"]))
            })
        default:
            throw TemplateError(message: "Unknown filter '\(name)'")
        }
    }

    private static func replaceFirst(_ s: String, _ what: String, _ with: String) -> String {
        guard !what.isEmpty, let range = s.range(of: what) else { return s }
        return s.replacingCharacters(in: range, with: with)
    }

    /// A value as a date: a date, "now", or text in a form dates are written in.
    static func date(_ value: TemplateValue) -> Date? {
        switch value {
        case .date(let d): return d
        case .number(let n): return Date(timeIntervalSince1970: n)
        case .string(let s), .safe(let s):
            if s == "now" || s == "today" { return Date() }
            return parseStamp(s)
        default: return nil
        }
    }

    private static func parseStamp(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }
}
