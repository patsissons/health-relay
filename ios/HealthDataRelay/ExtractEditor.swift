import HealthDataRelayKit
import SwiftUI

/// What a template pipeline reads, how much of it and how it's grouped.
struct ExtractEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var spec: ExtractSpec
    @State private var unlocking = false

    /// Days a range may reach back; nil with Full.
    private var cap: Int? { model.store.access.history.days }

    /// The range choices the picker offers, standing in for `RangeSpec`.
    private enum RangeChoice: Hashable {
        case changed, sinceLast, today, yesterday, previous, ask
    }

    private var rangeChoice: Binding<RangeChoice> {
        Binding {
            switch spec.range {
            case .changedDays: .changed
            case .sinceLastRun: .sinceLast
            case .today: .today
            case .yesterday: .yesterday
            case .previousDays, .lastDays, .fixed: .previous
            case .askAtRun: .ask
            }
        } set: { choice in
            switch choice {
            case .changed: spec.range = .changedDays
            case .sinceLast: spec.range = .sinceLastRun
            case .today: spec.range = .today
            case .yesterday: spec.range = .yesterday
            case .previous: spec.range = .previousDays(previousDays)
            case .ask: spec.range = .askAtRun
            }
        }
    }

    private var previousDays: Int {
        if case .previousDays(let n) = spec.range { return n }
        return 7
    }

    private var grouping: Binding<TimeGrouping?> {
        Binding { spec.grouping } set: { spec.grouping = $0 }
    }

    var body: some View {
        Section {
            ForEach(ExtractSpec.Section.allCases, id: \.self) { section in
                Toggle(section.title, isOn: Binding {
                    spec.sections.contains(section)
                } set: { on in
                    if on { spec.sections.insert(section) } else { spec.sections.remove(section) }
                })
                .accessibilityIdentifier("section-\(section.rawValue)")
            }
            if spec.sections.contains(.metrics) {
                NavigationLink {
                    MetricPicker(selection: $spec.metrics)
                } label: {
                    LabeledContent("Metrics", value: metricsSummary)
                }
                .accessibilityIdentifier("choose-metrics")
            }
        } header: {
            Text("Data")
        }

        Section {
            Picker("Range", selection: rangeChoice) {
                Text("Days that changed").tag(RangeChoice.changed)
                Text("Since the last run").tag(RangeChoice.sinceLast)
                Text("Today").tag(RangeChoice.today)
                Text("Yesterday").tag(RangeChoice.yesterday)
                Text("Previous days").tag(RangeChoice.previous)
                Text("Ask when run").tag(RangeChoice.ask)
            }
            .accessibilityIdentifier("range")
            if case .previousDays(let n) = spec.range {
                Stepper("Previous \(n) \(n == 1 ? "day" : "days")", value: Binding { n } set: { spec.range = .previousDays($0) }, in: 1...(cap ?? 365))
            }
            if let cap {
                Button {
                    unlocking = true
                } label: {
                    Label("Reaches back \(cap) days until you unlock Full", systemImage: "lock.fill")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("range-needs-full")
                .sheet(isPresented: $unlocking) { UnlockView() }
            }
            Picker("Grouping", selection: grouping) {
                Text("Every sample").tag(TimeGrouping?.none)
                Text("Automatic").tag(TimeGrouping?.some(.automatic))
                Text("Seconds").tag(TimeGrouping?.some(.seconds))
                Text("Minutes").tag(TimeGrouping?.some(.minutes))
                Text("Hours").tag(TimeGrouping?.some(.hours))
                Text("Days").tag(TimeGrouping?.some(.days))
                Text("Weeks").tag(TimeGrouping?.some(.weeks))
                Text("Months").tag(TimeGrouping?.some(.months))
                Text("Years").tag(TimeGrouping?.some(.years))
            }
            .accessibilityIdentifier("grouping")
        } header: {
            Text("How much")
        } footer: {
            Text(rangeNote)
        }

        Section {
            Picker("Sources", selection: sourceChoice) {
                Text("Merged, as Health shows").tag(0)
                Text("Each source separately").tag(1)
                Text("Prefer certain sources").tag(2)
            }
            .accessibilityIdentifier("sources")
            if case .preferred = spec.sources {
                TextField("Sources, in order", text: preferredText)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("preferred-sources")
            }
            Picker("Units", selection: Binding {
                spec.units.byDimension[.mass] == "lb" ? 1 : 0
            } set: { choice in
                let energy = spec.units.byDimension[.energy]
                spec.units = choice == 1 ? .imperial : UnitPreferences()
                if let energy { spec.units.byDimension[.energy] = energy }
            }) {
                Text("Metric").tag(0)
                Text("US").tag(1)
            }
            Picker("Energy", selection: Binding {
                spec.units.byDimension[.energy] ?? "kcal"
            } set: { spec.units.byDimension[.energy] = $0 == "kcal" ? nil : $0 }) {
                Text("kcal").tag("kcal")
                Text("kJ").tag("kJ")
            }
        } footer: {
            if case .preferred = spec.sources {
                Text("Names as the Health app shows them, separated by commas. Each value comes from the first one listed that has data for it, or Health's merged value if none do.")
            }
        }
    }

    private var sourceChoice: Binding<Int> {
        Binding {
            switch spec.sources {
            case .merged: 0
            case .eachSource: 1
            case .preferred: 2
            }
        } set: { choice in
            switch choice {
            case 1: spec.sources = .eachSource
            case 2: spec.sources = .preferred([])
            default: spec.sources = .merged
            }
        }
    }

    private var preferredText: Binding<String> {
        Binding {
            if case .preferred(let names) = spec.sources { return names.joined(separator: ", ") }
            return ""
        } set: { text in
            spec.sources = .preferred(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }

    private var metricsSummary: String {
        switch spec.metrics {
        case .all: "All"
        case .only(let names): "\(names.count)"
        }
    }

    private var rangeNote: String {
        switch spec.range {
        case .changedDays: "Whole days that changed since the last run, deletions included."
        case .sinceLastRun: "Everything since the last run, and anything older that has arrived since. Sends nothing if nothing is new."
        case .askAtRun: "You pick the dates when you tap Run. A schedule can't ask, so this needs a manual trigger."
        default: "The whole range, every run."
        }
    }
}

/// Choosing which metrics a pipeline reads.
private struct MetricPicker: View {
    @Binding var selection: ExtractSpec.MetricSelection

    private var all: Bool {
        if case .all = selection { return true }
        return false
    }

    private var names: Set<String> {
        if case .only(let list) = selection { return Set(list) }
        return Set(MetricCatalog.metrics.map(\.name))
    }

    var body: some View {
        List {
            Section {
                Toggle("Everything Health has", isOn: Binding { all } set: { on in
                    selection = on ? .all : .only(MetricCatalog.metrics.map(\.name))
                })
                .accessibilityIdentifier("all-metrics")
            }
            if !all {
                ForEach(Metric.Group.allCases, id: \.self) { group in
                    Section(String(describing: group).capitalized) {
                        ForEach(MetricCatalog.metrics.filter { $0.group == group }) { metric in
                            Toggle(metric.title, isOn: Binding { names.contains(metric.name) } set: { on in
                                var next = names
                                if on { next.insert(metric.name) } else { next.remove(metric.name) }
                                selection = .only(MetricCatalog.metrics.map(\.name).filter(next.contains))
                            })
                        }
                    }
                }
            }
        }
        .navigationTitle("Metrics")
    }
}

extension ExtractSpec.Section {
    var title: String {
        switch self {
        case .metrics: "Metrics"
        case .workouts: "Workouts"
        case .symptoms: "Symptoms"
        case .ecg: "ECG"
        case .heartRateNotifications: "Heart rate notifications"
        case .stateOfMind: "State of mind"
        case .cycleTracking: "Cycle tracking"
        case .medications: "Medications"
        }
    }
}
