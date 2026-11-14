import Foundation

extension MetricPoint {
    /// The one number a chart or a headline shows for a point, with the
    /// range around it when there is one.
    public struct Primary: Sendable, Equatable {
        public var value: Double
        public var low: Double?
        public var high: Double?
    }

    /// A night's sleep in hours, a range's mean with its low and high, a
    /// total or a mean, or blood pressure's systolic over its diastolic.
    public var primary: Primary? {
        if let night = sleep { return Primary(value: night.totalSleep) }
        if let avg { return Primary(value: avg, low: min, high: max) }
        if let qty { return Primary(value: qty) }
        if let systolic { return Primary(value: systolic, low: diastolic, high: systolic) }
        return nil
    }
}

/// One day's value of a metric.
public struct DayValue: Sendable, Codable, Equatable, Identifiable {
    public var day: Day
    public var value: Double
    public var low: Double?
    public var high: Double?

    public var id: Day { day }

    public init(day: Day, value: Double, low: Double? = nil, high: Double? = nil) {
        self.day = day
        self.value = value
        self.low = low
        self.high = high
    }
}

/// A metric over a period, in one set of numbers.
public struct PeriodSummary: Sendable, Codable, Equatable {
    /// Every day added together, for a metric that adds up (steps, energy,
    /// minutes); nil for one that doesn't (heart rate, weight).
    public var total: Double?
    /// The mean of the days that have a value.
    public var average: Double
    public var min: Double
    public var max: Double
    public var minDay: Day
    public var maxDay: Day
    /// The most recent day's value.
    public var latest: Double
    public var daysWithData: Int
    /// Days in the period, with data or not.
    public var days: Int

    init?(_ values: [DayValue], days: Int, adds: Bool) {
        guard let low = values.min(by: { $0.value < $1.value }), let high = values.max(by: { $0.value < $1.value }), let last = values.last else { return nil }
        let sum = values.reduce(0) { $0 + $1.value }
        total = adds ? sum : nil
        average = sum / Double(values.count)
        min = low.value
        max = high.value
        minDay = low.day
        maxDay = high.day
        latest = last.value
        daysWithData = values.count
        self.days = days
    }
}

/// A metric's days over a period and the period before it, summarized.
/// Charts and the report both read this, so their numbers agree.
public struct MetricSeries: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var title: String
    public var group: String
    public var unit: String
    public var form: String
    /// Whether days add up to a total.
    public var adds: Bool
    public var days: [DayValue]
    public var previousDays: [DayValue]
    public var summary: PeriodSummary
    public var previous: PeriodSummary?
    /// How the daily average moved against the period before, as a fraction:
    /// 0.1 is ten per cent up. Nil with nothing to compare against.
    public var change: Double?

    public var id: String { name }

    /// The number to lead with: a total where days add up, otherwise the average.
    public var headline: Double { summary.total ?? summary.average }
}

extension Metric {
    /// Whether a period's days add up to a total, rather than average out.
    public var adds: Bool {
        switch form {
        case .total, .eventCount, .eventMinutes: true
        case .average, .range, .bloodPressure, .sleep: false
        }
    }
}

/// Reads metrics a day at a time and summarizes them over a period.
public struct MetricSummarizer: Sendable {
    public let store: any HealthQuerying
    public let calendar: Calendar
    public let units: UnitPreferences

    public init(store: any HealthQuerying, calendar: Calendar, units: UnitPreferences = UnitPreferences()) {
        self.store = store
        self.calendar = calendar
        self.units = units
    }

    /// The same number of days, ending where the period starts.
    public static func previous(of period: DateInterval, calendar: Calendar) -> DateInterval {
        let first = Day(period.start, calendar: calendar)
        return DateInterval(start: first.adding(-dayCount(period, calendar: calendar)).start(in: calendar), end: period.start)
    }

    /// The local days a period touches.
    public static func dayCount(_ period: DateInterval, calendar: Calendar) -> Int {
        let first = Day(period.start, calendar: calendar)
        let last = Day(period.end > period.start ? period.end.addingTimeInterval(-0.001) : period.end, calendar: calendar)
        return first.through(last).count
    }

    /// One metric over the period; nil when it has no data there. The
    /// period before is read in the same pass, so a comparison costs no
    /// second query.
    public func series(_ metric: Metric, period: DateInterval, previous: DateInterval? = nil) async throws -> MetricSeries? {
        let range = DateInterval(start: Swift.min(previous?.start ?? period.start, period.start), end: period.end)
        let spec = ExtractSpec(metrics: .only([metric.name]), range: .fixed(range), grouping: .days, units: units)
        var pager = Extractor(store: store, spec: spec, calendar: calendar, ranges: [range]).points(of: metric)
        let unit = pager.unitLabel
        var now: [DayValue] = []
        var before: [DayValue] = []
        while let page = try await pager.next() {
            for point in page {
                guard let primary = point.primary else { continue }
                let value = DayValue(day: Day(point.date, calendar: calendar), value: primary.value, low: primary.low, high: primary.high)
                if point.date >= period.start {
                    if point.date < period.end { now.append(value) }
                } else if let previous, point.date >= previous.start {
                    before.append(value)
                }
            }
        }
        now.sort { $0.day < $1.day }
        before.sort { $0.day < $1.day }
        guard let summary = PeriodSummary(now, days: Self.dayCount(period, calendar: calendar), adds: metric.adds) else { return nil }
        let earlier = previous.flatMap { PeriodSummary(before, days: Self.dayCount($0, calendar: calendar), adds: metric.adds) }
        var change: Double?
        if let earlier, earlier.average != 0 { change = (summary.average - earlier.average) / abs(earlier.average) }
        return MetricSeries(name: metric.name, title: metric.title, group: metric.group.rawValue, unit: unit, form: metric.form.rawValue, adds: metric.adds,
                            days: now, previousDays: before, summary: summary, previous: earlier, change: change)
    }

    /// Every metric with data in the period, as each one finishes: a few at
    /// a time, so a screen fills in without a hundred queries at once. A
    /// metric that can't be read is left out, as one with no data is.
    public func all(_ metrics: [Metric] = MetricCatalog.metrics, period: DateInterval, previous: DateInterval? = nil, concurrency: Int = 6) -> AsyncStream<MetricSeries> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: MetricSeries?.self) { group in
                    var waiting = metrics.makeIterator()
                    func start() {
                        guard let metric = waiting.next() else { return }
                        group.addTask { try? await series(metric, period: period, previous: previous) }
                    }
                    for _ in 0..<max(1, concurrency) { start() }
                    while let done = await group.next() {
                        if Task.isCancelled { break }
                        if let done { continuation.yield(done) }
                        start()
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// How a chart gathers a series' days.
public enum SeriesGrouping: String, Sendable, CaseIterable {
    case day, week, month
}

extension Array where Element == DayValue {
    /// Days gathered into weeks or months, each dated by its first day: a
    /// total where days add up, otherwise their mean, with the widest range.
    public func grouped(_ grouping: SeriesGrouping, adds: Bool, calendar: Calendar) -> [DayValue] {
        guard grouping != .day else { return self }
        let unit: Calendar.Component = grouping == .week ? .weekOfYear : .month
        var order: [Day] = []
        var groups: [Day: [DayValue]] = [:]
        for value in self {
            let start = calendar.dateInterval(of: unit, for: value.day.start(in: calendar))?.start ?? value.day.start(in: calendar)
            let key = Day(start, calendar: calendar)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(value)
        }
        return order.map { key in
            let rows = groups[key]!
            let sum = rows.reduce(0) { $0 + $1.value }
            return DayValue(day: key, value: adds ? sum : sum / Double(rows.count),
                            low: rows.compactMap(\.low).min(), high: rows.compactMap(\.high).max())
        }
    }
}
