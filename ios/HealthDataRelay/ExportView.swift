import HealthDataRelayKit
import MessageUI
import SwiftUI

/// A one-off export: pick a template and some dates, get a file to send on.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var template: TemplateLibrary.Entry?
    @State private var dates = DateChoice()
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
                    DateChoiceFields(dates: $dates, id: "export-range")
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
                range = dates.interval
            }
            result = try await model.export(source: source, spec: spec, range: range)
        } catch {
            failure = String(describing: error)
        }
    }
}

/// Dates picked by hand: a preset, or nil for the two dates.
private struct DateChoice {
    var preset: DateRangePreset? = .last7Days
    var from = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
    var to = Date.now

    var interval: DateInterval {
        let calendar = Calendar.local()
        if let preset { return preset.interval(now: .now, calendar: calendar) }
        let start = calendar.startOfDay(for: from)
        let last = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!, .now)
        return DateInterval(start: start, end: max(last, start.addingTimeInterval(1)))
    }
}

/// The range picker, and the two dates when it's on Custom.
private struct DateChoiceFields: View {
    @Binding var dates: DateChoice
    let id: String

    var body: some View {
        Picker("Range", selection: $dates.preset) {
            ForEach(DateRangePreset.allCases, id: \.self) { Text($0.title).tag(DateRangePreset?.some($0)) }
            Text("Custom").tag(DateRangePreset?.none)
        }
        .accessibilityIdentifier(id)
        .onChange(of: dates.preset) { old, new in
            // Custom starts from what was just showing.
            guard new == nil, let interval = old?.interval(now: .now, calendar: Calendar.local()) else { return }
            dates.from = interval.start
            dates.to = interval.end
        }
        if dates.preset == nil {
            DatePicker("From", selection: $dates.from, in: ...dates.to, displayedComponents: .date)
                .accessibilityIdentifier("range-from")
            DatePicker("To", selection: $dates.to, in: dates.from...Date.now, displayedComponents: .date)
        }
    }
}

extension DateRangePreset {
    fileprivate var title: String {
        switch self {
        case .last24Hours: "Last 24 hours"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .last365Days: "Last 365 days"
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
    @State private var dates = DateChoice()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DateChoiceFields(dates: $dates, id: "range-preset")
                } footer: {
                    Text(dates.preset == .last24Hours ? "The 24 hours up to now." : "Whole days, up to now.")
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
                        run(dates.interval)
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

/// Sends a run's output by hand: Apple Mail's composer when it's set up, and
/// the share sheet for Gmail and everything else.
struct ComposeRow: View {
    let email: EmailTarget
    let file: URL
    @State private var composing = false
    @State private var sent = false

    var body: some View {
        if MFMailComposeViewController.canSendMail() {
            Button {
                composing = true
            } label: {
                Label(sent ? "Sent" : "Compose in Mail", systemImage: "envelope")
            }
            .accessibilityIdentifier("compose-mail")
            .sheet(isPresented: $composing) {
                MailComposer(email: email, file: file) { sent = $0 }
                    .ignoresSafeArea()
            }
        }
        ShareLink(item: file, subject: Text(email.subject), message: Text(email.body)) {
            Label("Send with another app", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("compose-share")
    }
}

private struct MailComposer: UIViewControllerRepresentable {
    let email: EmailTarget
    let file: URL
    let finished: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(email.to)
        // The subject is written when the run is; what's saved here is the template's, so it's plain only without one.
        vc.setSubject(email.subject.contains("{{") ? "Health data" : email.subject)
        vc.setMessageBody(email.body, isHTML: false)
        if let data = try? Data(contentsOf: file) {
            vc.addAttachmentData(data, mimeType: "application/octet-stream", fileName: file.lastPathComponent)
        }
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    @MainActor final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let finished: (Bool) -> Void

        init(finished: @escaping (Bool) -> Void) {
            self.finished = finished
        }

        func mailComposeController(_ vc: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            finished(result == .sent)
            vc.dismiss(animated: true)
        }
    }
}
