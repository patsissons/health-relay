import HealthDataRelayKit
import SwiftUI

/// A one-off export: pick a template and some dates, get a file to send on.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var template: TemplateLibrary.Entry?
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
    @State private var to = Date.now
    @State private var grouping: TimeGrouping? = .days
    @State private var sections: Set<ExtractSpec.Section> = [.metrics, .workouts]
    @State private var workout: WorkoutDetail?
    @State private var working = false
    @State private var result: ExportedFile?
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Picker("Template", selection: $template) {
                    ForEach(model.library.entries()) { Text($0.name).tag(TemplateLibrary.Entry?.some($0)) }
                }
                .accessibilityIdentifier("export-template")
            }

            Section {
                NavigationLink {
                    WorkoutPicker(selection: $workout)
                } label: {
                    LabeledContent("Just one workout", value: workout?.name ?? "No")
                }
                .accessibilityIdentifier("export-workout")
                if let workout {
                    Text(workout.start, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)
                    Button("Use dates instead") { self.workout = nil }
                }
            }

            if workout == nil {
                Section("Dates") {
                    DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
                    Picker("Grouping", selection: $grouping) {
                        Text("Every sample").tag(TimeGrouping?.none)
                        Text("Minutes").tag(TimeGrouping?.some(.minutes))
                        Text("Hours").tag(TimeGrouping?.some(.hours))
                        Text("Days").tag(TimeGrouping?.some(.days))
                        Text("Weeks").tag(TimeGrouping?.some(.weeks))
                        Text("Months").tag(TimeGrouping?.some(.months))
                    }
                }
                Section("Data") {
                    ForEach(ExtractSpec.Section.allCases, id: \.self) { section in
                        Toggle(section.title, isOn: Binding {
                            sections.contains(section)
                        } set: { on in
                            if on { sections.insert(section) } else { sections.remove(section) }
                        })
                    }
                }
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    HStack {
                        Label("Export", systemImage: "square.and.arrow.up")
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(working || template == nil)
                .accessibilityIdentifier("export-run")
                if let result {
                    ShareLink(item: result.url) {
                        Label("Share \(result.name)", systemImage: "square.and.arrow.up.on.square")
                    }
                    .accessibilityIdentifier("export-share")
                    Text("\(result.bytes.formatted(.byteCount(style: .file))), \(result.rows.formatted()) rows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("export-result")
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("export-failure")
                }
            } footer: {
                Text("Nothing is sent until you share it. Keep the app open while it works: iOS keeps Health locked while your iPhone is locked.")
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            if template == nil { template = model.library.entries().first }
        }
    }

    private func export() async {
        guard let template, let source = model.library.source(template.ref) else { return }
        working = true
        failure = nil
        result = nil
        defer { working = false }
        do {
            var spec: ExtractSpec
            let range: DateInterval
            if let workout {
                spec = ExtractSpec(sections: [.workouts], grouping: .days)
                spec.workouts.ids = [workout.id]
                range = DateInterval(start: workout.start, end: max(workout.end, workout.start.addingTimeInterval(1)))
            } else {
                spec = ExtractSpec(sections: sections, grouping: grouping)
                let calendar = Calendar.local()
                let last = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!, .now)
                range = DateInterval(start: calendar.startOfDay(for: from), end: max(last, calendar.startOfDay(for: from).addingTimeInterval(1)))
            }
            result = try await model.export(source: source, spec: spec, range: range)
        } catch {
            failure = String(describing: error)
        }
    }
}

/// Recent workouts to pick one from.
private struct WorkoutPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: WorkoutDetail?
    @State private var workouts: [WorkoutDetail]?

    var body: some View {
        List {
            if let workouts {
                if workouts.isEmpty {
                    Text("No workouts in the last 90 days").foregroundStyle(.secondary)
                }
                ForEach(workouts, id: \.id) { w in
                    Button {
                        selection = w
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(w.name)
                            Text(w.start, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Workouts")
        .task { workouts = await model.recentWorkouts() }
    }
}

/// Asks what a Run should cover, for a pipeline that asks each time.
struct RangePrompt: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let run: (DateInterval) -> Void
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
    @State private var to = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                        .accessibilityIdentifier("range-from")
                    DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
                } footer: {
                    Text("Whole days, up to now.")
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") {
                        let calendar = Calendar.current
                        let end = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!, .now)
                        run(DateInterval(start: calendar.startOfDay(for: from), end: max(end, calendar.startOfDay(for: from).addingTimeInterval(1))))
                        dismiss()
                    }
                    .accessibilityIdentifier("range-run")
                }
            }
        }
    }
}

/// What a template pipeline's runs did.
struct RunHistoryView: View {
    let runs: [RunRecord]

    var body: some View {
        List {
            if runs.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
            ForEach(runs) { run in
                VStack(alignment: .leading) {
                    Text(run.at, format: .dateTime.month().day().hour().minute())
                    Text("\(run.rows.formatted()) rows, \(run.bytes.formatted(.byteCount(style: .file))), \(run.parts == 1 ? "1 file" : "\(run.parts) files")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Run history")
    }
}
