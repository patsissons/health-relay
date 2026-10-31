import HealthRelayKit
import SwiftUI

/// One card per pipeline: what it does, how it stands, and when it runs.
struct PipelinesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    private var snapshot: Snapshot { model.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if snapshot.stateSetAside {
                        Notice {
                            Label("Saved settings could not be read", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                            Text("Health Relay started fresh, so pipelines need adding again. Your Health data is not affected. The old file is kept until you dismiss this.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Dismiss") { Task { await model.dismissSetAsideState() } }
                                .accessibilityIdentifier("dismiss-state-problem")
                        }
                    }
                    if model.needsAuthorization {
                        Notice {
                            Button {
                                Task { await model.authorize() }
                            } label: {
                                Label("Allow Health access", systemImage: "heart.circle.fill")
                                    .font(.headline)
                            }
                            .accessibilityIdentifier("authorize")
                            Text("Health Relay reads your Health data only to send it where your pipelines say.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if snapshot.pipelines.isEmpty {
                        ContentUnavailableView {
                            Label("No pipelines", systemImage: "arrow.triangle.branch")
                        } description: {
                            Text("A pipeline takes data from Health, shapes it, and delivers it somewhere you choose, when you tap Run or on a schedule.")
                        } actions: {
                            Button("Add a pipeline") { adding = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    ForEach(snapshot.pipelines) { pipeline in
                        PipelineCard(pipeline: pipeline, progress: snapshot.progress)
                    }
                }
                .padding()
            }
            .navigationTitle("Pipelines")
            .toolbar {
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("add-pipeline")
            }
            .sheet(isPresented: $adding) {
                NavigationStack { PipelineEditor(existing: nil) }
            }
        }
    }
}

/// A rounded panel, the shape of everything on the Pipelines screen.
private struct Notice<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PipelineCard: View {
    @Environment(AppModel.self) private var model
    let pipeline: Pipeline
    let progress: SyncProgress?

    var body: some View {
        Notice {
            NavigationLink {
                PipelineDetail(id: pipeline.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pipeline.name).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(pipeline.flow)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PipelineStateRow(pipeline: pipeline)
                        .font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if pipeline.activity == .running, let progress {
                SyncProgressRow(progress: progress)
            }
            PipelineTimingRow(pipeline: pipeline)
        }
    }
}

/// How a pipeline stands: paused, in trouble, or how much it has to send.
struct PipelineStateRow: View {
    let pipeline: Pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            state.accessibilityIdentifier("pipeline-state")
            if let success = pipeline.lane.lastSuccess {
                Text("Last delivered \(success, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var state: some View {
        let lane = pipeline.lane
        if pipeline.destination.paused {
            Label("Paused, \(daysText(lane.dirty.count)) waiting", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        } else if let attention = lane.attention {
            Label("Needs attention: \(attention)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if let after = lane.retryAfter, after > .now {
            Label("Retrying \(after, format: .relative(presentation: .named)): \(lane.lastError ?? "")", systemImage: "arrow.clockwise")
                .foregroundStyle(.orange)
        } else if let message = lane.lastMessage {
            Label(message, systemImage: "exclamationmark.circle")
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

/// When a pipeline runs: its Run button, or its countdown.
struct PipelineTimingRow: View {
    @Environment(AppModel.self) private var model
    let pipeline: Pipeline

    var body: some View {
        switch pipeline.activity {
        case .running:
            Label("Running", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pipeline-activity")
        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pipeline-activity")
        case .idle:
            if pipeline.trigger == .manual {
                Button {
                    Task { await model.run(pipeline.id) }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pipeline.destination.paused || pipeline.lane.attention != nil)
                .accessibilityIdentifier("run-\(pipeline.name)")
            } else {
                // A view of its own redrawing each second: nothing runs when
                // this is off screen.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(line(at: context.date))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("next-run")
                }
            }
        }
    }

    private func line(at now: Date) -> String {
        if pipeline.destination.paused { return "Paused" }
        switch pipeline.timing(now: now) {
        case .whenTapped: return ""
        case .whenHealthChanges: return "Runs when Health changes"
        case .next(let date): return "Next run in \(Countdown.text(date.timeIntervalSince(now)))"
        // iOS decides when background work runs; the card never claims more.
        case .due(.waitingForIOS): return "Due, waiting for iOS"
        case .due(.unlockIPhone): return "Due, unlock your iPhone"
        }
    }
}

/// One pipeline in full: its parts, its state and what can be done with it.
struct PipelineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    @State private var editing = false
    @State private var testing = false
    @State private var confirmRemove = false

    private var pipeline: Pipeline? { model.snapshot.pipelines.first { $0.id == id } }

    var body: some View {
        List {
            if let pipeline {
                Section {
                    PipelineStateRow(pipeline: pipeline)
                    if pipeline.activity == .running, let progress = model.snapshot.progress {
                        SyncProgressRow(progress: progress)
                    }
                    Button {
                        Task { await model.run(id) }
                    } label: {
                        HStack {
                            Label("Run now", systemImage: "play.fill")
                            if pipeline.activity != .idle {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(pipeline.activity != .idle || pipeline.destination.paused || pipeline.lane.attention != nil)
                    .accessibilityIdentifier("run-now")
                    if pipeline.trigger != .manual {
                        PipelineTimingRow(pipeline: pipeline)
                    }
                }

                Section("Pipeline") {
                    LabeledContent("Transform", value: pipeline.transform.title)
                    LabeledContent("Destination", value: pipeline.endpoint.url.host() ?? "")
                    LabeledContent("Trigger", value: pipeline.trigger.title)
                    Button("Edit") { editing = true }
                        .accessibilityIdentifier("edit-pipeline")
                }

                Section {
                    NavigationLink("Deliveries") { DeliveryLogView(destinationID: id) }
                        .accessibilityIdentifier("deliveries")
                    Button {
                        testing = true
                        Task {
                            await model.test(id)
                            testing = false
                        }
                    } label: {
                        HStack {
                            Label("Test", systemImage: "antenna.radiowaves.left.and.right")
                            if testing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(testing)
                    .accessibilityIdentifier("test-pipeline")
                    if let answer = model.tests[id] {
                        Label("\(answer.status.map { "\($0)" } ?? "No answer") · \(answer.message)", systemImage: answer.verdict.symbol)
                            .foregroundStyle(answer.verdict.color)
                            .font(.subheadline)
                            .accessibilityIdentifier("test-result")
                    }
                } footer: {
                    Text("Test sends an empty push (no days). Any receiver of the schema answers it with success.")
                }

                Section {
                    Menu {
                        ForEach([7, 14, 35], id: \.self) { n in
                            Button("Last \(n) days") { Task { await model.resend(id, lastDays: n) } }
                        }
                    } label: {
                        Label("Re-send recent days", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(pipeline.activity != .idle)
                } footer: {
                    Text("Replaces those days at this destination with what this iPhone has now, deletions included.")
                }

                Section {
                    Toggle("Paused", isOn: Binding(
                        get: { pipeline.destination.paused },
                        set: { paused in Task { await model.setPaused(id, paused) } }))
                } footer: {
                    Text("A paused pipeline keeps collecting days to send and catches up when resumed.")
                }

                Section {
                    Button("Remove pipeline", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Forgets its waiting days, queue and log. Data its destination already received stays there.")
                }
            }
        }
        .navigationTitle(pipeline?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack { PipelineEditor(existing: pipeline?.destination) }
        }
        .confirmationDialog("Remove \(pipeline?.name ?? "")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.remove(id)
                    dismiss()
                }
            }
        }
    }
}

/// Adds or edits a pipeline. Only its load target and trigger can be chosen
/// so far; every pipeline extracts changed days and sends the schema.
struct PipelineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Destination?
    /// Settings from a setup link, laid over the existing ones for review.
    var setup: SetupLink? = nil

    private enum TriggerKind: Hashable { case manual, health, schedule }

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var headers: [HTTPEndpoint.Header] = []
    @State private var kind = TriggerKind.manual
    @State private var count = 1
    @State private var unit = Schedule.Unit.hours
    @State private var saved: PipelineTrigger?
    @State private var loaded = false

    private var endpoint: HTTPEndpoint? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              ["http", "https"].contains(scheme), u.host() != nil else { return nil }
        return HTTPEndpoint(url: u, headers: headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private var status: DestinationStatus? {
        existing.flatMap { e in model.snapshot.destinations.first { $0.id == e.id } }
    }

    /// The trigger as chosen. An unchanged schedule keeps its start, so
    /// editing a name does not restart its countdown.
    private var trigger: PipelineTrigger {
        switch kind {
        case .manual: return .manual
        case .health: return .whenHealthChanges
        case .schedule:
            if case .every(let old)? = saved, old.count == count, old.unit == unit { return .every(old) }
            return .every(Schedule(count: count, unit: unit, since: Date()))
        }
    }

    var body: some View {
        Form {
            if let setup {
                Section {
                    Label {
                        Text("Check this is where you want your Health data to go: every day this phone records will be sent to **\(setup.endpoint.url.host() ?? "")**.")
                    } icon: {
                        Image(systemName: "qrcode")
                    }
                    .font(.subheadline)
                } header: {
                    Text(existing == nil ? "From a setup link" : "From a setup link: updates this pipeline")
                }
            }

            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("pipeline-name")
                LabeledContent("Transform", value: TransformSpec.healthRelayPush.title)
            } footer: {
                Text("Sends each day that changed, whole, in the Health Relay schema, deletions included.")
            }

            Section {
                TextField("https://example.com/push", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("pipeline-url")
                SecureField("Bearer token (optional)", text: $token)
                    // Not a password: keeps iOS from offering to save it to Passwords.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("pipeline-token")
            } header: {
                Text("Destination")
            } footer: {
                Text("Each batch of days is POSTed as JSON, with Authorization: Bearer <token> when a token is set. The token is kept in the Keychain.")
            }

            Section {
                ForEach(headers.indices, id: \.self) { i in
                    HStack {
                        TextField("Header", text: $headers[i].name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Value", text: $headers[i].value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button("Add header") { headers.append(.init(name: "", value: "")) }
            } header: {
                Text("Extra headers")
            }

            Section {
                Picker("Trigger", selection: $kind) {
                    Text("Manual").tag(TriggerKind.manual)
                    Text("Health changes").tag(TriggerKind.health)
                    Text("Schedule").tag(TriggerKind.schedule)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("trigger-kind")
                if kind == .schedule {
                    Stepper("Every \(count)", value: $count, in: 1...999)
                        .accessibilityIdentifier("schedule-count")
                    Picker("Unit", selection: $unit) {
                        Text("Minutes").tag(Schedule.Unit.minutes)
                        Text("Hours").tag(Schedule.Unit.hours)
                        Text("Days").tag(Schedule.Unit.days)
                        Text("Weeks").tag(Schedule.Unit.weeks)
                    }
                }
            } header: {
                Text("Trigger")
            } footer: {
                Text(triggerNote)
            }
        }
        .navigationTitle(existing == nil ? "New pipeline" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                        dismiss()
                    }
                }
                .disabled(endpoint == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("save-pipeline")
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let existing, case .http(let e) = existing.kind {
                name = existing.name
                url = e.url.absoluteString
                headers = e.headers
                token = await model.token(for: existing.id)
                let current = model.snapshot.pipelines.first { $0.id == existing.id }?.trigger
                saved = current
                switch current {
                case .whenHealthChanges: kind = .health
                case .every(let schedule):
                    kind = .schedule
                    count = schedule.count
                    unit = schedule.unit
                default: kind = .manual
                }
            }
            if let setup {
                if let n = setup.name { name = n } else if name.isEmpty { name = setup.endpoint.url.host() ?? "" }
                url = setup.endpoint.url.absoluteString
                if !setup.endpoint.headers.isEmpty { headers = setup.endpoint.headers }
                if let t = setup.token { token = t }
            }
        }
    }

    private var triggerNote: String {
        switch kind {
        case .manual:
            return "Runs only when you tap Run."
        case .health:
            return "Runs when Health records new data, each morning, and when you open the app, if Background App Refresh is on. iOS keeps Health data locked while your iPhone is locked, so changes overnight are sent after you first unlock it."
        case .schedule:
            return "Runs as soon as it can once due. iOS decides when background work happens and keeps Health data locked while your iPhone is locked, so a run can come later than its time."
        }
    }

    private func save() async {
        guard let endpoint else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var d = status?.destination {
            d.name = trimmed
            d.kind = .http(endpoint)
            await model.update(d, token: token, trigger: trigger)
        } else {
            await model.add(name: trimmed, endpoint: endpoint, token: token, trigger: trigger)
        }
    }
}

extension Pipeline {
    /// "Health Relay → example.com"
    var flow: String {
        "\(transform.title) → \(endpoint.url.host() ?? "")"
    }
}

extension TransformSpec {
    var title: String {
        switch self {
        case .healthRelayPush: "Health Relay"
        }
    }
}

extension PipelineTrigger {
    var title: String {
        switch self {
        case .manual: return "Manual"
        case .whenHealthChanges: return "When Health changes"
        case .every(let schedule):
            let unit = String(describing: schedule.unit)
            return schedule.count == 1 ? "Every \(unit.dropLast())" : "Every \(schedule.count) \(unit)"
        }
    }
}

/// One pipeline's recent deliveries, newest first.
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
            Text("\(progress.overall, format: .percent.precision(.fractionLength(0))) done")
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
