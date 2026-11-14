import Charts
import HealthDataRelayKit
import SwiftUI

/// Every metric Health has data for, at a glance: what it came to over the
/// chosen days, how that compares with the days before, and its shape. A
/// card opens the metric in full. Everything is read when asked for, and
/// nothing is sent.
struct ChartsView: View {
    @Environment(AppModel.self) private var model
    @State private var charts = ChartsModel()
    /// Metric names, comma separated, shown first.
    @AppStorage("chartPins") private var pinText = WidgetSnapshot.metricNames.joined(separator: ",")
    @State private var search = ""
    @State private var unlocking = false

    private var pins: Binding<[String]> {
        Binding {
            pinText.split(separator: ",").map(String.init)
        } set: {
            pinText = $0.joined(separator: ",")
        }
    }

    /// What the search leaves.
    private var shown: [MetricSeries] {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return charts.series }
        return charts.series.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    private var pinned: [MetricSeries] {
        let names = pins.wrappedValue
        return names.compactMap { name in shown.first { $0.name == name } }
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        RangePicker(charts: charts, unlocking: $unlocking)
                    }
                    if shown.isEmpty {
                        empty
                    } else {
                        if !pinned.isEmpty {
                            section("Pinned", symbol: "pin.fill", pinned)
                        }
                        let pinnedNames = Set(pinned.map(\.name))
                        ForEach(Metric.Group.allCases, id: \.self) { group in
                            let rows = shown.filter { $0.group == group.rawValue && !pinnedNames.contains($0.name) }
                            if !rows.isEmpty { section(group.title, symbol: group.symbol, rows) }
                        }
                        if charts.loading {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Charts")
            .navigationDestination(for: String.self) { name in
                MetricDetailView(name: name, charts: charts, pins: pins)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Metrics")
            .refreshable {
                charts.load(from: model, force: true)
                await charts.finish()
            }
            .task { charts.load(from: model) }
            .onChange(of: model.store.access) { charts.load(from: model) }
            .sheet(isPresented: $unlocking) { UnlockView() }
        }
    }

    @ViewBuilder private var empty: some View {
        if charts.loading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else if !charts.series.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView {
                Label("No data yet", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Nothing in Health for the last \(ChartFormat.rangeTitle(charts.days)) that this app may read.")
            } actions: {
                Button("Allow Health access") {
                    Task {
                        await model.allowEveryType()
                        charts.load(from: model, force: true)
                    }
                }
                .accessibilityIdentifier("charts-allow")
            }
        }
    }

    private func section(_ title: String, symbol: String, _ rows: [MetricSeries]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(rows) { MetricCard(series: $0) }
            }
        }
    }
}

/// One metric on the overview.
private struct MetricCard: View {
    let series: MetricSeries

    var body: some View {
        NavigationLink(value: series.name) {
            VStack(alignment: .leading, spacing: 6) {
                Text(series.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(ChartFormat.number(series.headline))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(series.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(series.adds ? "in total" : "a day, on average")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Sparkline(series: series)
                    .frame(height: 36)
                if let change = series.change {
                    Label(ChartFormat.change(change), systemImage: change > 0.005 ? "arrow.up.right" : (change < -0.005 ? "arrow.down.right" : "equal"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    // Nothing earlier to compare with; the line keeps cards the same height.
                    Text(" ").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chart-card-\(series.name)")
    }
}

/// A metric's shape with nothing to read off it: bars where days add up,
/// otherwise a line.
private struct Sparkline: View {
    let series: MetricSeries

    var body: some View {
        let calendar = Calendar.local()
        // A year of bars is a blur; weeks keep the shape.
        let points = series.days.grouped(series.days.count > 100 ? .week : .day, adds: series.adds, calendar: calendar)
        Chart(points) { p in
            if series.adds {
                BarMark(x: .value("Date", p.day.start(in: calendar), unit: series.days.count > 100 ? .weekOfYear : .day), y: .value("Value", p.value))
            } else {
                LineMark(x: .value("Date", p.day.start(in: calendar)), y: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                if points.count == 1 {
                    PointMark(x: .value("Date", p.day.start(in: calendar)), y: .value("Value", p.value))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: .automatic(includesZero: series.adds))
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
    }
}
