import HealthDataRelayKit
import SwiftUI
import UniformTypeIdentifiers

enum Pasteboard {
    @MainActor static var string: String? { UIPasteboard.general.string }
}

/// One card per pipeline: what it does, how it stands, and when it runs.
struct PipelinesView: View {
    @State private var exporting = false
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
                            Text("Health Data Relay started fresh, so pipelines need adding again. Your Health data is not affected. The old file is kept until you dismiss this.")
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
                            Text("Health Data Relay reads your Health data only to send it where your pipelines say.")
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
                    // One column on a phone, as many as fit on a larger screen.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(snapshot.pipelines) { pipeline in
                            PipelineCard(pipeline: pipeline, progress: snapshot.progress)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Pipelines")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        exporting = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-pipeline")
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack { PipelineEditor(existing: nil) }
            }
            .sheet(isPresented: $exporting) {
                NavigationStack { ExportView() }
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
        } else if let definition = pipeline.definition, !definition.usesDirtyDays {
            // It has a range, not days to catch up on, so "up to date" would mean nothing.
            if lane.lastRun == nil {
                Label("Hasn't run yet", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            } else {
                Label("Last run finished", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
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
    @State private var asking = false

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
                    if pipeline.extract.range == .askAtRun {
                        asking = true
                    } else {
                        Task { await model.run(pipeline.id) }
                    }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pipeline.destination.paused || pipeline.lane.attention != nil)
                .accessibilityIdentifier("run-\(pipeline.name)")
                .sheet(isPresented: $asking) {
                    RangePrompt(name: pipeline.name) { answer in
                        Task { await model.run(pipeline.id, answer: answer) }
                    }
                }
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
    @State private var asking = false

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
                        if pipeline.extract.range == .askAtRun {
                            asking = true
                        } else {
                            Task { await model.run(id) }
                        }
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
                    if pipeline.activity == .idle, let file = model.latestExport(id) {
                        if case .target(.email(let email)) = pipeline.destination.kind, case .compose = email.method {
                            ComposeRow(email: email, file: file)
                        } else if case .target(.share) = pipeline.destination.kind {
                            ShareLink(item: file) {
                                Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("share-export")
                        }
                    }
                }

                Section("Pipeline") {
                    LabeledContent("Transform", value: pipeline.transform.title)
                    LabeledContent("Destination", value: pipeline.destinationSummary)
                    LabeledContent("Trigger", value: pipeline.trigger.title)
                    Button("Edit") { editing = true }
                        .accessibilityIdentifier("edit-pipeline")
                }

                Section {
                    NavigationLink("Deliveries") { DeliveryLogView(destinationID: id) }
                        .accessibilityIdentifier("deliveries")
                    if pipeline.definition != nil {
                        NavigationLink("Run history") { RunHistoryView(runs: pipeline.lane.runs ?? []) }
                            .accessibilityIdentifier("run-history")
                    }
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
                    Text(pipeline.definition == nil
                         ? "Test sends an empty push (no days). Any receiver of the schema answers it with success."
                         : "Test sends the template's output with no data in it, so you can see the receiver's answer.")
                }

                if pipeline.definition?.usesDirtyDays ?? true {
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
                }

                PipelineNoticesSection(pipeline: pipeline)

                // A manual pipeline has nothing to pause, but one already paused can still resume.
                if pipeline.trigger != .manual || pipeline.destination.paused {
                    Section {
                        Toggle("Paused", isOn: Binding(
                            get: { pipeline.destination.paused },
                            set: { paused in Task { await model.setPaused(id, paused) } }))
                            .accessibilityIdentifier("pipeline-paused")
                    } footer: {
                        Text(pipeline.definition?.usesDirtyDays ?? true
                             ? "A paused pipeline keeps collecting days to send and catches up when resumed."
                             : "A paused pipeline doesn't run until resumed.")
                    }
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
        .sheet(isPresented: $asking) {
            RangePrompt(name: pipeline?.name ?? "") { answer in
                Task { await model.run(id, answer: answer) }
            }
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

/// Common jobs to start from, each with what it does.
private struct PresetList: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (PipelinePreset) -> Void

    var body: some View {
        List(PipelinePreset.all()) { preset in
            Button {
                choose(preset)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).foregroundStyle(.primary)
                    Text(preset.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("preset-\(preset.name)")
        }
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Adds or edits a pipeline: the native format, or a template and what it reads.
struct PipelineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Destination?
    /// Settings from a setup link, laid over the existing ones for review.
    var setup: SetupLink? = nil
    /// A whole pipeline's settings from a link, to review.
    var link: PipelineLink? = nil

    private enum TriggerKind: Hashable { case manual, health, schedule, time }

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var headers: [HTTPEndpoint.Header] = []
    @State private var kind = TriggerKind.manual
    @State private var count = 1
    @State private var unit = Schedule.Unit.hours
    @State private var saved: PipelineTrigger?
    @State private var loaded = false
    @State private var timeOfDay = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
    /// Calendar weekdays, 1 for Sunday. All of them means every day.
    @State private var weekdays = Set(1...7)
    /// Nil is the native format; otherwise a template and what it reads.
    @State private var template: TemplateLibrary.Entry?
    @State private var spec = ExtractSpec(range: .sinceLastRun, grouping: .automatic)
    @State private var method = WebTarget.Method.post
    @State private var multipart = false
    @State private var automationHeaders = true
    @State private var targetKind = TargetKind.web
    @State private var mqttHost = ""
    @State private var mqttPort = 1883
    @State private var mqttTLS = false
    @State private var mqttTopic = "health/{{ partition.key }}"
    @State private var mqttClient = "health-data-relay"
    @State private var mqttUser = ""
    @State private var mqttQoS = 1
    @State private var mqttRetain = false
    @State private var calendarID: String?
    @State private var calendarName = "Default calendar"
    @State private var calendars: [(id: String, title: String)] = []
    @State private var emailKind = EmailKind.compose
    @State private var emailTo = ""
    @State private var emailFrom = ""
    @State private var emailSubject = "Health data for {{ export.start | date: '%B %e' }}"
    @State private var emailBody = "Your Health Data Relay export is attached."
    @State private var smtpHost = ""
    @State private var smtpPort = 587
    @State private var smtpSecurity = SMTPSettings.Security.startTLS
    @State private var smtpUser = ""
    @State private var mailAPI = MailAPI.resend
    @State private var fileKind = FileKind.folder
    @State private var folderBookmark: Data?
    @State private var folderName = ""
    @State private var choosingFolder = false
    @State private var folderError: String?
    @State private var cloudAccount: UUID?
    @State private var cloudPath = "/Health"
    @State private var driveFolder = "Health"
    @State private var driveSheets = false
    @State private var overwrite = true

    private var cloudAccounts: [ConnectedAccount] {
        model.accounts.filter { $0.provider == (fileKind == .dropbox ? .dropbox : .google) }
    }

    private var fileLocation: FileTarget.Location? {
        switch fileKind {
        case .folder: folderBookmark.map { .folder(bookmark: $0, name: folderName) }
        case .dropbox: cloudAccount.map { .dropbox(account: $0, path: cloudPath) }
        case .drive: cloudAccount.map { .googleDrive(account: $0, folderName: driveFolder, sheets: driveSheets) }
        }
    }

    private var emailRecipients: [String] {
        emailTo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var emailMethod: EmailTarget.Method {
        switch emailKind {
        case .compose: .compose
        case .smtp: .smtp(SMTPSettings(host: smtpHost.trimmingCharacters(in: .whitespaces), port: smtpPort, security: smtpSecurity, username: smtpUser))
        case .api: .api(mailAPI)
        }
    }

    /// Where a template pipeline sends: the kinds of `LoadTarget`.
    private enum TargetKind: Hashable { case web, share, mqtt, calendar, email, file }

    private enum FileKind: Hashable { case folder, dropbox, drive }

    private enum EmailKind: Hashable { case compose, smtp, api }

    private var choices: [TemplateLibrary.Entry] { model.library.entries() }

    /// A template's name in the Transform list, told apart from the native format it shares a name with.
    private func transformTitle(_ entry: TemplateLibrary.Entry) -> String {
        entry.ref == .builtIn(BuiltInTemplates.healthDataRelay) ? "\(entry.name) (template)" : entry.name
    }

    /// Whether to offer a cloud service: this build can sign in to it, or this pipeline already saves there.
    private func offersCloud(_ kind: FileKind, _ provider: ConnectedAccount.Provider) -> Bool {
        fileKind == kind || AppModel.oauth(provider) != nil
    }

    private var offersAnyCloud: Bool {
        offersCloud(.dropbox, .dropbox) || offersCloud(.drive, .google)
    }

    /// Starts from a common job's settings.
    private func apply(_ preset: PipelinePreset) {
        template = choices.first { $0.ref == .builtIn(preset.template) }
        spec = preset.extract
        switch preset.trigger {
        case .manual: kind = .manual
        case .whenHealthChanges: kind = .health
        case .every(let schedule):
            kind = .schedule
            count = schedule.count
            unit = schedule.unit
        case .at(let time):
            kind = .time
            timeOfDay = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
        }
        switch preset.target {
        case .web(let web)?:
            targetKind = .web
            url = web.url
            automationHeaders = web.automationHeaders
        case .calendar?:
            targetKind = .calendar
        default:
            break
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = preset.name }
    }

    private var endpoint: HTTPEndpoint? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              ["http", "https"].contains(scheme), u.host() != nil else { return nil }
        return HTTPEndpoint(url: u, headers: headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// A template's address may have its own template parts in it.
    private var targetURLIsValid: Bool {
        let text = url.trimmingCharacters(in: .whitespaces)
        let literal = text.replacingOccurrences(of: "\\{\\{.*?\\}\\}", with: "x", options: .regularExpression)
        guard let u = URL(string: literal), let scheme = u.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && u.host() != nil
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if template == nil { return endpoint != nil }
        switch targetKind {
        case .web: return targetURLIsValid
        case .share, .calendar: return true
        case .mqtt: return !mqttHost.trimmingCharacters(in: .whitespaces).isEmpty && !mqttTopic.isEmpty
        case .file: return fileLocation != nil
        case .email:
            switch emailKind {
            case .compose: return true
            case .smtp: return !emailRecipients.isEmpty && !emailFrom.isEmpty && !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty
            case .api: return !emailRecipients.isEmpty && !emailFrom.isEmpty && !token.isEmpty
            }
        }
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
        case .time:
            let c = Calendar.current.dateComponents([.hour, .minute], from: timeOfDay)
            let days = weekdays.count == 7 || weekdays.isEmpty ? nil : weekdays.sorted()
            if case .at(let old)? = saved, old.hour == c.hour, old.minute == c.minute, old.weekdays == days { return .at(old) }
            return .at(TimeOfDay(hour: c.hour ?? 7, minute: c.minute ?? 0, weekdays: days, since: Date()))
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

            if let link {
                Section {
                    Label {
                        Text("Check this is where you want your Health data to go: this pipeline sends to **\(URL(string: link.web.url)?.host() ?? link.web.url)**.")
                    } icon: {
                        Image(systemName: "link")
                    }
                    .font(.subheadline)
                    ForEach(link.notes, id: \.self) { note in
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("From a link")
                }
            }

            if existing == nil && setup == nil && link == nil {
                Section {
                    Button {
                        if let text = Pasteboard.string { model.importLink(text) } else { model.linkProblem = "There's nothing copied." }
                        dismiss()
                    } label: {
                        Label("Use a copied link", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("paste-link")
                    NavigationLink {
                        PresetList { apply($0) }
                    } label: {
                        Label("Start from a preset", systemImage: "wand.and.stars")
                    }
                    .accessibilityIdentifier("preset")
                }
            }

            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("pipeline-name")
                Picker("Transform", selection: $template) {
                    Text(TransformSpec.healthDataRelayPush.title).tag(TemplateLibrary.Entry?.none)
                    ForEach(model.library.transforms(selected: template?.ref)) { Text(transformTitle($0)).tag(TemplateLibrary.Entry?.some($0)) }
                }
                // The native format stays first, even when the list opens upward.
                .menuOrder(.fixed)
                .accessibilityIdentifier("transform")
                .onChange(of: template) { _, entry in
                    // The native format only sends to a REST API.
                    if entry == nil { targetKind = .web }
                    // Start from the sections a template says it uses.
                    guard let entry, let source = model.library.source(entry.ref), let parsed = try? ParsedTemplate(source: source), !parsed.header.data.isEmpty else { return }
                    spec.sections = Set(parsed.header.data)
                }
            } footer: {
                Text(template == nil
                     ? "Sends each day that changed, whole, in the Health Data Relay schema, deletions included."
                     : "Written from a template, then sent. A failed send retries the same output.")
            }

            if template != nil {
                ExtractEditor(spec: $spec)
            }

            Section {
                Picker("Type", selection: $targetKind) {
                    Text("REST API").tag(TargetKind.web)
                    if template != nil {
                        Text("Share sheet").tag(TargetKind.share)
                        Text("MQTT").tag(TargetKind.mqtt)
                        Text("Calendar").tag(TargetKind.calendar)
                        Text("Email").tag(TargetKind.email)
                        Text(offersAnyCloud ? "Files or cloud" : "Files").tag(TargetKind.file)
                    }
                }
                .accessibilityIdentifier("target-kind")
                if template == nil || targetKind == .web {
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
                    if template != nil {
                        Picker("Method", selection: $method) {
                            ForEach(WebTarget.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Send as a file upload", isOn: $multipart)
                        Toggle("Send automation headers", isOn: $automationHeaders)
                    }
                }
            } header: {
                Text("Destination")
            } footer: {
                if template == nil {
                    Text("Each batch of days is POSTed as JSON, with Authorization: Bearer <token> when a token is set. The token is kept in the Keychain.")
                } else if targetKind == .web {
                    Text("Authorization: Bearer <token> is sent when a token is set, and the token is kept in the Keychain. Automation headers name this pipeline, its grouping and range, for receivers that read them.")
                } else if targetKind == .share {
                    Text("Writes a file you send on yourself, or a ZIP when there are several.")
                }
            }

            if template != nil && targetKind == .mqtt {
                Section {
                    TextField("Broker host", text: $mqttHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("mqtt-host")
                    Stepper("Port \(String(mqttPort))", value: $mqttPort, in: 1...65535)
                    Toggle("Use TLS", isOn: $mqttTLS)
                    TextField("Topic", text: $mqttTopic)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mqtt-topic")
                    TextField("Client ID", text: $mqttClient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username (optional)", text: $mqttUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (optional)", text: $token)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("QoS", selection: $mqttQoS) {
                        Text("0, at most once").tag(0)
                        Text("1, at least once").tag(1)
                        Text("2, exactly once").tag(2)
                    }
                    Toggle("Retain", isOn: $mqttRetain)
                } footer: {
                    Text("Each part is one message. A topic can name its part, like health/{{ partition.key }}. The password is kept in the Keychain.")
                }
            }

            if template != nil && targetKind == .file {
                Section {
                    if offersAnyCloud {
                        Picker("Save to", selection: $fileKind) {
                            Text("A folder").tag(FileKind.folder)
                            if offersCloud(.dropbox, .dropbox) { Text("Dropbox").tag(FileKind.dropbox) }
                            if offersCloud(.drive, .google) { Text("Google Drive").tag(FileKind.drive) }
                        }
                        .accessibilityIdentifier("file-kind")
                        .onChange(of: fileKind) { _, _ in cloudAccount = cloudAccounts.first?.id }
                    }
                    if fileKind == .folder {
                        Button(folderBookmark == nil ? "Choose a folder" : "Folder: \(folderName)") { choosingFolder = true }
                            .accessibilityIdentifier("choose-folder")
                        if let folderError { Text(folderError).font(.footnote).foregroundStyle(.red) }
                    } else if cloudAccounts.isEmpty {
                        Text("Connect an account in Settings first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Account", selection: $cloudAccount) {
                            ForEach(cloudAccounts) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        if fileKind == .dropbox {
                            TextField("Folder", text: $cloudPath)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            TextField("Folder", text: $driveFolder)
                            Toggle("Turn CSV into a Google Sheet", isOn: $driveSheets)
                        }
                    }
                    Toggle("Replace a file of the same name", isOn: $overwrite)
                } footer: {
                    Text(offersAnyCloud
                         ? "Each part is one file, named by the template. An interrupted cloud upload carries on where it stopped."
                         : "Each part is one file, named by the template.")
                }
                .task { await model.reloadAccounts() }
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if !Features.iCloudDriveFolders, (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                            folderError = "iCloud Drive isn't supported for health data yet. Choose a folder on this iPhone or use another service."
                            return
                        }
                        folderBookmark = try url.bookmarkData()
                        folderName = url.lastPathComponent
                        folderError = nil
                    } catch {
                        folderError = error.localizedDescription
                    }
                }
            }

            if template != nil && targetKind == .email {
                Section {
                    Picker("Send with", selection: $emailKind) {
                        Text("Mail or another app").tag(EmailKind.compose)
                        Text("My mail server (SMTP)").tag(EmailKind.smtp)
                        Text("A mail service").tag(EmailKind.api)
                    }
                    .accessibilityIdentifier("email-kind")
                    TextField("To", text: $emailTo)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("email-to")
                    TextField("Subject", text: $emailSubject)
                        .accessibilityIdentifier("email-subject")
                    TextField("Message", text: $emailBody, axis: .vertical)
                    if emailKind != .compose {
                        TextField("From", text: $emailFrom)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("email-from")
                    }
                    if emailKind == .smtp {
                        TextField("Server", text: $smtpHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("smtp-host")
                        Stepper("Port \(String(smtpPort))", value: $smtpPort, in: 1...65535)
                        Picker("Security", selection: $smtpSecurity) {
                            Text("STARTTLS").tag(SMTPSettings.Security.startTLS)
                            Text("TLS").tag(SMTPSettings.Security.tls)
                            Text("None").tag(SMTPSettings.Security.none)
                        }
                        .onChange(of: smtpSecurity) { _, next in
                            if next == .tls && smtpPort == 587 { smtpPort = 465 }
                            if next == .startTLS && smtpPort == 465 { smtpPort = 587 }
                        }
                        TextField("Username", text: $smtpUser)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $token)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if emailKind == .api {
                        Picker("Service", selection: $mailAPI) {
                            ForEach(MailAPI.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        SecureField("API key", text: $token)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(emailNote)
                }
            }

            if template != nil && targetKind == .calendar {
                Section {
                    Picker("Calendar", selection: $calendarID) {
                        Text("Default calendar").tag(String?.none)
                        ForEach(calendars, id: \.id) { Text($0.title).tag(String?.some($0.id)) }
                    }
                    .accessibilityIdentifier("calendar-picker")
                    .task {
                        calendars = await model.writableCalendars()
                    }
                } footer: {
                    Text("The template writes events with a key each. Running again updates them instead of adding more.")
                }
            }

            if template == nil || targetKind == .web {
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

            }

            Section {
                Picker("Trigger", selection: $kind) {
                    Text("Manual").tag(TriggerKind.manual)
                    Text("Health changes").tag(TriggerKind.health)
                    Text("Every").tag(TriggerKind.schedule)
                    Text("At a time").tag(TriggerKind.time)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("trigger-kind")
                if kind == .schedule {
                    Stepper("Every \(count)", value: $count, in: 1...999)
                        .accessibilityIdentifier("schedule-count")
                    Picker("Unit", selection: $unit) {
                        Text("Seconds").tag(Schedule.Unit.seconds)
                        Text("Minutes").tag(Schedule.Unit.minutes)
                        Text("Hours").tag(Schedule.Unit.hours)
                        Text("Days").tag(Schedule.Unit.days)
                        Text("Weeks").tag(Schedule.Unit.weeks)
                    }
                }
                if kind == .time {
                    DatePicker("Time", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("schedule-time")
                    HStack {
                        ForEach(Calendar.current.veryShortWeekdaySymbols.indices, id: \.self) { i in
                            let day = i + 1
                            Button(Calendar.current.veryShortWeekdaySymbols[i]) {
                                if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                            }
                            .buttonStyle(.bordered)
                            .tint(weekdays.contains(day) ? .accentColor : .secondary)
                            .frame(maxWidth: .infinity)
                        }
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
                .disabled(!isValid)
                .accessibilityIdentifier("save-pipeline")
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let existing {
                name = existing.name
                token = await model.token(for: existing.id)
                switch existing.kind {
                case .http(let e):
                    url = e.url.absoluteString
                    headers = e.headers
                case .target(.web(let web)):
                    url = web.url
                    headers = web.headers
                    method = web.method
                    automationHeaders = web.automationHeaders
                    if case .multipart = web.body { multipart = true }
                case .target(.share):
                    targetKind = .share
                case .target(.mqtt(let mqtt)):
                    targetKind = .mqtt
                    mqttHost = mqtt.host
                    mqttPort = mqtt.port
                    mqttTLS = mqtt.tls
                    mqttTopic = mqtt.topic
                    mqttClient = mqtt.clientID
                    mqttUser = mqtt.username
                    mqttQoS = mqtt.qos
                    mqttRetain = mqtt.retain
                case .target(.calendar(let calendar)):
                    targetKind = .calendar
                    calendarID = calendar.calendarID
                    calendarName = calendar.calendarName
                case .target(.file(let file)):
                    targetKind = .file
                    overwrite = file.overwrite
                    switch file.location {
                    case .folder(let bookmark, let name):
                        fileKind = .folder
                        folderBookmark = bookmark
                        folderName = name
                    case .dropbox(let account, let path):
                        fileKind = .dropbox
                        cloudAccount = account
                        cloudPath = path
                    case .googleDrive(let account, let folder, let sheets):
                        fileKind = .drive
                        cloudAccount = account
                        driveFolder = folder
                        driveSheets = sheets
                    }
                case .target(.email(let email)):
                    targetKind = .email
                    emailTo = email.to.joined(separator: ", ")
                    emailFrom = email.from
                    emailSubject = email.subject
                    emailBody = email.body
                    switch email.method {
                    case .compose: emailKind = .compose
                    case .smtp(let smtp):
                        emailKind = .smtp
                        smtpHost = smtp.host
                        smtpPort = smtp.port
                        smtpSecurity = smtp.security
                        smtpUser = smtp.username
                    case .api(let api):
                        emailKind = .api
                        mailAPI = api
                    }
                }
                let pipeline = model.snapshot.pipelines.first { $0.id == existing.id }
                if let definition = pipeline?.definition {
                    let entry = choices.first { $0.ref == definition.template }
                    template = entry ?? TemplateLibrary.Entry(ref: definition.template, name: definition.templateName, format: .text)
                    spec = definition.extract
                }
                let current = pipeline?.trigger
                saved = current
                switch current {
                case .whenHealthChanges: kind = .health
                case .every(let schedule):
                    kind = .schedule
                    count = schedule.count
                    unit = schedule.unit
                case .at(let time):
                    kind = .time
                    timeOfDay = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
                    weekdays = Set(time.weekdays ?? Array(1...7))
                default: kind = .manual
                }
            }
            if let link {
                name = link.name
                template = choices.first { $0.ref == .builtIn(link.template) }
                spec = link.extract
                targetKind = .web
                url = link.web.url
                headers = link.web.headers
                automationHeaders = link.web.automationHeaders
                token = link.token ?? ""
                switch link.trigger {
                case .every(let schedule):
                    kind = .schedule
                    count = schedule.count
                    unit = schedule.unit
                default:
                    kind = .manual
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

    private var emailNote: String {
        switch emailKind {
        case .compose:
            return "Opens Apple Mail's composer with the file attached, or the share sheet for Gmail and others. It needs a tap to send, so a scheduled run notifies you when it's ready."
        case .smtp:
            if smtpSecurity == .none { return "Without TLS, your password and Health data cross the network unencrypted. Only use this on your own network." }
            return "Sends unattended from your own account. Your password is kept in the Keychain. A service like Gmail needs an app password."
        case .api:
            return "Sends unattended with your own account at the service. Your key is kept in the Keychain. Attachments can be up to 25 MB."
        }
    }

    private var triggerNote: String {
        switch kind {
        case .manual:
            return "Runs only when you tap Run."
        case .health:
            return "Runs when Health records new data, each morning, and when you open the app, if Background App Refresh is on. iOS keeps Health data locked while your iPhone is locked, so changes overnight are sent after you first unlock it."
        case .schedule where unit == .seconds && count < 60:
            return "Runs only while the app is open. iOS has no background work this often."
        case .schedule, .time:
            return "Runs as soon as it can once due. iOS decides when background work happens and keeps Health data locked while your iPhone is locked, so a run can come later than its time."
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let template {
            let definition = PipelineDefinition(extract: spec, template: template.ref, templateName: template.name)
            switch targetKind {
            case .share:
                await model.save(existing: status?.destination, name: trimmed, target: .share, definition: definition, token: "", trigger: trigger)
                return
            case .mqtt:
                let mqtt = MQTTTarget(host: mqttHost.trimmingCharacters(in: .whitespaces), port: mqttPort, tls: mqttTLS, topic: mqttTopic, clientID: mqttClient, username: mqttUser, qos: mqttQoS, retain: mqttRetain)
                await model.save(existing: status?.destination, name: trimmed, target: .mqtt(mqtt), definition: definition, token: token, trigger: trigger)
                return
            case .calendar:
                let title = calendars.first { $0.id == calendarID }?.title ?? calendarName
                await model.save(existing: status?.destination, name: trimmed, target: .calendar(CalendarTarget(calendarID: calendarID, calendarName: title)), definition: definition, token: "", trigger: trigger)
                return
            case .file:
                guard let location = fileLocation else { return }
                await model.save(existing: status?.destination, name: trimmed, target: .file(FileTarget(location: location, overwrite: overwrite)), definition: definition, token: "", trigger: trigger)
                return
            case .email:
                let email = EmailTarget(method: emailMethod, from: emailFrom, to: emailRecipients, subject: emailSubject, body: emailBody)
                await model.save(existing: status?.destination, name: trimmed, target: .email(email), definition: definition, token: emailKind == .compose ? "" : token, trigger: trigger)
                return
            case .web:
                break
            }
            let web = WebTarget(url: url.trimmingCharacters(in: .whitespaces), method: method,
                                headers: headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty },
                                body: multipart ? .multipart(field: "file") : .raw, automationHeaders: automationHeaders)
            await model.save(existing: status?.destination, name: trimmed, target: .web(web), definition: definition, token: token, trigger: trigger)
            return
        }
        guard let endpoint else { return }
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
    /// "Health Data Relay → example.com"
    var flow: String {
        "\(transform.title) → \(destinationSummary)"
    }
}

extension TransformSpec {
    var title: String {
        switch self {
        case .healthDataRelayPush: "Health Data Relay"
        case .template(_, let name): name
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
        case .at(let time):
            let date = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
            let clock = date.formatted(date: .omitted, time: .shortened)
            guard let days = time.weekdays else { return "Daily at \(clock)" }
            let names = days.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            return "\(names) at \(clock)"
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
        case .rendering(let name): "Writing \(name)'s output"
        case .sendingPart(let part, let total, let name): total > 1 ? "Sending part \(part) of \(total) to \(name)" : "Sending to \(name)"
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
