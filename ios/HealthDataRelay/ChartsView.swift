import Charts
import HealthDataRelayKit
import SwiftUI

/// A metric over time. Everything is read when asked for, and nothing is sent.
struct ChartsView: View {
    @Environment(AppModel.self) private var model
    @State private var metricName = "step_count"
    @State private var days = 30
    @State private var points: [ChartPoint]?

    private var metric: Metric? { MetricCatalog.metric(named: metricName) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Metric", selection: $metricName) {
                        ForEach(Metric.Group.allCases, id: \.self) { group in
                            Section(String(describing: group).capitalized) {
                                ForEach(MetricCatalog.metrics.filter { $0.group == group }) { Text($0.title).tag($0.name) }
                            }
                        }
                    }
                    .accessibilityIdentifier("chart-metric")
                    Picker("Range", selection: $days) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("chart-range")
                }
                Section {
                    if let points {
                        if points.isEmpty {
                            ContentUnavailableView("No data", systemImage: "chart.xyaxis.line", description: Text("Nothing for this metric in this range. You may need to allow it in Settings › Values by day."))
                        } else {
                            chart(points)
                                .frame(height: 240)
                                .accessibilityIdentifier("chart")
                            summary(points)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
            }
            .navigationTitle("Charts")
            .task(id: "\(metricName)|\(days)") {
                points = nil
                points = await model.chartPoints(metric: metricName, days: days)
            }
        }
    }

    @ViewBuilder private func chart(_ points: [ChartPoint]) -> some View {
        Chart(points) { p in
            if metric?.form == .total || metric?.form == .eventCount || metric?.form == .eventMinutes {
                BarMark(x: .value("Date", p.date, unit: .day), y: .value(metric?.title ?? "", p.value))
            } else {
                if let low = p.low, let high = p.high {
                    AreaMark(x: .value("Date", p.date), yStart: .value("Low", low), yEnd: .value("High", high))
                        .opacity(0.2)
                }
                LineMark(x: .value("Date", p.date), y: .value(metric?.title ?? "", p.value))
                PointMark(x: .value("Date", p.date), y: .value(metric?.title ?? "", p.value))
                    .symbolSize(points.count > 60 ? 0 : 24)
            }
        }
    }

    @ViewBuilder private func summary(_ points: [ChartPoint]) -> some View {
        let values = points.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)
        LabeledContent("Average", value: "\(average.formatted(.number.precision(.fractionLength(0...1)))) \(points[0].units)")
        LabeledContent("Lowest", value: (values.min() ?? 0).formatted(.number.precision(.fractionLength(0...1))))
        LabeledContent("Highest", value: (values.max() ?? 0).formatted(.number.precision(.fractionLength(0...1))))
    }
}

struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var low: Double?
    var high: Double?
    let units: String

    var id: Date { date }
}
