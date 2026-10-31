import Foundation

/// The health data the kit reads, in plain values. `LiveHealthStore` reads
/// HealthKit; the tests use a fake. Units are the catalog's: a store returns
/// every value in the unit the catalog names for its type.
public protocol HealthStore: Sendable {
    /// Ask to read every catalog type (a no-op once asked).
    func requestAuthorization() async throws

    /// For a sum or last type: per day, one entry per source with data.
    /// `days` are consecutive local days in `calendar`.
    func statistics(_ type: StatType, days: [Day], calendar: Calendar) async throws -> [Day: [SourceStatistic]]

    /// Quantity samples of a type that overlap the interval, in `unit`
    /// (an HKUnit string).
    func quantitySamples(_ type: String, unit: String, in interval: DateInterval) async throws -> [QuantitySample]

    /// Category samples of a type that overlap the interval.
    func categorySamples(_ type: String, in interval: DateInterval) async throws -> [CategorySample]

    /// Workouts that overlap the interval, with their statistics and route.
    func workouts(in interval: DateInterval) async throws -> [WorkoutRecord]

    /// ECG recordings that start in the interval, with their voltages.
    func electrocardiograms(in interval: DateInterval) async throws -> [ECGRecord]

    /// Activity ring summaries for the days that have one.
    func activitySummaries(days: [Day], calendar: Calendar) async throws -> [ActivitySummaryRecord]

    /// What was added since `anchor` (nil: since `since`): the start and end
    /// of each added sample and the anchor to ask from next time. Deletions
    /// are not reported.
    func changes(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes

    /// The newest sample of a type at or after `since`, if any.
    func newestSample(_ type: HealthType, since: Date) async throws -> Date?
}

/// One source's statistics for one day.
public struct SourceStatistic: Sendable, Equatable {
    public var source: String
    public var sum: Double?
    public var latest: Double?
    public var latestAt: Date?

    public init(source: String, sum: Double? = nil, latest: Double? = nil, latestAt: Date? = nil) {
        self.source = source
        self.sum = sum
        self.latest = latest
        self.latestAt = latestAt
    }
}

public struct QuantitySample: Sendable, Equatable {
    /// Unique per sample (HealthKit's UUID), so a sample read for two days is sent once.
    public var id: String
    public var source: String
    public var start: Date
    public var end: Date
    public var value: Double

    public init(id: String = UUID().uuidString, source: String, start: Date, end: Date, value: Double) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.value = value
    }
}

public struct CategorySample: Sendable, Equatable {
    public var id: String
    public var source: String
    public var start: Date
    public var end: Date
    public var value: Int

    public init(id: String = UUID().uuidString, source: String, start: Date, end: Date, value: Int) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.value = value
    }
}

public struct WorkoutRecord: Sendable, Equatable {
    public struct Statistic: Sendable, Equatable {
        public var type: String
        public var unit: String
        public var sum: Double?
        public var average: Double?
        public var maximum: Double?

        public init(type: String, unit: String, sum: Double? = nil, average: Double? = nil, maximum: Double? = nil) {
            self.type = type
            self.unit = unit
            self.sum = sum
            self.average = average
            self.maximum = maximum
        }
    }

    public struct Point: Sendable, Equatable {
        public var lat: Double
        public var lon: Double
        /// Metres, or nil when the fix had no altitude.
        public var ele: Double?

        public init(lat: Double, lon: Double, ele: Double?) {
            self.lat = lat
            self.lon = lon
            self.ele = ele
        }
    }

    public var id: String
    /// `HKWorkoutActivityTypeRunning` etc.
    public var activityType: String
    public var source: String
    public var start: Date
    public var end: Date
    /// Seconds.
    public var duration: Double
    public var statistics: [Statistic]
    /// Nil when the workout has no route.
    public var route: [Point]?

    public init(id: String = UUID().uuidString, activityType: String, source: String, start: Date, end: Date, duration: Double, statistics: [Statistic], route: [Point]?) {
        self.id = id
        self.activityType = activityType
        self.source = source
        self.start = start
        self.end = end
        self.duration = duration
        self.statistics = statistics
        self.route = route
    }
}

public struct ECGRecord: Sendable, Equatable {
    public var id: String
    public var start: Date
    public var classification: String
    /// Hz.
    public var rate: Double
    public var averageHeartRate: Double?
    /// Microvolts, at `rate`.
    public var voltages: [Double]

    public init(id: String = UUID().uuidString, start: Date, classification: String, rate: Double, averageHeartRate: Double?, voltages: [Double]) {
        self.id = id
        self.start = start
        self.classification = classification
        self.rate = rate
        self.averageHeartRate = averageHeartRate
        self.voltages = voltages
    }
}

public struct ActivitySummaryRecord: Sendable, Equatable {
    public var day: Day
    public var standHours: Double
    /// Kilocalories.
    public var moveGoal: Double

    public init(day: Day, standHours: Double, moveGoal: Double) {
        self.day = day
        self.standHours = standHours
        self.moveGoal = moveGoal
    }
}

public struct Changes: Sendable {
    /// Start and end of each added sample.
    public var added: [DateInterval]
    public var anchor: Data?

    public init(added: [DateInterval], anchor: Data?) {
        self.added = added
        self.anchor = anchor
    }
}
