import Foundation

/// Reads days from a HealthStore into schema content, one Content per day.
/// A day's content holds everything the phone has for it in every section:
/// stats rows for the day, and every sample, workout and ECG that overlaps
/// it (a night that began the evening before belongs to both days; merging
/// sends it once).
public struct DayReader: Sendable {
    public let store: HealthStore
    public let calendar: Calendar

    public init(store: HealthStore, calendar: Calendar) {
        self.store = store
        self.calendar = calendar
    }

    /// Reads the days, one query per type for each run of consecutive days.
    public func read(_ days: [Day]) async throws -> [Day: Content] {
        var out: [Day: Content] = [:]
        for run in DayReader.runs(Set(days).sorted()) {
            for (day, content) in try await readRun(run) { out[day] = content }
        }
        return out
    }

    /// Consecutive days grouped: [1, 2, 3, 7, 8] -> [[1, 2, 3], [7, 8]].
    static func runs(_ sorted: [Day]) -> [[Day]] {
        var out: [[Day]] = []
        for d in sorted {
            if let last = out.last?.last, last.adding(1) == d {
                out[out.count - 1].append(d)
            } else {
                out.append([d])
            }
        }
        return out
    }

    private func readRun(_ days: [Day]) async throws -> [Day: Content] {
        let tz = calendar.timeZone
        let intervals = Dictionary(uniqueKeysWithValues: days.map { ($0, $0.interval(in: calendar)) })
        let span = DateInterval(start: intervals[days.first!]!.start, end: intervals[days.last!]!.end)
        var content = Dictionary(uniqueKeysWithValues: days.map { ($0, Content()) })
        /// The listed days an interval overlaps (an instant counts for its day).
        func daysOf(_ start: Date, _ end: Date) -> [Day] {
            days.filter { d in
                let i = intervals[d]!
                return start == end ? i.start <= start && start < i.end : start < i.end && end > i.start
            }
        }

        for type in Catalog.stats {
            switch type.mode {
            case .sum, .last:
                let byDay = try await store.statistics(type, days: days, calendar: calendar)
                for (day, sources) in byDay where content[day] != nil {
                    for s in sources {
                        var row = StatRow(type: type.id, day: day, source: s.source, unit: type.unit)
                        if type.mode == .sum {
                            guard let sum = s.sum else { continue }
                            row.sum = sum
                        } else {
                            guard let latest = s.latest, let at = s.latestAt else { continue }
                            row.latest = latest
                            row.latestAt = Stamp.local(at, tz)
                        }
                        content[day]!.stats.append(row)
                    }
                }
            case .mean, .hr:
                // HealthKit's statistics carry no sample count, and receivers
                // pool means by count, so these come from the samples. A
                // sample's day is the day it starts.
                let samples = try await store.quantitySamples(type.id, unit: type.healthKitUnit, in: span)
                var groups: [Day: [String: [Double]]] = [:]
                for s in samples {
                    let day = Day(s.start, calendar: calendar)
                    guard content[day] != nil else { continue }
                    groups[day, default: [:]][s.source, default: []].append(s.value)
                }
                for (day, sources) in groups {
                    for (source, values) in sources {
                        var row = StatRow(type: type.id, day: day, source: source, unit: type.unit)
                        row.avg = values.reduce(0, +) / Double(values.count)
                        row.count = values.count
                        if type.mode == .hr {
                            row.min = values.min()
                            row.max = values.max()
                        }
                        content[day]!.stats.append(row)
                    }
                }
            }
        }

        for type in Catalog.samples {
            var rows: [SampleRow] = []
            switch type.value {
            case .quantity(let unit, let hkUnit):
                for s in try await store.quantitySamples(type.id, unit: hkUnit, in: span) {
                    rows.append(SampleRow(id: s.id, type: type.id, sourceName: s.source, start: s.start, end: s.end,
                                          startDate: Stamp.local(s.start, tz), endDate: Stamp.local(s.end, tz),
                                          value: JSON.format(s.value), unit: unit))
                }
            case .category:
                for s in try await store.categorySamples(type.id, in: span) {
                    rows.append(SampleRow(id: s.id, type: type.id, sourceName: s.source, start: s.start, end: s.end,
                                          startDate: Stamp.local(s.start, tz), endDate: Stamp.local(s.end, tz),
                                          value: Catalog.categoryValueName(type: type.id, value: s.value), unit: nil))
                }
            }
            for row in rows {
                for day in daysOf(row.start, row.end) { content[day]!.samples.append(row) }
            }
        }

        for w in try await store.workouts(in: span) {
            let row = WorkoutRow(record: w, startDate: Stamp.local(w.start, tz), endDate: Stamp.local(w.end, tz))
            for day in daysOf(w.start, w.end) { content[day]!.workouts.append(row) }
        }

        for e in try await store.electrocardiograms(in: span) {
            let row = ECGRow(e, timeZone: tz)
            for day in daysOf(e.start, e.start) { content[day]!.ecg.append(row) }
        }

        for s in try await store.activitySummaries(days: days, calendar: calendar) where content[s.day] != nil {
            content[s.day]!.summaries.append(SummaryRow(record: s))
        }

        for day in days { content[day]!.sort() }
        return content
    }
}
