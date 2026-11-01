import Foundation

/// A parsed expression: a value and the filters it passes through.
struct TemplateExpr: Sendable {
    indirect enum Base: Sendable {
        case literal(TemplateValue)
        case path(String, [PathKey])
        case range(TemplateExpr, TemplateExpr)
    }

    enum PathKey: Sendable {
        case name(String)
        case index(TemplateExpr)
    }

    struct Filter: Sendable {
        let name: String
        let args: [TemplateExpr]
    }

    let base: Base
    let filters: [Filter]

    /// True when evaluating it may have to load a whole lazy list.
    var needsLists: Bool {
        if filters.contains(where: { TemplateFilters.takesLists.contains($0.name) || $0.args.contains(where: \.needsLists) }) { return true }
        switch base {
        case .literal: return false
        case .path(_, let keys):
            return keys.contains {
                switch $0 {
                case .name(let n): n == "size" || n == "first" || n == "last"
                case .index: true
                }
            }
        case .range: return false
        }
    }
}

indirect enum TemplateCondition: Sendable {
    case truthy(TemplateExpr)
    case compare(TemplateExpr, String, TemplateExpr)
    case and(TemplateCondition, TemplateCondition)
    case or(TemplateCondition, TemplateCondition)

    var needsLists: Bool {
        switch self {
        case .truthy(let e): e.needsLists
        case .compare(let a, _, let b): a.needsLists || b.needsLists
        case .and(let a, let b), .or(let a, let b): a.needsLists || b.needsLists
        }
    }
}

/// A block of nodes. `isSync` when nothing in it has to suspend, so a loop can
/// run it row by row at full speed.
struct TemplateBody: Sendable {
    let nodes: [TemplateNode]
    let isSync: Bool

    init(_ nodes: [TemplateNode]) {
        self.nodes = nodes
        isSync = nodes.allSatisfy(\.isSync)
    }
}

indirect enum TemplateNode: Sendable {
    case text([UInt8])
    case output(TemplateExpr, line: Int)
    case branch([(condition: TemplateCondition, negated: Bool, body: TemplateBody)], otherwise: TemplateBody?, line: Int)
    case choose(TemplateExpr, [(values: [TemplateExpr], body: TemplateBody)], otherwise: TemplateBody?, line: Int)
    case loop(name: String, collection: TemplateExpr, limit: TemplateExpr?, offset: TemplateExpr?, reversed: Bool, body: TemplateBody, otherwise: TemplateBody?, line: Int)
    case assign(String, TemplateExpr, line: Int)
    case capture(String, TemplateBody)
    case breakLoop
    case continueLoop

    var isSync: Bool {
        switch self {
        case .text, .breakLoop, .continueLoop: true
        case .output(let e, _), .assign(_, let e, _): !e.needsLists
        case .branch(let arms, let otherwise, _):
            arms.allSatisfy { !$0.condition.needsLists && $0.body.isSync } && (otherwise?.isSync ?? true)
        case .choose(let e, let arms, let otherwise, _):
            !e.needsLists && arms.allSatisfy { $0.body.isSync && !$0.values.contains(where: \.needsLists) } && (otherwise?.isSync ?? true)
        // A loop inside a loop may have to read Health.
        case .loop: false
        case .capture(_, let body): body.isSync
        }
    }
}

/// Liquid source to nodes. The language is a subset, kept free of anything
/// that could reach outside the data: no includes, no custom tags.
struct TemplateParser {
    private enum Token {
        case text(String)
        case output(String, line: Int, column: Int)
        case tag(name: String, rest: String, line: Int, column: Int)
    }

    private var tokens: [Token] = []
    private var at = 0
    private let lineOffset: Int

    init(source: String, lineOffset: Int = 0) throws {
        self.lineOffset = lineOffset
        tokens = try Self.tokenize(source, lineOffset: lineOffset)
    }

    static func parse(_ source: String, lineOffset: Int = 0) throws -> TemplateBody {
        var parser = try TemplateParser(source: source, lineOffset: lineOffset)
        let (body, end) = try parser.parseBlock(until: [])
        if let end { throw end.error("Unexpected {% \(end.name) %}") }
        return body
    }

    // MARK: Tokens

    private static func tokenize(_ source: String, lineOffset: Int) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(source.unicodeScalars)
        var i = 0
        var line = 1 + lineOffset
        var column = 1
        var trimNext = false

        func advance(to end: Int) {
            while i < end {
                if chars[i] == "\n" {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
                i += 1
            }
        }
        func string(_ a: Int, _ b: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: chars[a..<b])
            return String(s)
        }
        func find(_ text: String, from: Int) -> Int? {
            let needle = Array(text.unicodeScalars)
            guard chars.count >= needle.count else { return nil }
            var k = from
            while k <= chars.count - needle.count {
                if chars[k] == needle[0] && Array(chars[k..<(k + needle.count)]) == needle { return k }
                k += 1
            }
            return nil
        }
        func addText(_ a: Int, _ b: Int, trimEnd: Bool) {
            var text = string(a, b)
            if trimNext {
                text = String(text.drop { $0.isWhitespace })
                trimNext = false
            }
            if trimEnd {
                while text.last?.isWhitespace == true { text.removeLast() }
            }
            if !text.isEmpty { out.append(.text(text)) }
        }

        while i < chars.count {
            var open: Int?
            var k = i
            while k + 1 < chars.count {
                if chars[k] == "{" && (chars[k + 1] == "{" || chars[k + 1] == "%") {
                    open = k
                    break
                }
                k += 1
            }
            guard let start = open else {
                addText(i, chars.count, trimEnd: false)
                advance(to: chars.count)
                break
            }
            let isOutput = chars[start + 1] == "{"
            let trimBefore = start + 2 < chars.count && chars[start + 2] == "-"
            addText(i, start, trimEnd: trimBefore)
            advance(to: start)
            let startLine = line
            let startColumn = column
            let close = isOutput ? "}}" : "%}"
            guard let end = find(close, from: start + 2) else {
                throw TemplateError(message: "\(isOutput ? "{{" : "{%") is never closed", line: startLine, column: startColumn)
            }
            let inner = start + 2 + (trimBefore ? 1 : 0)
            let trimAfter = end > inner && chars[end - 1] == "-"
            let content = string(inner, trimAfter ? end - 1 : end).trimmingCharacters(in: .whitespacesAndNewlines)
            advance(to: end + 2)
            trimNext = trimAfter
            if isOutput {
                out.append(.output(content, line: startLine, column: startColumn))
                continue
            }
            let name = String(content.prefix { !$0.isWhitespace })
            let rest = String(content.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "raw" || name == "comment" {
                let endTag = "end" + name
                var scan = i
                var found: (start: Int, end: Int, trim: Bool)?
                while let tag = find("{%", from: scan) {
                    guard let tagEnd = find("%}", from: tag) else { break }
                    let body = string(tag + 2, tagEnd).trimmingCharacters(in: CharacterSet(charactersIn: "- \n\t\r"))
                    if body == endTag {
                        found = (tag, tagEnd + 2, tagEnd > tag && chars[tagEnd - 1] == "-")
                        break
                    }
                    scan = tagEnd + 2
                }
                guard let found else { throw TemplateError(message: "{% \(name) %} is never closed", line: startLine, column: startColumn) }
                if name == "raw", found.start > i { out.append(.text(string(i, found.start))) }
                advance(to: found.end)
                trimNext = found.trim
                continue
            }
            out.append(.tag(name: name, rest: rest, line: startLine, column: startColumn))
        }
        return out
    }

    // MARK: Blocks

    private struct EndTag {
        let name: String
        let rest: String
        let line: Int
        let column: Int

        func error(_ message: String) -> TemplateError {
            TemplateError(message: message, line: line, column: column)
        }
    }

    /// Nodes up to one of the closing tags, which is returned unconsumed-free:
    /// it's been read, and the caller decides what it means.
    private mutating func parseBlock(until closers: Set<String>) throws -> (TemplateBody, EndTag?) {
        var nodes: [TemplateNode] = []
        while at < tokens.count {
            let token = tokens[at]
            at += 1
            switch token {
            case .text(let s):
                nodes.append(.text(Array(s.utf8)))
            case .output(let content, let line, let column):
                var lex = try ExprLexer(content, line: line, column: column)
                let expr = try lex.filtered()
                try lex.expectEnd()
                nodes.append(.output(expr, line: line))
            case .tag(let name, let rest, let line, let column):
                if closers.contains(name) {
                    return (TemplateBody(nodes), EndTag(name: name, rest: rest, line: line, column: column))
                }
                nodes.append(try parseTag(name, rest, line: line, column: column))
            }
        }
        return (TemplateBody(nodes), nil)
    }

    private mutating func block(until closers: Set<String>, opener: String, line: Int, column: Int) throws -> (TemplateBody, EndTag) {
        let (body, end) = try parseBlock(until: closers)
        guard let end else { throw TemplateError(message: "{% \(opener) %} is never closed", line: line, column: column) }
        return (body, end)
    }

    private mutating func parseTag(_ name: String, _ rest: String, line: Int, column: Int) throws -> TemplateNode {
        switch name {
        case "if", "unless":
            var arms: [(condition: TemplateCondition, negated: Bool, body: TemplateBody)] = []
            var otherwise: TemplateBody?
            var condition = try Self.condition(rest, line: line, column: column)
            var negated = name == "unless"
            let closer = "end" + name
            while true {
                let (body, end) = try block(until: [closer, "elsif", "else"], opener: name, line: line, column: column)
                arms.append((condition, negated, body))
                if end.name == closer { break }
                if end.name == "else" {
                    let (other, final) = try block(until: [closer], opener: name, line: line, column: column)
                    guard final.name == closer else { throw final.error("Expected {% \(closer) %}") }
                    otherwise = other
                    break
                }
                condition = try Self.condition(end.rest, line: end.line, column: end.column)
                negated = false
            }
            return .branch(arms, otherwise: otherwise, line: line)

        case "case":
            var lex = try ExprLexer(rest, line: line, column: column)
            let subject = try lex.filtered()
            try lex.expectEnd()
            let (_, first) = try block(until: ["when", "else", "endcase"], opener: "case", line: line, column: column)
            var arms: [(values: [TemplateExpr], body: TemplateBody)] = []
            var otherwise: TemplateBody?
            var current = first
            while current.name != "endcase" {
                if current.name == "else" {
                    let (body, end) = try block(until: ["endcase"], opener: "case", line: line, column: column)
                    otherwise = body
                    current = end
                    continue
                }
                var values = try ExprLexer(current.rest, line: current.line, column: current.column)
                var list = [try values.filtered()]
                while try values.acceptSeparator() { list.append(try values.filtered()) }
                try values.expectEnd()
                let (body, end) = try block(until: ["when", "else", "endcase"], opener: "case", line: line, column: column)
                arms.append((list, body))
                current = end
            }
            return .choose(subject, arms, otherwise: otherwise, line: line)

        case "for":
            var lex = try ExprLexer(rest, line: line, column: column)
            let variable = try lex.identifier()
            guard try lex.acceptWord("in") else { throw TemplateError(message: "Expected 'in' after the loop's name", line: line, column: column) }
            let collection = try lex.filtered()
            var limit: TemplateExpr?
            var offset: TemplateExpr?
            var reversed = false
            while try !lex.atEnd {
                _ = try lex.acceptSeparator()
                if try lex.acceptWord("reversed") {
                    reversed = true
                } else if try lex.acceptWord("limit") {
                    try lex.expectColon()
                    limit = try lex.primary()
                } else if try lex.acceptWord("offset") {
                    try lex.expectColon()
                    offset = try lex.primary()
                } else {
                    throw TemplateError(message: "A loop takes limit, offset and reversed", line: line, column: column)
                }
            }
            let (body, end) = try block(until: ["endfor", "else"], opener: "for", line: line, column: column)
            var otherwise: TemplateBody?
            if end.name == "else" {
                let (other, _) = try block(until: ["endfor"], opener: "for", line: line, column: column)
                otherwise = other
            }
            return .loop(name: variable, collection: collection, limit: limit, offset: offset, reversed: reversed, body: body, otherwise: otherwise, line: line)

        case "assign":
            var lex = try ExprLexer(rest, line: line, column: column)
            let variable = try lex.identifier()
            try lex.expectEquals()
            let value = try lex.filtered()
            try lex.expectEnd()
            return .assign(variable, value, line: line)

        case "capture":
            var lex = try ExprLexer(rest, line: line, column: column)
            let variable = try lex.identifier()
            try lex.expectEnd()
            let (body, _) = try block(until: ["endcapture"], opener: "capture", line: line, column: column)
            return .capture(variable, body)

        case "break": return .breakLoop
        case "continue": return .continueLoop
        case "include", "render":
            throw TemplateError(message: "Templates can't include other files. Everything has to be in this one.", line: line, column: column)
        default:
            throw TemplateError(message: "Unknown tag '\(name)'", line: line, column: column)
        }
    }

    private static func condition(_ text: String, line: Int, column: Int) throws -> TemplateCondition {
        var lex = try ExprLexer(text, line: line, column: column)
        let out = try lex.condition()
        try lex.expectEnd()
        return out
    }
}

/// Expressions inside `{{ }}` and `{% %}`.
struct ExprLexer {
    enum Tok: Equatable {
        case word(String)
        case number(Double)
        case string(String)
        case symbol(String)
        case end
    }

    private var toks: [Tok] = []
    private var at = 0
    private let line: Int
    private let column: Int

    init(_ text: String, line: Int, column: Int) throws {
        self.line = line
        self.column = column
        let c = Array(text)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace {
                i += 1
            } else if ch == "'" || ch == "\"" {
                var j = i + 1
                var s = ""
                while j < c.count, c[j] != ch {
                    s.append(c[j])
                    j += 1
                }
                guard j < c.count else { throw TemplateError(message: "A string is never closed", line: line, column: column) }
                toks.append(.string(s))
                i = j + 1
            } else if ch.isNumber || (ch == "-" && i + 1 < c.count && c[i + 1].isNumber) {
                var j = i + 1
                while j < c.count, c[j].isNumber || (c[j] == "." && j + 1 < c.count && c[j + 1].isNumber) { j += 1 }
                toks.append(.number(Double(String(c[i..<j])) ?? 0))
                i = j
            } else if ch.isLetter || ch == "_" {
                var j = i + 1
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "-" || c[j] == "?" { j += 1 }
                toks.append(.word(String(c[i..<j])))
                i = j
            } else {
                let two = i + 1 < c.count ? String(c[i...(i + 1)]) : ""
                if ["==", "!=", "<>", "<=", ">=", ".."].contains(two) {
                    toks.append(.symbol(two))
                    i += 2
                } else if "|:,.[]()<>=".contains(ch) {
                    toks.append(.symbol(String(ch)))
                    i += 1
                } else {
                    throw TemplateError(message: "Unexpected '\(ch)'", line: line, column: column)
                }
            }
        }
        toks.append(.end)
    }

    private var peek: Tok { toks[at] }

    private mutating func take() -> Tok {
        defer { if at < toks.count - 1 { at += 1 } }
        return toks[at]
    }

    private func error(_ message: String) -> TemplateError {
        TemplateError(message: message, line: line, column: column)
    }

    var atEnd: Bool {
        get throws { peek == .end }
    }

    func expectEnd() throws {
        guard peek == .end else { throw error("Unexpected text after the expression") }
    }

    mutating func acceptSymbol(_ s: String) -> Bool {
        guard peek == .symbol(s) else { return false }
        _ = take()
        return true
    }

    /// `,` or the word `or`, between values.
    mutating func acceptSeparator() throws -> Bool {
        if acceptSymbol(",") { return true }
        return try acceptWord("or")
    }

    mutating func acceptWord(_ w: String) throws -> Bool {
        guard peek == .word(w) else { return false }
        _ = take()
        return true
    }

    mutating func expectColon() throws {
        guard acceptSymbol(":") else { throw error("Expected ':'") }
    }

    mutating func expectEquals() throws {
        guard acceptSymbol("=") else { throw error("Expected '='") }
    }

    mutating func identifier() throws -> String {
        guard case .word(let w) = take() else { throw error("Expected a name") }
        return w
    }

    mutating func filtered() throws -> TemplateExpr {
        let base = try primary()
        var filters: [TemplateExpr.Filter] = []
        while acceptSymbol("|") {
            let name = try identifier()
            guard TemplateFilters.names.contains(name) else { throw error("Unknown filter '\(name)'") }
            var args: [TemplateExpr] = []
            if acceptSymbol(":") {
                args.append(try primary())
                while acceptSymbol(",") { args.append(try primary()) }
            }
            filters.append(.init(name: name, args: args))
        }
        return TemplateExpr(base: base.base, filters: filters)
    }

    mutating func primary() throws -> TemplateExpr {
        switch take() {
        case .string(let s): return TemplateExpr(base: .literal(.string(s)), filters: [])
        case .number(let n): return TemplateExpr(base: .literal(.number(n)), filters: [])
        case .symbol("("):
            let from = try primary()
            guard acceptSymbol("..") else { throw error("Expected '..'") }
            let to = try primary()
            guard acceptSymbol(")") else { throw error("Expected ')'") }
            return TemplateExpr(base: .range(from, to), filters: [])
        case .word(let w):
            switch w {
            case "true": return TemplateExpr(base: .literal(.bool(true)), filters: [])
            case "false": return TemplateExpr(base: .literal(.bool(false)), filters: [])
            case "nil", "null": return TemplateExpr(base: .literal(.null), filters: [])
            case "empty": return TemplateExpr(base: .path("empty", []), filters: [])
            case "blank": return TemplateExpr(base: .path("blank", []), filters: [])
            default: break
            }
            var keys: [TemplateExpr.PathKey] = []
            while true {
                if acceptSymbol(".") {
                    keys.append(.name(try identifier()))
                } else if acceptSymbol("[") {
                    let inner = try filtered()
                    guard acceptSymbol("]") else { throw error("Expected ']'") }
                    keys.append(.index(inner))
                } else {
                    break
                }
            }
            return TemplateExpr(base: .path(w, keys), filters: [])
        default:
            throw error("Expected a value")
        }
    }

    /// `and` and `or` read right to left, as Liquid's do, with no brackets.
    mutating func condition() throws -> TemplateCondition {
        let left = try comparison()
        if try acceptWord("and") { return .and(left, try condition()) }
        if try acceptWord("or") { return .or(left, try condition()) }
        return left
    }

    private mutating func comparison() throws -> TemplateCondition {
        let a = try filtered()
        if case .symbol(let s) = peek, ["==", "!=", "<>", "<", ">", "<=", ">="].contains(s) {
            _ = take()
            return .compare(a, s == "<>" ? "!=" : s, try filtered())
        }
        if try acceptWord("contains") { return .compare(a, "contains", try filtered()) }
        return .truthy(a)
    }
}

/// A template's settings, from the `---` block at its top.
public struct TemplateHeader: Sendable, Equatable {
    public enum Partition: String, Sendable, CaseIterable {
        case none, day, week, month, year, workout, section, metric
    }

    public var name: String = ""
    public var description: String?
    public var format: OutputFormat = .text
    public var data: [ExtractSpec.Section] = []
    public var partition: Partition = .none
    /// A template of its own: what each part is called.
    public var filename: String?
    /// Overrides the format's media type.
    public var contentType: String?

    public init() {}
}

/// A template ready to render.
public struct ParsedTemplate: Sendable {
    public let header: TemplateHeader
    public let source: String
    let body: TemplateBody
    let filename: TemplateBody?
    /// Renders only the first partition: a test of a template over no data.
    var onlyFirstPartition = false

    public init(source: String) throws {
        self.source = source
        let (headerText, bodyText, headerLines) = Self.split(source)
        let header = try Self.parseHeader(headerText)
        guard !header.name.isEmpty else { throw TemplateError(message: "The template needs a name in its header") }
        self.header = header
        body = try TemplateParser.parse(bodyText, lineOffset: headerLines)
        filename = try header.filename.map { try TemplateParser.parse($0) }
    }

    /// Splits the `---` header from the body; a template without one is all body.
    private static func split(_ source: String) -> (String, String, Int) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return ("", source, 0) }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ("", source, 0) }
        let header = lines[1..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (header, body, close + 1)
    }

    static func parseHeader(_ text: String) throws -> TemplateHeader {
        var h = TemplateHeader()
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let number = index + 2
            guard let colon = line.firstIndex(of: ":") else { throw TemplateError(message: "Expected 'key: value' in the header", line: number) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            switch key {
            case "name": h.name = value
            case "description": h.description = value
            case "filename": h.filename = value
            case "content_type": h.contentType = value
            case "format":
                guard let f = OutputFormat(rawValue: value) else {
                    throw TemplateError(message: "Unknown format '\(value)'. Use \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).", line: number)
                }
                h.format = f
            case "partition":
                guard let p = TemplateHeader.Partition(rawValue: value) else {
                    throw TemplateError(message: "Unknown partition '\(value)'. Use \(TemplateHeader.Partition.allCases.map(\.rawValue).joined(separator: ", ")).", line: number)
                }
                h.partition = p
            case "data":
                let names = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                h.data = try names.map { name in
                    guard let s = ExtractSpec.Section(rawValue: Self.sectionName(name)) else { throw TemplateError(message: "Unknown data section '\(name)'", line: number) }
                    return s
                }
            default:
                throw TemplateError(message: "Unknown header key '\(key)'", line: number)
            }
        }
        return h
    }

    /// `heart_rate_notifications` and `heartRateNotifications` both work.
    private static func sectionName(_ name: String) -> String {
        var out = ""
        var upper = false
        for c in name {
            if c == "_" {
                upper = true
            } else {
                out.append(upper ? Character(c.uppercased()) : c)
                upper = false
            }
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }
}
