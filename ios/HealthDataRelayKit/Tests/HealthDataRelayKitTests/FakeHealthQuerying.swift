import Foundation
@testable import HealthDataRelayKit

/// An in-memory HealthQuerying that pages and buckets like HealthKit: a
/// bucket's merged sum adds its sources, and a page never repeats a sample.
final class FakeHealthQuerying: HealthQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var quantities: [String: [DetailedQuantity]] = [:]
    private var categories: [String: [DetailedCategory]] = [:]
    private var workouts: [WorkoutDetail] = []
    private var routes: [String: [RoutePoint]] = [:]
    private var ecgs: [ECGDetail] = []
    private var added: [String: [(Int, DateInterval)]] = [:]
    private var sequence = 0
    private(set) var pageReads = 0
    private(set) var bucketQueries: [BucketQuery] = []
    var heartbeatSeries: [HeartbeatSeries] = []
    var moods: [StateOfMindRecord] = []
    var doses: [MedicationDose] = []
    let calendar: Calendar

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func add(_ type: String, _ sample: DetailedQuantity) {
        locked {
            quantities[type, default: []].append(sample)
            sequence += 1
            added[type, default: []].append((sequence, DateInterval(start: sample.start, end: max(sample.start, sample.end))))
        }
    }

    func add(_ metric: String, source: String = "Watch", at: Date, end: Date? = nil, _ value: Double) {
        add(MetricCatalog.metric(named: metric)!.identifiers[0], DetailedQuantity(source: source, start: at, end: end ?? at, value: value))
    }

    func addCategory(_ type: String, _ sample: DetailedCategory) {
        locked { categories[type, default: []].append(sample) }
    }

    func add(_ workout: WorkoutDetail, route: [RoutePoint] = []) {
        locked {
            workouts.append(workout)
            routes[workout.id] = route
        }
    }

    func add(_ ecg: ECGDetail) {
        locked { ecgs.append(ecg) }
    }

    func requestAuthorization(types: [HealthType], extras: ReadExtras) async throws {}

    func buckets(_ query: BucketQuery) async throws -> [StatBucket] {
        let samples = locked {
            bucketQueries.append(query)
            return quantities[query.type] ?? []
        }
        var edge = query.plan.anchor
        var out: [StatBucket] = []
        while edge < query.plan.span.end {
            let end = stepped(edge, query.plan.step)
            let inBucket = samples.filter { edge <= $0.start && $0.start < end }
            if !inBucket.isEmpty {
                let sources = Dictionary(grouping: inBucket, by: \.source).keys.sorted().map { name in
                    value(inBucket.filter { $0.source == name }, source: name, style: query.style)
                }
                out.append(StatBucket(start: edge, end: end, merged: value(inBucket, source: "", style: query.style), sources: sources))
            }
            edge = end
        }
        return out
    }

    private func value(_ samples: [DetailedQuantity], source: String, style: BucketQuery.Style) -> StatBucket.SourceValue {
        let values = samples.map(\.value)
        switch style {
        case .sum: return .init(source: source, sum: values.reduce(0, +))
        case .range: return .init(source: source, avg: values.reduce(0, +) / Double(values.count), min: values.min(), max: values.max())
        }
    }

    private func stepped(_ date: Date, _ step: BucketStep) -> Date {
        switch step {
        case .seconds(let n): date.addingTimeInterval(Double(n))
        case .days(let n): calendar.date(byAdding: .day, value: n, to: date)!
        case .months(let n): calendar.date(byAdding: .month, value: n, to: date)!
        case .years(let n): calendar.date(byAdding: .year, value: n, to: date)!
        }
    }

    private func overlaps(_ start: Date, _ end: Date, _ i: DateInterval) -> Bool {
        start == end ? i.start <= start && start < i.end : start < i.end && end > i.start
    }

    private func page<T>(_ all: [T], start: KeyPath<T, Date>, id: KeyPath<T, String>, after cursor: PageCursor?, limit: Int) -> SamplePage<T> {
        var rest = all.sorted { $0[keyPath: start] < $1[keyPath: start] }
        if let cursor { rest = rest.filter { $0[keyPath: start] >= cursor.start && !cursor.ids.contains($0[keyPath: id]) } }
        let items = Array(rest.prefix(limit))
        guard rest.count > limit, let last = items.last else { return SamplePage(items: items, next: nil) }
        let at = items.filter { $0[keyPath: start] == last[keyPath: start] }.map { $0[keyPath: id] }
        return SamplePage(items: items, next: PageCursor(start: last[keyPath: start], ids: Set(at).union(cursor?.start == last[keyPath: start] ? cursor!.ids : [])))
    }

    func quantityPage(_ type: String, unit: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedQuantity> {
        locked {
            pageReads += 1
            return page((quantities[type] ?? []).filter { overlaps($0.start, $0.end, range) }, start: \.start, id: \.id, after: cursor, limit: limit)
        }
    }

    func categoryPage(_ type: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedCategory> {
        locked {
            pageReads += 1
            return page((categories[type] ?? []).filter { overlaps($0.start, $0.end, range) }, start: \.start, id: \.id, after: cursor, limit: limit)
        }
    }

    func sources(of type: HealthType) async throws -> [String] {
        locked { Set((quantities[type.id] ?? []).map(\.source)).sorted() }
    }

    func workoutPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<WorkoutDetail> {
        locked { page(workouts.filter { overlaps($0.start, $0.end, range) }, start: \.start, id: \.id, after: cursor, limit: limit) }
    }

    func routePage(workoutID: String, after cursor: Int?, limit: Int) async throws -> (points: [RoutePoint], next: Int?) {
        locked {
            let all = routes[workoutID] ?? []
            let from = cursor ?? 0
            let to = min(from + limit, all.count)
            return (Array(all[from..<to]), to < all.count ? to : nil)
        }
    }

    func ecgPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<ECGDetail> {
        locked { page(ecgs.filter { range.start <= $0.start && $0.start < range.end }, start: \.start, id: \.id, after: cursor, limit: limit) }
    }

    func voltages(ecgID: String) async throws -> [Double] { [1, 2, 3] }

    func heartbeats(in range: DateInterval) async throws -> [HeartbeatSeries] {
        locked { heartbeatSeries.filter { overlaps($0.start, $0.end, range) } }
    }

    func statesOfMind(in range: DateInterval) async throws -> [StateOfMindRecord] {
        locked { moods.filter { overlaps($0.start, $0.end, range) } }
    }

    func medicationDoses(in range: DateInterval) async throws -> [MedicationDose] {
        locked { doses.filter { overlaps($0.start, $0.end, range) } }
    }

    /// Anchors are the sequence number of the last sample seen.
    func additions(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes {
        locked {
            let from = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            let list = (added[type.id] ?? []).filter { $0.0 > from && (anchor != nil || $0.1.end >= since) }
            return Changes(added: list.map(\.1), anchor: Data(String(max((added[type.id] ?? []).last?.0 ?? from, from)).utf8))
        }
    }
}

/// A huge type that makes its samples as they're asked for, so a test can read
/// millions while the source holds nothing, and count what was fetched.
final class SyntheticHealthQuerying: HealthQuerying, @unchecked Sendable {
    let start: Date
    let count: Int
    private let lock = NSLock()
    private var read = 0

    init(start: Date, count: Int) {
        self.start = start
        self.count = count
    }

    var samplesRead: Int { lock.withLock { read } }

    func quantityPage(_ type: String, unit: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedQuantity> {
        let from = cursor.map { Int($0.start.timeIntervalSince(start)) + 1 } ?? 0
        let to = min(from + limit, count)
        lock.withLock { read += to - from }
        let items = (from..<to).map { i in
            let at = start.addingTimeInterval(Double(i))
            return DetailedQuantity(id: String(i), source: "Watch", start: at, end: at, value: Double(i))
        }
        return SamplePage(items: items, next: to < count ? PageCursor(start: start.addingTimeInterval(Double(to - 1)), ids: []) : nil)
    }

    func requestAuthorization(types: [HealthType], extras: ReadExtras) async throws {}
    func buckets(_ query: BucketQuery) async throws -> [StatBucket] { [] }
    func categoryPage(_ type: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedCategory> { SamplePage(items: [], next: nil) }
    func sources(of type: HealthType) async throws -> [String] { [] }
    func workoutPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<WorkoutDetail> { SamplePage(items: [], next: nil) }
    func routePage(workoutID: String, after cursor: Int?, limit: Int) async throws -> (points: [RoutePoint], next: Int?) { ([], nil) }
    func ecgPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<ECGDetail> { SamplePage(items: [], next: nil) }
    func voltages(ecgID: String) async throws -> [Double] { [] }
    func heartbeats(in range: DateInterval) async throws -> [HeartbeatSeries] { [] }
    func statesOfMind(in range: DateInterval) async throws -> [StateOfMindRecord] { [] }
    func medicationDoses(in range: DateInterval) async throws -> [MedicationDose] { [] }
    func additions(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes { Changes(added: [], anchor: nil) }
}
