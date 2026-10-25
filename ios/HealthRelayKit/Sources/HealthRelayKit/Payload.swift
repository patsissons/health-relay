import Foundation

/// The schema's name on the wire.
public let schemaName = "apple-push/1"

/// Who is sending: shown by receivers, never a person's identity.
public struct Device: Codable, Sendable, Equatable {
    public var name: String
    public var model: String
    public var os: String
    public var app: String

    public init(name: String, model: String, os: String, app: String) {
        self.name = name
        self.model = model
        self.os = os
        self.app = app
    }
}

/// A `stats` row: one quantity type, one local day, one source.
public struct StatRow: Sendable, Equatable {
    public var type: String
    public var day: Day
    public var source: String
    public var unit: String
    public var sum: Double?
    public var avg: Double?
    public var count: Int?
    public var min: Double?
    public var max: Double?
    public var latest: Double?
    public var latestAt: String?

    var json: JSON {
        var o: [String: JSON] = ["type": .string(type), "day": .string(day.description), "source": .string(source), "unit": .string(unit)]
        if let sum { o["sum"] = .number(sum) }
        if let avg { o["avg"] = .number(avg) }
        if let count { o["count"] = .number(Double(count)) }
        if let min { o["min"] = .number(min) }
        if let max { o["max"] = .number(max) }
        if let latest { o["latest"] = .number(latest) }
        if let latestAt { o["latestAt"] = .string(latestAt) }
        return .object(o)
    }
}

/// A `samples` row: an export.xml Record.
public struct SampleRow: Sendable, Equatable {
    public var id: String
    public var type: String
    public var sourceName: String
    public var start: Date
    public var end: Date
    public var startDate: String
    public var endDate: String
    public var value: String
    public var unit: String?

    var json: JSON {
        var o: [String: JSON] = ["type": .string(type), "sourceName": .string(sourceName), "startDate": .string(startDate), "endDate": .string(endDate), "value": .string(value)]
        if let unit { o["unit"] = .string(unit) }
        return .object(o)
    }
}

public struct WorkoutRow: Sendable, Equatable {
    public var record: WorkoutRecord
    public var startDate: String
    public var endDate: String

    var json: JSON {
        var o: [String: JSON] = [
            "workoutActivityType": .string(record.activityType),
            "sourceName": .string(record.source),
            "startDate": .string(startDate),
            "endDate": .string(endDate),
            "duration": .string(JSON.format(record.duration / 60)),
            "durationUnit": "min",
            "stats": .array(record.statistics.map { s in
                var stat: [String: JSON] = ["type": .string(s.type), "unit": .string(s.unit)]
                if let sum = s.sum { stat["sum"] = .string(JSON.format(sum)) }
                if let average = s.average { stat["average"] = .string(JSON.format(average)) }
                if let maximum = s.maximum { stat["maximum"] = .string(JSON.format(maximum)) }
                return .object(stat)
            }),
        ]
        if let route = record.route {
            o["route"] = .array(route.map { p in
                ["lat": .number(p.lat), "lon": .number(p.lon), "ele": p.ele.map(JSON.number) ?? .null]
            })
        }
        return .object(o)
    }
}

public struct SummaryRow: Sendable, Equatable {
    public var record: ActivitySummaryRecord

    var json: JSON {
        [
            "dateComponents": .string(record.day.description),
            "appleStandHours": .string(JSON.format(record.standHours)),
            "activeEnergyBurnedGoal": .string(JSON.format(record.moveGoal)),
            "activeEnergyBurnedGoalUnit": "kcal",
        ]
    }
}

public struct ECGRow: Sendable, Equatable {
    public static let targetRate = 128.0

    public var id: String
    public var start: Date
    public var recorded: String
    public var classification: String
    public var rate: Double
    public var averageHeartRate: Double?
    /// Microvolts at `rate`, whole numbers.
    public var samples: [Double]

    /// Averages the trace down to about 128 Hz: each block of
    /// round(rate / 128) samples becomes its mean, rounded as JavaScript's
    /// Math.round rounds (half up), so every platform gets the same trace.
    init(_ record: ECGRecord, timeZone: TimeZone) {
        id = record.id
        start = record.start
        recorded = Stamp.local(record.start, timeZone)
        classification = record.classification
        averageHeartRate = record.averageHeartRate
        let block = Swift.max(1, Int(jsRound(record.rate / ECGRow.targetRate)))
        rate = record.rate / Double(block)
        var out: [Double] = []
        out.reserveCapacity(record.voltages.count / block)
        var i = 0
        while i + block <= record.voltages.count {
            var sum = 0.0
            for v in record.voltages[i..<(i + block)] { sum += v }
            out.append(jsRound(sum / Double(block)))
            i += block
        }
        samples = out
    }

    var json: JSON {
        var o: [String: JSON] = [
            "recorded": .string(recorded),
            "classification": .string(classification),
            "rate": .number(rate),
            "samples": .array(samples.map(JSON.number)),
        ]
        if let averageHeartRate { o["avgHr"] = .number(averageHeartRate) }
        return .object(o)
    }
}

/// JavaScript's Math.round: halves round up (toward +infinity).
func jsRound(_ x: Double) -> Double {
    (x + 0.5).rounded(.down)
}

/// What a set of days carries, every section; records are unique by id and
/// kept in the order Health Relay sends them.
public struct Content: Sendable, Equatable {
    public var stats: [StatRow] = []
    public var samples: [SampleRow] = []
    public var workouts: [WorkoutRow] = []
    public var summaries: [SummaryRow] = []
    public var ecg: [ECGRow] = []

    public init() {}

    /// The union of several days' content: shared records (a night spanning
    /// two listed days) appear once.
    public static func merging(_ parts: [Content]) -> Content {
        var out = Content()
        var seen = Set<String>()
        for p in parts {
            out.stats += p.stats
            out.summaries += p.summaries
            out.samples += p.samples.filter { seen.insert($0.id).inserted }
            out.workouts += p.workouts.filter { seen.insert($0.record.id).inserted }
            out.ecg += p.ecg.filter { seen.insert($0.id).inserted }
        }
        out.sort()
        return out
    }

    public mutating func sort() {
        stats.sort { ($0.day, $0.type, $0.source) < ($1.day, $1.type, $1.source) }
        samples.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return ($0.type, $0.sourceName, $0.end, $0.value) < ($1.type, $1.sourceName, $1.end, $1.value)
        }
        workouts.sort { ($0.record.start, $0.record.activityType, $0.record.source) < ($1.record.start, $1.record.activityType, $1.record.source) }
        summaries.sort { $0.record.day < $1.record.day }
        ecg.sort { $0.start < $1.start }
    }

    public var isEmpty: Bool {
        stats.isEmpty && samples.isEmpty && workouts.isEmpty && summaries.isEmpty && ecg.isEmpty
    }

    /// Records in all sections, for the delivery log.
    public var recordCount: Int {
        stats.count + samples.count + workouts.count + summaries.count + ecg.count
    }
}

/// One push: a batch of days described in full, or (with no content) the
/// empty connection test.
public struct Push: Sendable {
    public var device: Device
    public var exportedAt: Date
    public var timeZone: TimeZone
    public var days: [Day]
    public var content: Content?

    public init(device: Device, exportedAt: Date, timeZone: TimeZone, days: [Day], content: Content?) {
        self.device = device
        self.exportedAt = exportedAt
        self.timeZone = timeZone
        self.days = days
        self.content = content
    }

    /// The connection test: no days, no sections.
    public static func empty(device: Device, at date: Date, timeZone: TimeZone) -> Push {
        Push(device: device, exportedAt: date, timeZone: timeZone, days: [], content: nil)
    }

    public var json: JSON {
        var o: [String: JSON] = [
            "schema": .string(schemaName),
            "device": ["name": .string(device.name), "model": .string(device.model), "os": .string(device.os), "app": .string(device.app)],
            "exportedAt": .string(Stamp.utc(exportedAt)),
            "tz": .string(timeZone.identifier),
            "days": .array(days.sorted().map { .string($0.description) }),
        ]
        if let content {
            o["stats"] = .array(content.stats.map(\.json))
            o["samples"] = .array(content.samples.map(\.json))
            o["workouts"] = .array(content.workouts.map(\.json))
            o["summaries"] = .array(content.summaries.map(\.json))
            o["ecg"] = .array(content.ecg.map(\.json))
        }
        return .object(o)
    }

    /// The canonical bytes sent.
    public var body: Data { json.data }
}
