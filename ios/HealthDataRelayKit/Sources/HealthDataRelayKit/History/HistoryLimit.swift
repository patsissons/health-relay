import Foundation
import os

/// How far back Health may be read. Until someone buys Full it is the seven
/// days before today plus today so far, and twice that only to compare a
/// window with the one before it. Held as days, not a date, so it stays right
/// when midnight passes or the time zone changes while the app is open.
public struct HistoryLimit: Sendable, Equatable, Codable {
    /// Days before today that may be read; nil is all of them.
    public var days: Int?
    /// The same when the older half is only being compared against.
    public var comparisonDays: Int?

    public init(days: Int?, comparisonDays: Int?) {
        self.days = days
        self.comparisonDays = comparisonDays
    }

    public static let unlimited = HistoryLimit(days: nil, comparisonDays: nil)
    public static let capped = HistoryLimit(days: 7, comparisonDays: 14)

    public var isCapped: Bool { days != nil }

    /// The oldest day that may be read; nil when there's no limit.
    public func firstDay(now: Date, calendar: Calendar, comparison: Bool = false) -> Day? {
        guard let n = comparison ? (comparisonDays ?? days) : days else { return nil }
        return Day(now, calendar: calendar).adding(-max(0, n))
    }

    /// Local midnight at the start of `firstDay`.
    public func floor(now: Date, calendar: Calendar, comparison: Bool = false) -> Date? {
        firstDay(now: now, calendar: calendar, comparison: comparison)?.start(in: calendar)
    }

    /// The part of a range that may be read; nil when none of it may.
    public func clamp(_ range: DateInterval, now: Date, calendar: Calendar, comparison: Bool = false) -> DateInterval? {
        guard let floor = floor(now: now, calendar: calendar, comparison: comparison) else { return range }
        return HistoryLimit.clip(range, to: floor)
    }

    /// A range cut to start no earlier than `floor`; nil when it ends by then.
    public static func clip(_ range: DateInterval, to floor: Date) -> DateInterval? {
        if range.start >= floor { return range }
        guard range.end > floor else { return nil }
        return DateInterval(start: floor, end: range.end)
    }

    /// Whether "the last n days" fits.
    public func allows(lastDays n: Int) -> Bool {
        days.map { n <= $0 } ?? true
    }

    /// Whether a saved range asks for more than may be read, so a run sends less.
    public func exceeds(_ range: RangeSpec, now: Date, calendar: Calendar) -> Bool {
        guard let floor = floor(now: now, calendar: calendar) else { return false }
        switch range {
        case .previousDays(let n), .lastDays(let n): return !allows(lastDays: n)
        case .fixed(let interval): return interval.start < floor
        case .changedDays, .sinceLastRun, .today, .yesterday, .askAtRun: return false
        }
    }
}

/// The limit in force, shared by everything that reads Health and changed
/// when a plan is bought or runs out.
public final class HistoryLimitBox: Sendable {
    private let value: OSAllocatedUnfairLock<HistoryLimit>

    public init(_ limit: HistoryLimit = .unlimited) {
        value = OSAllocatedUnfairLock(initialState: limit)
    }

    public var limit: HistoryLimit {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// What the engine may do, from what was paid for (see `Access`).
public struct EnginePolicy: Sendable, Equatable {
    /// Off: nothing runs by itself, though triggers stay saved.
    public var automation: Bool
    /// Off: a tap doesn't run a pipeline either.
    public var manualRuns: Bool
    public var history: HistoryLimit

    public init(automation: Bool = true, manualRuns: Bool = true, history: HistoryLimit = .unlimited) {
        self.automation = automation
        self.manualRuns = manualRuns
        self.history = history
    }

    public static let unrestricted = EnginePolicy()
}

extension Access {
    /// Trial and free read the last seven days; Full reads everything.
    public var history: HistoryLimit {
        if case .full = self { return .unlimited }
        return .capped
    }

    /// Running a pipeline at all, by a tap or by itself.
    public var allowsPipelineRuns: Bool { !isFree }
    /// Making a report. Ones already made stay readable.
    public var allowsReports: Bool { !isFree }

    public var enginePolicy: EnginePolicy {
        EnginePolicy(automation: allowsAutomation, manualRuns: allowsPipelineRuns, history: history)
    }
}

/// Reads Health no further back than the limit allows, whatever is asked.
/// Ranges are cut before a run is planned, so this is the backstop for reads
/// that widen afterwards: a week, month or year bucket grown to its whole
/// length, late samples, and a workout's heart rate.
public struct CappedHealthQuerying: HealthQuerying {
    public enum Scope: Sendable {
        case standard
        /// Reaches the older window too, for a report's comparison.
        case comparison
    }

    static let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"

    private let base: any HealthQuerying
    private let box: HistoryLimitBox
    private let scope: Scope
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date

    public init(_ base: any HealthQuerying, box: HistoryLimitBox, scope: Scope = .standard,
                calendar: @escaping @Sendable () -> Calendar = { .local() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.box = box
        self.scope = scope
        self.calendar = calendar
        self.now = now
    }

    private var floor: Date? {
        box.limit.floor(now: now(), calendar: calendar(), comparison: scope == .comparison)
    }

    private func clip(_ range: DateInterval, early: TimeInterval = 0) -> DateInterval? {
        guard let floor else { return range }
        return HistoryLimit.clip(range, to: floor.addingTimeInterval(-early))
    }

    public func requestAuthorization(types: [HealthType], extras: ReadExtras) async throws {
        try await base.requestAuthorization(types: types, extras: extras)
    }

    public func buckets(_ query: BucketQuery) async throws -> [StatBucket] {
        guard let floor else { return try await base.buckets(query) }
        guard query.plan.span.end > floor else { return [] }
        var query = query
        query.from = max(query.from ?? floor, floor)
        return try await base.buckets(query)
    }

    public func quantityPage(_ type: String, unit: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedQuantity> {
        guard let range = clip(range) else { return SamplePage(items: [], next: nil) }
        return try await base.quantityPage(type, unit: unit, in: range, after: cursor, limit: limit)
    }

    public func categoryPage(_ type: String, in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<DetailedCategory> {
        // A night starts the evening before the day it's counted on.
        guard let range = clip(range, early: type == Self.sleepType ? 86400 : 0) else { return SamplePage(items: [], next: nil) }
        return try await base.categoryPage(type, in: range, after: cursor, limit: limit)
    }

    public func sources(of type: HealthType) async throws -> [String] {
        try await base.sources(of: type)
    }

    public func workoutPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<WorkoutDetail> {
        guard let range = clip(range) else { return SamplePage(items: [], next: nil) }
        return try await base.workoutPage(in: range, after: cursor, limit: limit)
    }

    public func routePage(workoutID: String, after cursor: Int?, limit: Int) async throws -> (points: [RoutePoint], next: Int?) {
        try await base.routePage(workoutID: workoutID, after: cursor, limit: limit)
    }

    public func ecgPage(in range: DateInterval, after cursor: PageCursor?, limit: Int) async throws -> SamplePage<ECGDetail> {
        guard let range = clip(range) else { return SamplePage(items: [], next: nil) }
        return try await base.ecgPage(in: range, after: cursor, limit: limit)
    }

    public func voltages(ecgID: String) async throws -> [Double] {
        try await base.voltages(ecgID: ecgID)
    }

    public func heartbeats(in range: DateInterval) async throws -> [HeartbeatSeries] {
        guard let range = clip(range) else { return [] }
        return try await base.heartbeats(in: range)
    }

    public func statesOfMind(in range: DateInterval) async throws -> [StateOfMindRecord] {
        guard let range = clip(range) else { return [] }
        return try await base.statesOfMind(in: range)
    }

    public func medicationDoses(in range: DateInterval) async throws -> [MedicationDose] {
        guard let range = clip(range) else { return [] }
        return try await base.medicationDoses(in: range)
    }

    public func additions(_ type: HealthType, anchor: Data?, since: Date) async throws -> Changes {
        guard let floor else { return try await base.additions(type, anchor: anchor, since: since) }
        var changes = try await base.additions(type, anchor: anchor, since: max(since, floor))
        changes.added = changes.added.filter { $0.end > floor }
        return changes
    }
}
