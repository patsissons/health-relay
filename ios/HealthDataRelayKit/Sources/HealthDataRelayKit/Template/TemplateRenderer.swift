import Foundation

/// What one render may use, so a bad template fails its own run and nothing else.
public struct TemplateLimits: Sendable {
    public var outputBytes: Int
    /// Loop rows, across all loops.
    public var loopRows: Int
    /// Rows a filter like `sort` may load into memory.
    public var materializedRows: Int
    public var deadline: Date?

    public init(outputBytes: Int = 4 << 30, loopRows: Int = 200_000_000, materializedRows: Int = 500_000, deadline: Date? = nil) {
        self.outputBytes = outputBytes
        self.loopRows = loopRows
        self.materializedRows = materializedRows
        self.deadline = deadline
    }
}

/// Runs a parsed template against data, writing as it goes.
final class TemplateRenderer {
    private enum Flow {
        case normal, broke, continued
    }

    /// Bytes buffered before they go to the sink and validator.
    private static let flushSize = 1 << 16

    let format: OutputFormat
    let limits: TemplateLimits
    private let clock: LocalClock
    var timeZone: TimeZone { clock.timeZone }
    private let sink: OutputSink
    private let validator: OutputValidator?
    private var buffer: [UInt8] = []
    private var captures: [[UInt8]] = []
    private var written = 0
    private var rows = 0
    /// Rows read from Health, as opposed to looped over: zero means nothing to send.
    private(set) var dataRows = 0
    private var globals: [String: TemplateValue]
    private var locals: [(name: String, value: TemplateValue)] = []
    private var currentLine: Int?

    init(format: OutputFormat, timeZone: TimeZone, globals: [String: TemplateValue], sink: OutputSink, limits: TemplateLimits) {
        self.format = format
        self.limits = limits
        self.globals = globals
        self.globals["empty"] = .object(EmptyKeyword())
        self.globals["blank"] = .object(EmptyKeyword())
        self.sink = sink
        clock = LocalClock(timeZone: timeZone)
        validator = format.makeValidator()
        buffer.reserveCapacity(Self.flushSize + 4096)
    }

    func run(_ body: TemplateBody) async throws {
        do {
            _ = try await render(body)
            try flush()
            try validator?.finish()
        } catch var error as TemplateError {
            if error.line == nil { error.line = currentLine }
            throw error
        }
    }

    // MARK: Output

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBufferPointer { bytes in
            try validator?.feed(bytes)
            try sink.write(bytes)
        }
        written += buffer.count
        buffer.removeAll(keepingCapacity: true)
        if written > limits.outputBytes {
            throw TemplateError(message: "The output passed its size limit of \(limits.outputBytes / (1 << 20)) MB.")
        }
    }

    private func emit(_ bytes: [UInt8]) throws {
        if captures.isEmpty {
            buffer.append(contentsOf: bytes)
            if buffer.count >= Self.flushSize { try flush() }
        } else {
            captures[captures.count - 1].append(contentsOf: bytes)
        }
    }

    private func emit(_ text: String) throws {
        if captures.isEmpty {
            buffer.append(contentsOf: text.utf8)
            if buffer.count >= Self.flushSize { try flush() }
        } else {
            captures[captures.count - 1].append(contentsOf: text.utf8)
        }
    }

    /// `{{ value }}`, made safe for the format.
    private func write(_ value: TemplateValue) throws {
        switch format {
        case .json:
            var out = ""
            try TemplateRenderer.writeJSON(value, into: &out, clock: clock)
            try emit(out)
        default:
            switch value {
            case .safe(let s): try emit(s)
            case .number, .bool, .null: try emit(text(value))
            default: try emit(format.escape(text(value)))
            }
        }
    }

    /// A value as canonical JSON. Lazy lists have to go through `writeAsync`.
    static func writeJSON(_ value: TemplateValue, into out: inout String, clock: LocalClock) throws {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSON.format(n)
        case .string(let s): JSON.quote(s, into: &out)
        case .safe(let s): out += s
        case .date(let d):
            out += "\""
            out += clock.stamp(d)
            out += "\""
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                try writeJSON(item, into: &out, clock: clock)
            }
            out += "]"
        case .object(let o):
            out += "{"
            var first = true
            for key in o.keys {
                guard let v = o.value(key) else { continue }
                if !first { out += "," }
                first = false
                JSON.quote(key, into: &out)
                out += ":"
                try writeJSON(v, into: &out, clock: clock)
            }
            out += "}"
        case .lazy:
            throw TemplateError(message: "This list is too large to write here. Use a {% for %} loop.")
        }
    }

    /// Like `write`, for values that may hold lazy lists: those stream.
    private func writeAsync(_ value: TemplateValue) async throws {
        if case .object(let o) = value, let tree = o as? MarkdownTree {
            try await writeTree(tree.value, level: tree.level)
            return
        }
        guard format == .json else {
            if case .lazy(let list) = value {
                let rows = try await list.materialize(limit: limits.materializedRows)
                try write(.array(rows))
            } else {
                try write(value)
            }
            return
        }
        switch value {
        case .lazy(let list):
            try emit("[")
            let reader = list.make()
            var first = true
            while let page = try await reader.next() {
                try checkTime()
                for row in page {
                    if !first { try emit(",") }
                    first = false
                    try await writeAsync(row)
                }
            }
            try emit("]")
        case .array(let items):
            try emit("[")
            for (i, item) in items.enumerated() {
                if i > 0 { try emit(",") }
                try await writeAsync(item)
            }
            try emit("]")
        case .object(let o):
            try emit("{")
            var first = true
            for key in o.keys {
                guard let v = o.value(key) else { continue }
                if !first { try emit(",") }
                first = false
                var name = ""
                JSON.quote(key, into: &name)
                try emit(name)
                try emit(":")
                try await writeAsync(v)
            }
            try emit("}")
        default:
            try write(value)
        }
    }

    // MARK: Markdown trees

    /// Whether a value is a plain field of a table.
    private func isFlat(_ v: TemplateValue) -> Bool {
        switch v {
        case .object, .array, .lazy: false
        default: true
        }
    }

    /// A field as Markdown shows it: dates in UTC, text safe for a table.
    private func treeCell(_ v: TemplateValue, csv: Bool = false) -> String {
        if case .date(let d) = v { return clock.isoUTC(d) }
        let plain = text(v)
        switch v {
        case .number, .bool, .null: return plain
        default: return (csv ? OutputFormat.csv : .markdown).escape(plain)
        }
    }

    private func treeHeading(_ title: String, _ level: Int) throws {
        try emit("\n" + String(repeating: "#", count: Swift.min(level, 6)) + " " + title + "\n")
    }

    /// "activeEnergyBurned" -> "Active Energy Burned".
    private func treeTitle(_ key: String) -> String {
        var out = ""
        for c in key {
            if c.isUppercase && !out.isEmpty { out += " " }
            out.append(out.isEmpty ? Character(c.uppercased()) : c)
        }
        return out
    }

    /// An object as nested headings: its plain fields in a `Summary` table,
    /// each nested object under its own heading, and each list in the shape
    /// that reads best. Stops getting deeper at level 6, Markdown's last.
    private func writeTree(_ value: TemplateValue, level: Int) async throws {
        guard case .object(let o) = value else {
            try emit(treeCell(value))
            return
        }
        var flat: [(String, TemplateValue)] = []
        var nested: [(String, TemplateValue)] = []
        for key in o.keys {
            guard let v = o.value(key) else { continue }
            if isFlat(v) { flat.append((key, v)) } else { nested.append((key, v)) }
        }
        if !flat.isEmpty {
            try treeHeading("Summary", level)
            try emit("\n| Field | Value |\n|---|---|\n")
            for (key, v) in flat { try emit("| \(key) | \(treeCell(v)) |\n") }
        }
        for (key, v) in nested {
            try treeHeading(treeTitle(key), level)
            switch v {
            case .object: try await writeTree(v, level: level + 1)
            default: try await writeTreeList(v, level: level + 1)
            }
        }
    }

    /// Rows of plain fields stream as fenced CSV; rows with anything nested
    /// each get a heading, by their start time when they have one.
    private func writeTreeList(_ value: TemplateValue, level: Int) async throws {
        let reader: PageReader
        switch value {
        case .lazy(let list): reader = list.make()
        case .array(let items):
            var pending: [TemplateValue]? = items.isEmpty ? nil : items
            reader = PageReader {
                defer { pending = nil }
                return pending
            }
        default: return
        }
        var number = 0
        var columns: [String]?
        var deep = false
        while let page = try await reader.next() {
            try checkTime()
            for row in page {
                try countRow()
                number += 1
                guard case .object(let o) = row else { continue }
                if columns == nil {
                    deep = o.keys.contains { key in o.value(key).map { !isFlat($0) } ?? false }
                    columns = o.keys
                    if !deep { try emit("\n```csv\n\(o.keys.joined(separator: ","))\n") }
                }
                if deep {
                    var title = "Record \(number)"
                    if let start = o.value("start"), case .date(let d) = start { title = clock.isoUTC(d) }
                    try treeHeading(title, level)
                    try await writeTree(row, level: level + 1)
                } else {
                    try emit((columns ?? []).map { key in o.value(key).map { treeCell($0, csv: true) } ?? "" }.joined(separator: ",") + "\n")
                }
            }
        }
        if columns != nil && !deep { try emit("```\n") }
    }

    /// Plain text of a value: what filters and non-JSON output see.
    func text(_ value: TemplateValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSON.format(n)
        case .string(let s), .safe(let s): return s
        case .date(let d): return clock.stamp(d)
        case .array(let items): return items.map(text).joined()
        case .object:
            var out = ""
            try? TemplateRenderer.writeJSON(value, into: &out, clock: clock)
            return out
        case .lazy: return ""
        }
    }

    // MARK: Rendering

    private func render(_ body: TemplateBody) async throws -> Flow {
        for node in body.nodes {
            let flow = try await render(node)
            if flow != .normal { return flow }
        }
        return .normal
    }

    private func renderSync(_ body: TemplateBody) throws -> Flow {
        for node in body.nodes {
            switch node {
            case .text(let bytes):
                try emit(bytes)
            case .output(let e, let line):
                currentLine = line
                try write(try eval(e))
            case .branch(let arms, let otherwise, let line):
                currentLine = line
                var taken = false
                for arm in arms where try test(arm.condition) != arm.negated {
                    taken = true
                    let flow = try renderSync(arm.body)
                    if flow != .normal { return flow }
                    break
                }
                if !taken, let otherwise {
                    let flow = try renderSync(otherwise)
                    if flow != .normal { return flow }
                }
            case .choose(let e, let arms, let otherwise, let line):
                currentLine = line
                let subject = try eval(e)
                var taken = false
                choosing: for arm in arms {
                    for v in arm.values where equal(subject, try eval(v)) {
                        taken = true
                        let flow = try renderSync(arm.body)
                        if flow != .normal { return flow }
                        break choosing
                    }
                }
                if !taken, let otherwise {
                    let flow = try renderSync(otherwise)
                    if flow != .normal { return flow }
                }
            case .assign(let name, let e, let line):
                currentLine = line
                setVariable(name, try eval(e))
            case .capture(let name, let inner):
                captures.append([])
                let flow = try renderSync(inner)
                setVariable(name, .string(String(decoding: captures.removeLast(), as: UTF8.self)))
                if flow != .normal { return flow }
            case .breakLoop:
                return .broke
            case .continueLoop:
                return .continued
            case .loop:
                // A sync body never holds a loop: TemplateNode.isSync says so.
                throw TemplateError(message: "Internal: a loop in a sync body.")
            }
        }
        return .normal
    }

    private func render(_ node: TemplateNode) async throws -> Flow {
        switch node {
        case .text(let bytes):
            try emit(bytes)
        case .output(let e, let line):
            currentLine = line
            try await writeAsync(try await evalAsync(e))
        case .branch(let arms, let otherwise, let line):
            currentLine = line
            for arm in arms where try await testAsync(arm.condition) != arm.negated {
                return try await render(arm.body)
            }
            if let otherwise { return try await render(otherwise) }
        case .choose(let e, let arms, let otherwise, let line):
            currentLine = line
            let subject = try await evalAsync(e)
            for arm in arms {
                for v in arm.values where equal(subject, try await evalAsync(v)) {
                    return try await render(arm.body)
                }
            }
            if let otherwise { return try await render(otherwise) }
        case .assign(let name, let e, let line):
            currentLine = line
            setVariable(name, try await evalAsync(e))
        case .capture(let name, let inner):
            captures.append([])
            let flow = try await render(inner)
            setVariable(name, .string(String(decoding: captures.removeLast(), as: UTF8.self)))
            return flow
        case .breakLoop:
            return .broke
        case .continueLoop:
            return .continued
        case .loop(let name, let collection, let limit, let offset, let reversed, let body, let otherwise, let line):
            currentLine = line
            try await runLoop(name: name, collection: collection, limit: limit, offset: offset, reversed: reversed, body: body, otherwise: otherwise, line: line)
        }
        return .normal
    }

    private func setVariable(_ name: String, _ value: TemplateValue) {
        globals[name] = value
    }

    // MARK: Loops

    /// `forloop`: index, first, last and the like.
    private struct LoopInfo: TemplateObject {
        let index0: Int
        let length: Int?
        let isLast: Bool

        var keys: [String] { [] }

        func value(_ key: String) -> TemplateValue? {
            switch key {
            case "index": .number(Double(index0 + 1))
            case "index0": .number(Double(index0))
            case "first": .bool(index0 == 0)
            case "last": .bool(isLast)
            case "length": length.map { .number(Double($0)) }
            case "rindex": length.map { .number(Double($0 - index0)) }
            case "rindex0": length.map { .number(Double($0 - index0 - 1)) }
            default: nil
            }
        }
    }

    private func countRow() throws {
        rows += 1
        if rows > limits.loopRows {
            throw TemplateError(message: "Loops passed their limit of \(limits.loopRows) rows.")
        }
        if rows & 0x3FF == 0, let deadline = limits.deadline, Date() > deadline {
            throw TemplateError(message: "The template ran out of time.")
        }
    }

    private func checkTime() throws {
        try Task.checkCancellation()
        if let deadline = limits.deadline, Date() > deadline {
            throw TemplateError(message: "The template ran out of time.")
        }
    }

    private func runLoop(name: String, collection: TemplateExpr, limit: TemplateExpr?, offset: TemplateExpr?, reversed: Bool, body: TemplateBody, otherwise: TemplateBody?, line: Int) async throws {
        var source = try await evalAsync(collection)
        if case .object(let o) = source, let list = o.list { source = list }
        let limitCount = try limit.map { try eval($0) }.flatMap(number).map { Int($0) }
        let offsetCount = try offset.map { try eval($0) }.flatMap(number).map { Int($0) } ?? 0

        if case .lazy(let list) = source {
            if reversed {
                source = .array(try await list.materialize(limit: limits.materializedRows))
            } else {
                try await runLazy(name: name, list: list, limit: limitCount, offset: offsetCount, body: body, otherwise: otherwise)
                return
            }
        }

        guard case .array(var items) = source else {
            if let otherwise { _ = try await render(otherwise) }
            return
        }
        if offsetCount > 0 { items = Array(items.dropFirst(offsetCount)) }
        if let limitCount { items = Array(items.prefix(Swift.max(0, limitCount))) }
        if reversed { items.reverse() }
        if items.isEmpty {
            if let otherwise { _ = try await render(otherwise) }
            return
        }
        let depth = locals.count
        locals.append((name, .null))
        locals.append(("forloop", .null))
        defer { locals.removeLast(locals.count - depth) }
        for (i, item) in items.enumerated() {
            try countRow()
            locals[depth].value = item
            locals[depth + 1].value = .object(LoopInfo(index0: i, length: items.count, isLast: i == items.count - 1))
            let flow = try await render(body)
            if flow == .broke { break }
        }
    }

    /// Walks a list a page at a time. Reads one page ahead, so `forloop.last`
    /// is right. When the body can't suspend, a whole page runs at full speed.
    private func runLazy(name: String, list: LazyList, limit: Int?, offset: Int, body: TemplateBody, otherwise: TemplateBody?) async throws {
        let reader = list.make()
        var page = try await reader.next()
        var skipped = 0
        var produced = 0
        let depth = locals.count
        locals.append((name, .null))
        locals.append(("forloop", .null))
        defer { locals.removeLast(locals.count - depth) }
        let fast = body.isSync && list.plainItems
        outer: while let rows = page {
            try checkTime()
            var next: [TemplateValue]?
            var fetchedNext = false
            for (i, item) in rows.enumerated() {
                if skipped < offset {
                    skipped += 1
                    continue
                }
                var isLast = false
                if i == rows.count - 1 {
                    next = try await reader.next()
                    fetchedNext = true
                    isLast = next == nil
                }
                if let limit, produced + 1 == limit { isLast = true }
                try countRow()
                dataRows += 1
                locals[depth].value = item
                locals[depth + 1].value = .object(LoopInfo(index0: produced, length: nil, isLast: isLast))
                let flow = fast ? try renderSync(body) : try await render(body)
                produced += 1
                if flow == .broke { break outer }
                if let limit, produced >= limit { break outer }
            }
            if !fetchedNext { next = try await reader.next() }
            page = next
        }
        if produced == 0, let otherwise {
            _ = try await render(otherwise)
        }
    }

    // MARK: Evaluating

    private func lookup(_ name: String) -> TemplateValue? {
        var i = locals.count - 1
        while i >= 0 {
            if locals[i].name == name { return locals[i].value }
            i -= 1
        }
        return globals[name]
    }

    /// Evaluates with no suspension; a lazy list needing to load is an error.
    func eval(_ e: TemplateExpr) throws -> TemplateValue {
        var value = try base(e.base)
        for f in e.filters {
            let args = try f.args.map { try eval($0) }
            value = try TemplateFilters.apply(f.name, value, args, renderer: self)
        }
        return value
    }

    private func base(_ base: TemplateExpr.Base) throws -> TemplateValue {
        switch base {
        case .literal(let v):
            return v
        case .range(let a, let b):
            let from = Int(number(try eval(a)) ?? 0)
            let to = Int(number(try eval(b)) ?? 0)
            guard to >= from else { return .array([]) }
            guard to - from < limits.materializedRows else { throw TemplateError(message: "That range is too long.") }
            return .array((from...to).map { .number(Double($0)) })
        case .path(let root, let keys):
            guard var value = lookup(root) else { return .null }
            for key in keys {
                switch key {
                case .name(let name):
                    value = member(value, name)
                case .index(let inner):
                    value = index(value, try eval(inner))
                }
            }
            return value
        }
    }

    private func member(_ value: TemplateValue, _ name: String) -> TemplateValue {
        switch value {
        case .object(let o): return o.value(name) ?? .null
        case .array(let items):
            switch name {
            case "size": return .number(Double(items.count))
            case "first": return items.first ?? .null
            case "last": return items.last ?? .null
            default: return .null
            }
        case .string(let s), .safe(let s):
            return name == "size" ? .number(Double(s.count)) : .null
        default:
            return .null
        }
    }

    private func index(_ value: TemplateValue, _ key: TemplateValue) -> TemplateValue {
        switch (value, key) {
        case (.array(let items), .number(let n)):
            let i = n < 0 ? items.count + Int(n) : Int(n)
            return items.indices.contains(i) ? items[i] : .null
        case (.object(let o), .string(let s)):
            return o.value(s) ?? .null
        default:
            return .null
        }
    }

    /// Evaluates, loading any lazy list a list filter or `.size` is about to use.
    private func evalAsync(_ e: TemplateExpr) async throws -> TemplateValue {
        guard e.needsLists else { return try eval(e) }
        var value = try await baseAsync(e.base)
        for f in e.filters {
            var args: [TemplateValue] = []
            for a in f.args { args.append(try await evalAsync(a)) }
            if case .lazy(let list) = value, TemplateFilters.takesLists.contains(f.name) {
                value = .array(try await list.materialize(limit: limits.materializedRows))
            }
            value = try TemplateFilters.apply(f.name, value, args, renderer: self)
        }
        return value
    }

    private func baseAsync(_ base: TemplateExpr.Base) async throws -> TemplateValue {
        guard case .path(let root, let keys) = base else { return try self.base(base) }
        guard var value = lookup(root) else { return .null }
        for key in keys {
            // `metrics.size` counts the list; `metrics.step_count` reads the field.
            if case .object(let o) = value, let list = o.list, case .name(let name) = key, name == "size" || name == "first" || name == "last" { value = list }
            if case .lazy(let list) = value {
                if case .name(let name) = key, name == "first" {
                    let reader = list.make()
                    value = try await reader.next()?.first ?? .null
                    continue
                }
                value = .array(try await list.materialize(limit: limits.materializedRows))
            }
            switch key {
            case .name(let name):
                value = member(value, name)
            case .index(let inner):
                value = index(value, try await evalAsync(inner))
            }
        }
        return value
    }

    func number(_ v: TemplateValue) -> Double? {
        switch v {
        case .number(let n): n
        case .string(let s), .safe(let s): Double(s)
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    func dateText(_ date: Date, _ pattern: String) -> String { clock.format(date, pattern) }

    func iso(_ date: Date) -> String { clock.isoUTC(date) }

    // MARK: Conditions

    private func test(_ c: TemplateCondition) throws -> Bool {
        switch c {
        case .truthy(let e): return try eval(e).isTruthy
        case .and(let a, let b): return try test(a) && test(b)
        case .or(let a, let b): return try test(a) || test(b)
        case .compare(let a, let op, let b): return compare(try eval(a), op, try eval(b))
        }
    }

    private func testAsync(_ c: TemplateCondition) async throws -> Bool {
        switch c {
        case .truthy(let e):
            return try await evalAsync(e).isTruthy
        case .and(let a, let b):
            if try await testAsync(a) { return try await testAsync(b) }
            return false
        case .or(let a, let b):
            if try await testAsync(a) { return true }
            return try await testAsync(b)
        case .compare(let a, let op, let b):
            return compare(try await evalAsync(a), op, try await evalAsync(b))
        }
    }

    func equal(_ a: TemplateValue, _ b: TemplateValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.date(let x), .date(let y)): return x == y
        case (.string(let x), .string(let y)), (.safe(let x), .safe(let y)), (.string(let x), .safe(let y)), (.safe(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(equal)
        default: return false
        }
    }

    private func compare(_ a: TemplateValue, _ op: String, _ b: TemplateValue) -> Bool {
        switch op {
        case "==": return equal(a, b) || isEmptyMatch(a, b)
        case "!=": return !(equal(a, b) || isEmptyMatch(a, b))
        case "contains":
            switch a {
            case .string(let s), .safe(let s): return s.contains(text(b))
            case .array(let items): return items.contains { equal($0, b) }
            default: return false
            }
        default:
            let order: Int?
            switch (a, b) {
            case (.number(let x), .number(let y)): order = x < y ? -1 : (x > y ? 1 : 0)
            case (.date(let x), .date(let y)): order = x < y ? -1 : (x > y ? 1 : 0)
            case (.string(let x), .string(let y)), (.safe(let x), .safe(let y)): order = x < y ? -1 : (x > y ? 1 : 0)
            default: order = nil
            }
            guard let order else { return false }
            switch op {
            case "<": return order < 0
            case ">": return order > 0
            case "<=": return order <= 0
            case ">=": return order >= 0
            default: return false
            }
        }
    }

    /// `x == empty` and `x == blank`, which parse as paths to nothing.
    private func isEmptyMatch(_ a: TemplateValue, _ b: TemplateValue) -> Bool {
        if case .object(let o) = b, o is EmptyKeyword { return a.isEmptyish }
        if case .object(let o) = a, o is EmptyKeyword { return b.isEmptyish }
        return false
    }
}

/// What `markdown_tree` hands to the writer, which streams it.
struct MarkdownTree: TemplateObject {
    let value: TemplateValue
    let level: Int

    var keys: [String] { [] }
    func value(_ key: String) -> TemplateValue? { nil }
}

/// The value of the `empty` and `blank` keywords.
struct EmptyKeyword: TemplateObject {
    var keys: [String] { [] }
    func value(_ key: String) -> TemplateValue? { nil }
}
