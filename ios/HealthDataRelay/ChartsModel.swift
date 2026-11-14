import HealthDataRelayKit
import Observation
import SwiftUI

/// What the Charts tab shows: every metric with data over the chosen days,
/// read once and kept while the range, the plan and the day stay the same.
@MainActor @Observable
final class ChartsModel {
    static let ranges = [7, 30, 90, 365]

    /// Days the overview and each metric's screen cover.
    var days = 7
    /// In catalog order, filling in as each metric is read.
    private(set) var series: [MetricSeries] = []
    private(set) var loading = false
    private var loaded: String?
    private var task: Task<Void, Never>?

    private static let order = Dictionary(uniqueKeysWithValues: MetricCatalog.metrics.enumerated().map { ($1.name, $0) })

    func series(named name: String) -> MetricSeries? {
        series.first { $0.name == name }
    }

    /// Reads again when something it depends on changed, or when asked to.
    func load(from model: AppModel, force: Bool = false) {
        // Full opens on a month; the trial and free on the week they can read.
        if loaded == nil, model.store.access.history.allows(lastDays: 30) { days = 30 }
        let key = "\(days)|\(model.store.access.history.days ?? 0)|\(Day(.now, calendar: .local()))"
        guard force || key != loaded else { return }
        loaded = key
        task?.cancel()
        series = []
        loading = true
        let stream = model.chartSeries(days: days)
        task = Task {
            for await one in stream {
                if Task.isCancelled { return }
                insert(one)
            }
            if !Task.isCancelled { loading = false }
        }
    }

    /// Waits for the read under way, for pull to refresh.
    func finish() async {
        await task?.value
    }

    private func insert(_ one: MetricSeries) {
        let rank = Self.order[one.name] ?? .max
        let at = series.firstIndex { (Self.order[$0.name] ?? .max) > rank } ?? series.count
        series.insert(one, at: at)
    }
}

/// Numbers as the charts write them: no more digits than mean anything.
enum ChartFormat {
    static func number(_ value: Double) -> String {
        let size = abs(value)
        let digits = size >= 100 ? 0 : (size >= 10 ? 1 : 2)
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    /// "+12%", "-3%", or "No change".
    static func change(_ fraction: Double) -> String {
        let percent = (fraction * 100).rounded()
        if percent == 0 { return "No change" }
        return "\(percent > 0 ? "+" : "")\(Int(percent))%"
    }

    static func rangeTitle(_ days: Int) -> String {
        days == 365 ? "1 year" : "\(days) days"
    }

    static func date(_ day: Day, grouping: SeriesGrouping = .day) -> String {
        let date = day.start(in: .local())
        switch grouping {
        case .day: return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: return "Week of \(date.formatted(.dateTime.month(.abbreviated).day()))"
        case .month: return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

extension Metric.Group {
    var title: String {
        switch self {
        case .activity: "Activity"
        case .mobility: "Mobility"
        case .heart: "Heart"
        case .respiratory: "Respiratory"
        case .body: "Body"
        case .hearing: "Hearing"
        case .sleep: "Sleep"
        case .nutrition: "Nutrition"
        case .medical: "Medical"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "flame.fill"
        case .mobility: "figure.walk"
        case .heart: "heart.fill"
        case .respiratory: "lungs.fill"
        case .body: "figure"
        case .hearing: "ear.fill"
        case .sleep: "bed.double.fill"
        case .nutrition: "fork.knife"
        case .medical: "cross.case.fill"
        case .other: "square.grid.2x2.fill"
        }
    }
}
