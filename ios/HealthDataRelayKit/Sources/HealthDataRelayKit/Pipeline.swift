import Foundation

/// When a pipeline runs.
public enum PipelineTrigger: Codable, Sendable, Equatable {
    /// Only when the user taps Run.
    case manual
    /// When Health records new data, each morning, and on coming to the
    /// foreground if the last success is old (docs/design.md, When to sync).
    case whenHealthChanges
    case every(Schedule)
}

/// A repeating schedule: due this long after the last run. iOS decides when
/// background work happens, so "due" is the earliest it can run.
public struct Schedule: Codable, Sendable, Equatable {
    public enum Unit: String, Codable, Sendable, CaseIterable {
        case minutes, hours, days, weeks

        var seconds: TimeInterval {
            switch self {
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

    public func next(after last: Date?) -> Date {
        (last ?? since).addingTimeInterval(interval)
    }
}

/// How a pipeline turns what it extracted into what it delivers. The native
/// push is the schema (docs/schema.md), built in memory one batch at a time.
public enum TransformSpec: Sendable, Equatable {
    case healthDataRelayPush
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
    }

    public var destination: Destination
    public var lane: Lane
    public var hasToken: Bool
    public var trigger: PipelineTrigger
    public var activity: Activity

    public var id: UUID { destination.id }
    public var name: String { destination.name }
    public var extract: ExtractSpec { .changedDays }
    public var transform: TransformSpec { .healthDataRelayPush }

    public var endpoint: HTTPEndpoint {
        switch destination.kind {
        case .http(let endpoint): endpoint
        }
    }

    public func timing(now: Date) -> Timing {
        switch trigger {
        case .manual:
            return .whenTapped
        case .whenHealthChanges:
            return .whenHealthChanges
        case .every(let schedule):
            let next = schedule.next(after: lane.lastRun)
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
            case .every(let schedule):
                plan.observesHealth = true
                guard !d.paused else { continue }
                let next = schedule.next(after: lanes[d.id]?.lastRun)
                plan.nextRun = plan.nextRun.map { min($0, next) } ?? next
            }
        }
        return plan
    }
}
