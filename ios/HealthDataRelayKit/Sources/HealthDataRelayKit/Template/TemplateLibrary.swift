import Foundation

/// A user's own template, saved as a text file.
public struct CustomTemplate: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var source: String
    /// What it calls itself, or nil if the header doesn't parse yet.
    public var name: String?
    public var format: OutputFormat?

    init(id: UUID, source: String) {
        self.id = id
        self.source = source
        let parsed = try? ParsedTemplate(source: source)
        name = parsed?.header.name
        format = parsed?.header.format
    }
}

/// The built-in templates and the user's own, in `templates/<id>.liquid`.
public struct TemplateLibrary: Sendable {
    /// A template to choose from.
    public struct Entry: Identifiable, Hashable, Sendable {
        public var ref: TemplateRef
        public var name: String
        public var description: String?
        public var format: OutputFormat

        public var id: TemplateRef { ref }

        public init(ref: TemplateRef, name: String, description: String? = nil, format: OutputFormat) {
            self.ref = ref
            self.name = name
            self.description = description
            self.format = format
        }
    }

    /// A file larger than this isn't a template.
    public static let maxBytes = 1 << 20

    public let files: FileStore

    public init(files: FileStore) {
        self.files = files
    }

    private var folder: URL { files.root.appendingPathComponent("templates", isDirectory: true) }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).liquid") }

    public func custom() -> [CustomTemplate] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> CustomTemplate? in
            guard name.hasSuffix(".liquid"), let id = UUID(uuidString: String(name.dropLast(7))),
                  let text = try? String(contentsOf: url(id), encoding: .utf8) else { return nil }
            return CustomTemplate(id: id, source: text)
        }.sorted { ($0.name ?? "", $0.id.uuidString) < ($1.name ?? "", $1.id.uuidString) }
    }

    /// Everything that can be chosen: built-ins then the user's own that parse.
    public func entries() -> [Entry] {
        let builtIn = BuiltInTemplates.all.compactMap { id -> Entry? in
            guard let t = try? BuiltInTemplates.template(id) else { return nil }
            return Entry(ref: .builtIn(id), name: t.header.name, description: t.header.description, format: t.header.format)
        }
        let own = custom().compactMap { c -> Entry? in
            guard let name = c.name, let format = c.format else { return nil }
            return Entry(ref: .custom(c.id), name: name, description: (try? ParsedTemplate(source: c.source))?.header.description, format: format)
        }
        return builtIn + own
    }

    /// What a pipeline can use besides the native push. The native format's
    /// twin is only there to copy, so it's listed just for one already using it.
    public func transforms(selected: TemplateRef? = nil) -> [Entry] {
        entries().filter { $0.ref != .builtIn(BuiltInTemplates.healthDataRelay) || $0.ref == selected }
    }

    public func source(_ ref: TemplateRef) -> String? {
        switch ref {
        case .builtIn(let id): return BuiltInTemplates.source(id)
        case .custom(let id): return try? String(contentsOf: url(id), encoding: .utf8)
        }
    }

    /// Saves a template. One that doesn't parse throws, and the old one stays,
    /// so a pipeline using it can't break on a half-finished edit.
    @discardableResult
    public func save(_ source: String, id: UUID = UUID()) throws -> UUID {
        guard source.utf8.count <= Self.maxBytes else {
            throw TemplateError(message: "That's over \(Self.maxBytes / (1 << 20)) MB, too large for a template.")
        }
        _ = try ParsedTemplate(source: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return id
    }

    /// Imports a template's text from a file someone handed the app.
    public func importFile(_ file: URL) throws -> UUID {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= Self.maxBytes, let text = String(data: data, encoding: .utf8) else {
            throw TemplateError(message: "That doesn't look like a template: it should be a small text file.")
        }
        return try save(text)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// A safe file name for sharing a template.
    public static func exportName(_ name: String) -> String {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return (safe.isEmpty ? "template" : safe) + ".liquid"
    }
}

/// A template's output over sample or real data, for its editor.
public enum TemplatePreview {
    public struct Result: Sendable, Equatable {
        public struct Part: Sendable, Equatable {
            public var filename: String
            public var text: String
            public var isTruncated: Bool
        }

        public var parts: [Part] = []
        public var error: String?
        public var line: Int?
        public var column: Int?

        public init() {}
    }

    /// Each part keeps this many bytes for showing.
    public static let shownBytes = 64 * 1024

    /// Renders with limits tight enough to run on every keystroke's pause.
    public static func render(source: String, store: HealthQuerying? = nil, calendar: Calendar = .local(), now: Date = Date()) async -> Result {
        var out = Result()
        do {
            let template = try ParsedTemplate(source: source)
            let sample = store ?? SampleHealth(now: now, calendar: calendar)
            let day = Day(now, calendar: calendar)
            let range = DateInterval(start: day.adding(-2).start(in: calendar), end: now)
            let sections = template.header.data.isEmpty ? Set(ExtractSpec.Section.allCases) : Set(template.header.data)
            let spec = ExtractSpec(sections: sections, range: .fixed(range), grouping: .days)
            let extractor = Extractor(store: sample, spec: spec, calendar: calendar, ranges: [range])
            let export = ExportInfo(device: Device(name: "iPhone", model: "iPhone", os: "", app: "Health Data Relay"), generatedAt: now, timeZone: calendar.timeZone)
            var sinks: [CappedSink] = []
            var limits = TemplateLimits(outputBytes: 16 << 20, loopRows: 500_000, materializedRows: 50_000)
            limits.deadline = Date().addingTimeInterval(5)
            let run = try await TemplateTransformer(template: template, limits: limits).run(extractor: extractor, export: export) { _, _ in
                let sink = CappedSink(cap: shownBytes)
                sinks.append(sink)
                return sink
            }
            out.parts = run.parts.map { Result.Part(filename: $0.filename, text: sinks[$0.index].text, isTruncated: sinks[$0.index].truncated) }
        } catch let error as TemplateError {
            out.error = error.message
            out.line = error.line
            out.column = error.column
        } catch {
            out.error = error.localizedDescription
        }
        return out
    }
}

/// Keeps the start of what's written; the rest still counts for validation.
final class CappedSink: OutputSink {
    private let cap: Int
    private var data = Data()
    private(set) var truncated = false

    init(cap: Int) {
        self.cap = cap
    }

    func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        guard data.count < cap else {
            truncated = truncated || !bytes.isEmpty
            return
        }
        let take = min(bytes.count, cap - data.count)
        data.append(UnsafeBufferPointer(rebasing: bytes[0..<take]))
        if take < bytes.count { truncated = true }
    }

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Plausible made-up data, so a template can be tried without reading Health.
public struct SampleHealth: HealthQuerying {
    private let days: [Date]
    private let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .local()) {
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        days = (0..<3).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }

    private static let bases: [String: (value: Double, spread: Double)] = [
        "HKQuantityTypeIdentifierStepCount": (8200, 1400), "HKQuantityTypeIdentifierActiveEnergyBurned": (520, 90),
        "HKQuantityTypeIdentifierDistanceWalkingRunning": (6.3, 1.2), "HKQuantityTypeIdentifierHeartRate": (72, 18),
        "HKQuantityTypeIdentifierRestingHeartRate": (58, 3), "HKQuantityTypeIdentifierBodyMass": (78.4, 0.3),
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": (46, 8), "HKQuantityTypeIdentifierBloodPressureSystolic": (118, 6),
        "HKQuantityTypeIdentifierBloodPressureDiastolic": (76, 4),
    ]

    private func samples(_ type: String, unitFactor: Double = 1) -> [DetailedQuantity] {
        guard let base = Self.bases[type] else { return [] }
        return days.enumerated().map { i, day in
            let at = calendar.date(byAdding: .hour, value: 9, to: day)!
            let wobble = [0.4, -0.6, 0.2][i % 3] * base.spread
            return DetailedQuantity(id: "\(type)-\(i)", source: "Sample Watch", start: at, end: at.addingTimeInterval(1800), value: (base.value + wobble) * unitFactor,
                                    min: type.hasSuffix("HeartRate") ? base.value - base.spread : nil, max: type.hasSuffix("HeartRate") ? base.value + base.spread : nil)
        }
    }

    public func requestAuthorization(types: [HealthType], extras: ReadExtras) async throws {}

    public func buckets(_ query: BucketQuery) async throws -> [StatBucket] {
        let plan = query.plan
        var edge = plan.anchor
        var out: [StatBucket] = []
        let all = samples(query.type)
        while edge < plan.span.end {
            let end: Date
            switch plan.step {
            case .seconds(let n): end = edge.addingTimeInterval(Double(n))
            case .days(let n): end = calendar.date(byAdding: .day, value: n, to: edge)!
            case .months(let n): end = calendar.date(byAdding: .month, value: n, to: edge)!
            case .years(let n): end = calendar.date(byAdding: .year, value: n, to: edge)!
            }
            let inside = all.filter { edge <= $0.start && $0.start < end }.map(\.value)
            if !inside.isEmpty {
                let value: StatBucket.SourceValue = query.style == .sum
                    ? .init(source: "Sample Watch", sum: inside.reduce(0, +))
                    : .init(source: "Sample Watch", avg: inside.reduce(0, +) / Double(inside.count), min: inside.min(), max: inside.max())
                out.append(StatBucket(start: edge, end: end, merged: value, sources: [value]))
            }
            edge = end
        }
        return out
    }

    public func quantityPage(_ type: String, unit: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedQuantity> {
        SamplePage(items: cursor == nil ? samples(type).filter { $0.start < range.end && $0.end > range.start } : [], next: nil)
    }

    public func categoryPage(_ type: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedCategory> {
        guard cursor == nil else { return SamplePage(items: [], next: nil) }
        var out: [DetailedCategory] = []
        for (i, day) in days.enumerated() {
            let start = calendar.date(byAdding: .hour, value: -1, to: day)!
            switch type {
            case "HKCategoryTypeIdentifierSleepAnalysis":
                out.append(DetailedCategory(id: "s\(i)a", source: "Sample Watch", start: start, end: start.addingTimeInterval(3 * 3600), value: 3))
                out.append(DetailedCategory(id: "s\(i)b", source: "Sample Watch", start: start.addingTimeInterval(3 * 3600), end: start.addingTimeInterval(4 * 3600), value: 4))
                out.append(DetailedCategory(id: "s\(i)c", source: "Sample Watch", start: start.addingTimeInterval(4 * 3600), end: start.addingTimeInterval(7 * 3600), value: 5))
            case "HKCategoryTypeIdentifierHeadache" where i == 1:
                let at = calendar.date(byAdding: .hour, value: 15, to: day)!
                out.append(DetailedCategory(id: "h\(i)", source: "Sample iPhone", start: at, end: at.addingTimeInterval(3600), value: 2, userEntered: true))
            default: break
            }
        }
        return SamplePage(items: out.filter { $0.start < range.end && $0.end > range.start }, next: nil)
    }

    public func sources(of type: HealthType) async throws -> [String] { ["Sample Watch"] }

    private var workout: WorkoutDetail {
        let start = calendar.date(byAdding: .hour, value: 17, to: days[1])!
        return WorkoutDetail(id: "00000000-0000-4000-8000-00000000000a", activityType: "Running", activityTypeCode: 37, name: "Outdoor Run", source: "Sample Watch", sourceIdentifier: "com.example.watch",
                             start: start, end: start.addingTimeInterval(1800), duration: 1800, isIndoor: false,
                             statistics: ["activeEnergy": .init(unit: "kcal", sum: 310), "heartRate": .init(unit: "count/min", avg: 148, min: 96, max: 171), "walkingAndRunningDistance": .init(unit: "km", sum: 5.1), "stepCount": .init(unit: "count", sum: 4800)],
                             hasRoute: true)
    }

    public func workoutPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<WorkoutDetail> {
        let w = workout
        return SamplePage(items: cursor == nil && w.start < range.end && w.end > range.start ? [w] : [], next: nil)
    }

    public func routePage(workoutID: String, after cursor: Int?, limit: Int) async throws -> (points: [RoutePoint], next: Int?) {
        guard cursor == nil else { return ([], nil) }
        let start = workout.start
        return ((0..<5).map { i in
            RoutePoint(timestamp: start.addingTimeInterval(Double(i) * 60), latitude: 49.28 + Double(i) * 0.002, longitude: -123.12 - Double(i) * 0.002, altitude: 10 + Double(i), course: 45, horizontalAccuracy: 4, verticalAccuracy: 6, speed: 2.8)
        }, nil)
    }

    public func ecgPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<ECGDetail> {
        guard cursor == nil else { return SamplePage(items: [], next: nil) }
        let at = calendar.date(byAdding: .hour, value: 8, to: days[2])!
        let row = ECGDetail(id: "00000000-0000-4000-8000-00000000000b", source: "Sample Watch", start: at, end: at.addingTimeInterval(30), classification: "Sinus Rhythm", samplingFrequency: 512, averageHeartRate: 62, numberOfVoltageMeasurements: 4)
        return SamplePage(items: at >= range.start && at < range.end ? [row] : [], next: nil)
    }

    public func voltages(ecgID: String) async throws -> [Double] { [12, 48, -20, 5] }
    public func heartbeats(in range: DateInterval) async throws -> [HeartbeatSeries] { [] }

    public func statesOfMind(in range: DateInterval) async throws -> [StateOfMindRecord] {
        let at = calendar.date(byAdding: .hour, value: 20, to: days[1])!
        return at >= range.start && at < range.end ? [StateOfMindRecord(id: "m", source: "Sample iPhone", start: at, end: at, kind: "Daily Mood", valence: 0.4, valenceClassification: "pleasant", labels: ["calm"], associations: ["fitness"])] : []
    }

    public func medicationDoses(in range: DateInterval) async throws -> [MedicationDose] { [] }
    public func additions(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes { Changes(added: [], anchor: nil) }
}
