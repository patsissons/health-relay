#if os(iOS)
import CoreLocation
import Foundation
import HealthKit

/// The pipelines' reads over HealthKit. Pages are ordered by start time and
/// carry on from the last start, so a sample added mid-read can't shift them.
extension LiveHealthStore: HealthQuerying {
    // MARK: Authorization

    public static func objectTypes(_ types: [HealthType], extras: ReadExtras) -> Set<HKObjectType> {
        var out = Set<HKObjectType>(types.compactMap { sampleType($0) as HKObjectType? })
        if types.contains(.workout) || extras.contains(.routes) { out.insert(HKSeriesType.workoutRoute()) }
        if extras.contains(.heartbeats) { out.insert(HKSeriesType.heartbeat()) }
        if extras.contains(.stateOfMind), #available(iOS 18.0, *) { out.insert(HKObjectType.stateOfMindType()) }
        // Not medications: their doses come with the per-medication sharing
        // below, and HealthKit raises if they're asked for here.
        return out
    }

    public func requestAuthorization(types: [HealthType], extras: ReadExtras) async throws {
        try await healthStore.requestAuthorization(toShare: [], read: Self.objectTypes(types, extras: extras))
        if extras.contains(.medications), #available(iOS 26.0, *) {
            // Medications are shared one by one, on a sheet of their own.
            try await healthStore.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
        }
    }

    // MARK: Buckets

    public func buckets(_ query: BucketQuery) async throws -> [StatBucket] {
        guard let (qt, unit) = Self.resolve(query.type, unit: query.unit) else { return [] }
        let plan = query.plan
        // HealthKit raises when a sum is asked of a discrete type or a mean of
        // a cumulative one. Both happen when a type's style changes across iOS.
        let cumulative = qt.aggregationStyle == .cumulative
        guard cumulative == (query.style == .sum) else { return [] }
        let options: HKStatisticsOptions = cumulative ? [.cumulativeSum, .separateBySource] : [.discreteAverage, .discreteMin, .discreteMax, .separateBySource]
        let predicate = HKSamplePredicate.quantitySample(type: qt, predicate: HKQuery.predicateForSamples(withStart: plan.span.start, end: plan.span.end))
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: predicate, options: options, anchorDate: plan.anchor, intervalComponents: Self.components(plan.step))
        let collection = try await descriptor.result(for: healthStore)
        var out: [StatBucket] = []
        for stats in collection.statistics() where stats.startDate >= plan.span.start && stats.startDate < plan.span.end {
            let sources = (stats.sources ?? []).map { source -> StatBucket.SourceValue in
                if cumulative {
                    return .init(source: source.name, sum: stats.sumQuantity(for: source)?.doubleValue(for: unit))
                }
                return .init(source: source.name, avg: stats.averageQuantity(for: source)?.doubleValue(for: unit),
                             min: stats.minimumQuantity(for: source)?.doubleValue(for: unit),
                             max: stats.maximumQuantity(for: source)?.doubleValue(for: unit))
            }.sorted { $0.source < $1.source }
            let merged: StatBucket.SourceValue = cumulative
                ? .init(source: "", sum: stats.sumQuantity()?.doubleValue(for: unit))
                : .init(source: "", avg: stats.averageQuantity()?.doubleValue(for: unit), min: stats.minimumQuantity()?.doubleValue(for: unit), max: stats.maximumQuantity()?.doubleValue(for: unit))
            guard merged.sum != nil || merged.avg != nil else { continue }
            out.append(StatBucket(start: stats.startDate, end: stats.endDate, merged: merged, sources: sources))
        }
        return out
    }

    static func components(_ step: BucketStep) -> DateComponents {
        switch step {
        case .seconds(let n): DateComponents(second: n)
        case .days(let n): DateComponents(day: n)
        case .months(let n): DateComponents(month: n)
        case .years(let n): DateComponents(year: n)
        }
    }

    // MARK: Pages

    /// Overlapping the range, and at or after the cursor.
    private func pagePredicate(_ range: DateInterval, _ cursor: PageCursor?) -> NSPredicate {
        let overlap = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        guard let cursor else { return overlap }
        let after = NSPredicate(format: "%K >= %@", HKPredicateKeyPathStartDate, cursor.start as NSDate)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [overlap, after])
    }

    /// Reads one page past what's at the cursor already, keeping order and
    /// never repeating a sample that shares the cursor's start time.
    private func page<S: HKSample, Item: Sendable>(_ descriptor: (NSPredicate, Int) -> HKSampleQueryDescriptor<S>, _ range: DateInterval, _ cursor: PageCursor?, _ limit: Int, map: (S) -> Item) async throws -> SamplePage<Item> {
        let seen = cursor?.ids ?? []
        // Asking for what was already seen as well means a page always moves
        // forward, however many samples share a start time.
        let samples = try await descriptor(pagePredicate(range, cursor), limit + seen.count).result(for: healthStore)
        let fresh = samples.filter { !seen.contains($0.uuid.uuidString) }
        guard samples.count == limit + seen.count, let last = fresh.last else {
            return SamplePage(items: fresh.map(map), next: nil)
        }
        let atLast = samples.filter { $0.startDate == last.startDate }.map(\.uuid.uuidString)
        return SamplePage(items: fresh.map(map), next: PageCursor(start: last.startDate, ids: Set(atLast)))
    }

    public func quantityPage(_ type: String, unit text: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedQuantity> {
        guard let (qt, unit) = Self.resolve(type, unit: text) else { return SamplePage(items: [], next: nil) }
        return try await page({ predicate, limit in
            HKSampleQueryDescriptor(predicates: [.quantitySample(type: qt, predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
        }, range, cursor, limit) { s in
            let discrete = s as? HKDiscreteQuantitySample
            let series = (discrete?.count ?? 1) > 1
            return DetailedQuantity(id: s.uuid.uuidString, source: s.sourceRevision.source.name, start: s.startDate, end: s.endDate,
                                    value: s.quantity.doubleValue(for: unit),
                                    min: series ? discrete?.minimumQuantity.doubleValue(for: unit) : nil,
                                    max: series ? discrete?.maximumQuantity.doubleValue(for: unit) : nil,
                                    context: Self.motionContext(s), userEntered: s.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false)
        }
    }

    private static func motionContext(_ s: HKSample) -> String? {
        guard let raw = s.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber, let context = HKHeartRateMotionContext(rawValue: raw.intValue) else { return nil }
        switch context {
        case .notSet: return "Not Set"
        case .sedentary: return "Sedentary"
        case .active: return "Active"
        @unknown default: return nil
        }
    }

    public func categoryPage(_ type: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedCategory> {
        guard let ct = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: type)) else { return SamplePage(items: [], next: nil) }
        return try await page({ predicate, limit in
            HKSampleQueryDescriptor(predicates: [.categorySample(type: ct, predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
        }, range, cursor, limit) { s in
            DetailedCategory(id: s.uuid.uuidString, source: s.sourceRevision.source.name, start: s.startDate, end: s.endDate, value: s.value,
                             userEntered: s.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false,
                             cycleStart: s.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool ?? false)
        }
    }

    public func sources(of type: HealthType) async throws -> [String] {
        guard let st = Self.sampleType(type) else { return [] }
        let descriptor = HKSourceQueryDescriptor(predicate: HKSamplePredicate.sample(type: st))
        return try await descriptor.result(for: healthStore).map(\.name).sorted()
    }

    public func additions(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes {
        try await changes(type, anchor: anchor, since: since)
    }

    // MARK: Workouts

    public func workoutPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<WorkoutDetail> {
        let seen = cursor?.ids ?? []
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(pagePredicate(range, cursor))], sortDescriptors: [SortDescriptor(\.startDate)], limit: limit + seen.count)
        let samples = try await descriptor.result(for: healthStore)
        let fresh = samples.filter { !seen.contains($0.uuid.uuidString) }
        var items: [WorkoutDetail] = []
        for w in fresh { items.append(await detail(w)) }
        guard samples.count == limit + seen.count, let last = fresh.last else { return SamplePage(items: items, next: nil) }
        return SamplePage(items: items, next: PageCursor(start: last.startDate, ids: Set(samples.filter { $0.startDate == last.startDate }.map(\.uuid.uuidString))))
    }

    private func detail(_ w: HKWorkout) async -> WorkoutDetail {
        let metadata = w.metadata ?? [:]
        let hasRoute = ((try? await HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: w))], sortDescriptors: [], limit: 1).result(for: healthStore))?.isEmpty == false)
        let indoor = metadata[HKMetadataKeyIndoorWorkout] as? Bool
        let bare = String(Self.activityName(w.workoutActivityType).dropFirst("HKWorkoutActivityType".count))
        return WorkoutDetail(id: w.uuid.uuidString, activityType: bare, activityTypeCode: Int(w.workoutActivityType.rawValue),
                             name: Self.workoutTitle(bare, indoor: indoor), source: w.sourceRevision.source.name, sourceIdentifier: w.sourceRevision.source.bundleIdentifier,
                             start: w.startDate, end: w.endDate, duration: w.duration, isIndoor: indoor,
                             statistics: Self.statistics(w.allStatistics),
                             activities: w.workoutActivities.map { a in
                                 let name = String(Self.activityName(a.workoutConfiguration.activityType).dropFirst("HKWorkoutActivityType".count))
                                 return WorkoutDetail.Activity(id: a.uuid.uuidString, activityType: name, activityTypeCode: Int(a.workoutConfiguration.activityType.rawValue),
                                                               isIndoor: a.workoutConfiguration.locationType == .unknown ? nil : a.workoutConfiguration.locationType == .indoor,
                                                               swimmingLocation: Self.swimmingLocation(a.workoutConfiguration.swimmingLocationType),
                                                               start: a.startDate, end: a.endDate ?? a.startDate, duration: a.duration, statistics: Self.statistics(a.allStatistics))
                             },
                             events: (w.workoutEvents ?? []).map { e in
                                 WorkoutDetail.Event(type: Self.eventName(e.type), typeCode: e.type.rawValue, start: e.dateInterval.start, end: e.dateInterval.end, metadata: Self.plainMetadata(e.metadata ?? [:]))
                             },
                             metadata: Self.plainMetadata(metadata),
                             temperature: (metadata[HKMetadataKeyWeatherTemperature] as? HKQuantity)?.doubleValue(for: .degreeCelsius()),
                             humidity: (metadata[HKMetadataKeyWeatherHumidity] as? HKQuantity)?.doubleValue(for: .percent()).multipliedBy100(),
                             elevationAscended: (metadata[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
                             averageSpeed: (metadata[HKMetadataKeyAverageSpeed] as? HKQuantity)?.doubleValue(for: .meter().unitDivided(by: .second())),
                             maximumSpeed: (metadata[HKMetadataKeyMaximumSpeed] as? HKQuantity)?.doubleValue(for: .meter().unitDivided(by: .second())),
                             averageMETs: (metadata[HKMetadataKeyAverageMETs] as? HKQuantity)?.doubleValue(for: HKUnit(from: "kcal/(hr*kg)")),
                             estimatedEffort: await effort(of: w),
                             hasRoute: hasRoute)
    }

    /// The effort rating recorded during a workout, if any.
    private func effort(of w: HKWorkout) async -> Double? {
        guard #available(iOS 18.0, *), let (type, unit) = Self.resolve(HKQuantityTypeIdentifier.estimatedWorkoutEffortScore.rawValue, unit: "appleEffortScore") else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate)
        let found = try? await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)], limit: 1).result(for: healthStore)
        return found?.first?.quantity.doubleValue(for: unit)
    }

    private static func statistics(_ all: [HKQuantityType: HKStatistics]) -> [String: WorkoutStatistic] {
        var out: [String: WorkoutStatistic] = [:]
        for entry in MetricCatalog.workoutStatistics {
            guard let (type, unit) = resolve(entry.id, unit: entry.unit), let s = all[type] else { continue }
            out[entry.name] = WorkoutStatistic(unit: entry.unit, sum: s.sumQuantity()?.doubleValue(for: unit), avg: s.averageQuantity()?.doubleValue(for: unit),
                                               min: s.minimumQuantity()?.doubleValue(for: unit), max: s.maximumQuantity()?.doubleValue(for: unit))
        }
        return out
    }

    /// Metadata as text, leaving out what isn't meaningful as text.
    private static func plainMetadata(_ metadata: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in metadata {
            switch value {
            case let v as String: out[key] = v
            case let v as NSNumber: out[key] = v.stringValue
            case let v as HKQuantity: out[key] = v.description
            case let v as Date: out[key] = Stamp.utc(v)
            default: break
            }
        }
        return out
    }

    static func workoutTitle(_ activity: String, indoor: Bool?) -> String {
        // The Fitness app says Walk and Run where HealthKit says Walking and Running.
        let short = ["Walking": "Walk", "Running": "Run", "Hiking": "Hike"]
        var words = ""
        for c in short[activity] ?? activity {
            if c.isUppercase && !words.isEmpty { words += " " }
            words.append(c)
        }
        switch indoor {
        case true?: return "Indoor " + words
        case false?: return "Outdoor " + words
        default: return words
        }
    }

    private static func swimmingLocation(_ type: HKWorkoutSwimmingLocationType) -> String? {
        switch type {
        case .pool: "pool"
        case .openWater: "openWater"
        default: nil
        }
    }

    private static func eventName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: "pause"
        case .resume: "resume"
        case .lap: "lap"
        case .marker: "marker"
        case .motionPaused: "motionPaused"
        case .motionResumed: "motionResumed"
        case .segment: "segment"
        case .pauseOrResumeRequest: "pauseOrResumeRequest"
        @unknown default: "unknown"
        }
    }

    public func routePage(workoutID: String, after cursor: Int?, limit: Int) async throws -> (points: [RoutePoint], next: Int?) {
        guard let uuid = UUID(uuidString: workoutID) else { return ([], nil) }
        let found = try await HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: uuid))], sortDescriptors: [], limit: 1).result(for: healthStore)
        guard let workout = found.first else { return ([], nil) }
        let routes = try await HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))], sortDescriptors: [SortDescriptor(\.startDate)]).result(for: healthStore)
        // HealthKit streams a route from its start, so a page skips what it
        // already returned. Routes are thousands of points, not millions.
        let skip = cursor ?? 0
        var index = 0
        var points: [RoutePoint] = []
        for route in routes {
            for try await l in HKWorkoutRouteQueryDescriptor(route).results(for: healthStore) {
                defer { index += 1 }
                guard index >= skip else { continue }
                if points.count == limit { return (points, skip + limit) }
                points.append(RoutePoint(timestamp: l.timestamp, latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, altitude: l.altitude,
                                         course: l.course, courseAccuracy: l.courseAccuracy >= 0 ? l.courseAccuracy : nil,
                                         horizontalAccuracy: l.horizontalAccuracy, verticalAccuracy: l.verticalAccuracy,
                                         speed: l.speed, speedAccuracy: l.speedAccuracy >= 0 ? l.speedAccuracy : nil))
            }
        }
        return (points, nil)
    }

    // MARK: ECG

    public func ecgPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<ECGDetail> {
        try await page({ predicate, limit in
            HKSampleQueryDescriptor(predicates: [.electrocardiogram(predicate)], sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
        }, range, cursor, limit) { e in
            ECGDetail(id: e.uuid.uuidString, source: e.sourceRevision.source.name, start: e.startDate, end: e.endDate,
                      classification: Self.classificationName(e.classification), samplingFrequency: e.samplingFrequency?.doubleValue(for: .hertz()) ?? 512,
                      averageHeartRate: e.averageHeartRate?.doubleValue(for: .count().unitDivided(by: .minute())), numberOfVoltageMeasurements: e.numberOfVoltageMeasurements)
        }
    }

    public func voltages(ecgID: String) async throws -> [Double] {
        guard let uuid = UUID(uuidString: ecgID) else { return [] }
        let found = try await HKSampleQueryDescriptor(predicates: [.electrocardiogram(HKQuery.predicateForObject(with: uuid))], sortDescriptors: [], limit: 1).result(for: healthStore)
        guard let e = found.first else { return [] }
        let microvolts = HKUnit.voltUnit(with: .micro)
        var out: [Double] = []
        out.reserveCapacity(e.numberOfVoltageMeasurements)
        for try await m in HKElectrocardiogramQueryDescriptor(e).results(for: healthStore) {
            out.append(m.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(for: microvolts) ?? 0)
        }
        return out
    }

    // MARK: Heartbeats

    public func heartbeats(in range: DateInterval) async throws -> [HeartbeatSeries] {
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        let samples = try await HKSampleQueryDescriptor(predicates: [.heartbeatSeries(predicate)], sortDescriptors: [SortDescriptor(\.startDate)]).result(for: healthStore)
        var out: [HeartbeatSeries] = []
        for s in samples {
            var beats: [HeartbeatSeries.Beat] = []
            for try await beat in HKHeartbeatSeriesQueryDescriptor(s).results(for: healthStore) {
                beats.append(.init(timeSinceStart: beat.timeIntervalSinceStart, precededByGap: beat.precededByGap))
            }
            out.append(HeartbeatSeries(start: s.startDate, end: s.endDate, beats: beats))
        }
        return out
    }

    // MARK: State of mind and medications

    public func statesOfMind(in range: DateInterval) async throws -> [StateOfMindRecord] {
        guard #available(iOS 18.0, *) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        let samples = try await HKSampleQueryDescriptor(predicates: [.stateOfMind(predicate)], sortDescriptors: [SortDescriptor(\.startDate)]).result(for: healthStore)
        return samples.map { s in
            StateOfMindRecord(id: s.uuid.uuidString, source: s.sourceRevision.source.name, start: s.startDate, end: s.endDate,
                              kind: s.kind == .dailyMood ? "Daily Mood" : "Momentary Emotion", valence: s.valence,
                              valenceClassification: String(describing: s.valenceClassification),
                              labels: s.labels.map { String(describing: $0) }, associations: s.associations.map { String(describing: $0) })
        }
    }

    public func medicationDoses(in range: DateInterval) async throws -> [MedicationDose] {
        guard #available(iOS 26.0, *) else { return [] }
        let medications = try await HKUserAnnotatedMedicationQueryDescriptor().result(for: healthStore)
        let names = Dictionary(medications.map { ($0.medication.identifier, ($0.medication.displayText, $0.nickname)) }) { first, _ in first }
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        let doses = try await HKSampleQueryDescriptor(predicates: [.sample(type: HKObjectType.medicationDoseEventType(), predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)]).result(for: healthStore)
        return doses.compactMap { sample -> MedicationDose? in
            guard let e = sample as? HKMedicationDoseEvent else { return nil }
            let name = names[e.medicationConceptIdentifier]
            return MedicationDose(id: e.uuid.uuidString, name: name?.0 ?? "Medication", nickname: name?.1, source: e.sourceRevision.source.name,
                                  start: e.startDate, end: e.endDate, scheduledDate: e.scheduledDate, status: Self.doseStatus(e.logStatus),
                                  quantity: e.doseQuantity, scheduledQuantity: e.scheduledDoseQuantity, unit: e.unit.unitString)
        }
    }

    @available(iOS 26.0, *)
    private static func doseStatus(_ s: HKMedicationDoseEvent.LogStatus) -> String {
        switch s {
        case .notInteracted: "Not Interacted"
        case .notificationNotSent: "Notification Not Sent"
        case .snoozed: "Snoozed"
        case .taken: "Taken"
        case .skipped: "Skipped"
        case .notLogged: "Not Logged"
        @unknown default: "Unknown"
        }
    }
}

private extension Double {
    /// HealthKit keeps per cent as a fraction.
    func multipliedBy100() -> Double { self * 100 }
}
#endif
