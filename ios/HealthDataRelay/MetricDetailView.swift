import Charts
import HealthDataRelayKit
import SwiftUI

/// One metric in full: a chart to read values off, how it compares with the
/// period before, its numbers, and each day.
struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    let name: String
    let charts: ChartsModel
    @Binding var pins: [String]
    @State private var grouping = SeriesGrouping.day
    @State private var comparing = false
    @State private var selected: Date?
    @State private var unlocking = false

    private var metric: Metric? { MetricCatalog.metric(named: name) }
    private var series: MetricSeries? { charts.series(named: name) }
    private let calendar = Calendar.local()

    var body: some View {
        List {
            Section {
                RangePicker(charts: charts, unlocking: $unlocking)
            }
            if let series {
                Section {
                    header(series)
                    chart(series)
                        .frame(height: 240)
                        .accessibilityIdentifier("chart")
                    if charts.days > 14 {
                        Picker("Group by", selection: $grouping) {
                            Text("Day").tag(SeriesGrouping.day)
                            Text("Week").tag(SeriesGrouping.week)
                            if charts.days > 60 { Text("Month").tag(SeriesGrouping.month) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("chart-grouping")
                    }
                    if series.previous != nil {
                        Toggle("Show the \(ChartFormat.rangeTitle(charts.days)) before", isOn: $comparing)
                            .accessibilityIdentifier("chart-compare")
                    }
                }
                Section("Summary") {
                    if let total = series.summary.total {
                        LabeledContent("Total", value: value(total, series))
                    }
                    LabeledContent("Average", value: "\(value(series.summary.average, series)) a day")
                    LabeledContent("Highest", value: "\(value(series.summary.max, series)) · \(ChartFormat.date(series.summary.maxDay))")
                    LabeledContent("Lowest", value: "\(value(series.summary.min, series)) · \(ChartFormat.date(series.summary.minDay))")
                    LabeledContent("Days with data", value: "\(series.summary.daysWithData) of \(series.summary.days)")
                }
                if let previous = series.previous {
                    Section("Against the \(ChartFormat.rangeTitle(charts.days)) before") {
                        if let change = series.change {
                            LabeledContent("Daily average", value: ChartFormat.change(change))
                                .accessibilityIdentifier("chart-change")
                        }
                        LabeledContent("Average then", value: "\(value(previous.average, series)) a day")
                        if let total = previous.total {
                            LabeledContent("Total then", value: value(total, series))
                        }
                    }
                }
                Section("Each day") {
                    ForEach(series.days.reversed()) { day in
                        LabeledContent(ChartFormat.date(day.day), value: dayText(day, series))
                    }
                }
            } else if charts.loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ContentUnavailableView("No data", systemImage: "chart.xyaxis.line",
                                       description: Text("Nothing for \(metric?.title ?? "this") in the last \(ChartFormat.rangeTitle(charts.days))."))
            }
        }
        .navigationTitle(metric?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if pins.contains(name) { pins.removeAll { $0 == name } } else { pins.append(name) }
                } label: {
                    Label(pins.contains(name) ? "Unpin" : "Pin", systemImage: pins.contains(name) ? "pin.fill" : "pin")
                }
                .accessibilityIdentifier("chart-pin")
            }
        }
        .sheet(isPresented: $unlocking) { UnlockView() }
        .onChange(of: charts.days) { _, days in
            if days <= 14 || (days <= 60 && grouping == .month) { grouping = .day }
            selected = nil
        }
    }

    // MARK: Chart

    private func points(_ series: MetricSeries) -> [DayValue] {
        series.days.grouped(grouping, adds: series.adds, calendar: calendar)
    }

    /// The period before, moved forward to sit under this one.
    private func earlier(_ series: MetricSeries) -> [DayValue] {
        let shift = series.summary.days
        return series.previousDays.map { DayValue(day: $0.day.adding(shift), value: $0.value) }
            .grouped(grouping, adds: series.adds, calendar: calendar)
    }

    private var unit: Calendar.Component {
        switch grouping {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// The point nearest where a finger is.
    private func picked(_ series: MetricSeries) -> DayValue? {
        guard let selected else { return nil }
        return points(series).min { abs($0.day.start(in: calendar).timeIntervalSince(selected)) < abs($1.day.start(in: calendar).timeIntervalSince(selected)) }
    }

    @ViewBuilder private func header(_ series: MetricSeries) -> some View {
        let picked = picked(series)
        VStack(alignment: .leading, spacing: 2) {
            Text(picked.map { ChartFormat.date($0.day, grouping: grouping) } ?? (series.adds ? "Total, last \(ChartFormat.rangeTitle(charts.days))" : "Daily average, last \(ChartFormat.rangeTitle(charts.days))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(picked.map { ChartFormat.number($0.value) } ?? ChartFormat.number(series.headline))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text(series.unit)
                    .foregroundStyle(.secondary)
                if let picked, let low = picked.low, let high = picked.high, low != high {
                    Text("\(ChartFormat.number(low))–\(ChartFormat.number(high))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chart-reading")
    }

    @ViewBuilder private func chart(_ series: MetricSeries) -> some View {
        let now = points(series)
        let before = comparing ? earlier(series) : []
        Chart {
            ForEach(before) { p in
                if series.adds {
                    BarMark(x: .value("Date", p.day.start(in: calendar), unit: unit), y: .value("Before", p.value))
                        .foregroundStyle(.gray.opacity(0.35))
                        .position(by: .value("Period", "Before"))
                } else {
                    LineMark(x: .value("Date", p.day.start(in: calendar)), y: .value("Before", p.value), series: .value("Period", "Before"))
                        .foregroundStyle(.gray)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                }
            }
            ForEach(now) { p in
                if series.adds {
                    BarMark(x: .value("Date", p.day.start(in: calendar), unit: unit), y: .value(series.title, p.value))
                        .foregroundStyle(Color.accentColor)
                        .position(by: .value("Period", "Now"))
                } else {
                    if let low = p.low, let high = p.high, low != high {
                        AreaMark(x: .value("Date", p.day.start(in: calendar)), yStart: .value("Low", low), yEnd: .value("High", high))
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                    }
                    LineMark(x: .value("Date", p.day.start(in: calendar)), y: .value(series.title, p.value), series: .value("Period", "Now"))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Date", p.day.start(in: calendar)), y: .value(series.title, p.value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(now.count > 45 ? 0 : 24)
                }
            }
            if grouping == .day {
                RuleMark(y: .value("Average", series.summary.average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("avg \(ChartFormat.number(series.summary.average))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let picked = picked(series) {
                RuleMark(x: .value("Date", mid(picked.day)))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: .automatic(includesZero: series.adds))
        // The whole range, so days with nothing recorded show as gaps.
        .chartXScale(domain: span(series))
        .chartXSelection(value: $selected)
        .chartLegend(.hidden)
    }

    /// From the first day of the range to the end of today.
    private func span(_ series: MetricSeries) -> ClosedRange<Date> {
        let today = Day(.now, calendar: calendar)
        return today.adding(1 - series.summary.days).start(in: calendar)...today.adding(1).start(in: calendar)
    }

    /// The middle of a bar, or a point's own instant.
    private func mid(_ day: Day) -> Date {
        let start = day.start(in: calendar)
        guard series?.adds == true, let end = calendar.date(byAdding: unit, value: 1, to: start) else { return start }
        return start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }

    private func value(_ number: Double, _ series: MetricSeries) -> String {
        "\(ChartFormat.number(number)) \(series.unit)"
    }

    private func dayText(_ day: DayValue, _ series: MetricSeries) -> String {
        if series.form == Metric.Form.bloodPressure.rawValue, let low = day.low {
            return "\(ChartFormat.number(day.value))/\(ChartFormat.number(low)) \(series.unit)"
        }
        if let low = day.low, let high = day.high, low != high {
            return "\(ChartFormat.number(low))–\(ChartFormat.number(high)), avg \(value(day.value, series))"
        }
        return value(day.value, series)
    }
}

/// The days Charts covers. A range longer than the plan's history reaches
/// stays where it was and opens the plans.
struct RangePicker: View {
    @Environment(AppModel.self) private var model
    let charts: ChartsModel
    @Binding var unlocking: Bool

    var body: some View {
        Picker("Range", selection: Binding {
            charts.days
        } set: { days in
            if model.store.access.history.allows(lastDays: days) {
                charts.days = days
                charts.load(from: model)
            } else {
                unlocking = true
            }
        }) {
            ForEach(ChartsModel.ranges, id: \.self) { Text(ChartFormat.rangeTitle($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chart-range")
        if let cap = model.store.access.history.days {
            Button {
                unlocking = true
            } label: {
                Label("Reaches back \(cap) days until you unlock Full", systemImage: "lock.fill")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("chart-needs-full")
        }
    }
}
