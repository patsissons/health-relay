import Foundation
import Testing
@testable import HealthDataRelayKit

private let newYork = TimeZone(identifier: "America/New_York")!
private let calendar = Calendar.local(newYork)

/// "2026-03-08 01:30:00 -0500" -> Date.
private func at(_ text: String) -> Date { T.date(text) }

private func all(_ pager: MetricPager) async throws -> [MetricPoint] {
    var p = pager
    var out: [MetricPoint] = []
    while let page = try await p.next() { out += page }
    return out
}

@Suite struct MetricCatalogTests {
    @Test func namesAreUniqueAndReachable() {
        #expect(Set(MetricCatalog.metrics.map(\.name)).count == MetricCatalog.metrics.count)
        #expect(MetricCatalog.metric(named: "step_count")?.identifiers == ["HKQuantityTypeIdentifierStepCount"])
    }

    @Test func coversEveryQuantityTypeTheFrozenCatalogDoes() {
        let ids = Set(MetricCatalog.metrics.flatMap(\.identifiers))
        for t in Catalog.stats { #expect(ids.contains(t.id), "\(t.id)") }
    }

    @Test func coversTheNamesSeenInRealExports() {
        // Every metric name seen in a real JSON export.
        let seen = """
        active_energy apple_exercise_time apple_sleeping_wrist_temperature apple_stand_hour apple_stand_time basal_energy_burned \
        blood_oxygen_saturation body_fat_percentage body_mass_index breathing_disturbances caffeine calcium carbohydrates cardio_recovery \
        cholesterol copper cycling_distance dietary_energy dietary_sugar dietary_water environmental_audio_exposure fiber flights_climbed \
        folate headphone_audio_exposure heart_rate heart_rate_variability heart_rate_variability_rmssd height iron lean_body_mass magnesium \
        manganese monounsaturated_fat niacin pantothenic_acid phosphorus physical_effort polyunsaturated_fat potassium protein \
        respiratory_rate resting_heart_rate riboflavin saturated_fat selenium six_minute_walking_test_distance sleep_analysis sodium \
        stair_speed_down stair_speed_up step_count thiamin time_in_daylight total_fat vitamin_a vitamin_b12 vitamin_b6 vitamin_c vitamin_d \
        vitamin_e vitamin_k vo2_max walking_asymmetry_percentage walking_double_support_percentage walking_heart_rate_average \
        walking_running_distance walking_speed walking_step_length weight_body_mass zinc
        """
        for name in seen.split(separator: " ") { #expect(MetricCatalog.metric(named: String(name)) != nil, "\(name)") }
    }

    @Test func theFormerGapsAreCovered() {
        for name in ["apple_move_time", "swimming_distance", "wheelchair_distance", "push_count", "swimming_stroke_count", "cycling_cadence",
                     "cycling_functional_threshold_power", "cycling_power", "cycling_speed", "running_power", "running_speed",
                     "running_ground_contact_time", "running_stride_length", "running_vertical_oscillation", "waist_circumference",
                     "atrial_fibrillation_burden", "forced_expiratory_volume_1", "forced_vital_capacity", "peripheral_perfusion_index",
                     "peak_expiratory_flow_rate", "inhaler_usage", "body_temperature", "basal_body_temperature", "underwater_depth",
                     "water_temperature", "uv_exposure", "insulin_delivery", "blood_glucose", "biotin", "chloride", "chromium", "iodine",
                     "molybdenum", "electrodermal_activity", "blood_alcohol_content", "number_of_alcoholic_beverages", "handwashing", "toothbrushing",
                     "downhill_snow_sports_distance", "breathing_disturbances"] {
            #expect(MetricCatalog.metric(named: name) != nil, "\(name)")
        }
        #expect(MetricCatalog.cycleTracking.contains { $0.id.hasSuffix("SexualActivity") })
    }

    @Test func eventValuesHaveNames() {
        let flow = MetricCatalog.cycleTracking.first { $0.id.hasSuffix("MenstrualFlow") }!
        #expect(flow.valueName(3) == "Medium")
        #expect(flow.valueName(99) == "99")
        #expect(MetricCatalog.symptoms.first { $0.id.hasSuffix("Headache") }!.valueName(4) == "Severe")
        #expect(MetricCatalog.notifications.first { $0.id.hasSuffix("HighHeartRateEvent") }!.valueName(0) == nil)
    }

    @Test func unitsFollowChoices() {
        let weight = MetricCatalog.metric(named: "weight_body_mass")!
        #expect(UnitPreferences().unit(for: weight) == "kg")
        #expect(UnitPreferences.imperial.unit(for: weight) == "lb")
        #expect(UnitPreferences.imperial.label(for: weight) == "lb")
        #expect(UnitPreferences(byMetric: ["weight_body_mass": "g"]).unit(for: weight) == "g")
        // A choice from the wrong dimension is ignored.
        #expect(UnitPreferences(byDimension: [.mass: "mi"]).unit(for: weight) == "kg")
        let effort = MetricCatalog.metric(named: "physical_effort")!
        #expect(UnitPreferences().label(for: effort) == "kcal/hr·kg")
    }

    @Test func specListsOnlyWhatItReads() {
        var spec = ExtractSpec(sections: [.metrics], metrics: .only(["step_count", "blood_pressure"]))
        #expect(spec.healthTypes.count == 3)
        spec.sections = [.workouts, .ecg]
        #expect(spec.healthTypes == [.workout, .ecg])
    }
}

@Suite struct BucketPlannerTests {
    private func planner(_ g: TimeGrouping, _ c: Calendar = calendar) -> BucketPlanner { BucketPlanner(grouping: g, calendar: c) }

    @Test func aShortDayHas23HourBuckets() {
        let day = T.day("2026-03-08").interval(in: calendar)
        let edges = planner(.hours).edges(day)
        #expect(edges.count == 24)
        #expect(edges.first == at("2026-03-08 00:00:00 -0500"))
        #expect(edges[2] == at("2026-03-08 03:00:00 -0400"))
        #expect(edges.last == at("2026-03-09 00:00:00 -0400"))
    }

    @Test func aLongDayHas25HourBuckets() {
        let day = T.day("2026-11-01").interval(in: calendar)
        let edges = planner(.hours).edges(day)
        #expect(edges.count == 26)
        // The repeated hour gets two buckets.
        #expect(edges[1] == at("2026-11-01 01:00:00 -0400"))
        #expect(edges[2] == at("2026-11-01 01:00:00 -0500"))
    }

    @Test func dayBucketsFollowLocalMidnights() {
        let span = DateInterval(start: at("2026-03-07 12:00:00 -0500"), end: at("2026-03-09 12:00:00 -0400"))
        let edges = planner(.days).edges(span)
        #expect(edges == [at("2026-03-07 00:00:00 -0500"), at("2026-03-08 00:00:00 -0500"), at("2026-03-09 00:00:00 -0400"), at("2026-03-10 00:00:00 -0400")])
        #expect(edges[2].timeIntervalSince(edges[1]) == 23 * 3600)
    }

    @Test func weeksStartOnTheCalendarsFirstDay() {
        var monday = calendar
        monday.firstWeekday = 2
        let week = planner(.weeks, monday)
        // Thursday 2026-10-29: its week began Monday the 26th.
        #expect(week.floor(at("2026-10-29 12:00:00 -0400")) == at("2026-10-26 00:00:00 -0400"))
        // That week holds the fall-back, so it's 7 local days and 169 hours.
        let next = week.next(at("2026-10-26 00:00:00 -0400"))
        #expect(next == at("2026-11-02 00:00:00 -0500"))
        var sunday = calendar
        sunday.firstWeekday = 1
        #expect(planner(.weeks, sunday).floor(at("2026-10-29 12:00:00 -0400")) == at("2026-10-25 00:00:00 -0400"))
    }

    @Test func monthsAndYearsAreCalendarLengths() {
        #expect(planner(.months).floor(at("2026-02-15 12:00:00 -0500")) == at("2026-02-01 00:00:00 -0500"))
        #expect(planner(.months).next(at("2026-02-01 00:00:00 -0500")) == at("2026-03-01 00:00:00 -0500"))
        #expect(planner(.years).floor(at("2026-02-15 12:00:00 -0500")) == at("2026-01-01 00:00:00 -0500"))
        #expect(planner(.years).next(at("2026-01-01 00:00:00 -0500")) == at("2027-01-01 00:00:00 -0500"))
    }

    @Test func snappingGrowsToWholeBuckets() {
        let range = DateInterval(start: at("2026-10-29 12:30:10 -0400"), end: at("2026-10-29 13:00:00 -0400"))
        #expect(planner(.hours).snap(range) == DateInterval(start: at("2026-10-29 12:00:00 -0400"), end: at("2026-10-29 13:00:00 -0400")))
        #expect(planner(.minutes).snap(range).start == at("2026-10-29 12:30:00 -0400"))
        #expect(planner(.seconds).snap(range).start == at("2026-10-29 12:30:10 -0400"))
    }

    @Test func aPointInTimeStillHasABucket() {
        let moment = at("2026-10-29 12:00:00 -0400")
        #expect(planner(.hours).snap(DateInterval(start: moment, end: moment)).duration == 3600)
    }

    @Test func plansCoverTheRangeWithoutGapsOrOverlap() {
        for g in TimeGrouping.allCases {
            let range = DateInterval(start: at("2026-03-01 00:00:00 -0500"), end: at("2026-03-20 00:00:00 -0400"))
            let plans = g == .seconds ? planner(g).plans(DateInterval(start: range.start, duration: 200_000)) : planner(g).plans(range)
            #expect(!plans.isEmpty, "\(g)")
            for (a, b) in zip(plans, plans.dropFirst()) { #expect(a.span.end == b.span.start, "\(g)") }
        }
    }

    @Test func aPlanHoldsAtMostTheLimit() {
        let range = DateInterval(start: at("2026-03-01 00:00:00 -0500"), duration: 86400)
        let plans = planner(.seconds).plans(range)
        #expect(plans.count == 5)
        for p in plans { #expect(p.span.duration <= Double(BucketPlanner.maxBucketsPerQuery)) }
    }

    @Test func aWholeYearOfMinutesIsFewQueries() {
        let range = DateInterval(start: at("2026-01-01 00:00:00 -0500"), end: at("2027-01-01 00:00:00 -0500"))
        // 525,600 minutes at 20,000 per query.
        #expect(planner(.minutes).plans(range).count == 27)
    }

    @Test func aHalfHourClockChangeEndsThePlan() {
        let lordHowe = Calendar.local(TimeZone(identifier: "Australia/Lord_Howe")!)
        let p = BucketPlanner(grouping: .hours, calendar: lordHowe)
        let start = Day(year: 2026, month: 3, day: 1).start(in: lordHowe)
        let end = Day(year: 2026, month: 5, day: 1).start(in: lordHowe)
        let plans = p.plans(DateInterval(start: start, end: end))
        #expect(plans.count == 2)
        // The second plan starts at a local midnight, where hours line up again.
        #expect(lordHowe.startOfDay(for: plans[1].anchor) == plans[1].anchor)
    }

    @Test func oneHourClockChangesDoNotSplitHours() {
        let range = DateInterval(start: at("2026-03-01 00:00:00 -0500"), end: at("2026-03-20 00:00:00 -0400"))
        #expect(planner(.hours).plans(range).count == 1)
    }

    @Test func automaticIsMinutes() {
        #expect(planner(.automatic).plans(DateInterval(start: at("2026-03-01 00:00:00 -0500"), duration: 3600))[0].step == .seconds(60))
    }
}

@Suite struct RangePlannerTests {
    private let planner = RangePlanner(calendar: calendar)
    private let now = at("2026-11-01 12:00:00 -0500")

    @Test func changedDaysBecomeWholeDaysAndMerge() throws {
        let ranges = try planner.ranges(.changedDays, now: now, changedDays: [T.day("2026-11-01"), T.day("2026-10-31"), T.day("2026-10-20")])
        #expect(ranges == [T.day("2026-10-20").interval(in: calendar), DateInterval(start: at("2026-10-31 00:00:00 -0400"), end: at("2026-11-02 00:00:00 -0500"))])
    }

    @Test func todayRunsToNow() throws {
        #expect(try planner.ranges(.today, now: now) == [DateInterval(start: at("2026-11-01 00:00:00 -0400"), end: now)])
    }

    @Test func yesterdayIsAWholeDay() throws {
        #expect(try planner.ranges(.yesterday, now: now) == [T.day("2026-10-31").interval(in: calendar)])
    }

    @Test func previousDaysEndsAtMidnight() throws {
        let r = try planner.ranges(.previousDays(7), now: now)
        #expect(r == [DateInterval(start: at("2026-10-25 00:00:00 -0400"), end: at("2026-11-01 00:00:00 -0400"))])
    }

    @Test func lastDaysIncludesToday() throws {
        let r = try planner.ranges(.lastDays(2), now: now)
        #expect(r == [DateInterval(start: at("2026-10-31 00:00:00 -0400"), end: now)])
    }

    @Test func sinceLastRunStartsAtTheCursor() throws {
        let last = at("2026-11-01 09:00:00 -0500")
        let r = try planner.ranges(.sinceLastRun, now: now, cursor: ExtractCursor(lastEnd: last))
        #expect(r == [DateInterval(start: last, end: now)])
    }

    @Test func aFirstSinceLastRunLooksBackAWeek() throws {
        let r = try planner.ranges(.sinceLastRun, now: now)
        #expect(r == [DateInterval(start: at("2026-10-25 00:00:00 -0400"), end: now)])
    }

    @Test func lateSamplesAreAddedToTheRange() throws {
        let last = at("2026-11-01 09:00:00 -0500")
        let late = DateInterval(start: at("2026-10-30 08:00:00 -0400"), end: at("2026-10-30 09:00:00 -0400"))
        let r = try planner.ranges(.sinceLastRun, now: now, cursor: ExtractCursor(lastEnd: last), late: [late])
        #expect(r == [late, DateInterval(start: last, end: now)])
    }

    @Test func aLateSampleTouchingTheCursorMerges() throws {
        let last = at("2026-11-01 09:00:00 -0500")
        let late = DateInterval(start: at("2026-11-01 08:00:00 -0500"), end: last)
        let r = try planner.ranges(.sinceLastRun, now: now, cursor: ExtractCursor(lastEnd: last), late: [late])
        #expect(r == [DateInterval(start: late.start, end: now)])
    }

    @Test func askedRangeNeedsAnAnswer() throws {
        #expect(throws: RangePlanner.Failure.needsAnswer) { try planner.ranges(.askAtRun, now: now) }
        let answer = DateInterval(start: at("2026-10-01 00:00:00 -0400"), end: now)
        #expect(try planner.ranges(.askAtRun, now: now, answer: answer) == [answer])
    }

    @Test func onlySinceLastRunMovesTheCursor() {
        let a = planner.advanced(ExtractCursor(), spec: .sinceLastRun, now: now, anchors: [.workout: Data([1])])
        #expect(a.lastEnd == now)
        #expect(a.anchors[.workout] == Data([1]))
        let b = planner.advanced(a, spec: .yesterday, now: now.addingTimeInterval(60), anchors: [:])
        #expect(b.lastEnd == now)
    }

    @Test func aCursorSurvivesBeingSaved() throws {
        let cursor = ExtractCursor(lastEnd: now, anchors: [.workout: Data([1, 2]), HealthType(.quantity, "x"): Data([3])])
        let back = try JSONDecoder().decode(ExtractCursor.self, from: JSONEncoder().encode(cursor))
        #expect(back == cursor)
    }

    @Test func aSpecSurvivesBeingSaved() throws {
        let spec = ExtractSpec(sections: [.metrics, .workouts], metrics: .only(["step_count"]), range: .fixed(DateInterval(start: now, duration: 60)),
                               grouping: nil, sources: .preferred(["Watch"]), metricSources: ["step_count": .eachSource], units: .imperial)
        #expect(try JSONDecoder().decode(ExtractSpec.self, from: JSONEncoder().encode(spec)) == spec)
    }
}

@Suite struct ExtractorTests {
    private let day = T.day("2026-10-29").interval(in: calendar)
    private let noon = at("2026-10-29 12:00:00 -0400")

    private func extractor(_ store: HealthQuerying, _ spec: ExtractSpec = ExtractSpec(), ranges: [DateInterval]? = nil) -> Extractor {
        Extractor(store: store, spec: spec, calendar: calendar, ranges: ranges ?? [day])
    }

    private func steps() -> Metric { MetricCatalog.metric(named: "step_count")! }

    @Test func mergedPointsListTheirSources() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 100)
        store.add("step_count", source: "iPhone", at: noon, 50)
        let points = try await all(extractor(store, ExtractSpec(grouping: .days)).points(of: steps()))
        #expect(points.count == 1)
        #expect(points[0].qty == 150)
        #expect(points[0].source == "Watch|iPhone")
        #expect(points[0].date == day.start)
    }

    @Test func eachSourceGetsItsOwnPoint() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 100)
        store.add("step_count", source: "iPhone", at: noon, 50)
        let points = try await all(extractor(store, ExtractSpec(grouping: .days, sources: .eachSource)).points(of: steps()))
        #expect(points.map(\.qty) == [100, 50])
        #expect(points.map(\.source) == ["Watch", "iPhone"])
    }

    @Test func aPreferredSourceWinsPerBucket() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 100)
        store.add("step_count", source: "iPhone", at: noon, 50)
        store.add("step_count", source: "iPhone", at: noon.addingTimeInterval(7200), 30)
        let spec = ExtractSpec(grouping: .hours, sources: .preferred(["Watch"]))
        let points = try await all(extractor(store, spec).points(of: steps()))
        #expect(points.map(\.qty) == [100, 30])
        #expect(points.map(\.source) == ["Watch", "iPhone"])
    }

    @Test func aMetricCanHaveItsOwnPolicy() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 100)
        store.add("step_count", source: "iPhone", at: noon, 50)
        let spec = ExtractSpec(grouping: .days, sources: .merged, metricSources: ["step_count": .preferred(["iPhone"])])
        #expect(try await all(extractor(store, spec).points(of: steps())).map(\.qty) == [50])
    }

    @Test func emptyBucketsMakeNoPoints() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: noon, 1)
        store.add("step_count", at: noon.addingTimeInterval(7200), 2)
        let points = try await all(extractor(store, ExtractSpec(grouping: .hours)).points(of: steps()))
        #expect(points.count == 2)
    }

    @Test func discreteTypesAverageAndHeartRateHasARange() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("weight_body_mass", at: noon, 70)
        store.add("weight_body_mass", at: noon, 72)
        store.add("heart_rate", at: noon, 60)
        store.add("heart_rate", at: noon, 90)
        let e = extractor(store, ExtractSpec(grouping: .days))
        #expect(try await all(e.points(of: MetricCatalog.metric(named: "weight_body_mass")!))[0].qty == 71)
        let hr = try await all(e.points(of: MetricCatalog.metric(named: "heart_rate")!))[0]
        #expect((hr.min, hr.avg, hr.max) == (60, 75, 90))
        // Min/Avg/Max points name no source when summarized.
        #expect(hr.source == nil)
        #expect(hr.qty == nil)
    }

    @Test func aRequestedUnitReachesTheQuery() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("weight_body_mass", at: noon, 150)
        let spec = ExtractSpec(grouping: .days, units: .imperial)
        let pager = extractor(store, spec).points(of: MetricCatalog.metric(named: "weight_body_mass")!)
        #expect(pager.unitLabel == "lb")
        _ = try await all(pager)
        #expect(store.bucketQueries[0].unit == "lb")
    }

    @Test func aRangeGrowsToWholeBuckets() async throws {
        // Asking from mid-morning still counts the whole day's steps.
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: at("2026-10-29 08:00:00 -0400"), 10)
        store.add("step_count", at: noon, 5)
        let e = extractor(store, ExtractSpec(grouping: .days), ranges: [DateInterval(start: at("2026-10-29 11:00:00 -0400"), end: noon.addingTimeInterval(60))])
        #expect(try await all(e.points(of: steps())).map(\.qty) == [15])
    }

    @Test func aDaylightSavingDayIsOneBucket() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: at("2026-11-01 00:30:00 -0400"), 1)
        store.add("step_count", at: at("2026-11-01 23:30:00 -0500"), 2)
        store.add("step_count", at: at("2026-11-02 00:30:00 -0500"), 4)
        let e = extractor(store, ExtractSpec(grouping: .days), ranges: [T.day("2026-11-01").interval(in: calendar), T.day("2026-11-02").interval(in: calendar)])
        let points = try await all(e.points(of: steps()))
        #expect(points.map(\.qty) == [3, 4])
        #expect(points[1].date == at("2026-11-02 00:00:00 -0500"))
    }

    @Test func theRepeatedHourKeepsTwoPoints() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: at("2026-11-01 01:30:00 -0400"), 1)
        store.add("step_count", at: at("2026-11-01 01:30:00 -0500"), 2)
        let e = extractor(store, ExtractSpec(grouping: .hours), ranges: [T.day("2026-11-01").interval(in: calendar)])
        #expect(try await all(e.points(of: steps())).map(\.qty) == [1, 2])
    }

    // MARK: Unsummarized

    @Test func rawPointsKeepEachSample() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add(MetricCatalog.metric(named: "heart_rate")!.identifiers[0], DetailedQuantity(source: "Watch", start: noon, end: noon.addingTimeInterval(60), value: 70, min: 60, max: 80, context: "Active"))
        store.add("step_count", at: noon, end: noon.addingTimeInterval(60), 5)
        let e = extractor(store, ExtractSpec(grouping: nil))
        let hr = try await all(e.points(of: MetricCatalog.metric(named: "heart_rate")!))[0]
        #expect((hr.min, hr.avg, hr.max) == (60, 70, 80))
        #expect(hr.context == "Active")
        #expect(hr.source == "Watch")
        #expect(hr.end == noon.addingTimeInterval(60))
        #expect(try await all(e.points(of: steps()))[0].qty == 5)
    }

    @Test func aRawPreferredSourceKeepsOnlyThatSource() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", source: "Watch", at: noon, 1)
        store.add("step_count", source: "iPhone", at: noon, 2)
        let e = extractor(store, ExtractSpec(grouping: nil, sources: .preferred(["iPad", "iPhone"])))
        #expect(try await all(e.points(of: steps())).map(\.qty) == [2])
        // No listed source has data: everything is kept.
        let none = extractor(store, ExtractSpec(grouping: nil, sources: .preferred(["iPad"])))
        #expect(try await all(none.points(of: steps())).count == 2)
    }

    @Test func aSampleSpanningTwoRangesIsWrittenOnce() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.add("step_count", at: at("2026-10-29 10:00:00 -0400"), end: at("2026-10-29 13:00:00 -0400"), 9)
        let ranges = [DateInterval(start: at("2026-10-29 09:00:00 -0400"), end: at("2026-10-29 11:00:00 -0400")),
                      DateInterval(start: at("2026-10-29 12:00:00 -0400"), end: at("2026-10-29 14:00:00 -0400"))]
        let e = extractor(store, ExtractSpec(grouping: nil), ranges: ranges)
        #expect(try await all(e.points(of: steps())).count == 1)
    }

    @Test func pagesNeverRepeatSamplesThatShareAStart() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        for i in 0..<(Extractor.pageSize + 10) { store.add("step_count", at: noon, Double(i)) }
        let points = try await all(extractor(store, ExtractSpec(grouping: nil)).points(of: steps()))
        #expect(points.count == Extractor.pageSize + 10)
        #expect(Set(points.map(\.qty)).count == Extractor.pageSize + 10)
    }

    @Test func heartbeatsAttachToTheirReading() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let hrv = MetricCatalog.metric(named: "heart_rate_variability")!
        store.add("heart_rate_variability", at: noon, end: noon.addingTimeInterval(60), 40)
        store.heartbeatSeries = [HeartbeatSeries(start: noon, end: noon.addingTimeInterval(60), beats: [.init(timeSinceStart: 1.5, precededByGap: false)])]
        let p = try await all(extractor(store, ExtractSpec(grouping: nil)).points(of: hrv))[0]
        #expect(p.heartbeats == [HeartbeatPoint(date: noon.addingTimeInterval(1.5), timeSinceStart: 1.5, precededByGap: false)])
    }

    // MARK: Paired and counted

    @Test func bloodPressurePairsByReading() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let bp = MetricCatalog.metric(named: "blood_pressure")!
        store.add(bp.identifiers[0], DetailedQuantity(source: "Cuff", start: noon, end: noon, value: 120))
        store.add(bp.identifiers[1], DetailedQuantity(source: "Cuff", start: noon, end: noon, value: 80))
        store.add(bp.identifiers[0], DetailedQuantity(source: "Cuff", start: noon.addingTimeInterval(60), end: noon.addingTimeInterval(60), value: 130))
        store.add(bp.identifiers[1], DetailedQuantity(source: "Cuff", start: noon.addingTimeInterval(60), end: noon.addingTimeInterval(60), value: 90))
        let raw = try await all(extractor(store, ExtractSpec(grouping: nil)).points(of: bp))
        #expect(raw.map(\.systolic) == [120, 130])
        #expect(raw.map(\.diastolic) == [80, 90])
        let day = try await all(extractor(store, ExtractSpec(grouping: .days)).points(of: bp))
        #expect(day.count == 1)
        #expect(day[0].systolic == 125)
        #expect(day[0].diastolic == 85)
    }

    @Test func standHoursCountOnlyStoodHours() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let stand = MetricCatalog.metric(named: "apple_stand_hour")!
        store.addCategory(stand.identifiers[0], DetailedCategory(source: "Watch", start: noon, end: noon.addingTimeInterval(3600), value: 0))
        store.addCategory(stand.identifiers[0], DetailedCategory(source: "Watch", start: noon.addingTimeInterval(3600), end: noon.addingTimeInterval(7200), value: 1))
        store.addCategory(stand.identifiers[0], DetailedCategory(source: "Watch", start: noon.addingTimeInterval(7200), end: noon.addingTimeInterval(10800), value: 0))
        #expect(try await all(extractor(store, ExtractSpec(grouping: .days)).points(of: stand)).map(\.qty) == [2])
    }

    @Test func mindfulMinutesAddUp() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let mindful = MetricCatalog.metric(named: "mindful_minutes")!
        store.addCategory(mindful.identifiers[0], DetailedCategory(source: "Mindfulness", start: noon, end: noon.addingTimeInterval(600), value: 0))
        store.addCategory(mindful.identifiers[0], DetailedCategory(source: "Mindfulness", start: noon.addingTimeInterval(900), end: noon.addingTimeInterval(1200), value: 0))
        #expect(try await all(extractor(store, ExtractSpec(grouping: .days)).points(of: mindful)).map(\.qty) == [15])
    }

    // MARK: Sleep

    private func sleepStore() -> FakeHealthQuerying {
        let store = FakeHealthQuerying(calendar: calendar)
        let id = MetricCatalog.metric(named: "sleep_analysis")!.identifiers[0]
        func add(_ start: String, _ end: String, _ stage: MetricCatalog.SleepStage, _ source: String = "Watch") {
            store.addCategory(id, DetailedCategory(source: source, start: at(start), end: at(end), value: stage.rawValue))
        }
        // In bed from the phone across the whole night, stages from the watch.
        add("2026-10-28 22:00:00 -0400", "2026-10-29 06:30:00 -0400", .inBed, "iPhone")
        add("2026-10-28 22:30:00 -0400", "2026-10-29 01:00:00 -0400", .core)
        add("2026-10-29 01:00:00 -0400", "2026-10-29 02:00:00 -0400", .deep)
        add("2026-10-29 02:00:00 -0400", "2026-10-29 02:30:00 -0400", .awake)
        add("2026-10-29 02:30:00 -0400", "2026-10-29 06:00:00 -0400", .rem)
        return store
    }

    @Test func aNightIsTotalledOnceAcrossSources() async throws {
        let points = try await all(extractor(sleepStore(), ExtractSpec(grouping: .days)).points(of: MetricCatalog.metric(named: "sleep_analysis")!))
        #expect(points.count == 1)
        let n = try #require(points[0].sleep)
        #expect(n.date == at("2026-10-29 00:00:00 -0400"))
        #expect(n.core == 2.5)
        #expect(n.deep == 1)
        #expect(n.rem == 3.5)
        #expect(n.awake == 0.5)
        #expect(n.totalSleep == 7)
        // Only the time nothing more specific covers counts as just in bed.
        #expect(n.inBed == 1)
        #expect(n.inBedStart == at("2026-10-28 22:00:00 -0400"))
        #expect(n.inBedEnd == at("2026-10-29 06:30:00 -0400"))
        #expect(n.sleepStart == at("2026-10-28 22:30:00 -0400"))
        #expect(n.sleepEnd == at("2026-10-29 06:00:00 -0400"))
        #expect(n.source == "Watch|iPhone")
    }

    @Test func nightsSplitOnALongGap() {
        let id = { (s: String, e: String, v: Int) in DetailedCategory(source: "Watch", start: at(s), end: at(e), value: v) }
        let nights = SleepNight.nights(from: [id("2026-10-28 23:00:00 -0400", "2026-10-29 06:00:00 -0400", 3),
                                              id("2026-10-29 14:00:00 -0400", "2026-10-29 15:00:00 -0400", 3)], calendar: calendar)
        #expect(nights.count == 2)
    }

    @Test func aDayEndingAcrossDaylightSavingKeepsTheRightHours() {
        let night = SleepNight.nights(from: [DetailedCategory(source: "Watch", start: at("2026-10-31 23:00:00 -0400"), end: at("2026-11-01 07:00:00 -0500"), value: 3)], calendar: calendar)[0]
        #expect(night.core == 9)
        #expect(night.date == at("2026-11-01 00:00:00 -0400"))
    }

    @Test func sleepHasNoPointBelowADay() async throws {
        let e = extractor(sleepStore(), ExtractSpec(grouping: .hours))
        #expect(try await all(e.points(of: MetricCatalog.metric(named: "sleep_analysis")!)).isEmpty)
    }

    @Test func rawSleepIsOnePointPerSegment() async throws {
        let points = try await all(extractor(sleepStore(), ExtractSpec(grouping: nil)).points(of: MetricCatalog.metric(named: "sleep_analysis")!))
        #expect(points.count == 5)
        #expect(points.map(\.value).contains("REM"))
        #expect(points.first { $0.value == "REM" }?.qty == 3.5)
    }

    @Test func weeksAddTheirNightsTogether() async throws {
        let store = sleepStore()
        let id = MetricCatalog.metric(named: "sleep_analysis")!.identifiers[0]
        store.addCategory(id, DetailedCategory(source: "Watch", start: at("2026-10-29 23:00:00 -0400"), end: at("2026-10-30 01:00:00 -0400"), value: 4))
        let week = T.day("2026-10-25").interval(in: calendar)
        let e = Extractor(store: store, spec: ExtractSpec(grouping: .weeks), calendar: calendar, ranges: [DateInterval(start: week.start, duration: 6 * 86400)])
        let points = try await all(e.points(of: MetricCatalog.metric(named: "sleep_analysis")!))
        #expect(points.count == 1)
        #expect(points[0].sleep?.deep == 3)
    }

    // MARK: Sections

    @Test func eventsComeInTimeOrderAcrossTypes() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let headache = MetricCatalog.symptoms.first { $0.id.hasSuffix("Headache") }!
        let fever = MetricCatalog.symptoms.first { $0.id.hasSuffix("Fever") }!
        store.addCategory(headache.id, DetailedCategory(source: "Health", start: noon.addingTimeInterval(60), end: noon.addingTimeInterval(120), value: 3, userEntered: true))
        store.addCategory(fever.id, DetailedCategory(source: "Health", start: noon, end: noon.addingTimeInterval(60), value: 4))
        var pager = extractor(store).events([headache, fever])
        let rows = try #require(try await pager.next())
        #expect(rows.map(\.name) == ["Fever", "Headache"])
        #expect(rows.map(\.value) == ["Severe", "Moderate"])
        #expect(rows[1].userEntered)
        #expect(try await pager.next() == nil)
    }

    @Test func workoutsFilterByTypeAndRoutesPage() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let run = WorkoutDetail(activityType: "Running", name: "Outdoor Run", source: "Watch", start: noon, end: noon.addingTimeInterval(600), duration: 600, hasRoute: true)
        let yoga = WorkoutDetail(activityType: "Yoga", name: "Yoga", source: "Watch", start: noon.addingTimeInterval(3600), end: noon.addingTimeInterval(4200), duration: 600)
        let route = (0..<(Extractor.pageSize + 5)).map { RoutePoint(timestamp: noon.addingTimeInterval(Double($0)), latitude: 49, longitude: -123) }
        store.add(run, route: route)
        store.add(yoga)

        let spec = ExtractSpec(sections: [.workouts], workouts: .init(activityTypes: ["Running"]))
        var pager = extractor(store, spec).workouts()
        let found = try #require(try await pager.next())
        #expect(found == [run])
        #expect(try await pager.next() == nil)

        var points = extractor(store, spec).route(of: run)
        var count = 0
        var pages = 0
        while let page = try await points.next() {
            count += page.count
            pages += 1
        }
        #expect(count == route.count)
        #expect(pages == 2)
    }

    @Test func recordsAreNotRepeatedAcrossRanges() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        store.moods = [StateOfMindRecord(id: "1", source: "Health", start: noon, end: noon.addingTimeInterval(7200), kind: "Daily Mood", valence: 0.5, valenceClassification: "pleasant", labels: [], associations: [])]
        let e = extractor(store, ExtractSpec(), ranges: [DateInterval(start: noon, duration: 60), DateInterval(start: noon.addingTimeInterval(3600), duration: 60)])
        #expect(try await e.statesOfMind().count == 1)
    }

    @Test func lateSamplesAreFoundOnlyOnceThereIsAnAnchor() async throws {
        let store = FakeHealthQuerying(calendar: calendar)
        let type = steps().healthTypes[0]
        store.add("step_count", at: noon, 1)
        let lastRun = noon.addingTimeInterval(3600)

        // Before any anchor, everything is the first read rather than late.
        let first = try await Extractor.late(in: store, types: [type], cursor: ExtractCursor(lastEnd: lastRun), since: noon.addingTimeInterval(-86400))
        #expect(first.late.isEmpty)

        // A sample recorded before the last run but added after it is late.
        store.add("step_count", at: noon.addingTimeInterval(-1800), 2)
        let cursor = ExtractCursor(lastEnd: lastRun, anchors: first.anchors)
        let second = try await Extractor.late(in: store, types: [type], cursor: cursor, since: noon.addingTimeInterval(-86400))
        #expect(second.late.count == 1)
        #expect(second.late[0].start == noon.addingTimeInterval(-1800))

        // A new sample after the last run isn't late: the range covers it.
        store.add("step_count", at: lastRun.addingTimeInterval(60), 3)
        let third = try await Extractor.late(in: store, types: [type], cursor: ExtractCursor(lastEnd: lastRun, anchors: second.anchors), since: noon)
        #expect(third.late.isEmpty)
    }
}

@Suite struct ExtractMemoryTests {
    /// The process's physical footprint.
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test func millionsOfSamplesStayUnderAPageInMemory() async throws {
        // The largest metric seen in a real unsummarized export: 2.6 million.
        let count = 3_000_000
        let start = at("2026-01-01 00:00:00 -0500")
        let store = SyntheticHealthQuerying(start: start, count: count)
        let e = Extractor(store: store, spec: ExtractSpec(grouping: nil), calendar: calendar, ranges: [DateInterval(start: start, duration: Double(count))])
        var pager = e.points(of: MetricCatalog.metric(named: "step_count")!)
        let before = footprint()
        var peak = before
        var seen = 0
        var aheadOfConsumer = 0
        while let page = try await pager.next() {
            seen += page.count
            aheadOfConsumer = max(aheadOfConsumer, store.samplesRead - seen)
            peak = max(peak, footprint())
        }
        #expect(seen == count)
        // Nothing is fetched before it's asked for.
        #expect(aheadOfConsumer == 0)
        // Holding them all would be over 500 MB. Other suites run alongside, so the
        // limit leaves room for what they allocate.
        #expect(peak - before < 128 * 1024 * 1024, "grew by \((peak - before) / 1024 / 1024) MB")
    }
}
