import Foundation

/// The richer reads pipelines use, beside `HealthStore`, which stays as it is
/// for the native push. Everything large comes in pages so a long export
/// never holds more than a page of samples at once.
public protocol HealthQuerying: Sendable {
    /// Ask to read these types, plus routes, heartbeats, state of mind and
    /// medications when `extras` says so.
    func requestAuthorization(types: [HealthType], extras: ReadExtras) async throws

    /// Statistics per bucket. Only buckets with data are returned.
    func buckets(_ query: BucketQuery) async throws -> [StatBucket]

    /// Quantity samples overlapping the range, oldest first, in the unit.
    func quantityPage(_ type: String, unit: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedQuantity>

    /// Category samples overlapping the range, oldest first.
    func categoryPage(_ type: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedCategory>

    /// The apps and devices that wrote a type.
    func sources(of type: HealthType) async throws -> [String]

    /// Workouts overlapping the range, oldest first, without route or series.
    func workoutPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<WorkoutDetail>

    /// Part of a workout's route, oldest first. A nil cursor starts over;
    /// a nil `next` means the route is finished.
    func routePage(workoutID: String, after cursor: Int?, limit: Int) async throws -> (points: [RoutePoint], next: Int?)

    /// ECG recordings that start in the range, without voltages.
    func ecgPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<ECGDetail>

    /// One recording's voltages in microvolts, in order.
    func voltages(ecgID: String) async throws -> [Double]

    /// Each beat's timing from heartbeat series overlapping the range.
    func heartbeats(in range: DateInterval) async throws -> [HeartbeatSeries]

    func statesOfMind(in range: DateInterval) async throws -> [StateOfMindRecord]

    func medicationDoses(in range: DateInterval) async throws -> [MedicationDose]

    /// What was added since `anchor` (nil: since `since`).
    func additions(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes
}

/// Reads beyond plain sample types.
public struct ReadExtras: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let routes = ReadExtras(rawValue: 1)
    public static let heartbeats = ReadExtras(rawValue: 2)
    public static let stateOfMind = ReadExtras(rawValue: 4)
    public static let medications = ReadExtras(rawValue: 8)
}

public struct BucketQuery: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// `sum`: the type must be cumulative.
        case sum
        /// `avg`, `min` and `max`: the type must be discrete.
        case range
    }

    public var type: String
    public var unit: String
    public var style: Style
    public var plan: BucketPlan

    public init(type: String, unit: String, style: Style, plan: BucketPlan) {
        self.type = type
        self.unit = unit
        self.style = style
        self.plan = plan
    }
}

/// One bucket's values, combined as Health combines them, and per source.
public struct StatBucket: Sendable, Equatable {
    public struct SourceValue: Sendable, Equatable {
        public var source: String
        public var sum: Double?
        public var avg: Double?
        public var min: Double?
        public var max: Double?

        public init(source: String, sum: Double? = nil, avg: Double? = nil, min: Double? = nil, max: Double? = nil) {
            self.source = source
            self.sum = sum
            self.avg = avg
            self.min = min
            self.max = max
        }
    }

    public var start: Date
    public var end: Date
    public var merged: SourceValue
    /// Sorted by source name.
    public var sources: [SourceValue]

    public init(start: Date, end: Date, merged: SourceValue, sources: [SourceValue]) {
        self.start = start
        self.end = end
        self.merged = merged
        self.sources = sources
    }
}

/// Where the next page starts. Several samples can share a start time, so the
/// ones already read at that time are named.
public struct PageCursor: Sendable, Equatable {
    public var start: Date
    public var ids: Set<String>

    public init(start: Date, ids: Set<String>) {
        self.start = start
        self.ids = ids
    }
}

/// A page of samples and where to carry on; a nil `next` is the last page.
public struct SamplePage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var next: PageCursor?

    public init(items: [Item], next: PageCursor?) {
        self.items = items
        self.next = next
    }
}

public struct DetailedQuantity: Sendable, Equatable {
    public var id: String
    public var source: String
    public var start: Date
    public var end: Date
    /// The sample's value; for a series, its mean.
    public var value: Double
    /// Set for a discrete series of several readings.
    public var min: Double?
    public var max: Double?
    /// Heart rate's context: Sedentary, Active or Not Set.
    public var context: String?
    public var userEntered: Bool

    public init(id: String = UUID().uuidString, source: String, start: Date, end: Date, value: Double, min: Double? = nil, max: Double? = nil, context: String? = nil, userEntered: Bool = false) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.value = value
        self.min = min
        self.max = max
        self.context = context
        self.userEntered = userEntered
    }
}

public struct DetailedCategory: Sendable, Equatable {
    public var id: String
    public var source: String
    public var start: Date
    public var end: Date
    public var value: Int
    public var userEntered: Bool
    public var cycleStart: Bool

    public init(id: String = UUID().uuidString, source: String, start: Date, end: Date, value: Int, userEntered: Bool = false, cycleStart: Bool = false) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.value = value
        self.userEntered = userEntered
        self.cycleStart = cycleStart
    }
}

public struct HeartbeatSeries: Sendable, Equatable {
    public struct Beat: Sendable, Equatable {
        /// Seconds since the series began.
        public var timeSinceStart: Double
        public var precededByGap: Bool

        public init(timeSinceStart: Double, precededByGap: Bool) {
            self.timeSinceStart = timeSinceStart
            self.precededByGap = precededByGap
        }
    }

    public var start: Date
    public var end: Date
    public var beats: [Beat]

    public init(start: Date, end: Date, beats: [Beat]) {
        self.start = start
        self.end = end
        self.beats = beats
    }
}

public struct RoutePoint: Sendable, Equatable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    /// Metres.
    public var altitude: Double
    /// Degrees, with -1 when unknown.
    public var course: Double
    public var courseAccuracy: Double?
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    /// Metres per second, with -1 when unknown.
    public var speed: Double
    public var speedAccuracy: Double?

    public init(timestamp: Date, latitude: Double, longitude: Double, altitude: Double = 0, course: Double = -1, courseAccuracy: Double? = nil, horizontalAccuracy: Double = 0, verticalAccuracy: Double = 0, speed: Double = -1, speedAccuracy: Double? = nil) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
    }
}

/// A workout's statistics by the names in `MetricCatalog.workoutStatistics`.
public struct WorkoutStatistic: Sendable, Equatable {
    public var unit: String
    public var sum: Double?
    public var avg: Double?
    public var min: Double?
    public var max: Double?

    public init(unit: String, sum: Double? = nil, avg: Double? = nil, min: Double? = nil, max: Double? = nil) {
        self.unit = unit
        self.sum = sum
        self.avg = avg
        self.min = min
        self.max = max
    }
}

public struct WorkoutDetail: Sendable, Equatable {
    /// A part of a workout: one sport of a multisport, or the whole of a simple one.
    public struct Activity: Sendable, Equatable {
        public var id: String
        public var activityType: String
        public var activityTypeCode: Int
        public var isIndoor: Bool?
        public var swimmingLocation: String?
        public var start: Date
        public var end: Date
        public var duration: Double
        public var statistics: [String: WorkoutStatistic]

        public init(id: String, activityType: String, activityTypeCode: Int, isIndoor: Bool? = nil, swimmingLocation: String? = nil, start: Date, end: Date, duration: Double, statistics: [String: WorkoutStatistic] = [:]) {
            self.id = id
            self.activityType = activityType
            self.activityTypeCode = activityTypeCode
            self.isIndoor = isIndoor
            self.swimmingLocation = swimmingLocation
            self.start = start
            self.end = end
            self.duration = duration
            self.statistics = statistics
        }
    }

    public struct Event: Sendable, Equatable {
        public var type: String
        public var typeCode: Int
        public var start: Date
        public var end: Date
        public var metadata: [String: String]

        public init(type: String, typeCode: Int, start: Date, end: Date, metadata: [String: String] = [:]) {
            self.type = type
            self.typeCode = typeCode
            self.start = start
            self.end = end
            self.metadata = metadata
        }
    }

    public var id: String
    /// "Running", as HealthKit's activity type reads.
    public var activityType: String
    public var activityTypeCode: Int
    /// "Outdoor Run", what the Fitness app shows.
    public var name: String
    public var source: String
    public var sourceIdentifier: String
    public var start: Date
    public var end: Date
    public var duration: Double
    public var isIndoor: Bool?
    public var statistics: [String: WorkoutStatistic]
    public var activities: [Activity]
    public var events: [Event]
    public var metadata: [String: String]
    /// Celsius, per cent, metres and metres per second when recorded.
    public var temperature: Double?
    public var humidity: Double?
    public var elevationAscended: Double?
    public var averageSpeed: Double?
    public var maximumSpeed: Double?
    public var hasRoute: Bool

    public init(id: String = UUID().uuidString, activityType: String, activityTypeCode: Int = 0, name: String, source: String, sourceIdentifier: String = "", start: Date, end: Date, duration: Double, isIndoor: Bool? = nil, statistics: [String: WorkoutStatistic] = [:], activities: [Activity] = [], events: [Event] = [], metadata: [String: String] = [:], temperature: Double? = nil, humidity: Double? = nil, elevationAscended: Double? = nil, averageSpeed: Double? = nil, maximumSpeed: Double? = nil, hasRoute: Bool = false) {
        self.id = id
        self.activityType = activityType
        self.activityTypeCode = activityTypeCode
        self.name = name
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.start = start
        self.end = end
        self.duration = duration
        self.isIndoor = isIndoor
        self.statistics = statistics
        self.activities = activities
        self.events = events
        self.metadata = metadata
        self.temperature = temperature
        self.humidity = humidity
        self.elevationAscended = elevationAscended
        self.averageSpeed = averageSpeed
        self.maximumSpeed = maximumSpeed
        self.hasRoute = hasRoute
    }
}

public struct ECGDetail: Sendable, Equatable {
    public var id: String
    public var source: String
    public var start: Date
    public var end: Date
    public var classification: String
    public var samplingFrequency: Double
    public var averageHeartRate: Double?
    public var numberOfVoltageMeasurements: Int

    public init(id: String = UUID().uuidString, source: String, start: Date, end: Date, classification: String, samplingFrequency: Double, averageHeartRate: Double?, numberOfVoltageMeasurements: Int) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.classification = classification
        self.samplingFrequency = samplingFrequency
        self.averageHeartRate = averageHeartRate
        self.numberOfVoltageMeasurements = numberOfVoltageMeasurements
    }
}

public struct StateOfMindRecord: Sendable, Equatable {
    public var id: String
    public var source: String
    public var start: Date
    public var end: Date
    /// "Momentary Emotion" or "Daily Mood".
    public var kind: String
    /// -1 to 1.
    public var valence: Double
    public var valenceClassification: String
    public var labels: [String]
    public var associations: [String]

    public init(id: String = UUID().uuidString, source: String, start: Date, end: Date, kind: String, valence: Double, valenceClassification: String, labels: [String], associations: [String]) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.kind = kind
        self.valence = valence
        self.valenceClassification = valenceClassification
        self.labels = labels
        self.associations = associations
    }
}

public struct MedicationDose: Sendable, Equatable {
    public var id: String
    public var name: String
    public var nickname: String?
    public var source: String
    public var start: Date
    public var end: Date
    public var scheduledDate: Date?
    public var status: String
    public var quantity: Double?
    public var scheduledQuantity: Double?
    public var unit: String

    public init(id: String = UUID().uuidString, name: String, nickname: String? = nil, source: String, start: Date, end: Date, scheduledDate: Date? = nil, status: String, quantity: Double? = nil, scheduledQuantity: Double? = nil, unit: String) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.source = source
        self.start = start
        self.end = end
        self.scheduledDate = scheduledDate
        self.status = status
        self.quantity = quantity
        self.scheduledQuantity = scheduledQuantity
        self.unit = unit
    }
}
