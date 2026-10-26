import HealthRelayKit
import SwiftUI

/// Last sync, each destination's state and log, per-type data hints, and
/// the manual actions.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var deviceName = ""

    private var snapshot: Snapshot { model.snapshot }

    var body: some View {
        NavigationStack {
            List {
                if model.needsAuthorization {
                    Section {
                        Button {
                            Task { await model.authorize() }
                        } label: {
                            Label("Allow Health access", systemImage: "heart.circle.fill")
                        }
                        .accessibilityIdentifier("authorize")
                    } footer: {
                        Text("Health Relay reads your Health data only to send it to the destinations you add.")
                    }
                }

                Section {
                    LabeledContent("Last sync") {
                        if let last = snapshot.lastSync {
                            Text(last, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    // While a sync runs, its progress row says more.
                    if let message = snapshot.lastSyncMessage, snapshot.progress == nil {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-message")
                    }
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            if snapshot.syncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(snapshot.syncing || snapshot.destinations.isEmpty)
                    .accessibilityIdentifier("sync-now")
                    if let progress = snapshot.progress {
                        SyncProgressRow(progress: progress)
                    }
                } footer: {
                    Text("iOS keeps Health data locked while your iPhone is locked, so changes overnight are sent after you first unlock it.")
                }

                if snapshot.destinations.isEmpty {
                    Section {
                        Text("Add a destination to start sending your days.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Destinations") {
                        ForEach(snapshot.destinations) { status in
                            NavigationLink {
                                DeliveryLogView(destinationID: status.id)
                            } label: {
                                DestinationStatusRow(status: status)
                            }
                        }
                    }
                }

                Section {
                    Menu {
                        ForEach([7, 14, 35], id: \.self) { n in
                            Button("Last \(n) days") { Task { await model.resend(lastDays: n) } }
                        }
                    } label: {
                        Label("Re-send recent days", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(snapshot.destinations.isEmpty || snapshot.syncing)
                } footer: {
                    Text("Re-sending replaces those days at every destination with what this iPhone has now, deletions included.")
                }

                Section {
                    TextField("iPhone", text: $deviceName)
                        .onSubmit { Task { await model.setDeviceName(deviceName) } }
                        .submitLabel(.done)
                } header: {
                    Text("This iPhone's name")
                } footer: {
                    Text("Destinations see this name with each delivery.")
                }

                Section {
                    NavigationLink("Data by type") { TypesView() }
                }
            }
            .navigationTitle("Health Relay")
            .refreshable { await model.syncNow() }
            .onAppear { deviceName = snapshot.deviceName }
        }
    }
}

struct DestinationStatusRow: View {
    let status: DestinationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.destination.name).font(.headline)
            state
                .font(.subheadline)
            if let success = status.lane.lastSuccess {
                Text("Last delivered \(success, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var state: some View {
        let lane = status.lane
        if status.destination.paused {
            Label("Paused, \(daysText(lane.dirty.count)) waiting", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        } else if let attention = lane.attention {
            Label("Needs attention: \(attention)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if let after = lane.retryAfter, after > .now {
            Label("Retrying \(after, format: .relative(presentation: .named)): \(lane.lastError ?? "")", systemImage: "arrow.clockwise")
                .foregroundStyle(.orange)
        } else if lane.dirty.isEmpty {
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("\(daysText(lane.dirty.count)) to send", systemImage: "tray.full")
                .foregroundStyle(.secondary)
        }
    }

    private func daysText(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
}

/// One destination's recent deliveries, newest first.
struct DeliveryLogView: View {
    @Environment(AppModel.self) private var model
    let destinationID: UUID

    var body: some View {
        let status = model.snapshot.destinations.first { $0.id == destinationID }
        List {
            if let status {
                if !status.lane.dirty.isEmpty {
                    Section("Waiting") {
                        Text(status.lane.dirty.days.map(\.description).joined(separator: ", "))
                            .font(.footnote.monospaced())
                    }
                }
                Section("Deliveries") {
                    if status.lane.log.isEmpty {
                        Text("Nothing sent yet").foregroundStyle(.secondary)
                    }
                    ForEach(status.lane.log) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: entry.delivery.verdict.symbol)
                                    .foregroundStyle(entry.delivery.verdict.color)
                                Text(entry.days.isEmpty ? "Test" : DeliveryLogView.range(entry.days))
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(entry.at, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(entry.delivery.status.map { "\($0)" } ?? "No answer") · \(entry.delivery.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(status?.destination.name ?? "Deliveries")
    }

    static func range(_ days: [Day]) -> String {
        guard let first = days.min(), let last = days.max() else { return "" }
        return first == last ? first.description : "\(first) – \(last) (\(days.count) days)"
    }
}

extension Verdict {
    var symbol: String {
        switch self {
        case .accepted: "checkmark.circle.fill"
        case .authFailed: "lock.trianglebadge.exclamationmark"
        case .rejected: "xmark.octagon.fill"
        case .retry: "arrow.clockwise.circle"
        }
    }

    var color: Color {
        switch self {
        case .accepted: .green
        case .authFailed, .rejected: .red
        case .retry: .orange
        }
    }
}

/// Which types have had data lately. iOS never says which read permissions
/// were denied, so a type with nothing in 30 days may be either.
struct TypesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let withData = model.recent.filter { $0.newest != nil }
        let without = model.recent.filter { $0.newest == nil }
        List {
            Section("Data in the last 30 days") {
                ForEach(withData, id: \.type.id) { item in
                    LabeledContent(TypesView.name(item.type)) {
                        Text(item.newest!, format: .relative(presentation: .named))
                    }
                }
            }
            Section {
                ForEach(without, id: \.type.id) { item in
                    Text(TypesView.name(item.type)).foregroundStyle(.secondary)
                }
            } header: {
                Text("No data in 30 days")
            } footer: {
                Text("If you expected data here, check Settings > Health > Data Access & Devices > Health Relay.")
            }
        }
        .navigationTitle("Data by type")
        .task { await model.loadRecent() }
    }

    /// "HKQuantityTypeIdentifierHeartRateVariabilitySDNN" -> "Heart Rate Variability SDNN"
    static func name(_ type: HealthType) -> String {
        let bare = type.id
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
        switch type.kind {
        case .workout: return "Workouts"
        case .ecg: return "ECG"
        default:
            return bare.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
    }
}

/// What a running sync is doing, how far through that it is, and how far
/// through the whole sync.
struct SyncProgressRow: View {
    let progress: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(progress.item, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.overall)
            Text("\(progress.overall, format: .percent.precision(.fractionLength(0))) synced")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync-progress")
    }

    private var line: String {
        switch progress.step {
        case .checking: "Checking Health for changes"
        case .reading(let days): "Reading \(Self.span(days)) from Health"
        case .sending(let days, let name): "Sending \(Self.span(days)) to \(name)"
        }
    }

    /// "Oct 12", or "Oct 12 – Oct 18" for several days.
    static func span(_ days: [Day]) -> String {
        guard let first = days.min(), let last = days.max() else { return "" }
        let style = Date.FormatStyle().month(.abbreviated).day()
        let start = first.interval(in: .current).start.formatted(style)
        return first == last ? start : "\(start) – \(last.interval(in: .current).start.formatted(style))"
    }
}
