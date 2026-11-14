import Foundation

/// How one bucket steps to the next: a fixed length, or a calendar unit whose
/// length depends on the date (a day is 23 or 25 hours across daylight saving).
public enum BucketStep: Sendable, Equatable {
    case seconds(Int)
    case days(Int)
    case months(Int)
    case years(Int)
}

/// One query's worth of buckets.
public struct BucketPlan: Sendable, Equatable {
    /// The first bucket's start: what every later edge is measured from.
    public var anchor: Date
    public var step: BucketStep
    /// From the first bucket's start to the last bucket's end.
    public var span: DateInterval
}

/// Where bucket edges fall in local time, and how to split a long range into
/// queries small enough that one result fits in memory.
public struct BucketPlanner: Sendable {
    /// A query is cut so it holds at most this many buckets.
    public static let maxBucketsPerQuery = 20_000

    public let grouping: TimeGrouping
    public let calendar: Calendar

    public init(grouping: TimeGrouping, calendar: Calendar) {
        self.grouping = grouping
        self.calendar = calendar
    }

    private var fixedLength: Int? {
        switch grouping {
        case .seconds: 1
        case .minutes, .automatic: 60
        case .hours: 3600
        case .days, .weeks, .months, .years: nil
        }
    }

    /// The bucket start at or before an instant. Sub-day buckets count from
    /// local midnight, so a 25-hour day has 25 hour buckets.
    public func floor(_ date: Date) -> Date {
        if let length = fixedLength {
            let day = calendar.startOfDay(for: date)
            let elapsed = date.timeIntervalSince(day)
            return day.addingTimeInterval((elapsed / Double(length)).rounded(.down) * Double(length))
        }
        switch grouping {
        case .weeks: return calendar.dateInterval(of: .weekOfYear, for: date)!.start
        case .months: return calendar.dateInterval(of: .month, for: date)!.start
        case .years: return calendar.dateInterval(of: .year, for: date)!.start
        default: return calendar.startOfDay(for: date)
        }
    }

    /// The start of the bucket after the one starting at `start`.
    public func next(_ start: Date) -> Date {
        if let length = fixedLength {
            // A sub-day bucket ending past midnight stops at midnight, so
            // buckets never straddle two local days.
            let stepped = start.addingTimeInterval(Double(length))
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
            return min(stepped, tomorrow)
        }
        switch grouping {
        case .weeks: return calendar.date(byAdding: .day, value: 7, to: start)!
        case .months: return calendar.date(byAdding: .month, value: 1, to: start)!
        case .years: return calendar.date(byAdding: .year, value: 1, to: start)!
        default: return calendar.date(byAdding: .day, value: 1, to: start)!
        }
    }

    /// Extends a range outward to whole buckets, so a point is never built
    /// from part of its bucket.
    public func snap(_ range: DateInterval) -> DateInterval {
        let start = floor(range.start)
        var end = floor(range.end)
        if end < range.end || end == start { end = next(end) }
        return DateInterval(start: start, end: end)
    }

    /// Bucket starts in a range, in order, with the end of the last bucket.
    public func edges(_ range: DateInterval) -> [Date] {
        let snapped = snap(range)
        var out = [snapped.start]
        var at = snapped.start
        while at < snapped.end {
            at = next(at)
            out.append(at)
        }
        return out
    }

    /// One plan per query, covering the range, each within the bucket limit.
    /// HealthKit counts fixed-length buckets from a plan's anchor, so a plan
    /// also ends at the midnight after a clock change that isn't a whole number
    /// of buckets (Lord Howe's 30 minutes against hours), where counting from
    /// the old midnight would no longer land on bucket edges.
    public func plans(_ range: DateInterval) -> [BucketPlan] {
        let snapped = snap(range)
        var out: [BucketPlan] = []
        var start = snapped.start
        while start < snapped.end {
            let plan = plan(from: start, within: snapped.end)
            out.append(plan)
            start = plan.span.end
        }
        return out
    }

    private func plan(from start: Date, within limit: Date) -> BucketPlan {
        let cap = Self.maxBucketsPerQuery
        switch grouping {
        case .seconds, .minutes, .hours, .automatic:
            let length = fixedLength!
            var end = min(start.addingTimeInterval(Double(length * cap)), limit)
            var check = start
            let zone = calendar.timeZone
            while let change = zone.nextDaylightSavingTimeTransition(after: check), change < end {
                let shift = zone.secondsFromGMT(for: change) - zone.secondsFromGMT(for: change.addingTimeInterval(-1))
                if shift % length != 0 {
                    end = min(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: change))!)
                    break
                }
                check = change
            }
            return BucketPlan(anchor: start, step: .seconds(length), span: DateInterval(start: start, end: end))
        case .days:
            let end = min(calendar.date(byAdding: .day, value: cap, to: start)!, limit)
            return BucketPlan(anchor: start, step: .days(1), span: DateInterval(start: start, end: end))
        case .weeks:
            let end = min(calendar.date(byAdding: .day, value: 7 * cap, to: start)!, limit)
            return BucketPlan(anchor: start, step: .days(7), span: DateInterval(start: start, end: end))
        case .months:
            let end = min(calendar.date(byAdding: .month, value: cap, to: start)!, limit)
            return BucketPlan(anchor: start, step: .months(1), span: DateInterval(start: start, end: end))
        case .years:
            let end = min(calendar.date(byAdding: .year, value: cap, to: start)!, limit)
            return BucketPlan(anchor: start, step: .years(1), span: DateInterval(start: start, end: end))
        }
    }
}

/// Ordered, non-overlapping ranges from any list of intervals.
public func mergeIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
    var out: [DateInterval] = []
    for i in intervals.sorted(by: { $0.start < $1.start }) {
        if let last = out.last, i.start <= last.end {
            out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
        } else {
            out.append(i)
        }
    }
    return out
}

/// Turns a range setting into the time this run actually covers.
public struct RangePlanner: Sendable {
    public enum Failure: Error, Equatable {
        /// `askAtRun` with nothing answered.
        case needsAnswer
        /// All of it is older than the plan's history reaches (see `HistoryLimit`).
        case beyondHistory
    }

    /// A first since-last-run has no last run: it covers this many days back.
    public static let firstRunDays = 7

    public let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// The run's ranges, in order and not overlapping. `changedDays` are the
    /// pipeline's dirty days, `late` the older samples found since last time,
    /// and `answer` what was picked for an asked range. Nothing starts before
    /// `floor`; a range wholly before it fails rather than send nothing.
    public func ranges(_ spec: RangeSpec, now: Date, cursor: ExtractCursor = ExtractCursor(), changedDays: [Day] = [], late: [DateInterval] = [], answer: DateInterval? = nil, floor: Date? = nil) throws -> [DateInterval] {
        let whole = try unbounded(spec, now: now, cursor: cursor, changedDays: changedDays, late: late, answer: answer)
        guard let floor else { return whole }
        let kept = whole.compactMap { HistoryLimit.clip($0, to: floor) }
        if kept.isEmpty && !whole.isEmpty { throw Failure.beyondHistory }
        return kept
    }

    private func unbounded(_ spec: RangeSpec, now: Date, cursor: ExtractCursor, changedDays: [Day], late: [DateInterval], answer: DateInterval?) throws -> [DateInterval] {
        let today = Day(now, calendar: calendar)
        switch spec {
        case .changedDays:
            return mergeIntervals(changedDays.map { $0.interval(in: calendar) })
        case .sinceLastRun:
            let start = cursor.lastEnd ?? today.adding(-Self.firstRunDays).start(in: calendar)
            let main = start < now ? [DateInterval(start: start, end: now)] : []
            return mergeIntervals(main + late)
        case .today:
            return [DateInterval(start: today.start(in: calendar), end: max(now, today.start(in: calendar)))]
        case .yesterday:
            return [today.adding(-1).interval(in: calendar)]
        case .previousDays(let n):
            return [DateInterval(start: today.adding(-max(1, n)).start(in: calendar), end: today.start(in: calendar))]
        case .lastDays(let n):
            return [lastDays(n, now: now)]
        case .fixed(let interval):
            return [interval]
        case .askAtRun:
            guard let answer else { throw Failure.needsAnswer }
            return [answer]
        }
    }

    /// The last `n` days including today so far.
    public func lastDays(_ n: Int, now: Date) -> DateInterval {
        DateInterval(start: Day(now, calendar: calendar).adding(1 - max(1, n)).start(in: calendar), end: now)
    }

    /// The cursor after a run that covered up to `now`. A run that didn't
    /// advance time, like a re-send of a fixed range, leaves it alone.
    public func advanced(_ cursor: ExtractCursor, spec: RangeSpec, now: Date, anchors: [HealthType: Data]) -> ExtractCursor {
        var out = cursor
        out.anchors.merge(anchors) { _, new in new }
        if spec == .sinceLastRun { out.lastEnd = now }
        return out
    }
}
