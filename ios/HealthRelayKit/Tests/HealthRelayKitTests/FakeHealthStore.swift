import Foundation
@testable import HealthRelayKit

/// An in-memory HealthStore. Quantity samples are kept in the catalog's
/// unit; statistics are computed from them the way HealthKit would (a
/// sample counts for the day it starts).
final class FakeHealthStore: HealthStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _quantities: [String: [QuantitySample]] = [:]
    private var _categories: [String: [CategorySample]] = [:]
    private var _workouts: [WorkoutRecord] = []
    private var _ecgs: [ECGRecord] = []
    private var _summaries: [ActivitySummaryRecord] = []
    /// Every added sample with the sequence number it was added at, per type id.
    private var added: [String: [(Int, DateInterval)]] = [:]
    private var sequence = 0
    var failReads = false
    private(set) var reads = 0

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func note(_ id: String, _ start: Date, _ end: Date) {
        sequence += 1
        added[id, default: []].append((sequence, DateInterval(start: start, end: max(start, end))))
    }

    func add(_ type: String, source: String, _ start: Date, _ end: Date, _ value: Double) {
        locked {
            _quantities[type, default: []].append(QuantitySample(source: source, start: start, end: end, value: value))
            note(type, start, end)
        }
    }

    func add(_ type: String, source: String, _ at: Date, _ value: Double) {
        add(type, source: source, at, at, value)
    }

    func addCategory(_ type: String, source: String, _ start: Date, _ end: Date, _ value: Int) {
        locked {
            _categories[type, default: []].append(CategorySample(source: source, start: start, end: end, value: value))
            note(type, start, end)
        }
    }

    func addCategory(_ type: String, source: String, _ at: Date, _ value: Int) {
        addCategory(type, source: source, at, at, value)
    }

    func add(_ workout: WorkoutRecord) {
        locked {
            _workouts.append(workout)
            note(HealthType.workout.id, workout.start, workout.end)
        }
    }

    func add(_ ecg: ECGRecord) {
        locked {
            _ecgs.append(ecg)
            note(HealthType.ecg.id, ecg.start, ecg.start)
        }
    }

    func add(_ summary: ActivitySummaryRecord) {
        locked { _summaries.append(summary) }
    }

    func requestAuthorization() async throws {}

    private func countRead() throws {
        try locked {
            reads += 1
            if failReads { throw FakeError.unreadable }
        }
    }

    func statistics(_ type: StatType, days: [Day], calendar: Calendar) async throws -> [Day: [SourceStatistic]] {
        try countRead()
        let samples = locked { _quantities[type.id] ?? [] }
        var out: [Day: [SourceStatistic]] = [:]
        for day in days {
            let interval = day.interval(in: calendar)
            let inDay = samples.filter { interval.start <= $0.start && $0.start < interval.end }
            let bySource = Dictionary(grouping: inDay, by: \.source)
            for (source, list) in bySource {
                if type.mode == .sum {
                    out[day, default: []].append(SourceStatistic(source: source, sum: list.reduce(0) { $0 + $1.value }))
                } else {
                    let last = list.max { $0.start < $1.start }!
                    out[day, default: []].append(SourceStatistic(source: source, latest: last.value, latestAt: last.start))
                }
            }
        }
        return out
    }

    func quantitySamples(_ type: String, unit: String, in interval: DateInterval) async throws -> [QuantitySample] {
        try countRead()
        return locked { (_quantities[type] ?? []).filter { overlaps($0.start, $0.end, interval) } }
    }

    func categorySamples(_ type: String, in interval: DateInterval) async throws -> [CategorySample] {
        try countRead()
        return locked { (_categories[type] ?? []).filter { overlaps($0.start, $0.end, interval) } }
    }

    func workouts(in interval: DateInterval) async throws -> [WorkoutRecord] {
        try countRead()
        return locked { _workouts.filter { overlaps($0.start, $0.end, interval) } }
    }

    func electrocardiograms(in interval: DateInterval) async throws -> [ECGRecord] {
        try countRead()
        return locked { _ecgs.filter { interval.start <= $0.start && $0.start < interval.end } }
    }

    func activitySummaries(days: [Day], calendar: Calendar) async throws -> [ActivitySummaryRecord] {
        try countRead()
        return locked { _summaries.filter { days.contains($0.day) } }
    }

    /// Anchors are the sequence number of the last sample seen.
    func changes(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes {
        locked {
            let from = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            let list = (added[type.id] ?? []).filter { $0.0 > from && (anchor != nil || $0.1.end >= since) }
            let last = (added[type.id] ?? []).last?.0 ?? from
            return Changes(added: list.map(\.1), anchor: Data(String(max(last, from)).utf8))
        }
    }

    func newestSample(_ type: HealthType, since: Date) async throws -> Date? {
        locked { (added[type.id] ?? []).map(\.1.start).filter { $0 >= since }.max() }
    }

    private func overlaps(_ start: Date, _ end: Date, _ i: DateInterval) -> Bool {
        start == end ? i.start <= start && start < i.end : start < i.end && end > i.start
    }
}

enum FakeError: Error {
    case unreadable
}

/// Test helpers: dates written as export.xml stamps.
enum T {
    static let vancouver = TimeZone(identifier: "America/Vancouver")!

    /// "2026-10-24 17:00:00 -0700" -> Date.
    static func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: text)!
    }

    static func day(_ text: String) -> Day { Day(text)! }
}
