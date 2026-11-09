import Foundation

/// When a pipeline runs.
public enum PipelineTrigger: Codable, Sendable, Equatable {
    /// Only when the user taps Run.
    case manual
    /// When Health records new data, each morning, and on coming to the
    /// foreground if the last success is old (docs/design.md, When to sync).
    case whenHealthChanges
    case every(Schedule)
    /// At a time of day, on chosen days.
    case at(TimeOfDay)

    /// When a time-based trigger next comes due; nil for the others.
    public func next(after last: Date?, calendar: Calendar = .current) -> Date? {
        switch self {
        case .manual, .whenHealthChanges: nil
        case .every(let schedule): schedule.next(after: last)
        case .at(let time): time.next(after: last, calendar: calendar)
        }
    }
}

/// A time of day. iOS still decides when background work happens, so this is
/// the earliest a run can start. A time the clocks skip runs just after.
public struct TimeOfDay: Codable, Sendable, Equatable {
    public var hour: Int
    public var minute: Int
    /// 1 is Sunday, as `Calendar` counts them. Nil is every day.
    public var weekdays: [Int]?
    /// When it was set, so a time already past today isn't due at once.
    public var since: Date

    public init(hour: Int, minute: Int, weekdays: [Int]? = nil, since: Date) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.since = since
    }

    public func next(after last: Date?, calendar: Calendar) -> Date {
        let from = max(last ?? since, since)
        func following(_ weekday: Int?) -> Date {
            var c = DateComponents(hour: hour, minute: minute, second: 0)
            c.weekday = weekday
            return calendar.nextDate(after: from, matching: c, matchingPolicy: .nextTime) ?? from.addingTimeInterval(86400)
        }
        guard let weekdays, !weekdays.isEmpty else { return following(nil) }
        return weekdays.map(following).min()!
    }
}

/// A repeating schedule: due this long after the last run. iOS decides when
/// background work happens, so "due" is the earliest it can run.
public struct Schedule: Codable, Sendable, Equatable {
    public enum Unit: String, Codable, Sendable, CaseIterable {
        /// Only while the app is open: iOS has no background work this often.
        case seconds
        case minutes, hours, days, weeks

        var seconds: TimeInterval {
            switch self {
            case .seconds: 1
            case .minutes: 60
            case .hours: 3600
            case .days: 86400
            case .weeks: 7 * 86400
            }
        }
    }

    public var count: Int
    public var unit: Unit
    /// When the schedule was set: the first run is one interval after this.
    public var since: Date

    public init(count: Int, unit: Unit, since: Date) {
        self.count = max(1, count)
        self.unit = unit
        self.since = since
    }

    public var interval: TimeInterval { Double(count) * unit.seconds }

    /// Whether it needs the app open to keep time.
    public var isForegroundOnly: Bool { interval < 60 }

    public func next(after last: Date?) -> Date {
        (last ?? since).addingTimeInterval(interval)
    }
}

/// How a pipeline turns what it extracted into what it delivers. The native
/// push is the schema (docs/schema.md), built in memory one batch at a time.
public enum TransformSpec: Sendable, Equatable {
    case healthDataRelayPush
    case template(TemplateRef, name: String)
}

/// One pipeline as the screens show it: Extract, Transform, Load and a
/// Trigger. Its destination is its load target, and its id is the
/// destination's, so a token, lane and log saved before pipelines existed
/// are its own.
public struct Pipeline: Sendable, Identifiable, Equatable {
    public enum Activity: Sendable, Equatable {
        case idle
        /// Waiting for the run in progress to finish.
        case queued
        case running
    }

    /// Why a due pipeline has not run yet.
    public enum Due: Sendable, Equatable {
        case waitingForIOS
        case unlockIPhone
    }

    /// When it will run next.
    public enum Timing: Sendable, Equatable {
        case whenTapped
        case whenHealthChanges
        case next(Date)
        case due(Due)
        /// Set to run by itself, but the free tier only runs it when tapped.
        case needsFullAccess
    }

    public var destination: Destination
    public var lane: Lane
    public var hasToken: Bool
    public var trigger: PipelineTrigger
    public var activity: Activity

    public init(destination: Destination, lane: Lane, hasToken: Bool, trigger: PipelineTrigger, activity: Activity, definition: PipelineDefinition? = nil) {
        self.destination = destination
        self.lane = lane
        self.hasToken = hasToken
        self.trigger = trigger
        self.activity = activity
        self.definition = definition
    }

    public var id: UUID { destination.id }
    public var name: String { destination.name }
    /// Set for a template pipeline; nil for the native push.
    public var definition: PipelineDefinition?
    /// False on the free tier, where only a tap runs a pipeline.
    public var automatic = true
    public var extract: ExtractSpec { definition?.extract ?? .changedDays }

    public var transform: TransformSpec {
        definition.map { .template($0.template, name: $0.templateName) } ?? .healthDataRelayPush
    }

    /// Where it sends, for the screens.
    public var destinationSummary: String {
        switch destination.kind {
        case .http(let endpoint): endpoint.url.host() ?? ""
        case .target(let target): target.summary
        }
    }

    public var endpoint: HTTPEndpoint? {
        if case .http(let endpoint) = destination.kind { return endpoint }
        return nil
    }

    public func timing(now: Date) -> Timing {
        if !automatic, trigger != .manual { return .needsFullAccess }
        switch trigger {
        case .manual:
            return .whenTapped
        case .whenHealthChanges:
            return .whenHealthChanges
        case .every, .at:
            let next = trigger.next(after: lane.lastRun) ?? now
            if next > now { return .next(next) }
            return .due(lane.lastMessage == Engine.lockedMessage ? .unlockIPhone : .waitingForIOS)
        }
    }
}

/// "3h 12m 05s": seconds always, larger units once they are not zero.
public enum Countdown {
    public static func text(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let (days, hours, minutes, seconds) = (total / 86400, total % 86400 / 3600, total % 3600 / 60, total % 60)
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if days > 0 { return "\(days)d \(hours)h \(pad(minutes))m \(pad(seconds))s" }
        if hours > 0 { return "\(hours)h \(pad(minutes))m \(pad(seconds))s" }
        if minutes > 0 { return "\(minutes)m \(pad(seconds))s" }
        return "\(seconds)s"
    }
}

/// What the platform has to be asked for so pipelines run unattended.
public struct BackgroundPlan: Sendable, Equatable {
    /// Whether to register for Health's change notifications.
    public var observesHealth = false
    /// Whether to ask for the daily catch-up.
    public var dailyCatchUp = false
    /// The soonest a scheduled pipeline comes due.
    public var nextRun: Date?
    /// The soonest one iOS could run in the background: not a schedule of seconds.
    public var backgroundRun: Date?
    /// A template pipeline is scheduled: its output can take longer than a
    /// refresh allows, so ask for processing time too.
    public var wantsLongRun = false

    public init() {}
}

extension EngineState {
    /// A pipeline's trigger. One saved before triggers existed follows the
    /// old global setting, which keeps its behaviour exactly.
    public func trigger(for id: UUID) -> PipelineTrigger {
        triggers?[id] ?? (autoSync == true ? .whenHealthChanges : .manual)
    }

    public var backgroundPlan: BackgroundPlan {
        var plan = BackgroundPlan()
        for d in destinations {
            switch trigger(for: d.id) {
            case .manual:
                break
            case .whenHealthChanges:
                plan.observesHealth = true
                plan.dailyCatchUp = true
            case .every, .at:
                let t = trigger(for: d.id)
                plan.observesHealth = true
                guard !d.paused, let next = t.next(after: lanes[d.id]?.lastRun) else { continue }
                plan.nextRun = plan.nextRun.map { min($0, next) } ?? next
                if case .every(let schedule) = t, schedule.isForegroundOnly { continue }
                plan.backgroundRun = plan.backgroundRun.map { min($0, next) } ?? next
                if definitions?[d.id] != nil { plan.wantsLongRun = true }
            }
        }
        return plan
    }
}
