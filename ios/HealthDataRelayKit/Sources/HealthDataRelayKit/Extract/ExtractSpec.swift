import Foundation

/// What a pipeline reads from Health, how much of it, and how it's grouped.
public struct ExtractSpec: Codable, Sendable, Equatable {
    /// The kinds of data. One export can carry any of them.
    public enum Section: String, Codable, Sendable, CaseIterable {
        case metrics, workouts, symptoms, ecg, heartRateNotifications, stateOfMind, cycleTracking, medications
    }

    public enum MetricSelection: Codable, Sendable, Equatable {
        case all
        case only([String])
    }

    public struct WorkoutOptions: Codable, Sendable, Equatable {
        /// Only these activity names, or every workout.
        public var activityTypes: [String]?
        /// Route points for each workout.
        public var routes: Bool
        /// Heart rate, energy and step series inside each workout.
        public var series: Bool
        /// Only these workouts, by id: a single-workout export.
        public var ids: [String]?
        /// Only these activity types, by HealthKit's number.
        public var activityCodes: [Int]?

        public init(activityTypes: [String]? = nil, routes: Bool = true, series: Bool = true, ids: [String]? = nil) {
            self.ids = ids
            self.activityTypes = activityTypes
            self.routes = routes
            self.series = series
        }
    }

    /// The native push's: whole days that changed.
    public static let changedDays = ExtractSpec(range: .changedDays)

    public var sections: Set<Section>
    public var metrics: MetricSelection
    public var workouts: WorkoutOptions
    public var range: RangeSpec
    /// Nil writes every sample as it is, unsummarized.
    public var grouping: TimeGrouping?
    public var sources: SourcePolicy
    /// A different policy for particular metrics, by name.
    public var metricSources: [String: SourcePolicy]
    /// Chosen units by dimension, then by metric name, as HKUnit strings.
    public var units: UnitPreferences

    public init(sections: Set<Section> = [.metrics], metrics: MetricSelection = .all, workouts: WorkoutOptions = WorkoutOptions(),
                range: RangeSpec = .changedDays, grouping: TimeGrouping? = .automatic, sources: SourcePolicy = .merged,
                metricSources: [String: SourcePolicy] = [:], units: UnitPreferences = UnitPreferences()) {
        self.sections = sections
        self.metrics = metrics
        self.workouts = workouts
        self.range = range
        self.grouping = grouping
        self.sources = sources
        self.metricSources = metricSources
        self.units = units
    }

    /// The metrics selected, in catalog order; an unknown name is left out.
    public var selectedMetrics: [Metric] {
        switch metrics {
        case .all: MetricCatalog.metrics
        case .only(let names): MetricCatalog.metrics.filter { names.contains($0.name) }
        }
    }

    public func sourcePolicy(for metric: Metric) -> SourcePolicy {
        metricSources[metric.name] ?? sources
    }

    /// Every type this spec reads, for asking Health and watching changes.
    public var healthTypes: [HealthType] {
        var seen = Set<HealthType>()
        var all: [HealthType] = []
        if sections.contains(.metrics) { all += selectedMetrics.flatMap(\.healthTypes) }
        if sections.contains(.workouts) { all.append(.workout) }
        if sections.contains(.symptoms) { all += MetricCatalog.symptoms.map(\.type) }
        if sections.contains(.ecg) { all.append(.ecg) }
        if sections.contains(.heartRateNotifications) { all += MetricCatalog.notifications.map(\.type) }
        if sections.contains(.cycleTracking) { all += MetricCatalog.cycleTracking.map(\.type) }
        return all.filter { seen.insert($0).inserted }
    }
}

/// How samples combine over time. Only buckets with data produce a point.
public enum TimeGrouping: String, Codable, Sendable, CaseIterable {
    case seconds, minutes, hours, days, weeks, months, years
    /// One point per minute: fine enough to chart a day, and small enough
    /// to send. Scheduled exports default to it.
    case automatic
}

/// Which source a value comes from when several recorded the same thing.
public enum SourcePolicy: Codable, Sendable, Equatable {
    /// Health's own combined value, with overlaps removed, as the Health app
    /// shows it. `source` lists everything that contributed.
    case merged
    /// One point per source per bucket.
    case eachSource
    /// In each bucket, the first listed source that has data. A bucket with
    /// none of them falls back to the merged value.
    case preferred([String])
}

/// Which units values are written in. A metric's own choice beats its
/// dimension's, and an unusable choice falls back to the catalog's default.
public struct UnitPreferences: Codable, Sendable, Equatable {
    public var byDimension: [UnitDimension: String]
    public var byMetric: [String: String]

    public init(byDimension: [UnitDimension: String] = [:], byMetric: [String: String] = [:]) {
        self.byDimension = byDimension
        self.byMetric = byMetric
    }

    public func unit(for metric: Metric) -> String {
        if let chosen = byMetric[metric.name] { return chosen }
        if let chosen = byDimension[metric.dimension], metric.dimension.choices.contains(chosen) { return chosen }
        return metric.unit
    }

    /// The text written for a metric's unit.
    public func label(for metric: Metric) -> String {
        let unit = unit(for: metric)
        return unit == metric.unit ? metric.label : unit
    }

    /// The US customary choices.
    public static let imperial = UnitPreferences(byDimension: [.distance: "mi", .shortLength: "in", .mass: "lb", .temperature: "degF", .volume: "fl_oz_us", .speed: "mi/hr"])
}

/// How much of Health a run covers.
public enum RangeSpec: Codable, Sendable, Equatable {
    /// Whole days that changed, deletions included.
    case changedDays
    /// From the end of the last run to now, plus older samples that arrived late.
    case sinceLastRun
    case today
    case yesterday
    /// The last `n` whole days, not counting today.
    case previousDays(Int)
    /// The last `n` days including today so far.
    case lastDays(Int)
    case fixed(DateInterval)
    /// Asked when Run is tapped.
    case askAtRun
}

/// What's known about a pipeline's progress, saved between runs.
public struct ExtractCursor: Codable, Sendable, Equatable {
    /// The end of the last run's range; the next since-last-run starts here.
    public var lastEnd: Date?
    /// Per type, where the look for late samples last stopped.
    public var anchors: [HealthType: Data]

    public init(lastEnd: Date? = nil, anchors: [HealthType: Data] = [:]) {
        self.lastEnd = lastEnd
        self.anchors = anchors
    }

    enum CodingKeys: String, CodingKey { case lastEnd, anchors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastEnd = try c.decodeIfPresent(Date.self, forKey: .lastEnd)
        let entries = try c.decodeIfPresent([Anchor].self, forKey: .anchors) ?? []
        anchors = Dictionary(entries.map { ($0.type, $0.data) }) { _, last in last }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lastEnd, forKey: .lastEnd)
        try c.encode(anchors.map { Anchor(type: $0.key, data: $0.value) }.sorted { $0.type.id < $1.type.id }, forKey: .anchors)
    }

    private struct Anchor: Codable {
        let type: HealthType
        let data: Data
    }
}
