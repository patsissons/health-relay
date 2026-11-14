import Foundation
import Testing
@testable import HealthDataRelayKit

private let zone = Calendar.local(T.vancouver)
private let noon = T.date("2026-10-25 12:00:00 -0700")

@Suite struct MetricSummaryTests {
    private let fake = FakeHealthQuerying(calendar: zone)
    /// 2026-10-19 through noon on the 25th, and the seven days before.
    private let period = RangePlanner(calendar: zone).lastDays(7, now: noon)
    private var previous: DateInterval { MetricSummarizer.previous(of: period, calendar: zone) }
    private var summarizer: MetricSummarizer { MetricSummarizer(store: fake, calendar: zone) }

    private func metric(_ name: String) -> Metric { MetricCatalog.metric(named: name)! }

    private func at(_ day: String, _ time: String = "09:00:00") -> Date { T.date("\(day) \(time) -0700") }

    @Test func thePeriodBeforeIsTheSameLength() {
        #expect(period.start == at("2026-10-19", "00:00:00"))
        #expect(previous == DateInterval(start: at("2026-10-12", "00:00:00"), end: period.start))
        #expect(MetricSummarizer.dayCount(period, calendar: zone) == 7)
        #expect(MetricSummarizer.dayCount(previous, calendar: zone) == 7)
    }

    @Test func aMetricThatAddsUpHasATotal() async throws {
        fake.add("step_count", at: at("2026-10-20"), 4000)
        fake.add("step_count", at: at("2026-10-20", "15:00:00"), 2000)
        fake.add("step_count", at: at("2026-10-22"), 9000)
        let series = try #require(try await summarizer.series(metric("step_count"), period: period))
        #expect(series.days == [DayValue(day: T.day("2026-10-20"), value: 6000), DayValue(day: T.day("2026-10-22"), value: 9000)])
        #expect(series.summary.total == 15000 && series.headline == 15000)
        #expect(series.summary.average == 7500)
        #expect(series.summary.max == 9000 && series.summary.maxDay == T.day("2026-10-22"))
        #expect(series.summary.min == 6000 && series.summary.minDay == T.day("2026-10-20"))
        #expect(series.summary.latest == 9000)
        #expect(series.summary.daysWithData == 2 && series.summary.days == 7)
        #expect(series.adds && series.unit == "count" && series.group == "activity")
        #expect(series.previous == nil && series.change == nil && series.previousDays.isEmpty)
    }

    @Test func aMetricThatAveragesHasNoTotalAndKeepsItsRange() async throws {
        fake.add("heart_rate", at: at("2026-10-21"), 60)
        fake.add("heart_rate", at: at("2026-10-21", "18:00:00"), 100)
        fake.add("heart_rate", at: at("2026-10-23"), 70)
        let series = try #require(try await summarizer.series(metric("heart_rate"), period: period))
        #expect(series.days.first == DayValue(day: T.day("2026-10-21"), value: 80, low: 60, high: 100))
        #expect(series.summary.total == nil && series.headline == 75)
        #expect(!series.adds)
    }

    @Test func theChangeComparesDailyAveragesWithThePeriodBefore() async throws {
        fake.add("step_count", at: at("2026-10-14"), 5000)
        fake.add("step_count", at: at("2026-10-16"), 5000)
        fake.add("step_count", at: at("2026-10-20"), 6000)
        // Older than the period before: never counted.
        fake.add("step_count", at: at("2026-10-05"), 90000)
        let series = try #require(try await summarizer.series(metric("step_count"), period: period, previous: previous))
        #expect(series.previousDays.map(\.day) == [T.day("2026-10-14"), T.day("2026-10-16")])
        #expect(series.previous?.total == 10000)
        #expect(abs((series.change ?? 0) - 0.2) < 1e-9)
        // One read covers both periods.
        #expect(fake.bucketQueries.count == 1)
    }

    @Test func nothingInThePeriodIsNoSeries() async throws {
        fake.add("step_count", at: at("2026-10-14"), 5000)
        #expect(try await summarizer.series(metric("step_count"), period: period, previous: previous) == nil)
    }

    @Test func sleepIsHoursANight() async throws {
        let sleep = CappedHealthQuerying.sleepType
        fake.addCategory(sleep, DetailedCategory(source: "Watch", start: at("2026-10-21", "23:00:00"), end: at("2026-10-22", "06:00:00"), value: 3))
        let series = try #require(try await summarizer.series(metric("sleep_analysis"), period: period))
        #expect(series.days == [DayValue(day: T.day("2026-10-22"), value: 7)])
        #expect(series.summary.total == nil)
    }

    @Test func bloodPressureLeadsWithSystolic() async throws {
        let when = at("2026-10-22")
        fake.add("HKQuantityTypeIdentifierBloodPressureSystolic", DetailedQuantity(source: "Cuff", start: when, end: when, value: 120))
        fake.add("HKQuantityTypeIdentifierBloodPressureDiastolic", DetailedQuantity(source: "Cuff", start: when, end: when, value: 80))
        let series = try #require(try await summarizer.series(metric("blood_pressure"), period: period))
        #expect(series.days == [DayValue(day: T.day("2026-10-22"), value: 120, low: 80, high: 120)])
    }

    @Test func everyMetricWithDataComesThroughAndTheRestAreLeftOut() async {
        fake.add("step_count", at: at("2026-10-20"), 4000)
        fake.add("heart_rate", at: at("2026-10-21"), 60)
        fake.add("weight_body_mass", at: at("2026-10-01"), 80)
        var names: [String] = []
        for await series in summarizer.all(period: period, previous: previous, concurrency: 4) { names.append(series.name) }
        #expect(Set(names) == ["step_count", "heart_rate"])
    }

    @Test func aCappedReaderComparesOnlyWithItsWiderScope() async throws {
        fake.add("step_count", at: at("2026-10-14"), 5000)
        fake.add("step_count", at: at("2026-10-20"), 6000)
        let box = HistoryLimitBox(.capped)
        let standard = MetricSummarizer(store: CappedHealthQuerying(fake, box: box, calendar: { zone }, now: { noon }), calendar: zone)
        let comparing = MetricSummarizer(store: CappedHealthQuerying(fake, box: box, scope: .comparison, calendar: { zone }, now: { noon }), calendar: zone)
        #expect(try await standard.series(metric("step_count"), period: period, previous: previous)?.previous == nil)
        #expect(try await comparing.series(metric("step_count"), period: period, previous: previous)?.previous?.total == 5000)
    }

    @Test func aSeriesSurvivesBeingSaved() async throws {
        fake.add("step_count", at: at("2026-10-20"), 4000)
        let series = try #require(try await summarizer.series(metric("step_count"), period: period))
        #expect(try JSONDecoder().decode(MetricSeries.self, from: JSONEncoder().encode(series)) == series)
    }
}

@Suite struct SeriesGroupingTests {
    private let days = [
        DayValue(day: T.day("2026-10-17"), value: 10, low: 5, high: 20),
        DayValue(day: T.day("2026-10-18"), value: 20, low: 8, high: 30),
        DayValue(day: T.day("2026-10-20"), value: 40, low: 2, high: 50),
        DayValue(day: T.day("2026-11-02"), value: 6),
    ]

    @Test func weeksStartOnSundayAndAddOrAverage() {
        // The 17th is a Saturday; the 18th starts the next week.
        let totals = days.grouped(.week, adds: true, calendar: zone)
        #expect(totals.map(\.day) == [T.day("2026-10-11"), T.day("2026-10-18"), T.day("2026-11-01")])
        #expect(totals.map(\.value) == [10, 60, 6])
        let means = days.grouped(.week, adds: false, calendar: zone)
        #expect(means.map(\.value) == [10, 30, 6])
        #expect(means[1].low == 2 && means[1].high == 50 && means[2].low == nil)
    }

    @Test func monthsAndDays() {
        #expect(days.grouped(.month, adds: true, calendar: zone).map(\.value) == [70, 6])
        #expect(days.grouped(.month, adds: true, calendar: zone).map(\.day) == [T.day("2026-10-01"), T.day("2026-11-01")])
        #expect(days.grouped(.day, adds: true, calendar: zone) == days)
    }
}
