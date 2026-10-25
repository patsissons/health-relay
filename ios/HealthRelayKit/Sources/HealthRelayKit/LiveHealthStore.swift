#if os(iOS)
import CoreLocation
import Foundation
import HealthKit

/// The HealthStore over HealthKit. Every catalog identifier is resolved at
/// run time, so a type the running iOS does not have is skipped, and every
/// unit is checked against its type before a value is read (HealthKit raises
/// on an incompatible unit).
public final class LiveHealthStore: HealthStore, @unchecked Sendable {
    public let healthStore: HKHealthStore
    /// Anchored queries are paged so a first read of a busy type stays small.
    static let pageSize = 2000

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Types and units

    public static func sampleType(_ type: HealthType) -> HKSampleType? {
        switch type.kind {
        case .quantity: HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: type.id))
        case .category: HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: type.id))
        case .workout: HKObjectType.workoutType()
        case .ecg: HKObjectType.electrocardiogramType()
        }
    }

    static func quantityType(_ id: String) -> HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id))
    }

    /// The HKUnit for a catalog unit string; nil when this iOS lacks it.
    public static func unit(_ text: String) -> HKUnit? {
        if text == "appleEffortScore" {
            if #available(iOS 18.0, *) { return .appleEffortScore() }
            return nil
        }
        return HKUnit(from: text)
    }

    /// A quantity type with a unit it can be read in.
    static func resolve(_ id: String, unit text: String) -> (HKQuantityType, HKUnit)? {
        guard let type = quantityType(id), let unit = unit(text), type.is(compatibleWith: unit) else { return nil }
        return (type, unit)
    }

    /// Everything the app asks to read.
    public static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(Catalog.allTypes.compactMap(sampleType))
        types.insert(HKSeriesType.workoutRoute())
        types.insert(HKObjectType.activitySummaryType())
        return types
    }

    public func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    // MARK: Reading

    public func statistics(_ type: StatType, days: [Day], calendar: Calendar) async throws -> [Day: [SourceStatistic]] {
        guard let (qt, unit) = Self.resolve(type.id, unit: type.healthKitUnit), let first = days.first, let last = days.last else { return [:] }
        let start = first.start(in: calendar)
        let end = last.adding(1).start(in: calendar)
        let wantsSum = type.mode == .sum
        // HealthKit raises when a sum is asked of a discrete type or a most
        // recent value of a cumulative one; those few come from the samples.
        guard (qt.aggregationStyle == .cumulative) == wantsSum else {
            return try await statisticsFromSamples(type, qt: qt, unit: unit, days: days, calendar: calendar)
        }
        let predicate = HKSamplePredicate.quantitySample(type: qt, predicate: HKQuery.predicateForSamples(withStart: start, end: end))
        let options: HKStatisticsOptions = wantsSum ? [.cumulativeSum, .separateBySource] : [.mostRecent, .separateBySource]
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: predicate, options: options, anchorDate: start, intervalComponents: DateComponents(day: 1))
        let collection = try await descriptor.result(for: healthStore)
        var out: [Day: [SourceStatistic]] = [:]
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            let day = Day(stats.startDate, calendar: calendar)
            for source in stats.sources ?? [] {
                var s = SourceStatistic(source: source.name)
                if wantsSum {
                    s.sum = stats.sumQuantity(for: source)?.doubleValue(for: unit)
                } else {
                    s.latest = stats.mostRecentQuantity(for: source)?.doubleValue(for: unit)
                    s.latestAt = stats.mostRecentQuantityDateInterval(for: source)?.start
                }
                out[day, default: []].append(s)
            }
        }
        return out
    }

    private func statisticsFromSamples(_ type: StatType, qt: HKQuantityType, unit: HKUnit, days: [Day], calendar: Calendar) async throws -> [Day: [SourceStatistic]] {
        let span = DateInterval(start: days.first!.start(in: calendar), end: days.last!.adding(1).start(in: calendar))
        let samples = try await quantitySamples(type.id, unit: type.healthKitUnit, in: span)
        var out: [Day: [String: SourceStatistic]] = [:]
        for s in samples {
            let day = Day(s.start, calendar: calendar)
            guard days.contains(day) else { continue }
            var stat = out[day]?[s.source] ?? SourceStatistic(source: s.source)
            if type.mode == .sum {
                stat.sum = (stat.sum ?? 0) + s.value
            } else if stat.latestAt.map({ s.start >= $0 }) ?? true {
                stat.latest = s.value
                stat.latestAt = s.start
            }
            out[day, default: [:]][s.source] = stat
        }
        return out.mapValues { Array($0.values) }
    }

    private func overlapping(_ interval: DateInterval) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
    }

    public func quantitySamples(_ type: String, unit text: String, in interval: DateInterval) async throws -> [QuantitySample] {
        guard let (qt, unit) = Self.resolve(type, unit: text) else { return [] }
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: qt, predicate: overlapping(interval))], sortDescriptors: [SortDescriptor(\.startDate)])
        return try await descriptor.result(for: healthStore).map {
            QuantitySample(id: $0.uuid.uuidString, source: $0.sourceRevision.source.name, start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
    }

    public func categorySamples(_ type: String, in interval: DateInterval) async throws -> [CategorySample] {
        guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: type)) else { return [] }
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: ct, predicate: overlapping(interval))], sortDescriptors: [SortDescriptor(\.startDate)])
        return try await descriptor.result(for: healthStore).map {
            CategorySample(id: $0.uuid.uuidString, source: $0.sourceRevision.source.name, start: $0.startDate, end: $0.endDate, value: $0.value)
        }
    }

    public func workouts(in interval: DateInterval) async throws -> [WorkoutRecord] {
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(overlapping(interval))], sortDescriptors: [SortDescriptor(\.startDate)])
        var out: [WorkoutRecord] = []
        for w in try await descriptor.result(for: healthStore) {
            var stats: [WorkoutRecord.Statistic] = []
            if let (t, u) = Self.resolve(HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, unit: "kcal"), let sum = w.statistics(for: t)?.sumQuantity() {
                stats.append(.init(type: t.identifier, unit: "kcal", sum: sum.doubleValue(for: u)))
            }
            for id in Catalog.workoutDistances {
                if let (t, u) = Self.resolve(id, unit: "km"), let sum = w.statistics(for: t)?.sumQuantity() {
                    stats.append(.init(type: id, unit: "km", sum: sum.doubleValue(for: u)))
                }
            }
            if let (t, u) = Self.resolve(HKQuantityTypeIdentifier.heartRate.rawValue, unit: "count/min"), let hr = w.statistics(for: t) {
                let avg = hr.averageQuantity()?.doubleValue(for: u)
                let max = hr.maximumQuantity()?.doubleValue(for: u)
                if avg != nil || max != nil {
                    stats.append(.init(type: t.identifier, unit: "count/min", average: avg, maximum: max))
                }
            }
            out.append(WorkoutRecord(id: w.uuid.uuidString, activityType: Self.activityName(w.workoutActivityType),
                                     source: w.sourceRevision.source.name, start: w.startDate, end: w.endDate,
                                     duration: w.duration, statistics: stats, route: try await route(of: w)))
        }
        return out
    }

    private func route(of workout: HKWorkout) async throws -> [WorkoutRecord.Point]? {
        let routes = try await HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
                                                       sortDescriptors: [SortDescriptor(\.startDate)]).result(for: healthStore)
        guard !routes.isEmpty else { return nil }
        var points: [WorkoutRecord.Point] = []
        for r in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(r).results(for: healthStore) {
                points.append(.init(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                                    ele: location.verticalAccuracy >= 0 ? location.altitude : nil))
            }
        }
        return points
    }

    public func electrocardiograms(in interval: DateInterval) async throws -> [ECGRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.electrocardiogram(predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        let microvolts = HKUnit.voltUnit(with: .micro)
        var out: [ECGRecord] = []
        for e in try await descriptor.result(for: healthStore) {
            var voltages: [Double] = []
            voltages.reserveCapacity(e.numberOfVoltageMeasurements)
            for try await m in HKElectrocardiogramQueryDescriptor(e).results(for: healthStore) {
                voltages.append(m.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(for: microvolts) ?? 0)
            }
            out.append(ECGRecord(id: e.uuid.uuidString, start: e.startDate, classification: Self.classificationName(e.classification),
                                 rate: e.samplingFrequency?.doubleValue(for: .hertz()) ?? 512,
                                 averageHeartRate: e.averageHeartRate?.doubleValue(for: .count().unitDivided(by: .minute())),
                                 voltages: voltages))
        }
        return out
    }

    public func activitySummaries(days: [Day], calendar: Calendar) async throws -> [ActivitySummaryRecord] {
        guard let first = days.first, let last = days.last else { return [] }
        func components(_ d: Day) -> DateComponents {
            var c = calendar.dateComponents([.era, .year, .month, .day], from: d.start(in: calendar))
            c.calendar = calendar
            return c
        }
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: components(first), end: components(last))
        return try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: healthStore).compactMap { s in
            let c = s.dateComponents(for: calendar)
            guard let y = c.year, let m = c.month, let d = c.day else { return nil }
            return ActivitySummaryRecord(day: Day(year: y, month: m, day: d),
                                         standHours: s.appleStandHours.doubleValue(for: .count()),
                                         moveGoal: s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()))
        }
    }

    // MARK: Changes

    public func changes(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes {
        guard let st = Self.sampleType(type) else { return Changes(added: [], anchor: anchor) }
        var hkAnchor = anchor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        var added: [DateInterval] = []
        while true {
            let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.sample(type: st, predicate: predicate)], anchor: hkAnchor, limit: Self.pageSize)
            let result = try await descriptor.result(for: healthStore)
            added += result.addedSamples.map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
            hkAnchor = result.newAnchor
            if result.addedSamples.count + result.deletedObjects.count < Self.pageSize { break }
        }
        let data = try hkAnchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return Changes(added: added, anchor: data)
    }

    public func newestSample(_ type: HealthType, since: Date) async throws -> Date? {
        guard let st = Self.sampleType(type) else { return nil }
        let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: st, predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
                                                 sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
        return try await descriptor.result(for: healthStore).first?.startDate
    }

    // MARK: Waking

    /// Registers an observer query and background delivery per type. Each
    /// wake runs `wake` and then tells HealthKit it was handled.
    public func observe(_ wake: @escaping @Sendable () async -> Void) {
        for type in Catalog.allTypes {
            guard let st = Self.sampleType(type) else { continue }
            let query = HKObserverQuery(sampleType: st, predicate: nil) { _, completion, error in
                let done = Completion(completion)
                guard error == nil else { return done.call() }
                Task {
                    await wake()
                    done.call()
                }
            }
            healthStore.execute(query)
            let frequency: HKUpdateFrequency = Catalog.frequency(of: type) == .daily ? .daily : .hourly
            healthStore.enableBackgroundDelivery(for: st, frequency: frequency) { _, _ in }
        }
    }

    private struct Completion: @unchecked Sendable {
        let body: HKObserverQueryCompletionHandler
        init(_ body: @escaping HKObserverQueryCompletionHandler) { self.body = body }
        func call() { body() }
    }

    // MARK: Names

    static func classificationName(_ c: HKElectrocardiogram.Classification) -> String {
        switch c {
        case .notSet: "Not Set"
        case .sinusRhythm: "Sinus Rhythm"
        case .atrialFibrillation: "Atrial Fibrillation"
        case .inconclusiveLowHeartRate: "Heart Rate Under 50"
        case .inconclusiveHighHeartRate: "Heart Rate Over 120"
        case .inconclusivePoorReading: "Poor Recording"
        case .inconclusiveOther: "Inconclusive"
        case .unrecognized: "Unrecognized"
        @unknown default: "Unrecognized"
        }
    }

    /// `HKWorkoutActivityTypeRunning`, as export.xml writes it.
    static func activityName(_ t: HKWorkoutActivityType) -> String {
        let name: String = switch t {
        case .americanFootball: "AmericanFootball"
        case .archery: "Archery"
        case .australianFootball: "AustralianFootball"
        case .badminton: "Badminton"
        case .baseball: "Baseball"
        case .basketball: "Basketball"
        case .bowling: "Bowling"
        case .boxing: "Boxing"
        case .climbing: "Climbing"
        case .cricket: "Cricket"
        case .crossTraining: "CrossTraining"
        case .curling: "Curling"
        case .cycling: "Cycling"
        case .dance: "Dance"
        case .danceInspiredTraining: "DanceInspiredTraining"
        case .elliptical: "Elliptical"
        case .equestrianSports: "EquestrianSports"
        case .fencing: "Fencing"
        case .fishing: "Fishing"
        case .functionalStrengthTraining: "FunctionalStrengthTraining"
        case .golf: "Golf"
        case .gymnastics: "Gymnastics"
        case .handball: "Handball"
        case .hiking: "Hiking"
        case .hockey: "Hockey"
        case .hunting: "Hunting"
        case .lacrosse: "Lacrosse"
        case .martialArts: "MartialArts"
        case .mindAndBody: "MindAndBody"
        case .mixedMetabolicCardioTraining: "MixedMetabolicCardioTraining"
        case .paddleSports: "PaddleSports"
        case .play: "Play"
        case .preparationAndRecovery: "PreparationAndRecovery"
        case .racquetball: "Racquetball"
        case .rowing: "Rowing"
        case .rugby: "Rugby"
        case .running: "Running"
        case .sailing: "Sailing"
        case .skatingSports: "SkatingSports"
        case .snowSports: "SnowSports"
        case .soccer: "Soccer"
        case .softball: "Softball"
        case .squash: "Squash"
        case .stairClimbing: "StairClimbing"
        case .surfingSports: "SurfingSports"
        case .swimming: "Swimming"
        case .tableTennis: "TableTennis"
        case .tennis: "Tennis"
        case .trackAndField: "TrackAndField"
        case .traditionalStrengthTraining: "TraditionalStrengthTraining"
        case .volleyball: "Volleyball"
        case .walking: "Walking"
        case .waterFitness: "WaterFitness"
        case .waterPolo: "WaterPolo"
        case .waterSports: "WaterSports"
        case .wrestling: "Wrestling"
        case .yoga: "Yoga"
        case .barre: "Barre"
        case .coreTraining: "CoreTraining"
        case .crossCountrySkiing: "CrossCountrySkiing"
        case .downhillSkiing: "DownhillSkiing"
        case .flexibility: "Flexibility"
        case .highIntensityIntervalTraining: "HighIntensityIntervalTraining"
        case .jumpRope: "JumpRope"
        case .kickboxing: "Kickboxing"
        case .pilates: "Pilates"
        case .snowboarding: "Snowboarding"
        case .stairs: "Stairs"
        case .stepTraining: "StepTraining"
        case .wheelchairWalkPace: "WheelchairWalkPace"
        case .wheelchairRunPace: "WheelchairRunPace"
        case .taiChi: "TaiChi"
        case .mixedCardio: "MixedCardio"
        case .handCycling: "HandCycling"
        case .discSports: "DiscSports"
        case .fitnessGaming: "FitnessGaming"
        case .cardioDance: "CardioDance"
        case .socialDance: "SocialDance"
        case .pickleball: "Pickleball"
        case .cooldown: "Cooldown"
        case .swimBikeRun: "SwimBikeRun"
        case .transition: "Transition"
        case .underwaterDiving: "UnderwaterDiving"
        case .other: "Other"
        @unknown default: "Other"
        }
        return "HKWorkoutActivityType" + name
    }
}
#endif
