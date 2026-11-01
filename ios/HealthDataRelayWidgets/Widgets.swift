import HealthDataRelayKit
import SwiftUI
import WidgetKit

/// The newest snapshot the app wrote. A widget reads nothing else.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    static let sample = WidgetSnapshot(
        updatedAt: .now,
        pipelines: [.init(id: UUID(), name: "Morning export", state: "Last run finished", needsAttention: false, nextRun: .now.addingTimeInterval(7200), lastSuccess: .now, runLink: nil)],
        values: [.init(name: "step_count", title: "Steps", text: "8,204"), .init(name: "active_energy", title: "Active Energy", text: "412 kcal"),
                 .init(name: "apple_exercise_time", title: "Exercise Minutes", text: "34 min"), .init(name: "resting_heart_rate", title: "Resting Heart Rate", text: "58 count/min")])

    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? Self.sample : WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads these whenever it has news; this only keeps countdowns honest.
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct TodayWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var values: [WidgetSnapshot.Value] {
        Array((entry.snapshot?.values ?? []).prefix(family == .systemSmall ? 2 : 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if values.isEmpty {
                Text("Open Health Data Relay to see today's values here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 0) {
                    Text(value.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text(value.text).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PipelinesWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var rows: [WidgetSnapshot.PipelineRow] {
        Array((entry.snapshot?.pipelines ?? []).prefix(family == .systemSmall ? 1 : 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("No pipelines yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let next = row.nextRun, next > entry.date {
                            Text(next, style: .relative).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(row.state).font(.caption2).foregroundStyle(row.needsAttention ? .red : .secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let link = row.runLink {
                        Link(destination: link) {
                            Image(systemName: "play.circle.fill").font(.title3)
                        }
                        .accessibilityLabel("Run \(row.name)")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: SnapshotProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today")
            .description("Today's values from Health, as of the last time the app ran.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PipelinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "pipelines", provider: SnapshotProvider()) { PipelinesWidgetView(entry: $0) }
            .configurationDisplayName("Pipelines")
            .description("How your pipelines stand, with a button to run them.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct HealthDataRelayWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        PipelinesWidget()
    }
}
