import Foundation

/// A pipeline's settings in a link, to review and save:
/// `healthdatarelay://pipeline?url=...&name=...&datatype=workouts&period=today`.
/// A link copied from another health export app uses the same parameters, so
/// `com.HealthExport://automation?...` can be pasted in too. Names are case-insensitive.
/// The app never acts on a link by itself: it fills the editor, and the user saves.
public struct PipelineLink: Sendable, Equatable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notALink
        case missing(String)
        case badValue(String, String)
        case legacyFormat

        public var description: String {
            switch self {
            case .notALink: "That isn't a pipeline link."
            case .missing(let name): "The link needs a \(name)."
            case .badValue(let name, let value): "The link's \(name) can't be \(value)."
            case .legacyFormat: "This link asks for the older v1 format, which Health Data Relay doesn't write. Its receiver needs the v2 format, so nothing was set up."
            }
        }
    }

    public static let action = "pipeline"
    /// Pasted, never registered: that scheme belongs to another app.
    public static let importedScheme = "com.healthexport"

    public var name: String
    public var web: WebTarget
    public var token: String?
    public var template: String
    public var extract: ExtractSpec
    public var trigger: PipelineTrigger
    public var enabled: Bool
    public var notices: PipelineNotices
    /// What couldn't be carried over, to show when reviewing.
    public var notes: [String] = []

    /// Whether a URL looks like one of these, right or wrong.
    public static func matches(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == SetupLink.scheme && url.host()?.lowercased() == action) || (scheme == importedScheme && url.host()?.lowercased() == "automation")
    }

    public static func parse(_ url: URL, now: Date = Date()) throws -> PipelineLink {
        guard matches(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw Failure.notALink }
        var p: [String: String] = [:]
        for item in items { p[item.name.lowercased()] = item.value ?? "" }

        func bool(_ key: String, _ fallback: Bool) throws -> Bool {
            guard let v = p[key]?.lowercased() else { return fallback }
            if ["true", "1", "yes"].contains(v) { return true }
            if ["false", "0", "no"].contains(v) { return false }
            throw Failure.badValue(key, v)
        }

        guard let address = p["url"], !address.isEmpty else { throw Failure.missing("url") }
        guard let u = URL(string: address), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host() != nil else { throw Failure.badValue("url", address) }
        guard let name = p["name"], !name.isEmpty else { throw Failure.missing("name") }

        var notes: [String] = []
        // Asked for by name: a receiver expecting v1 can't read v2, so saying no beats sending what it can't use.
        let version = p["exportversion"]?.lowercased() ?? "v2"
        if version == "v1" || version == "1" { throw Failure.legacyFormat }
        guard version == "v2" || version == "2" else { throw Failure.badValue("exportversion", version) }

        let format = p["format"]?.lowercased() ?? "json"
        let template: String
        switch format {
        case "json": template = BuiltInTemplates.metricsJSONv2
        case "csv":
            template = BuiltInTemplates.metricsCSV
            notes.append("CSV uses this app's own columns, which may differ from what the link's receiver expects.")
        default: throw Failure.badValue("format", format)
        }

        var spec = ExtractSpec(sections: [.metrics], range: .sinceLastRun, grouping: .automatic)
        switch p["datatype"]?.lowercased() ?? "healthmetrics" {
        case "healthmetrics": spec.sections = [.metrics]
        case "workouts": spec.sections = [.workouts]
        case "symptoms": spec.sections = [.symptoms]
        case "ecg": spec.sections = [.ecg]
        case "heartratenotification", "heartratenotifications": spec.sections = [.heartRateNotifications]
        case "stateofmind": spec.sections = [.stateOfMind]
        case "cycletracking": spec.sections = [.cycleTracking]
        case "medications": spec.sections = [.medications]
        case let other: throw Failure.badValue("datatype", other)
        }

        var trigger = PipelineTrigger.manual
        let quantity = p["syncquantity"].flatMap(Int.init) ?? 5
        if let text = p["syncquantity"], Int(text) ?? 0 < 1 { throw Failure.badValue("syncquantity", text) }
        if let unit = p["syncinterval"]?.lowercased() {
            switch unit {
            case "seconds": trigger = .every(Schedule(count: quantity, unit: .seconds, since: now))
            case "minutes": trigger = .every(Schedule(count: quantity, unit: .minutes, since: now))
            case "hours": trigger = .every(Schedule(count: quantity, unit: .hours, since: now))
            case "days": trigger = .every(Schedule(count: quantity, unit: .days, since: now))
            case "weeks": trigger = .every(Schedule(count: quantity, unit: .weeks, since: now))
            default: throw Failure.badValue("syncinterval", unit)
            }
        }
        switch p["period"]?.lowercased() ?? "none" {
        case "none", "lastsync": spec.range = .sinceLastRun
        case "today": spec.range = .today
        case "yesterday": spec.range = .yesterday
        case "previous7days": spec.range = .previousDays(7)
        case "realtime":
            spec.range = .sinceLastRun
            if case .every(let s) = trigger, s.unit == .seconds {} else { throw Failure.badValue("period", "realtime without syncinterval=seconds") }
        case let other: throw Failure.badValue("period", other)
        }

        switch p["interval"]?.lowercased() ?? "none" {
        case "none": break
        case let text:
            guard let grouping = TimeGrouping(rawValue: text), grouping != .automatic, grouping != .seconds else { throw Failure.badValue("interval", text) }
            spec.grouping = grouping
        }
        if p["interval"] == nil, format == "json", !(try bool("aggregatedata", false)) { spec.grouping = nil }
        if format == "csv", spec.grouping == nil { spec.grouping = .days }

        if let list = p["metrics"] {
            var chosen: [String] = []
            for raw in list.split(separator: ",") {
                let wanted = raw.trimmingCharacters(in: .whitespaces)
                if let m = Self.metric(wanted) { chosen.append(m.name) } else { notes.append("No metric called \(wanted), so it was left out.") }
            }
            spec.metrics = .only(chosen)
        }

        spec.workouts.routes = try bool("includeroutes", true)
        spec.workouts.series = try bool("includeworkoutmetadata", true)
        if let codes = p["workouttypes"] {
            spec.workouts.activityCodes = codes.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        if p["workoutsmetadatainterval"]?.lowercased() == "seconds" { notes.append("Workout series are per minute here, not per second.") }
        if try bool("batchrequests", false) { notes.append("Batched requests aren't carried over: output goes as one request unless a template splits it.") }
        if p["aggregatesleep"] != nil { notes.append("Sleep is always summarized by night when grouped by day or more.") }

        var headers: [HTTPEndpoint.Header] = []
        var token: String?
        if let text = p["headers"] {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count % 2 == 0 else { throw Failure.badValue("headers", "an odd list") }
            for i in stride(from: 0, to: parts.count, by: 2) {
                let key = parts[i].trimmingCharacters(in: .whitespaces)
                let value = parts[i + 1].trimmingCharacters(in: .whitespaces)
                // A bearer token belongs in the Keychain, not in saved settings.
                if key.lowercased() == "authorization", value.lowercased().hasPrefix("bearer ") {
                    token = String(value.dropFirst(7))
                } else {
                    headers.append(.init(name: key, value: value))
                }
            }
        }
        var timeout: TimeInterval = 60
        if let text = p["requesttimeout"] {
            guard let n = Int(text), (60...86400).contains(n) else { throw Failure.badValue("requesttimeout", text) }
            timeout = TimeInterval(n)
        }

        return PipelineLink(name: name, web: WebTarget(url: address, headers: headers, timeout: timeout), token: token, template: template, extract: spec, trigger: trigger,
                            enabled: try bool("enabled", false), notices: PipelineNotices(onFailure: try bool("notifyonupdate", true), onSuccess: try bool("notifywhenrun", true)), notes: notes)
    }

    /// `step_count`, `Step Count` and `Steps` all find the same metric.
    static func metric(_ text: String) -> Metric? {
        let key = text.lowercased().replacingOccurrences(of: "_", with: " ")
        return MetricCatalog.metrics.first { $0.name.replacingOccurrences(of: "_", with: " ") == key || $0.title.lowercased() == key }
    }
}

/// `healthdatarelay://run?pipeline=<id>&key=<key>`, from the app's own widget. The
/// key is random and private to this phone, so another app can't trigger a send.
public struct RunLink: Sendable, Equatable {
    public static let action = "run"
    public var pipeline: UUID
    public var key: String

    public init(pipeline: UUID, key: String) {
        self.pipeline = pipeline
        self.key = key
    }

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == SetupLink.scheme, url.host()?.lowercased() == Self.action,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "pipeline" })?.value.flatMap(UUID.init(uuidString:)),
              let key = items.first(where: { $0.name == "key" })?.value else { return nil }
        self.init(pipeline: id, key: key)
    }

    public var url: URL {
        URL(string: "\(SetupLink.scheme)://\(Self.action)?pipeline=\(pipeline.uuidString)&key=\(key)")!
    }
}

/// What a widget shows, written by the app to its shared folder. A widget can't
/// read Health or the app's state, and this is all it needs.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct PipelineRow: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        /// "Last run finished", "Needs attention" and so on.
        public var state: String
        public var needsAttention: Bool
        /// When a schedule comes due; nil for one you tap.
        public var nextRun: Date?
        public var lastSuccess: Date?
        /// Opens the app and runs it.
        public var runLink: URL?

        public init(id: UUID, name: String, state: String, needsAttention: Bool, nextRun: Date?, lastSuccess: Date?, runLink: URL?) {
            self.id = id
            self.name = name
            self.state = state
            self.needsAttention = needsAttention
            self.nextRun = nextRun
            self.lastSuccess = lastSuccess
            self.runLink = runLink
        }
    }

    public struct Value: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var title: String
        public var text: String
        public var id: String { name }

        public init(name: String, title: String, text: String) {
            self.name = name
            self.title = title
            self.text = text
        }
    }

    public var updatedAt: Date
    public var pipelines: [PipelineRow]
    /// Today so far.
    public var values: [Value]

    public init(updatedAt: Date, pipelines: [PipelineRow], values: [Value]) {
        self.updatedAt = updatedAt
        self.pipelines = pipelines
        self.values = values
    }

    public static let appGroup = "group.com.patsissons.healthdatarelay"
    public static let fileName = "widget.json"

    /// The metrics a widget shows.
    public static let metricNames = ["step_count", "active_energy", "apple_exercise_time", "resting_heart_rate", "sleep_analysis", "weight_body_mass"]

    public static var sharedFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    public static func read(from url: URL? = sharedFile) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func write(to url: URL? = sharedFile) {
        guard var url, let data = try? JSONEncoder().encode(self) else { return }
        // Readable while locked, or a widget would go blank: it's only a summary a person chose to put on their Home Screen.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // It holds health values, so it stays out of backups like the app's own
        // storage. An atomic write makes a new file, so this is set every time.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
