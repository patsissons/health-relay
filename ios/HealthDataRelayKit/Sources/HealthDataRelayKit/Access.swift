import Foundation

/// What the user has paid for. Free keeps Export and Charts. Trial and Full
/// add pipelines, by a tap or by themselves, Shortcuts and widget runs, the
/// server, and your own templates. Only Full reads further back than the
/// last seven days (see `HistoryLimit`).
public enum Access: Sendable, Equatable, Codable {
    case free
    case trial(endsAt: Date)
    case full(Plan)

    public enum Plan: String, Sendable, Codable {
        case monthly, yearly, lifetime
    }

    public static let trialLength: TimeInterval = 7 * 86400

    /// A purchase wins over the trial; a trial past its seven days is free.
    /// A subscription counts only while StoreKit says it is current.
    public static func resolve(lifetime: Bool, subscription: Plan?, trialStartedAt: Date?, now: Date) -> Access {
        if lifetime { return .full(.lifetime) }
        if let subscription { return .full(subscription) }
        if let start = trialStartedAt {
            let end = start.addingTimeInterval(trialLength)
            if now < end { return .trial(endsAt: end) }
        }
        return .free
    }

    /// When the trial began: the first download on this Apple ID, from the
    /// App Store. TestFlight and the sandbox (where App Review tests) give a
    /// fixed 2013 date, and an offline launch gives none, so there the first
    /// launch on this device counts instead.
    public static func trialStart(firstDownload: Date?, fromAppStore: Bool, firstLaunch: Date) -> Date {
        if fromAppStore, let firstDownload { return firstDownload }
        return firstLaunch
    }

    public var isFree: Bool { self == .free }

    /// Automatic triggers, background runs, Shortcuts and widget runs.
    public var allowsAutomation: Bool { !isFree }
    /// The local MCP and HTTP server.
    public var allowsServer: Bool { !isFree }
    /// Writing and editing templates; the built-in ones are always free.
    public var allowsCustomTemplates: Bool { !isFree }

    /// Whole days left in the trial, rounded up, so the last day reads 1.
    public func trialDaysLeft(now: Date) -> Int? {
        guard case .trial(let end) = self else { return nil }
        return max(0, Int((end.timeIntervalSince(now) / 86400).rounded(.up)))
    }
}
