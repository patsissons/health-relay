import Foundation

/// A night's sleep built from its stage segments. Durations are hours.
public struct SleepNight: Sendable, Equatable {
    public var date: Date
    public var inBedStart: Date
    public var inBedEnd: Date
    public var sleepStart: Date?
    public var sleepEnd: Date?
    public var inBed: Double
    public var asleep: Double
    public var awake: Double
    public var core: Double
    public var deep: Double
    public var rem: Double
    public var source: String

    /// Sleep of any stage.
    public var totalSleep: Double { asleep + core + deep + rem }

    /// A gap longer than this starts a new night.
    static let nightGap: TimeInterval = 4 * 3600

    /// Splits segments into nights and totals each. Several sources often
    /// record the same night, so each moment counts once, for the most
    /// specific stage anyone recorded: a stage beats plain asleep, which
    /// beats awake, which beats in bed. A night's date is the local midnight
    /// of the morning it ended.
    public static func nights(from segments: [DetailedCategory], calendar: Calendar) -> [SleepNight] {
        let sorted = segments.sorted { $0.start < $1.start }
        var clusters: [[DetailedCategory]] = []
        var clusterEnd = Date.distantPast
        for s in sorted {
            if clusters.isEmpty || s.start.timeIntervalSince(clusterEnd) > nightGap {
                clusters.append([s])
                clusterEnd = s.end
            } else {
                clusters[clusters.count - 1].append(s)
                clusterEnd = max(clusterEnd, s.end)
            }
        }
        return clusters.compactMap { night(from: $0, calendar: calendar) }
    }

    private static func night(from segments: [DetailedCategory], calendar: Calendar) -> SleepNight? {
        guard let first = segments.first else { return nil }
        let edges = Set(segments.flatMap { [$0.start, $0.end] }).sorted()
        var durations: [MetricCatalog.SleepStage: Double] = [:]
        var sleepStart: Date?
        var sleepEnd: Date?
        var end = first.end
        var start = first.start
        for (a, b) in zip(edges, edges.dropFirst()) {
            let covering = segments.filter { $0.start <= a && $0.end >= b }.compactMap { MetricCatalog.SleepStage(rawValue: $0.value) }
            guard let stage = covering.max(by: { rank($0) < rank($1) }) else { continue }
            durations[stage, default: 0] += b.timeIntervalSince(a) / 3600
            start = min(start, a)
            end = max(end, b)
            if stage != .awake && stage != .inBed {
                sleepStart = sleepStart ?? a
                sleepEnd = b
            }
        }
        return SleepNight(date: calendar.startOfDay(for: end), inBedStart: start, inBedEnd: end, sleepStart: sleepStart, sleepEnd: sleepEnd,
                          inBed: durations[.inBed] ?? 0, asleep: durations[.asleep] ?? 0, awake: durations[.awake] ?? 0,
                          core: durations[.core] ?? 0, deep: durations[.deep] ?? 0, rem: durations[.rem] ?? 0,
                          source: Set(segments.map(\.source)).sorted().joined(separator: "|"))
    }

    private static func rank(_ s: MetricCatalog.SleepStage) -> Int {
        switch s {
        case .inBed: 0
        case .awake: 1
        case .asleep: 2
        case .core, .deep, .rem: 3
        }
    }

    /// Summarized points. Groupings finer than a day have no sleep point: a
    /// night isn't an hour's value. Coarser ones add their nights together.
    static func points(_ nights: [SleepNight], grouping: TimeGrouping, planner: BucketPlanner, within ranges: [DateInterval]) -> [MetricPoint] {
        let inRange = nights.filter { n in ranges.contains { $0.start <= n.date && n.date < $0.end } }
        switch grouping {
        case .seconds, .minutes, .hours, .automatic:
            return []
        case .days:
            return inRange.map { MetricPoint(date: $0.date, source: $0.source, sleep: $0) }
        case .weeks, .months, .years:
            let groups = Dictionary(grouping: inRange) { planner.floor($0.date) }
            return groups.keys.sorted().map { key in
                let rows = groups[key]!
                var sum = rows[0]
                sum.date = key
                for n in rows.dropFirst() {
                    sum.inBed += n.inBed
                    sum.asleep += n.asleep
                    sum.awake += n.awake
                    sum.core += n.core
                    sum.deep += n.deep
                    sum.rem += n.rem
                    sum.inBedEnd = max(sum.inBedEnd, n.inBedEnd)
                    if let end = n.sleepEnd { sum.sleepEnd = max(sum.sleepEnd ?? end, end) }
                }
                sum.source = Set(rows.flatMap { $0.source.split(separator: "|").map(String.init) }).sorted().joined(separator: "|")
                return MetricPoint(date: key, source: sum.source, sleep: sum)
            }
        }
    }
}
