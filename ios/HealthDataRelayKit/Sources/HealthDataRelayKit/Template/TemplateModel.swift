import Foundation

/// Facts about the export, available to every template as `export`.
public struct ExportInfo: Sendable {
    public var device: Device
    public var generatedAt: Date
    public var timeZone: TimeZone

    public init(device: Device, generatedAt: Date, timeZone: TimeZone) {
        self.device = device
        self.generatedAt = generatedAt
        self.timeZone = timeZone
    }
}

/// One part of a transform's output: a template runs once per partition.
public struct TemplatePartition: Sendable {
    public var kind: TemplateHeader.Partition
    /// Stable within the run, for file names and upserts: "2026-10-24", "step_count".
    public var key: String
    public var ranges: [DateInterval]
    public var start: Date?
    public var end: Date?
    public var section: ExtractSpec.Section?
    public var metric: Metric?
    public var workout: WorkoutDetail?
}

/// A template's rows as objects. A point's `keys` are its JSON form: which
/// fields exist depends on the metric and on summarizing.
struct PointObject: TemplateObject {
    let point: MetricPoint
    let units: String

    var keys: [String] {
        var out: [String] = []
        if point.avg != nil { out.append("Avg") }
        if point.max != nil { out.append("Max") }
        if point.min != nil { out.append("Min") }
        if point.sleep != nil {
            out += ["asleep", "awake", "core", "date", "deep", "inBed", "inBedEnd", "inBedStart", "rem", "sleepEnd", "sleepStart", "source", "totalSleep"]
            return out
        }
        if point.context != nil { out.append("context") }
        out.append("date")
        if point.diastolic != nil { out.append("diastolic") }
        if point.end != nil { out.append("end") }
        if point.value != nil { out.append("endDate") }
        if point.heartbeats != nil { out.append("heartbeatSeries") }
        if point.qty != nil { out.append("qty") }
        if point.source != nil { out.append("source") }
        if point.start != nil { out.append("start") }
        if point.value != nil { out.append("startDate") }
        if point.systolic != nil { out.append("systolic") }
        if point.value != nil { out.append("value") }
        return out
    }

    func value(_ key: String) -> TemplateValue? {
        func n(_ v: Double?) -> TemplateValue? { v.map { .number($0) } }
        func d(_ v: Date?) -> TemplateValue? { v.map { .date($0) } }
        func s(_ v: String?) -> TemplateValue? { v.map { .string($0) } }
        switch key {
        case "date": return .date(point.date)
        case "qty": return n(point.qty)
        case "source": return s(point.source)
        case "units": return .string(units)
        case "start": return d(point.start)
        case "end": return d(point.end)
        case "startDate": return point.value == nil ? nil : d(point.start)
        case "endDate": return point.value == nil ? nil : d(point.end)
        case "min", "Min": return n(point.min)
        case "avg", "Avg": return n(point.avg)
        case "max", "Max": return n(point.max)
        case "context": return s(point.context)
        case "systolic": return n(point.systolic)
        case "diastolic": return n(point.diastolic)
        case "value": return s(point.value)
        case "heartbeatSeries", "heartbeat_series":
            return point.heartbeats.map { beats in
                .array(beats.map { b in
                    .object(DictionaryObject(["date": .number(b.date.timeIntervalSince1970), "precededByGap": .bool(b.precededByGap), "timeSinceStart": .number(b.timeSinceStart)]))
                })
            }
        default: break
        }
        guard let night = point.sleep else { return nil }
        switch key {
        case "asleep": return .number(night.asleep)
        case "awake": return .number(night.awake)
        case "core": return .number(night.core)
        case "deep": return .number(night.deep)
        case "rem": return .number(night.rem)
        case "inBed": return .number(night.inBed)
        case "totalSleep": return .number(night.totalSleep)
        case "inBedStart": return .date(night.inBedStart)
        case "inBedEnd": return .date(night.inBedEnd)
        case "sleepStart": return d(night.sleepStart) ?? .date(night.inBedStart)
        case "sleepEnd": return d(night.sleepEnd) ?? .date(night.inBedEnd)
        default: return nil
        }
    }
}

/// One metric: its name, its units and its rows.
final class MetricObject: TemplateObject, @unchecked Sendable {
    let metric: Metric
    let extractor: Extractor
    let units: String
    /// The first page, if it's been read already to see whether there's data.
    private let firstPage: [MetricPoint]?
    private let firstPager: MetricPager?

    init(metric: Metric, extractor: Extractor, firstPage: [MetricPoint]? = nil, pager: MetricPager? = nil) {
        self.metric = metric
        self.extractor = extractor
        units = extractor.spec.units.label(for: metric)
        self.firstPage = firstPage
        firstPager = pager
    }

    var keys: [String] { ["data", "name", "units"] }

    func value(_ key: String) -> TemplateValue? {
        switch key {
        case "name": return .string(metric.name)
        case "title": return .string(metric.title)
        case "group": return .string(metric.group.rawValue)
        case "units": return .string(units)
        case "data": return .lazy(rows())
        default: return nil
        }
    }

    private func rows() -> LazyList {
        let extractor = extractor
        let metric = metric
        let units = units
        let peeked = firstPage
        let pagerAfterPeek = firstPager
        return LazyList(plainItems: true) {
            var pager = pagerAfterPeek ?? extractor.points(of: metric)
            var pending = peeked
            return PageReader {
                if let page = pending {
                    pending = nil
                    return page.map { .object(PointObject(point: $0, units: units)) }
                }
                return try await pager.next()?.map { .object(PointObject(point: $0, units: units)) }
            }
        }
    }
}

/// `metrics`: by name, or walked as a list of the metrics that have data.
struct MetricsObject: TemplateObject {
    let extractor: Extractor
    let selection: [Metric]

    var keys: [String] { [] }

    func value(_ key: String) -> TemplateValue? {
        guard let metric = selection.first(where: { $0.name == key }) else { return nil }
        return .object(MetricObject(metric: metric, extractor: extractor))
    }

    var list: TemplateValue? {
        let extractor = extractor
        let selection = selection
        return .lazy(LazyList(plainItems: false) {
            var remaining = selection[...]
            return PageReader {
                while let metric = remaining.popFirst() {
                    var pager = extractor.points(of: metric)
                    if let first = try await pager.next() {
                        return [.object(MetricObject(metric: metric, extractor: extractor, firstPage: first, pager: pager))]
                    }
                }
                return nil
            }
        })
    }
}

/// An event row in a section.
struct EventObject: TemplateObject {
    let record: EventRecord
    let valueKey: String

    var keys: [String] {
        if valueKey == "severity" { return ["cycleStart", "end", "name", "severity", "source", "start", "userEntered"] }
        return record.value == nil ? ["cycleStart", "end", "name", "source", "start", "userEntered"] : ["cycleStart", "end", "name", "source", "start", "userEntered", "value"]
    }

    func value(_ key: String) -> TemplateValue? {
        switch key {
        case "name": .string(record.name)
        case "value", "severity": record.value.map { .string($0) } ?? (key == "severity" ? .string("") : nil)
        case "source": .string(record.source)
        case "start": .date(record.start)
        case "end": .date(record.end)
        case "userEntered": .bool(record.userEntered)
        case "cycleStart": .bool(record.cycleStart)
        default: nil
        }
    }
}

/// Builds the variables a template sees.
enum TemplateData {
    static func globals(extractor: Extractor, partition: TemplatePartition, export: ExportInfo, format: OutputFormat, push: JSON? = nil) -> [String: TemplateValue] {
        let spec = extractor.spec
        let selected = partition.metric.map { [$0] } ?? spec.selectedMetrics
        var fields: [String: TemplateValue] = [
            "export": .object(exportObject(extractor: extractor, export: export, format: format)),
            "partition": .object(partitionObject(partition)),
            "metrics": .object(MetricsObject(extractor: extractor, selection: spec.sections.contains(.metrics) ? selected : [])),
            "workouts": .lazy(workouts(extractor)),
            "symptoms": .lazy(events(extractor, MetricCatalog.symptoms, on: spec.sections.contains(.symptoms), valueKey: "severity")),
            "cycle_tracking": .lazy(events(extractor, MetricCatalog.cycleTracking, on: spec.sections.contains(.cycleTracking), valueKey: "value")),
            "heart_rate_notifications": .lazy(events(extractor, MetricCatalog.notifications, on: spec.sections.contains(.heartRateNotifications), valueKey: "value")),
            "ecg": .lazy(ecgs(extractor)),
            "state_of_mind": .lazy(moods(extractor)),
            "medications": .lazy(medications(extractor)),
        ]
        if let workout = partition.workout { fields["workout"] = .object(WorkoutObject(workout: workout, extractor: extractor)) }
        if let push { fields["push"] = TemplateValue(json: push) }
        return fields
    }

    static func exportObject(extractor: Extractor, export: ExportInfo, format: OutputFormat) -> DictionaryObject {
        DictionaryObject([
            "start": extractor.ranges.first.map { .date($0.start) } ?? .null,
            "end": extractor.ranges.last.map { .date($0.end) } ?? .null,
            "generated_at": .date(export.generatedAt),
            "format": .string(format.rawValue),
            "time_zone": .string(export.timeZone.identifier),
            "grouping": extractor.spec.grouping.map { .string($0.rawValue) } ?? .null,
            "device": .object(DictionaryObject([
                "name": .string(export.device.name), "model": .string(export.device.model), "os": .string(export.device.os), "app": .string(export.device.app),
            ])),
        ])
    }

    static func partitionObject(_ p: TemplatePartition) -> DictionaryObject {
        DictionaryObject([
            "kind": .string(p.kind.rawValue),
            "key": .string(p.key),
            "start": p.start.map { .date($0) } ?? .null,
            "end": p.end.map { .date($0) } ?? .null,
            "section": p.section.map { .string($0.rawValue) } ?? .null,
            "metric": p.metric.map { .string($0.name) } ?? .null,
        ])
    }

    private static func events(_ extractor: Extractor, _ types: [MetricCatalog.EventType], on: Bool, valueKey: String) -> LazyList {
        LazyList(plainItems: true) {
            guard on else { return PageReader { nil } }
            var pager = extractor.events(types)
            return PageReader { try await pager.next()?.map { .object(EventObject(record: $0, valueKey: valueKey)) } }
        }
    }

    private static func workouts(_ extractor: Extractor) -> LazyList {
        LazyList(plainItems: false) {
            guard extractor.spec.sections.contains(.workouts) else { return PageReader { nil } }
            var pager = extractor.workouts()
            return PageReader { try await pager.next()?.map { .object(WorkoutObject(workout: $0, extractor: extractor)) } }
        }
    }

    private static func ecgs(_ extractor: Extractor) -> LazyList {
        LazyList(plainItems: false) {
            guard extractor.spec.sections.contains(.ecg) else { return PageReader { nil } }
            var pager = extractor.ecgs()
            return PageReader { try await pager.next()?.map { .object(ECGObject(record: $0, store: extractor.store)) } }
        }
    }

    private static func moods(_ extractor: Extractor) -> LazyList {
        LazyList(plainItems: true) {
            guard extractor.spec.sections.contains(.stateOfMind) else { return PageReader { nil } }
            var done = false
            return PageReader {
                if done { return nil }
                done = true
                let rows = try await extractor.statesOfMind()
                return rows.isEmpty ? nil : rows.map { r in
                    .object(DictionaryObject([
                        "kind": .string(r.kind), "valence": .number(r.valence), "valenceClassification": .string(r.valenceClassification),
                        "labels": .array(r.labels.map { .string($0) }), "associations": .array(r.associations.map { .string($0) }),
                        "source": .string(r.source), "start": .date(r.start), "end": .date(r.end), "id": .string(r.id),
                    ]))
                }
            }
        }
    }

    private static func medications(_ extractor: Extractor) -> LazyList {
        LazyList(plainItems: true) {
            guard extractor.spec.sections.contains(.medications) else { return PageReader { nil } }
            var done = false
            return PageReader {
                if done { return nil }
                done = true
                let rows = try await extractor.medicationDoses()
                return rows.isEmpty ? nil : rows.map { r in
                    var fields: [String: TemplateValue] = ["name": .string(r.name), "source": .string(r.source), "start": .date(r.start), "end": .date(r.end), "status": .string(r.status), "unit": .string(r.unit), "id": .string(r.id)]
                    if let v = r.nickname { fields["nickname"] = .string(v) }
                    if let v = r.scheduledDate { fields["scheduledDate"] = .date(v) }
                    if let v = r.quantity { fields["quantity"] = .number(v) }
                    if let v = r.scheduledQuantity { fields["scheduledQuantity"] = .number(v) }
                    return .object(DictionaryObject(fields))
                }
            }
        }
    }
}

/// An ECG recording; its voltages load when asked for.
struct ECGObject: TemplateObject {
    let record: ECGDetail
    let store: HealthQuerying

    var keys: [String] { ["averageHeartRate", "classification", "end", "numberOfVoltageMeasurements", "samplingFrequency", "source", "start", "voltageMeasurements"] }

    func value(_ key: String) -> TemplateValue? {
        switch key {
        case "averageHeartRate": return record.averageHeartRate.map { .number($0) } ?? .null
        case "classification": return .string(record.classification)
        case "start": return .date(record.start)
        case "end": return .date(record.end)
        case "numberOfVoltageMeasurements": return .number(Double(record.numberOfVoltageMeasurements))
        case "samplingFrequency": return .number(record.samplingFrequency)
        case "source": return .string(record.source)
        case "voltageMeasurements":
            let store = store
            let record = record
            return .lazy(LazyList(plainItems: true) {
                var done = false
                return PageReader {
                    if done { return nil }
                    done = true
                    let period = 1 / record.samplingFrequency
                    let volts = try await store.voltages(ecgID: record.id)
                    return volts.isEmpty ? nil : volts.enumerated().map { i, v in
                        .object(DictionaryObject(["date": .number(Double(i) * period), "units": .string("mcV"), "voltage": .number(v)]))
                    }
                }
            })
        default: return nil
        }
    }
}

/// A workout. Statistics are named the way `MetricCatalog.workoutStatistics`
/// names them; its route loads when asked for.
struct WorkoutObject: TemplateObject {
    let workout: WorkoutDetail
    let extractor: Extractor

    private static func quantity(_ qty: Double?, _ units: String) -> TemplateValue? {
        qty.map { .object(DictionaryObject(["qty": .number($0), "units": .string(units)])) }
    }

    var keys: [String] {
        var out = ["id", "name", "start", "end", "duration", "source"]
        if workout.isIndoor != nil { out += ["isIndoor", "location"] }
        return out
    }

    func value(_ key: String) -> TemplateValue? {
        let w = workout
        switch key {
        case "id": return .string(w.id)
        case "name": return .string(w.name)
        case "activity_type": return .string(w.activityType)
        case "start": return .date(w.start)
        case "end": return .date(w.end)
        case "duration": return .number(w.duration)
        case "isIndoor": return w.isIndoor.map { .bool($0) }
        case "location": return w.isIndoor.map { .string($0 ? "Indoor" : "Outdoor") }
        case "source": return .object(DictionaryObject(["name": .string(w.source), "identifier": .string(w.sourceIdentifier)]))
        case "metadata": return .object(DictionaryObject(w.metadata.mapValues { .string($0) }))
        case "has_route": return .bool(w.hasRoute)
        case "statistics":
            return .object(DictionaryObject(w.statistics.mapValues(Self.statistic)))
        case "route":
            guard w.hasRoute, extractor.spec.workouts.routes else { return .array([]) }
            let extractor = extractor
            return .lazy(LazyList(plainItems: true) {
                var pager = extractor.route(of: w)
                return PageReader { try await pager.next()?.map { .object(RouteObject(point: $0)) } }
            })
        default:
            return w.statistics[key].map(Self.statistic)
        }
    }

    private static func statistic(_ s: WorkoutStatistic) -> TemplateValue {
        var fields: [String: TemplateValue] = ["units": .string(s.unit)]
        if let v = s.sum { fields["sum"] = .number(v) }
        if let v = s.avg { fields["avg"] = .number(v) }
        if let v = s.min { fields["min"] = .number(v) }
        if let v = s.max { fields["max"] = .number(v) }
        return .object(DictionaryObject(fields))
    }
}

struct RouteObject: TemplateObject {
    let point: RoutePoint

    var keys: [String] {
        var out = ["altitude", "course"]
        if point.courseAccuracy != nil { out.append("courseAccuracy") }
        out += ["horizontalAccuracy", "latitude", "longitude"]
        if point.speed >= 0 { out.append("speed") }
        if point.speedAccuracy != nil { out.append("speedAccuracy") }
        out += ["timestamp", "verticalAccuracy"]
        return out
    }

    func value(_ key: String) -> TemplateValue? {
        switch key {
        case "altitude": .number(point.altitude)
        case "course": .number(point.course)
        case "courseAccuracy": point.courseAccuracy.map { .number($0) }
        case "horizontalAccuracy": .number(point.horizontalAccuracy)
        case "latitude": .number(point.latitude)
        case "longitude": .number(point.longitude)
        case "speed": point.speed >= 0 ? .number(point.speed) : nil
        case "speedAccuracy": point.speedAccuracy.map { .number($0) }
        case "timestamp": .date(point.timestamp)
        case "verticalAccuracy": .number(point.verticalAccuracy)
        default: nil
        }
    }
}

/// Splits a run into the parts a template's `partition` asks for.
public struct PartitionPlanner: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func partitions(_ kind: TemplateHeader.Partition, extractor: Extractor) async throws -> [TemplatePartition] {
        switch kind {
        case .none:
            return [TemplatePartition(kind: .none, key: "all", ranges: extractor.ranges, start: extractor.ranges.first?.start, end: extractor.ranges.last?.end)]
        case .day: return timed(.day, .days, extractor)
        case .week: return timed(.week, .weeks, extractor)
        case .month: return timed(.month, .months, extractor)
        case .year: return timed(.year, .years, extractor)
        case .metric:
            return extractor.spec.selectedMetrics.map {
                TemplatePartition(kind: .metric, key: $0.name, ranges: extractor.ranges, start: extractor.ranges.first?.start, end: extractor.ranges.last?.end, metric: $0)
            }
        case .section:
            return ExtractSpec.Section.allCases.filter(extractor.spec.sections.contains).map {
                TemplatePartition(kind: .section, key: $0.rawValue, ranges: extractor.ranges, start: extractor.ranges.first?.start, end: extractor.ranges.last?.end, section: $0)
            }
        case .workout:
            var out: [TemplatePartition] = []
            var pager = extractor.workouts()
            while let page = try await pager.next() {
                for w in page {
                    out.append(TemplatePartition(kind: .workout, key: w.id, ranges: [DateInterval(start: w.start, end: w.end)], start: w.start, end: w.end, workout: w))
                }
            }
            return out
        }
    }

    private func timed(_ kind: TemplateHeader.Partition, _ grouping: TimeGrouping, _ extractor: Extractor) -> [TemplatePartition] {
        let planner = BucketPlanner(grouping: grouping, calendar: calendar)
        var out: [TemplatePartition] = []
        var seen = Set<Date>()
        for range in extractor.ranges {
            let edges = planner.edges(range)
            for (a, b) in zip(edges, edges.dropFirst()) where seen.insert(a).inserted {
                // A run covering part of a bucket reads only that part of it.
                let clipped = extractor.ranges.compactMap { $0.intersection(with: DateInterval(start: a, end: b)) }
                out.append(TemplatePartition(kind: kind, key: Day(a, calendar: calendar).description, ranges: clipped, start: a, end: b))
            }
        }
        return out
    }
}

/// A finished part: what it's called and how much was written.
public struct RenderedPart: Sendable, Equatable {
    public var key: String
    public var filename: String
    public var contentType: String
    public var bytes: Int
}

/// Writes a template's output: one part per partition, streamed to `sink`.
public struct TemplateTransformer: Sendable {
    public let template: ParsedTemplate
    public let limits: TemplateLimits

    public init(template: ParsedTemplate, limits: TemplateLimits = TemplateLimits()) {
        self.template = template
        self.limits = limits
    }

    /// Renders every partition. `sink` gets each part's name and returns where
    /// to write it. A failure stops the run: its parts aren't complete.
    public func run(extractor: Extractor, export: ExportInfo, push: JSON? = nil, sink: (TemplatePartition, String) throws -> OutputSink) async throws -> [RenderedPart] {
        let planner = PartitionPlanner(calendar: extractor.calendar)
        var out: [RenderedPart] = []
        for partition in try await planner.partitions(template.header.partition, extractor: extractor) {
            let inner = Extractor(store: extractor.store, spec: extractor.spec, calendar: extractor.calendar, ranges: partition.ranges)
            let globals = TemplateData.globals(extractor: inner, partition: partition, export: export, format: template.header.format, push: push)
            let name = try await filename(partition, globals: globals, timeZone: export.timeZone)
            let counted = CountingSink(try sink(partition, name))
            let renderer = TemplateRenderer(format: template.header.format, timeZone: export.timeZone, globals: globals, sink: counted, limits: limits)
            try await renderer.run(template.body)
            out.append(RenderedPart(key: partition.key, filename: name, contentType: template.header.contentType ?? template.header.format.contentType, bytes: counted.bytes))
        }
        return out
    }

    private func filename(_ partition: TemplatePartition, globals: [String: TemplateValue], timeZone: TimeZone) async throws -> String {
        guard let body = template.filename else {
            return "\(template.header.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(partition.key).\(template.header.format.fileExtension)"
        }
        let memory = MemorySink()
        // A file name is plain text: nothing in it should be quoted as JSON.
        try await TemplateRenderer(format: .text, timeZone: timeZone, globals: globals, sink: memory, limits: limits).run(body)
        // A name can't climb out of its folder.
        return memory.string.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
    }
}

final class CountingSink: OutputSink {
    private let inner: OutputSink
    private(set) var bytes = 0

    init(_ inner: OutputSink) {
        self.inner = inner
    }

    func write(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        self.bytes += bytes.count
        try inner.write(bytes)
    }
}
