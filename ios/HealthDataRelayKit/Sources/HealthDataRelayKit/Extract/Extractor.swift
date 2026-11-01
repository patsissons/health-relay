import Foundation

/// One value of a metric. Which fields are set depends on the metric's form
/// and on whether it was summarized; templates see the set fields.
public struct MetricPoint: Sendable, Equatable {
    public var date: Date
    /// Set for an unsummarized sample.
    public var start: Date?
    public var end: Date?
    public var qty: Double?
    public var min: Double?
    public var avg: Double?
    public var max: Double?
    /// Sources, separated by `|` when there are several.
    public var source: String?
    public var context: String?
    public var systolic: Double?
    public var diastolic: Double?
    /// A sleep stage's name, for an unsummarized sleep point.
    public var value: String?
    public var sleep: SleepNight?
    public var heartbeats: [HeartbeatPoint]?

    public init(date: Date, start: Date? = nil, end: Date? = nil, qty: Double? = nil, min: Double? = nil, avg: Double? = nil, max: Double? = nil, source: String? = nil, context: String? = nil, systolic: Double? = nil, diastolic: Double? = nil, value: String? = nil, sleep: SleepNight? = nil, heartbeats: [HeartbeatPoint]? = nil) {
        self.date = date
        self.start = start
        self.end = end
        self.qty = qty
        self.min = min
        self.avg = avg
        self.max = max
        self.source = source
        self.context = context
        self.systolic = systolic
        self.diastolic = diastolic
        self.value = value
        self.sleep = sleep
        self.heartbeats = heartbeats
    }
}

public struct HeartbeatPoint: Sendable, Equatable {
    /// When the beat fell.
    public var date: Date
    public var timeSinceStart: Double
    public var precededByGap: Bool

    public init(date: Date, timeSinceStart: Double, precededByGap: Bool) {
        self.date = date
        self.timeSinceStart = timeSinceStart
        self.precededByGap = precededByGap
    }
}

/// A one-event-per-row section: symptoms, cycle tracking, notifications.
public struct EventRecord: Sendable, Equatable {
    public var name: String
    /// The value's name, when the type has values.
    public var value: String?
    public var source: String
    public var start: Date
    public var end: Date
    public var userEntered: Bool
    public var cycleStart: Bool

    public init(name: String, value: String?, source: String, start: Date, end: Date, userEntered: Bool, cycleStart: Bool) {
        self.name = name
        self.value = value
        self.source = source
        self.start = start
        self.end = end
        self.userEntered = userEntered
        self.cycleStart = cycleStart
    }
}

/// Reads what a spec asks for, one page at a time: nothing past the current
/// page is held, so an export can be far larger than memory.
public struct Extractor: Sendable {
    /// Samples per page read from Health.
    public static let pageSize = 2000

    public let store: HealthQuerying
    public let spec: ExtractSpec
    public let calendar: Calendar
    /// The run's ranges, from `RangePlanner`.
    public let ranges: [DateInterval]

    public init(store: HealthQuerying, spec: ExtractSpec, calendar: Calendar, ranges: [DateInterval]) {
        self.store = store
        self.spec = spec
        self.calendar = calendar
        self.ranges = mergeIntervals(ranges)
    }

    /// The pages of one metric's points. An empty metric produces no page.
    public func points(of metric: Metric) -> MetricPager {
        MetricPager(extractor: self, metric: metric)
    }

    /// The ranges every metric reads, grown to whole buckets.
    func bucketRanges(_ grouping: TimeGrouping) -> [DateInterval] {
        let planner = BucketPlanner(grouping: grouping, calendar: calendar)
        return mergeIntervals(ranges.map(planner.snap))
    }

    /// All of a section's events, in time order, one page at a time.
    public func events(_ types: [MetricCatalog.EventType]) -> EventPager {
        EventPager(extractor: self, types: types)
    }

    public func workouts() -> WorkoutPager {
        WorkoutPager(extractor: self)
    }

    /// All the route points of a workout, one page at a time.
    public func route(of workout: WorkoutDetail) -> RoutePager {
        RoutePager(store: store, workoutID: workout.id)
    }

    /// ECG recordings with no voltages; `Extractor.voltages` reads those one
    /// recording at a time.
    public func ecgs() -> ECGPager {
        ECGPager(extractor: self)
    }

    public func statesOfMind() async throws -> [StateOfMindRecord] {
        var out: [StateOfMindRecord] = []
        for range in ranges { out += try await store.statesOfMind(in: range) }
        return dedupe(out, by: \.id).sorted { $0.start < $1.start }
    }

    public func medicationDoses() async throws -> [MedicationDose] {
        var out: [MedicationDose] = []
        for range in ranges { out += try await store.medicationDoses(in: range) }
        return dedupe(out, by: \.id).sorted { $0.start < $1.start }
    }

    /// Samples added since the cursor's anchors that are older than its last
    /// run, which a since-last-run would otherwise miss, and the new anchors.
    public static func late(in store: HealthQuerying, types: [HealthType], cursor: ExtractCursor, since: Date) async throws -> (late: [DateInterval], anchors: [HealthType: Data]) {
        var late: [DateInterval] = []
        var anchors: [HealthType: Data] = [:]
        for type in types {
            let changes = try await store.additions(type, anchor: cursor.anchors[type], since: since)
            if let anchor = changes.anchor { anchors[type] = anchor }
            // Nothing is late before a first run, or without an anchor to
            // say the sample really is new.
            guard let lastEnd = cursor.lastEnd, cursor.anchors[type] != nil else { continue }
            // An instant has no length, and a range with no length overlaps nothing.
            late += changes.added.filter { $0.start < lastEnd }.map { DateInterval(start: $0.start, end: max($0.end, $0.start.addingTimeInterval(1))) }
        }
        return (mergeIntervals(late), anchors)
    }

    private func dedupe<T>(_ items: [T], by id: KeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0[keyPath: id]).inserted }
    }
}

/// Pages of one metric's points. Call `next` until it returns nil.
public struct MetricPager: Sendable {
    let extractor: Extractor
    let metric: Metric
    private var plans: [BucketPlan]
    private var rawRanges: [DateInterval]
    private var cursor: PageCursor?
    private var filter: Filter
    private var loadedEverything = false
    /// The end of the raw range before this one. A sample starting before it
    /// was already written with that range.
    private var previousEnd: Date?

    /// Which source's samples an unsummarized read keeps.
    private enum Filter: Sendable {
        case unresolved
        case all
        case source(String)
    }

    init(extractor: Extractor, metric: Metric) {
        self.extractor = extractor
        self.metric = metric
        filter = .unresolved
        if let grouping = extractor.spec.grouping {
            let planner = BucketPlanner(grouping: grouping, calendar: extractor.calendar)
            plans = extractor.bucketRanges(grouping).flatMap(planner.plans)
            rawRanges = []
        } else {
            plans = []
            rawRanges = extractor.ranges
        }
    }

    public var unitLabel: String { extractor.spec.units.label(for: metric) }

    /// The next page, or nil at the end. Never returns an empty page.
    public mutating func next() async throws -> [MetricPoint]? {
        while true {
            let page: [MetricPoint]?
            switch metric.form {
            case .total, .average, .range:
                page = extractor.spec.grouping == nil ? try await nextRawQuantity() : try await nextBucket()
            case .bloodPressure:
                page = try await nextBloodPressure()
            case .sleep:
                page = try await nextSleep()
            case .eventCount, .eventMinutes:
                page = try await nextCategory()
            }
            guard let page else { return nil }
            if !page.isEmpty { return page }
        }
    }

    // MARK: Quantities

    private var unit: String { extractor.spec.units.unit(for: metric) }

    private mutating func nextBucket() async throws -> [MetricPoint]? {
        guard !plans.isEmpty else { return nil }
        let plan = plans.removeFirst()
        let style: BucketQuery.Style = metric.form == .total ? .sum : .range
        let buckets = try await extractor.store.buckets(BucketQuery(type: metric.identifiers[0], unit: unit, style: style, plan: plan))
        let policy = extractor.spec.sourcePolicy(for: metric)
        return buckets.flatMap { point(from: $0, policy: policy) }
    }

    private func point(from bucket: StatBucket, policy: SourcePolicy) -> [MetricPoint] {
        switch policy {
        case .merged:
            return [make(bucket, bucket.merged, source: joined(bucket.sources.map(\.source)))]
        case .eachSource:
            return bucket.sources.map { make(bucket, $0, source: $0.source) }
        case .preferred(let names):
            if let name = names.first(where: { n in bucket.sources.contains { $0.source == n } }),
               let value = bucket.sources.first(where: { $0.source == name }) {
                return [make(bucket, value, source: name)]
            }
            return [make(bucket, bucket.merged, source: joined(bucket.sources.map(\.source)))]
        }
    }

    private func make(_ bucket: StatBucket, _ value: StatBucket.SourceValue, source: String) -> MetricPoint {
        switch metric.form {
        case .range:
            // Min/Avg/Max points name no source when summarized.
            MetricPoint(date: bucket.start, min: value.min, avg: value.avg, max: value.max)
        case .total:
            MetricPoint(date: bucket.start, qty: value.sum, source: source)
        default:
            MetricPoint(date: bucket.start, qty: value.avg, source: source)
        }
    }

    private func joined(_ sources: [String]) -> String {
        sources.joined(separator: "|")
    }

    private mutating func nextRawQuantity() async throws -> [MetricPoint]? {
        guard let range = rawRanges.first else { return nil }
        let id = metric.identifiers[0]
        if case .unresolved = filter {
            filter = try await resolveFilter(type: HealthType(.quantity, id))
        }
        let page = try await extractor.store.quantityPage(id, unit: unit, in: range, after: cursor, limit: Extractor.pageSize)
        var samples = page.items.filter { isNew($0.start) }
        advance(page.next)
        if case .source(let name) = filter { samples = samples.filter { $0.source == name } }
        var beats: [HeartbeatSeries] = []
        if metric.name == "heart_rate_variability", let first = samples.first, let last = samples.last {
            beats = try await extractor.store.heartbeats(in: DateInterval(start: first.start, end: max(first.start, last.end)))
        }
        return samples.map { s in
            var p = MetricPoint(date: s.start, start: s.start, end: s.end, source: s.source)
            switch metric.form {
            case .range:
                p.avg = s.value
                p.min = s.min ?? s.value
                p.max = s.max ?? s.value
                p.context = s.context
            default:
                p.qty = s.value
            }
            if let series = beats.first(where: { $0.start < s.end && $0.end > s.start }) {
                p.heartbeats = series.beats.map {
                    HeartbeatPoint(date: series.start.addingTimeInterval($0.timeSinceStart), timeSinceStart: $0.timeSinceStart, precededByGap: $0.precededByGap)
                }
            }
            return p
        }
    }

    private mutating func advance(_ next: PageCursor?) {
        cursor = next
        guard next == nil else { return }
        previousEnd = rawRanges.removeFirst().end
    }

    private func isNew(_ start: Date) -> Bool {
        previousEnd.map { start >= $0 } ?? true
    }

    /// For an unsummarized read, a preferred policy keeps only the first
    /// listed source with any data: mixing sources would count overlaps twice.
    private func resolveFilter(type: HealthType) async throws -> Filter {
        guard case .preferred(let names) = extractor.spec.sourcePolicy(for: metric) else { return .all }
        let available = try await extractor.store.sources(of: type)
        if let name = names.first(where: available.contains) { return .source(name) }
        return .all
    }

    // MARK: Blood pressure

    /// Readings pair by their start time. Summarized, a bucket holds the
    /// mean of each side.
    private mutating func nextBloodPressure() async throws -> [MetricPoint]? {
        guard !loadedEverything else { return nil }
        loadedEverything = true
        var out: [MetricPoint] = []
        for range in extractor.ranges {
            let systolic = try await allQuantities(metric.identifiers[0], range)
            let diastolic = try await allQuantities(metric.identifiers[1], range)
            let matched = Dictionary(diastolic.map { ($0.start, $0) }) { first, _ in first }
            for s in systolic {
                guard let d = matched[s.start] else { continue }
                out.append(MetricPoint(date: s.start, start: extractor.spec.grouping == nil ? s.start : nil, end: extractor.spec.grouping == nil ? s.end : nil,
                                       source: s.source, systolic: s.value, diastolic: d.value))
            }
        }
        guard let grouping = extractor.spec.grouping else { return out }
        let planner = BucketPlanner(grouping: grouping, calendar: extractor.calendar)
        let groups = Dictionary(grouping: out) { planner.floor($0.date) }
        return groups.keys.sorted().map { key in
            let rows = groups[key]!
            let sources = Set(rows.compactMap(\.source)).sorted().joined(separator: "|")
            return MetricPoint(date: key, source: sources,
                               systolic: rows.compactMap(\.systolic).reduce(0, +) / Double(rows.count),
                               diastolic: rows.compactMap(\.diastolic).reduce(0, +) / Double(rows.count))
        }
    }

    private func allQuantities(_ type: String, _ range: DateInterval) async throws -> [DetailedQuantity] {
        var out: [DetailedQuantity] = []
        var cursor: PageCursor?
        repeat {
            let page = try await extractor.store.quantityPage(type, unit: unit, in: range, after: cursor, limit: Extractor.pageSize)
            out += page.items
            cursor = page.next
        } while cursor != nil
        return out
    }

    // MARK: Categories

    private func allCategories(_ range: DateInterval) async throws -> [DetailedCategory] {
        var out: [DetailedCategory] = []
        var cursor: PageCursor?
        repeat {
            let page = try await extractor.store.categoryPage(metric.identifiers[0], in: range, after: cursor, limit: Extractor.pageSize)
            out += page.items
            cursor = page.next
        } while cursor != nil
        return out
    }

    private mutating func nextCategory() async throws -> [MetricPoint]? {
        guard let grouping = extractor.spec.grouping else {
            guard let range = rawRanges.first else { return nil }
            let page = try await extractor.store.categoryPage(metric.identifiers[0], in: range, after: cursor, limit: Extractor.pageSize)
            let fresh = page.items.filter { isNew($0.start) }
            advance(page.next)
            return fresh.map { categoryPoint($0) }
        }
        guard !loadedEverything else { return nil }
        loadedEverything = true
        let planner = BucketPlanner(grouping: grouping, calendar: extractor.calendar)
        var totals: [Date: Double] = [:]
        var sources: [Date: Set<String>] = [:]
        for range in extractor.bucketRanges(grouping) {
            for s in try await allCategories(range) where counts(s) {
                let key = planner.floor(s.start)
                totals[key, default: 0] += metric.form == .eventMinutes ? s.end.timeIntervalSince(s.start) / 60 : 1
                sources[key, default: []].insert(s.source)
            }
        }
        return totals.keys.sorted().map { MetricPoint(date: $0, qty: totals[$0], source: sources[$0]!.sorted().joined(separator: "|")) }
    }

    private func categoryPoint(_ s: DetailedCategory) -> MetricPoint {
        MetricPoint(date: s.start, start: s.start, end: s.end, qty: metric.form == .eventMinutes ? s.end.timeIntervalSince(s.start) / 60 : 1, source: s.source)
    }

    /// A stand hour counts when it was stood (value 0); idle hours don't.
    private func counts(_ s: DetailedCategory) -> Bool {
        metric.name == "apple_stand_hour" ? s.value == 0 : true
    }

    // MARK: Sleep

    private mutating func nextSleep() async throws -> [MetricPoint]? {
        guard let grouping = extractor.spec.grouping else {
            guard let range = rawRanges.first else { return nil }
            let page = try await extractor.store.categoryPage(metric.identifiers[0], in: range, after: cursor, limit: Extractor.pageSize)
            let fresh = page.items.filter { isNew($0.start) }
            advance(page.next)
            return fresh.map { s in
                MetricPoint(date: s.start, start: s.start, end: s.end, qty: s.end.timeIntervalSince(s.start) / 3600, source: s.source,
                            value: MetricCatalog.SleepStage(rawValue: s.value)?.name ?? String(s.value))
            }
        }
        guard !loadedEverything else { return nil }
        loadedEverything = true
        var segments: [DetailedCategory] = []
        // A night can begin before the range starts, so reading starts a day early.
        for range in extractor.bucketRanges(grouping) {
            let wider = DateInterval(start: range.start.addingTimeInterval(-86400), end: range.end)
            segments += try await allCategories(wider)
        }
        var seen = Set<String>()
        let unique = segments.filter { seen.insert($0.id).inserted }
        let nights = SleepNight.nights(from: unique, calendar: extractor.calendar)
        let planner = BucketPlanner(grouping: grouping, calendar: extractor.calendar)
        return SleepNight.points(nights, grouping: grouping, planner: planner, within: extractor.bucketRanges(grouping))
    }
}

/// Pages of events across several types, in time order.
public struct EventPager: Sendable {
    let extractor: Extractor
    let types: [MetricCatalog.EventType]
    private var started = false
    private var rows: [EventRecord] = []
    private var at = 0

    init(extractor: Extractor, types: [MetricCatalog.EventType]) {
        self.extractor = extractor
        self.types = types
    }

    public mutating func next() async throws -> [EventRecord]? {
        if !started {
            started = true
            // Sparse by nature: a person logs far fewer events than a watch
            // writes samples, so these are sorted across types in memory.
            for type in types {
                for range in extractor.ranges {
                    var cursor: PageCursor?
                    repeat {
                        let page = try await extractor.store.categoryPage(type.id, in: range, after: cursor, limit: Extractor.pageSize)
                        rows += page.items.map {
                            EventRecord(name: type.name, value: type.valueName($0.value), source: $0.source, start: $0.start, end: $0.end, userEntered: $0.userEntered, cycleStart: $0.cycleStart)
                        }
                        cursor = page.next
                    } while cursor != nil
                }
            }
            rows.sort { ($0.start, $0.name) < ($1.start, $1.name) }
        }
        guard at < rows.count else { return nil }
        let end = min(at + Extractor.pageSize, rows.count)
        defer { at = end }
        return Array(rows[at..<end])
    }
}

public struct WorkoutPager: Sendable {
    let extractor: Extractor
    private var remaining: [DateInterval]
    private var cursor: PageCursor?
    private var seen = Set<String>()

    /// Workouts are read a few at a time because each carries statistics.
    static let limit = 25

    init(extractor: Extractor) {
        self.extractor = extractor
        remaining = extractor.ranges
    }

    public mutating func next() async throws -> [WorkoutDetail]? {
        let wanted = extractor.spec.workouts.activityTypes
        let only = extractor.spec.workouts.ids
        while let range = remaining.first {
            let page = try await extractor.store.workoutPage(in: range, after: cursor, limit: Self.limit)
            cursor = page.next
            if page.next == nil { remaining.removeFirst() }
            var kept: [WorkoutDetail] = []
            for w in page.items where seen.insert(w.id).inserted && (wanted?.contains(w.activityType) ?? true) && (only?.contains(w.id) ?? true) {
                kept.append(w)
            }
            if !kept.isEmpty { return kept }
        }
        return nil
    }
}

public struct RoutePager: Sendable {
    let store: HealthQuerying
    let workoutID: String
    private var cursor: Int?
    private var finished = false

    init(store: HealthQuerying, workoutID: String) {
        self.store = store
        self.workoutID = workoutID
    }

    public mutating func next() async throws -> [RoutePoint]? {
        guard !finished else { return nil }
        let page = try await store.routePage(workoutID: workoutID, after: cursor, limit: Extractor.pageSize)
        cursor = page.next
        finished = page.next == nil
        return page.points.isEmpty ? nil : page.points
    }
}

public struct ECGPager: Sendable {
    let extractor: Extractor
    private var remaining: [DateInterval]
    private var cursor: PageCursor?
    private var seen = Set<String>()

    init(extractor: Extractor) {
        self.extractor = extractor
        remaining = extractor.ranges
    }

    public mutating func next() async throws -> [ECGDetail]? {
        while let range = remaining.first {
            let page = try await extractor.store.ecgPage(in: range, after: cursor, limit: 25)
            cursor = page.next
            if page.next == nil { remaining.removeFirst() }
            let kept = page.items.filter { seen.insert($0.id).inserted }
            if !kept.isEmpty { return kept }
        }
        return nil
    }
}
