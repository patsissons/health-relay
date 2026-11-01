import HealthDataRelayKit
import SwiftUI

/// What the app has been doing, and a file to send with a bug report.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ActivityEntry] = []
    @State private var diagnostics: URL?

    var body: some View {
        List {
            Section {
                if let diagnostics {
                    ShareLink(item: diagnostics) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-diagnostics")
                } else {
                    Button("Make a diagnostics file") { diagnostics = model.makeDiagnostics() }
                        .accessibilityIdentifier("make-diagnostics")
                }
            } footer: {
                Text("A ZIP of this log and your pipelines' settings, for a bug report. It has no health data, tokens, full addresses or names you've given your pipelines.")
            }
            Section("Activity") {
                if entries.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.message).font(.subheadline)
                        Text(entry.at, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("activity-entry")
                }
            }
        }
        .navigationTitle("Activity")
        .onAppear { entries = model.activity() }
    }
}

/// When to hear about a pipeline, on its detail screen.
struct PipelineNoticesSection: View {
    @Environment(AppModel.self) private var model
    let pipeline: Pipeline
    @State private var notices = PipelineNotices()
    @State private var loaded = false

    private var isScheduled: Bool {
        switch pipeline.trigger {
        case .every, .at: true
        default: false
        }
    }

    var body: some View {
        Section {
            Toggle("When it fails", isOn: $notices.onFailure)
                .accessibilityIdentifier("notify-failure")
            Toggle("When it finishes", isOn: $notices.onSuccess)
            if isScheduled {
                Toggle("Remind me when it's due", isOn: $notices.reminder)
                    .accessibilityIdentifier("notify-reminder")
            }
        } header: {
            Text("Notifications")
        } footer: {
            if notices.reminder {
                Text("iOS decides when background work runs. If it hasn't run a few minutes after it's due, you get a reminder to open the app.")
            }
        }
        .onChange(of: notices) { _, next in
            guard loaded else { return }
            Task { await model.setNotices(pipeline.id, next) }
        }
        .task {
            notices = await model.notices(for: pipeline.id)
            loaded = true
        }
    }
}
