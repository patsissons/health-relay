import HealthRelayKit
import SwiftUI

/// The destinations: add an HTTP endpoint, edit, test, pause, remove.
struct DestinationsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if model.snapshot.destinations.isEmpty {
                    ContentUnavailableView {
                        Label("No destinations", systemImage: "paperplane")
                    } description: {
                        Text("A destination is any HTTP endpoint that accepts the Health Relay schema: your own server, a self-hosted dashboard, a home automation webhook.")
                    } actions: {
                        Button("Add a destination") { adding = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                ForEach(model.snapshot.destinations) { status in
                    NavigationLink {
                        DestinationEditor(existing: status.destination)
                    } label: {
                        DestinationStatusRow(status: status)
                    }
                }
            }
            .navigationTitle("Destinations")
            .toolbar {
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("add-destination")
            }
            .sheet(isPresented: $adding) {
                NavigationStack { DestinationEditor(existing: nil) }
            }
        }
    }
}

/// Adds or edits an HTTP endpoint destination.
struct DestinationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Destination?

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var headers: [HTTPEndpoint.Header] = []
    @State private var loaded = false
    @State private var testing = false
    @State private var confirmRemove = false

    private var endpoint: HTTPEndpoint? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              ["http", "https"].contains(scheme), u.host() != nil else { return nil }
        return HTTPEndpoint(url: u, headers: headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private var status: DestinationStatus? {
        existing.flatMap { e in model.snapshot.destinations.first { $0.id == e.id } }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("destination-name")
                TextField("https://example.com/push", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("destination-url")
                SecureField("Bearer token (optional)", text: $token)
                    // Not a password: keeps iOS from offering to save it to Passwords.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("destination-token")
            } header: {
                Text("HTTP endpoint")
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

            if let status {
                Section {
                    Button {
                        testing = true
                        Task {
                            await save()
                            await model.test(status.id)
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
                    .disabled(testing || endpoint == nil)
                    .accessibilityIdentifier("test-destination")
                    if let answer = model.tests[status.id] {
                        Label("\(answer.status.map { "\($0)" } ?? "No answer") · \(answer.message)", systemImage: answer.verdict.symbol)
                            .foregroundStyle(answer.verdict.color)
                            .font(.subheadline)
                            .accessibilityIdentifier("test-result")
                    }
                } footer: {
                    Text("Sends an empty push (no days). Any receiver of the schema answers it with success.")
                }

                Section {
                    Toggle("Paused", isOn: Binding(
                        get: { status.destination.paused },
                        set: { paused in Task { await model.setPaused(status.id, paused) } }))
                } footer: {
                    Text("A paused destination keeps collecting days to send and catches up when resumed.")
                }

                Section {
                    Button("Remove destination", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Forgets its waiting days, queue and log. Data it already received stays there.")
                }
            }
        }
        .navigationTitle(existing == nil ? "New destination" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                        dismiss()
                    }
                }
                .disabled(endpoint == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("save-destination")
            }
        }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let id = existing?.id else { return }
                Task {
                    await model.remove(id)
                    dismiss()
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            guard let existing, case .http(let e) = existing.kind else { return }
            name = existing.name
            url = e.url.absoluteString
            headers = e.headers
            token = await model.token(for: existing.id)
        }
    }

    private func save() async {
        guard let endpoint else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var d = status?.destination {
            d.name = trimmed
            d.kind = .http(endpoint)
            await model.update(d, token: token)
        } else {
            await model.add(name: trimmed, endpoint: endpoint, token: token)
        }
    }
}
