import HealthDataRelayKit
import SwiftUI

/// What belongs to the whole app: Health access, this phone's name, and
/// which types have data.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var deviceName = ""
    @FocusState private var editingName: Bool

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
                    }
                }

                Section {
                    TextField("iPhone", text: $deviceName)
                        .focused($editingName)
                        .submitLabel(.done)
                        .accessibilityIdentifier("device-name")
                        // Saved on leaving the field, however it is left.
                        .onChange(of: editingName) { _, editing in if !editing { saveName() } }
                        .onDisappear { saveName() }
                } header: {
                    Text("This iPhone's name")
                } footer: {
                    Text("Destinations see this name with each delivery.")
                }

                Section {
                    NavigationLink("Data by type") { TypesView() }
                    NavigationLink("Values by day") { DayValuesView() }
                    NavigationLink("Activity") { ActivityView() }
                        .accessibilityIdentifier("activity")
                } footer: {
                    Text("iOS keeps Health data locked while your iPhone is locked, so nothing can be read until you unlock it.")
                }

                Section {
                    NavigationLink("Server") { ServerView() }
                        .accessibilityIdentifier("server")
                } footer: {
                    Text("Lets tools on your network ask about your Health data while this app is open.")
                }

                Section {
                    NavigationLink("Connected accounts") { AccountsView() }
                        .accessibilityIdentifier("connected-accounts")
                } footer: {
                    Text("Cloud storage your pipelines can save to.")
                }

                Section {
                    Link("Privacy policy", destination: URL(string: "https://health-relay.lgtm.page/privacy/")!)
                }
            }
            .navigationTitle("Settings")
            .dismissingKeyboardOnScroll()
            // The saved name, once loaded and after each save, unless being edited.
            .onChange(of: snapshot.deviceName, initial: true) { _, name in
                if !editingName { deviceName = name }
            }
        }
    }

    private func saveName() {
        guard deviceName != snapshot.deviceName else { return }
        let name = deviceName
        Task { await model.setDeviceName(name) }
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
                Text("If you expected data here, check Settings > Health > Data Access & Devices > Health Data Relay.")
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

extension View {
    /// Vision Pro has no keyboard to scroll away.
    @ViewBuilder func dismissingKeyboardOnScroll() -> some View {
        #if os(visionOS)
        self
        #else
        scrollDismissesKeyboard(.immediately)
        #endif
    }
}
