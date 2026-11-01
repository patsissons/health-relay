import Foundation

/// The formats a template can write. Each decides how `{{ value }}` is made
/// safe, so a template can't produce broken output by accident.
public enum OutputFormat: String, Sendable, CaseIterable, Codable {
    case json, csv, markdown, html, xml, gpx, text

    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        case .markdown: "md"
        case .html: "html"
        case .xml: "xml"
        case .gpx: "gpx"
        case .text: "txt"
        }
    }

    public var contentType: String {
        switch self {
        case .json: "application/json"
        case .csv: "text/csv; charset=utf-8"
        case .markdown: "text/markdown; charset=utf-8"
        case .html: "text/html; charset=utf-8"
        case .xml: "application/xml"
        case .gpx: "application/gpx+xml"
        case .text: "text/plain; charset=utf-8"
        }
    }

    public var title: String {
        switch self {
        case .json: "JSON"
        case .csv: "CSV"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .xml: "XML"
        case .gpx: "GPX"
        case .text: "Plain text"
        }
    }

    /// A value as text in this format.
    func escape(_ text: String) -> String {
        switch self {
        case .json:
            var out = ""
            JSON.quote(text, into: &out)
            return out
        case .csv:
            // A leading = + - @ would run as a formula in a spreadsheet; these
            // come from names people typed, so they're neutralized with a quote.
            let dangerous = text.first.map { "=+-@\t\r".contains($0) } ?? false
            guard dangerous || text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
            return "\"" + (dangerous ? "'" : "") + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .html, .xml, .gpx:
            return Self.escapeMarkup(text)
        case .markdown:
            return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        case .text:
            return text
        }
    }

    static func escapeMarkup(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for u in text.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Checks output as it's written; nil for formats with no grammar to break.
    func makeValidator() -> OutputValidator? {
        switch self {
        case .json: JSONValidator()
        case .xml, .gpx, .html: self == .html ? nil : XMLValidator()
        default: nil
        }
    }
}

/// Sees output as it's written and throws when it stops being valid.
protocol OutputValidator: AnyObject {
    func feed(_ bytes: UnsafeBufferPointer<UInt8>) throws
    func finish() throws
}

/// A streaming JSON grammar check holding only the current nesting.
final class JSONValidator: OutputValidator {
    private enum State {
        case value, afterValue, objectStart, key, colon, arrayStart
        case string(isKey: Bool), escape(isKey: Bool), unicode(isKey: Bool, left: Int)
        case number(NumberPart)
        case word(left: [UInt8])
        case done
    }

    private enum NumberPart { case sign, zero, whole, dot, fraction, exp, expSign, expDigits }

    private var state = State.value
    private var stack: [UInt8] = []
    private var offset = 0

    private func bad(_ what: String) -> TemplateError {
        TemplateError(message: "The output isn't valid JSON at byte \(offset): \(what). Check the template's commas and quotes, and use {{ value | raw }} only inside your own quotes.")
    }

    func feed(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        for b in bytes {
            try step(b)
            offset += 1
        }
    }

    private func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 10 || b == 13 || b == 9 }

    private func valueDone() {
        state = stack.isEmpty ? .done : .afterValue
    }

    private func startValue(_ b: UInt8) throws {
        switch b {
        case 34: state = .string(isKey: false)
        case 123:
            stack.append(b)
            state = .objectStart
        case 91:
            stack.append(b)
            state = .arrayStart
        case 45: state = .number(.sign)
        case 48: state = .number(.zero)
        case 49...57: state = .number(.whole)
        case 116: state = .word(left: Array("rue".utf8))
        case 102: state = .word(left: Array("alse".utf8))
        case 110: state = .word(left: Array("ull".utf8))
        default: throw bad("expected a value")
        }
    }

    private func step(_ b: UInt8) throws {
        switch state {
        case .value:
            if isSpace(b) { return }
            try startValue(b)
        case .objectStart:
            if isSpace(b) { return }
            if b == 125 {
                stack.removeLast()
                valueDone()
            } else if b == 34 {
                state = .string(isKey: true)
            } else {
                throw bad("expected a key")
            }
        case .key:
            if isSpace(b) { return }
            guard b == 34 else { throw bad("expected a key") }
            state = .string(isKey: true)
        case .colon:
            if isSpace(b) { return }
            guard b == 58 else { throw bad("expected ':'") }
            state = .value
        case .arrayStart:
            if isSpace(b) { return }
            if b == 93 {
                stack.removeLast()
                valueDone()
            } else {
                try startValue(b)
            }
        case .afterValue:
            if isSpace(b) { return }
            let top = stack.last
            if b == 44 {
                state = top == 123 ? .key : .value
            } else if (b == 125 && top == 123) || (b == 93 && top == 91) {
                stack.removeLast()
                valueDone()
            } else {
                throw bad("expected ',' or a closing bracket")
            }
        case .string(let isKey):
            if b == 34 {
                if isKey { state = .colon } else { valueDone() }
            } else if b == 92 {
                state = .escape(isKey: isKey)
            } else if b < 32 {
                throw bad("a control character in a string")
            }
        case .escape(let isKey):
            if b == 117 {
                state = .unicode(isKey: isKey, left: 4)
            } else if "\"\\/bfnrt".utf8.contains(b) {
                state = .string(isKey: isKey)
            } else {
                throw bad("a bad escape")
            }
        case .unicode(let isKey, let left):
            guard (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b) else { throw bad("a bad unicode escape") }
            state = left == 1 ? .string(isKey: isKey) : .unicode(isKey: isKey, left: left - 1)
        case .word(let left):
            guard b == left[0] else { throw bad("a misspelled word") }
            if left.count == 1 { valueDone() } else { state = .word(left: Array(left.dropFirst())) }
        case .number(let part):
            try stepNumber(b, part)
        case .done:
            guard isSpace(b) else { throw bad("text after the end") }
        }
    }

    private func stepNumber(_ b: UInt8, _ part: NumberPart) throws {
        let digit = (48...57).contains(b)
        func end() throws {
            switch part {
            case .zero, .whole, .fraction, .expDigits:
                valueDone()
                try step(b)
            default:
                throw bad("an unfinished number")
            }
        }
        switch part {
        case .sign:
            if b == 48 { state = .number(.zero) } else if digit { state = .number(.whole) } else { throw bad("an unfinished number") }
        case .zero:
            if b == 46 { state = .number(.dot) } else if b == 101 || b == 69 { state = .number(.exp) } else if digit { throw bad("a number with a leading zero") } else { try end() }
        case .whole:
            if digit { return }
            if b == 46 { state = .number(.dot) } else if b == 101 || b == 69 { state = .number(.exp) } else { try end() }
        case .dot:
            if digit { state = .number(.fraction) } else { throw bad("an unfinished number") }
        case .fraction:
            if digit { return }
            if b == 101 || b == 69 { state = .number(.exp) } else { try end() }
        case .exp:
            if b == 43 || b == 45 { state = .number(.expSign) } else if digit { state = .number(.expDigits) } else { throw bad("an unfinished number") }
        case .expSign:
            if digit { state = .number(.expDigits) } else { throw bad("an unfinished number") }
        case .expDigits:
            if digit { return }
            try end()
        }
    }

    func finish() throws {
        if case .number(let part) = state {
            switch part {
            case .zero, .whole, .fraction, .expDigits: valueDone()
            default: break
            }
        }
        guard case .done = state else { throw bad("it ends too early") }
    }
}

/// Checks that markup's tags nest and close, holding only the open tags.
final class XMLValidator: OutputValidator {
    private enum State {
        case text, tagStart, name, closeName, attrs, quote(UInt8), selfClose, special, comment(dashes: Int), done
    }

    private var state = State.text
    private var stack: [[UInt8]] = []
    private var current: [UInt8] = []
    private var sawRoot = false
    private var offset = 0

    private func bad(_ what: String) -> TemplateError {
        TemplateError(message: "The output isn't valid XML at byte \(offset): \(what).")
    }

    func feed(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        for b in bytes {
            try step(b)
            offset += 1
        }
    }

    private func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 10 || b == 13 || b == 9 }

    private func step(_ b: UInt8) throws {
        switch state {
        case .text:
            if b == 60 { state = .tagStart }
        case .tagStart:
            if b == 47 {
                current = []
                state = .closeName
            } else if b == 63 || b == 33 {
                state = b == 33 ? .comment(dashes: 0) : .special
            } else if isSpace(b) || b == 62 {
                throw bad("an empty tag")
            } else {
                current = [b]
                state = .name
            }
        case .name:
            if isSpace(b) {
                state = .attrs
            } else if b == 62 {
                open()
            } else if b == 47 {
                state = .selfClose
            } else {
                current.append(b)
            }
        case .attrs:
            if b == 34 || b == 39 {
                state = .quote(b)
            } else if b == 62 {
                open()
            } else if b == 47 {
                state = .selfClose
            }
        case .quote(let q):
            if b == q { state = .attrs } else if b == 60 { throw bad("'<' in an attribute") }
        case .selfClose:
            guard b == 62 else { throw bad("expected '>'") }
            sawRoot = true
            state = .text
        case .closeName:
            if b == 62 {
                guard let top = stack.last, top == current else {
                    throw bad("</\(String(decoding: current, as: UTF8.self))> closes nothing open")
                }
                stack.removeLast()
                state = .text
            } else if !isSpace(b) {
                current.append(b)
            }
        case .special:
            if b == 62 { state = .text }
        case .comment(let dashes):
            // Good enough for declarations and comments, which a template writes itself.
            if b == 62 && dashes != 1 { state = .text } else { state = .comment(dashes: b == 45 ? dashes + 1 : 0) }
        case .done:
            break
        }
    }

    private func open() {
        stack.append(current)
        sawRoot = true
        state = .text
    }

    func finish() throws {
        guard case .text = state else { throw bad("it ends inside a tag") }
        if let top = stack.last { throw bad("<\(String(decoding: top, as: UTF8.self))> is never closed") }
        guard sawRoot else { throw bad("there's no element") }
    }
}

/// Where rendered bytes go.
public protocol OutputSink: AnyObject {
    func write(_ bytes: UnsafeBufferPointer<UInt8>) throws
}

/// Keeps output in memory: small transforms, previews and tests.
public final class MemorySink: OutputSink {
    public private(set) var data = Data()

    public init() {}

    public func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        data.append(bytes)
    }

    public var string: String { String(decoding: data, as: UTF8.self) }
}

/// Streams output to a file, so its size never costs memory.
public final class FileSink: OutputSink {
    private let handle: FileHandle

    public init(url: URL, attributes: [FileAttributeKey: Any]? = nil) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes)
        handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none))
    }

    public func close() throws {
        try handle.close()
    }

    deinit {
        try? handle.close()
    }
}
