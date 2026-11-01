import HealthDataRelayKit
import SwiftUI

/// One day's value for every metric, as a pipeline would read them, to hold
/// up against the Health app.
struct DayValuesView: View {
    @Environment(AppModel.self) private var model
    @State private var yesterday = false
    @State private var values: [AppModel.DayValue]?

    var body: some View {
        List {
            Section {
                Picker("Day", selection: $yesterday) {
                    Text("Today").tag(false)
                    Text("Yesterday").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("day-picker")
            } footer: {
                Text("These should match the Health app. A metric you expected but don't see may still need access.")
            }
            Section {
                Button("Allow every kind of data") {
                    Task {
                        await model.allowEveryType()
                        await load()
                    }
                }
                .accessibilityIdentifier("allow-every-type")
            }
            if let values {
                Section {
                    ForEach(values) { value in
                        LabeledContent(value.title, value: value.text)
                            .accessibilityIdentifier("value-" + value.title)
                    }
                    if values.isEmpty { Text("No data").foregroundStyle(.secondary) }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Values by day")
        .task(id: yesterday) { await load() }
    }

    private func load() async {
        values = nil
        values = await model.dayValues(yesterday: yesterday)
    }
}
