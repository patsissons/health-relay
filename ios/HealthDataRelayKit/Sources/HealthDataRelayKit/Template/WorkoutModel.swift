import Foundation

/// A workout in full. Whatever takes extra reads from Health (series, route,
/// segments, splits) is a lazy list, read only if a template asks for it.
struct WorkoutObject: TemplateObject {
    let workout: WorkoutDetail
    let extractor: Extractor

    private var units: UnitPreferences { extractor.spec.units }
    private var energyUnit: String { units.byDimension[.energy] ?? "kcal" }
    private var distanceUnit: String { units.byDimension[.distance] ?? "km" }
    private var speedUnit: String { units.byDimension[.speed] ?? "km/hr" }
    private var temperatureUnit: String { units.byDimension[.temperature] ?? "degC" }

    /// `{"qty": 1, "units": "km"}`
    static func quantity(_ qty: Double, _ units: String) -> TemplateValue {
        .object(DictionaryObject(["qty": .number(qty), "units": .string(units)]))
    }

    /// The statistic that says how far it went, whichever kind of distance it was.
    private var distanceStat: (name: String, km: Double)? {
        for name in ["walkingAndRunningDistance", "cyclingDistance", "wheelchairDistance", "rowingDistance", "paddleSportsDistance", "crossCountrySkiingDistance", "downhillSnowSportsDistance", "skatingSportsDistance"] {
            if let sum = workout.statistics[name]?.sum { return (name, sum) }
        }
        if let metres = workout.statistics["swimmingDistance"]?.sum { return ("swimmingDistance", metres / 1000) }
        return nil
    }

    var keys: [String] {
        let w = workout
        var out = ["id", "name", "start", "end", "duration", "source", "metadata", "activities"]
        if w.isIndoor != nil { out += ["isIndoor", "location"] }
        func has(_ stat: String) -> Bool { w.statistics[stat] != nil }
        if has("activeEnergy") { out += ["activeEnergyBurned", "totalEnergy"] }
        if has("heartRate") { out += ["heartRate", "avgHeartRate", "maxHeartRate"] }
        if has("flightsClimbed") { out.append("flightsClimbed") }
        if distanceStat != nil { out += ["distance", "speed"] }
        if has("stepCount") { out.append("stepCadence") }
        if w.averageSpeed != nil { out.append("avgSpeed") }
        if w.maximumSpeed != nil { out.append("maxSpeed") }
        if w.elevationAscended != nil { out.append("elevationUp") }
        if w.temperature != nil { out.append("temperature") }
        if w.humidity != nil { out.append("humidity") }
        if w.averageMETs != nil { out.append("intensity") }
        if w.estimatedEffort != nil { out.append("estimatedEffortScore") }
        if !w.events.isEmpty { out += ["events", "segments"] }
        if distanceStat != nil { out.append("splits") }
        if extractor.spec.workouts.series {
            out += ["heartRateData", "heartRateRecovery", "activeEnergy", "basalEnergy"]
            if has("stepCount") { out.append("stepCount") }
            if has("walkingAndRunningDistance") { out.append("walkingAndRunningDistance") }
            if has("cyclingDistance") { out.append("cyclingDistance") }
        }
        if w.hasRoute && extractor.spec.workouts.routes { out.append("route") }
        return out.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    func value(_ key: String) -> TemplateValue? {
        let w = workout
        switch key {
        case "id": return .string(w.id)
        case "name": return .string(w.name)
        case "activity_type": return .string(w.activityType)
        case "start": return .date(w.start)
        case "end": return .date(w.end)
        case "duration": return .number(w.duration)
        case "isIndoor": return w.isIndoor.map { .bool($0) }
        case "location": return w.isIndoor.map { .string($0 ? "Indoor" : "Outdoor") }
        case "source": return .object(DictionaryObject(["name": .string(w.source), "identifier": .string(w.sourceIdentifier)]))
        case "metadata": return .object(DictionaryObject(w.metadata.mapValues { .string($0) }))
        case "has_route": return .bool(w.hasRoute)
        case "statistics": return .object(DictionaryObject(w.statistics.mapValues(Self.statistic)))
        case "activeEnergyBurned":
            return w.statistics["activeEnergy"]?.sum.map { Self.quantity(WorkoutUnits.energy($0, energyUnit), energyUnit) }
        case "totalEnergy":
            guard let active = w.statistics["activeEnergy"]?.sum else { return nil }
            return Self.quantity(WorkoutUnits.energy(active + (w.statistics["basalEnergy"]?.sum ?? 0), energyUnit), energyUnit)
        case "heartRate":
            guard let hr = w.statistics["heartRate"] else { return nil }
            var fields: [String: TemplateValue] = [:]
            if let v = hr.avg { fields["avg"] = Self.quantity(v, "count/min") }
            if let v = hr.max { fields["max"] = Self.quantity(v, "count/min") }
            if let v = hr.min { fields["min"] = Self.quantity(v, "count/min") }
            return .object(DictionaryObject(fields))
        case "avgHeartRate": return w.statistics["heartRate"]?.avg.map { Self.quantity($0, "count/min") }
        case "maxHeartRate": return w.statistics["heartRate"]?.max.map { Self.quantity($0, "count/min") }
        case "flightsClimbed": return w.statistics["flightsClimbed"]?.sum.map { Self.quantity($0, "count") }
        case "distance": return distanceStat.map { Self.quantity(WorkoutUnits.distance($0.km, distanceUnit), distanceUnit) }
        case "speed":
            guard let km = distanceStat?.km, w.duration > 0 else { return nil }
            return Self.quantity(WorkoutUnits.speed(km * 1000 / w.duration, speedUnit), speedUnit)
        case "stepCadence":
            guard let steps = w.statistics["stepCount"]?.sum, w.duration > 0 else { return nil }
            return Self.quantity(steps / (w.duration / 60), "count/min")
        case "avgSpeed": return w.averageSpeed.map { Self.quantity(WorkoutUnits.speed($0, speedUnit), speedUnit) }
        case "maxSpeed": return w.maximumSpeed.map { Self.quantity(WorkoutUnits.speed($0, speedUnit), speedUnit) }
        case "elevationUp": return w.elevationAscended.map { Self.quantity($0, "m") }
        case "temperature": return w.temperature.map { Self.quantity(temperatureUnit == "degF" ? $0 * 9 / 5 + 32 : $0, temperatureUnit) }
        case "humidity": return w.humidity.map { Self.quantity($0, "%") }
        case "intensity": return w.averageMETs.map { Self.quantity($0, "kcal/hr·kg") }
        case "estimatedEffortScore": return w.estimatedEffort.map { Self.quantity($0, "appleEffortScore") }
        case "activities": return .array(w.activities.enumerated().map { activity($0.element, index: $0.offset) })
        case "events": return .array(w.events.enumerated().map { Self.event($0.element, index: $0.offset) })
        case "segments": return .lazy(once { try await segments() })
        case "splits": return .lazy(once { try await splits() })
        case "heartRateData": return .lazy(heartRate(in: DateInterval(start: w.start, end: w.end)))
        case "heartRateRecovery":
            return .lazy(heartRate(in: DateInterval(start: w.end, duration: 180)))
        case "activeEnergy": return .lazy(series("activeEnergy", unit: energyUnit))
        case "basalEnergy": return .lazy(series("basalEnergy", unit: energyUnit))
        case "stepCount": return .lazy(series("stepCount", unit: "count"))
        case "walkingAndRunningDistance": return .lazy(series("walkingAndRunningDistance", unit: distanceUnit))
        case "cyclingDistance": return .lazy(series("cyclingDistance", unit: distanceUnit))
        case "route":
            guard w.hasRoute, extractor.spec.workouts.routes else { return .array([]) }
            let extractor = extractor
            return .lazy(LazyList(plainItems: true) {
                var pager = extractor.route(of: w)
                return PageReader { try await pager.next()?.map { .object(RouteObject(point: $0)) } }
            })
        default:
            return w.statistics[key].map(Self.statistic)
        }
    }

    private static func statistic(_ s: WorkoutStatistic) -> TemplateValue {
        var fields: [String: TemplateValue] = ["units": .string(s.unit)]
        if let v = s.sum { fields["sum"] = .number(v) }
        if let v = s.avg { fields["avg"] = .number(v) }
        if let v = s.min { fields["min"] = .number(v) }
        if let v = s.max { fields["max"] = .number(v) }
        return .object(DictionaryObject(fields))
    }

    private func once(_ body: @escaping @Sendable () async throws -> [TemplateValue]) -> LazyList {
        LazyList(plainItems: true) {
            var done = false
            return PageReader {
                if done { return nil }
                done = true
                let rows = try await body()
                return rows.isEmpty ? nil : rows
            }
        }
    }

    // MARK: Series

    /// Per-minute buckets across the workout, in order.
    private func buckets(_ id: String, unit: String, style: BucketQuery.Style, in range: DateInterval) async throws -> [StatBucket] {
        let planner = BucketPlanner(grouping: .minutes, calendar: extractor.calendar)
        var out: [StatBucket] = []
        for plan in planner.plans(range) {
            out += try await extractor.store.buckets(BucketQuery(type: id, unit: unit, style: style, plan: plan))
        }
        return out
    }

    private func series(_ name: String, unit: String) -> LazyList {
        let w = workout
        let id = MetricCatalog.workoutStatistics.first { $0.name == name }!.id
        return once {
            try await buckets(id, unit: unit, style: .sum, in: DateInterval(start: w.start, end: w.end)).map { b in
                .object(DictionaryObject(["date": .date(b.start), "qty": .number(b.merged.sum ?? 0), "source": .string(b.sources.map(\.source).joined(separator: "|")), "units": .string(unit)]))
            }
        }
    }

    private func heartRate(in range: DateInterval) -> LazyList {
        once {
            try await buckets(WorkoutUnits.heartRateID, unit: "count/min", style: .range, in: range).map { b in
                var fields: [String: TemplateValue] = ["date": .date(b.start), "units": .string("count/min")]
                if let v = b.merged.avg { fields["Avg"] = .number(v) }
                if let v = b.merged.max { fields["Max"] = .number(v) }
                if let v = b.merged.min { fields["Min"] = .number(v) }
                return .object(DictionaryObject(fields))
            }
        }
    }

    // MARK: Activities and events

    private func activity(_ a: WorkoutDetail.Activity, index: Int) -> TemplateValue {
        var metrics: [String: TemplateValue] = [:]
        func metric(_ qty: Double, _ units: String, _ origin: String) -> TemplateValue {
            .object(DictionaryObject(["origin": .string(origin), "qty": .number(qty), "units": .string(units)]))
        }
        if let v = a.statistics["activeEnergy"]?.sum { metrics["activeEnergy"] = metric(v, "kcal", "activityStatistics") }
        if let hr = a.statistics["heartRate"] {
            if let v = hr.avg { metrics["heartRateAverage"] = metric(v, "bpm", "activityStatistics") }
            if let v = hr.max { metrics["heartRateMaximum"] = metric(v, "bpm", "activityStatistics") }
            if let v = hr.min { metrics["heartRateMinimum"] = metric(v, "bpm", "activityStatistics") }
        }
        let distance = ["walkingAndRunningDistance", "cyclingDistance", "wheelchairDistance", "rowingDistance", "paddleSportsDistance", "crossCountrySkiingDistance", "downhillSnowSportsDistance", "skatingSportsDistance"].compactMap { a.statistics[$0]?.sum }.first.map { $0 * 1000 } ?? a.statistics["swimmingDistance"]?.sum
        if let metres = distance {
            metrics["distance"] = metric(metres, "m", "activityStatistics")
            if a.duration > 0 && metres > 0 {
                metrics["speed"] = metric(metres / a.duration, "m/s", "activeTimeCalculation")
                metrics["paceKilometre"] = metric(a.duration / (metres / 1000), "s/km", "activeTimeCalculation")
                metrics["paceMile"] = metric(a.duration / (metres / 1609.344), "s/mi", "activeTimeCalculation")
            }
        }
        var configuration: [String: TemplateValue] = ["swimmingLocationType": .string(a.swimmingLocation ?? "unknown")]
        if let indoor = a.isIndoor { configuration["locationType"] = .string(indoor ? "indoor" : "outdoor") }
        return .object(DictionaryObject([
            "activeDuration": .number(a.duration), "activityType": .string(a.activityType.prefix(1).lowercased() + a.activityType.dropFirst()),
            "activityTypeCode": .number(Double(a.activityTypeCode)), "boundaryKind": .string("interval"), "boundaryOrigin": .string("recordedActivity"),
            "configuration": .object(DictionaryObject(configuration)), "duration": .number(a.duration), "elapsedDuration": .number(a.end.timeIntervalSince(a.start)),
            "end": .date(a.end), "id": .string(a.id), "index": .number(Double(index + 1)), "metrics": .object(DictionaryObject(metrics)), "start": .date(a.start),
        ]))
    }

    private static func event(_ e: WorkoutDetail.Event, index: Int) -> TemplateValue {
        .object(DictionaryObject([
            "boundaryKind": .string(e.start == e.end ? "instant" : "interval"), "boundaryOrigin": .string("recordedEvent"), "end": .date(e.end),
            "index": .number(Double(index)), "start": .date(e.start), "type": .string(e.type), "typeCode": .number(Double(e.typeCode)),
        ]))
    }

    // MARK: Segments and splits

    /// Time between the bounds with the workout not paused.
    func activeDuration(from: Date, to: Date) -> Double {
        var active = to.timeIntervalSince(from)
        var pausedAt: Date?
        for e in workout.events {
            if e.type == "pause" || e.type == "motionPaused" {
                pausedAt = pausedAt ?? e.start
            } else if e.type == "resume" || e.type == "motionResumed", let start = pausedAt {
                active -= max(0, min(e.start, to).timeIntervalSince(max(start, from)))
                pausedAt = nil
            }
        }
        if let start = pausedAt { active -= max(0, to.timeIntervalSince(max(start, from))) }
        return max(0, active)
    }

    /// Everything splits and segments are worked out from, read once per
    /// workout: a query per split would take minutes for a month of runs.
    private func samples() async throws -> WorkoutSamples {
        let span = DateInterval(start: workout.start, end: workout.end)
        func all(_ id: String, _ unit: String) async throws -> [DetailedQuantity] {
            var out: [DetailedQuantity] = []
            var cursor: PageCursor?
            repeat {
                let page = try await extractor.store.quantityPage(id, unit: unit, in: span, after: cursor, limit: Extractor.pageSize)
                out += page.items
                cursor = page.next
            } while cursor != nil
            // Other sources often record the same movement, and adding them
            // would count it twice. A watch's workout has its own samples.
            let own = out.filter { $0.source == workout.source }
            return own.isEmpty ? out : own
        }
        let energyID = MetricCatalog.workoutStatistics.first { $0.name == "activeEnergy" }!.id
        var distance: [DetailedQuantity] = []
        if let id = distanceIdentifier?.id { distance = try await all(id, "m") }
        return WorkoutSamples(energy: try await all(energyID, "kcal"), distance: distance, heartRate: try await all(WorkoutUnits.heartRateID, "count/min"))
    }

    /// One span's energy, distance, heart rate and pace, from what was read.
    private func metrics(from: Date, to: Date, active: Double, samples: WorkoutSamples) -> TemplateValue {
        var out: [String: TemplateValue] = [:]
        let span = max(0, to.timeIntervalSince(from))
        func covered(_ qty: Double, _ units: String) -> TemplateValue {
            .object(DictionaryObject(["coveredDuration": .number(span), "origin": .string("sampleOverlapEstimate"), "qty": .number(qty), "units": .string(units)]))
        }
        func estimated(_ qty: Double, _ units: String) -> TemplateValue {
            .object(DictionaryObject(["origin": .string("activeTimeCalculation"), "qty": .number(qty), "units": .string(units)]))
        }
        out["activeEnergy"] = covered(WorkoutSamples.overlap(samples.energy, from: from, to: to), "kcal")
        let metres = WorkoutSamples.overlap(samples.distance, from: from, to: to)
        out["distance"] = covered(metres, "m")
        let moving = metres > 0 && active > 0
        out["speed"] = estimated(moving ? metres / active : 0, "m/s")
        out["paceKilometre"] = estimated(moving ? active / (metres / 1000) : 0, "s/km")
        out["paceMile"] = estimated(moving ? active / (metres / 1609.344) : 0, "s/mi")
        let beats = samples.heartRate.filter { $0.start >= from && $0.start < to }.map(\.value)
        if !beats.isEmpty {
            func summary(_ qty: Double) -> TemplateValue {
                .object(DictionaryObject(["origin": .string("sampleSummary"), "qty": .number(qty), "sampleCount": .number(Double(beats.count)), "units": .string("bpm")]))
            }
            out["heartRateAverage"] = summary(beats.reduce(0, +) / Double(beats.count))
            out["heartRateMaximum"] = summary(beats.max()!)
            out["heartRateMinimum"] = summary(beats.min()!)
        }
        return .object(DictionaryObject(out))
    }

    private var distanceIdentifier: (id: String, unit: String, type: String)? {
        guard let name = distanceStat?.name, let entry = MetricCatalog.workoutStatistics.first(where: { $0.name == name }) else { return nil }
        let type = name.replacingOccurrences(of: "AndRunningDistance", with: "Running").replacingOccurrences(of: "Distance", with: "")
        return (entry.id, entry.unit, type)
    }

    private func segments() async throws -> [TemplateValue] {
        var out: [TemplateValue] = []
        guard workout.events.contains(where: { $0.type == "segment" }) else { return [] }
        let read = try await samples()
        for (i, e) in workout.events.enumerated() where e.type == "segment" {
            let active = activeDuration(from: e.start, to: e.end)
            out.append(.object(DictionaryObject([
                "activeDuration": .number(active), "boundaryKind": .string("interval"), "boundaryOrigin": .string("recordedEvent"),
                "elapsedDuration": .number(e.end.timeIntervalSince(e.start)), "end": .date(e.end), "eventIndex": .number(Double(i)),
                "index": .number(Double(out.count)), "metrics": metrics(from: e.start, to: e.end, active: active, samples: read), "start": .date(e.start),
            ])))
        }
        return out
    }

    /// Per-kilometre and per-mile splits, placed where the distance samples
    /// cross each mark, assuming even progress within a sample.
    private func splits() async throws -> [TemplateValue] {
        guard let distance = distanceIdentifier else { return [] }
        let read = try await samples()
        guard !read.distance.isEmpty else { return [] }
        var out: [TemplateValue] = []
        for (target, units) in [(1000.0, "km"), (1609.344, "mi")] {
            let marks = WorkoutSplits.marks(read.distance, every: target, workoutStart: workout.start, workoutEnd: workout.end)
            var items: [TemplateValue] = []
            for (i, m) in marks.enumerated() {
                let active = activeDuration(from: m.start, to: m.end)
                items.append(.object(DictionaryObject([
                    "activeDuration": .number(active), "boundaryKind": .string("interval"), "boundaryOrigin": .string("distanceInterpolation"),
                    "elapsedDuration": .number(m.end.timeIntervalSince(m.start)), "end": .date(m.end), "index": .number(Double(i)), "isPartial": .bool(m.isPartial),
                    "metrics": metrics(from: m.start, to: m.end, active: active, samples: read), "start": .date(m.start),
                ])))
            }
            out.append(.object(DictionaryObject([
                "boundaryOrigin": .string("distanceInterpolation"), "distanceType": .string(distance.type), "items": .array(items),
                "targetDistance": Self.quantity(1, units),
            ])))
        }
        return out
    }
}

/// A workout's samples, kept for working out its splits and segments.
struct WorkoutSamples: Sendable {
    var energy: [DetailedQuantity]
    var distance: [DetailedQuantity]
    var heartRate: [DetailedQuantity]

    /// The total falling between two times, sharing each sample out evenly
    /// across its length. An instant counts where it falls.
    static func overlap(_ samples: [DetailedQuantity], from: Date, to: Date) -> Double {
        var total = 0.0
        for s in samples {
            let length = s.end.timeIntervalSince(s.start)
            if length <= 0 {
                if s.start >= from && s.start < to { total += s.value }
                continue
            }
            let shared = min(s.end, to).timeIntervalSince(max(s.start, from))
            if shared > 0 { total += s.value * shared / length }
        }
        return total
    }
}

/// Splitting a workout at each whole distance mark.
enum WorkoutSplits {
    struct Mark: Equatable {
        var start: Date
        var end: Date
        var isPartial: Bool
    }

    static func marks(_ samples: [DetailedQuantity], every target: Double, workoutStart: Date, workoutEnd: Date) -> [Mark] {
        var out: [Mark] = []
        var from = workoutStart
        var total = 0.0
        for s in samples.sorted(by: { $0.start < $1.start }) where s.value > 0 {
            var left = s.value
            var at = s.start
            let rate = s.end > s.start ? s.value / s.end.timeIntervalSince(s.start) : 0
            while total + left >= target {
                let needed = target - total
                let crossed = rate > 0 ? at.addingTimeInterval(needed / rate) : s.end
                out.append(Mark(start: from, end: crossed, isPartial: false))
                from = crossed
                at = crossed
                left -= needed
                total = 0
            }
            total += left
        }
        if total > 0 { out.append(Mark(start: from, end: workoutEnd, isPartial: true)) }
        return out
    }
}

enum WorkoutUnits {
    static let heartRateID = "HKQuantityTypeIdentifierHeartRate"

    static func energy(_ kcal: Double, _ unit: String) -> Double { unit == "kJ" ? kcal * 4.184 : kcal }

    static func distance(_ km: Double, _ unit: String) -> Double {
        switch unit {
        case "mi": km / 1.609344
        case "m": km * 1000
        default: km
        }
    }

    static func speed(_ metresPerSecond: Double, _ unit: String) -> Double {
        switch unit {
        case "mi/hr": metresPerSecond * 2.236936
        case "m/s": metresPerSecond
        default: metresPerSecond * 3.6
        }
    }
}
