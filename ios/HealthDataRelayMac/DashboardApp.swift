import Charts
import HealthDataRelayKit
import Observation
import SwiftUI

/// The Mac's view of a phone's Health data. A Mac has no Health data of its
/// own, so everything comes from the phone's server and is kept for next time.
@MainActor @Observable
final class DashboardModel {
    struct Connection: Codable, Equatable {
        var address = ""
        var fingerprint = ""
        /// Whole days to fetch.
        var days = 30
    }

    private(set) var dashboard: Dashboard?
    private(set) var loading = false
    private(set) var problem: String?
    var connection = Connection()
    var token = ""
    /// Showing sample data rather than a phone's.
    private(set) var demo = ProcessInfo.processInfo.arguments.contains("-demo")

    private let tokens = KeychainTokenStore(service: "health-data-relay.mac")
    private static let tokenID = UUID(uuidString: "5E7E1000-0000-4000-8000-000000000010")!

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HealthDataRelayDashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var connectionFile: URL { folder.appendingPathComponent("connection.json") }
    private var dashboardFile: URL { folder.appendingPathComponent("dashboard.json") }

    var isConnected: Bool { demo || !connection.address.isEmpty }

    init() {
        if let data = try? Data(contentsOf: connectionFile), let saved = try? JSONDecoder().decode(Connection.self, from: data) { connection = saved }
        token = tokens.token(for: Self.tokenID) ?? ""
        if !demo, let data = try? Data(contentsOf: dashboardFile) { dashboard = try? JSONDecoder().decode(Dashboard.self, from: data) }
    }

    func useDemo() async {
        demo = true
        await refresh()
    }

    func connect() async {
        demo = false
        try? JSONEncoder().encode(connection).write(to: connectionFile, options: .atomic)
        tokens.setToken(token, for: Self.tokenID)
        await refresh()
    }

    func disconnect() {
        connection = Connection()
        token = ""
        tokens.setToken(nil, for: Self.tokenID)
        dashboard = nil
        problem = nil
        demo = false
        try? FileManager.default.removeItem(at: connectionFile)
        try? FileManager.default.removeItem(at: dashboardFile)
    }

    func setDays(_ days: Int) async {
        connection.days = days
        try? JSONEncoder().encode(connection).write(to: connectionFile, options: .atomic)
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let source: PhoneSource = demo ? DemoSource() : try PhoneClient(address: connection.address, token: token, fingerprint: connection.fingerprint)
            let fetched = try await Dashboard.fetch(from: source, days: connection.days)
            dashboard = fetched
            if !demo, let data = try? JSONEncoder().encode(fetched) { try? data.write(to: dashboardFile, options: .atomic) }
        } catch {
            // The last data stays on screen, with the reason it's not newer.
            problem = String(describing: error)
        }
    }
}

@main
struct DashboardApp: App {
    @State private var model = DashboardModel()

    var body: some Scene {
        WindowGroup("Health Data Relay") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 540)
                .task { if model.isConnected { await model.refresh() } }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct RootView: View {
    @Environment(DashboardModel.self) private var model

    var body: some View {
        if model.isConnected {
            DashboardView()
        } else {
            ConnectView()
        }
    }
}

/// Setting up a phone, with what's on its Server screen.
struct ConnectView: View {
    @Environment(DashboardModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Address", text: $model.connection.address, prompt: Text("https://192.168.1.20:8443/mcp"))
                SecureField("Token", text: $model.token)
                TextField("Certificate fingerprint", text: $model.connection.fingerprint, prompt: Text("AB:CD:EF:…"))
            } header: {
                Text("Your iPhone")
            } footer: {
                Text("On your iPhone, open Health Data Relay, go to Settings › Server and turn on MCP server. It's there while the app is open and on the same network. The fingerprint is how this Mac knows it's your iPhone.")
                    .foregroundStyle(.secondary)
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red)
            }
            HStack {
                Button("Try with sample data") { Task { await model.useDemo() } }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.connection.address.isEmpty || model.token.isEmpty || model.connection.fingerprint.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .padding()
    }
}

struct DashboardView: View {
    @Environment(DashboardModel.self) private var model
    @State private var selection: String? = "overview"

    private var groups: [(String, [Dashboard.Series])] {
        let all = model.dashboard?.series ?? []
        return Dictionary(grouping: all, by: \.group).sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag("overview")
                Label("Workouts", systemImage: "figure.run").tag("workouts")
                ForEach(groups, id: \.0) { group in
                    Section(group.0.capitalized) {
                        ForEach(group.1) { Text($0.title).tag($0.name) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.15))
                }
                detail
            }
            .toolbar {
                ToolbarItemGroup {
                    if let at = model.dashboard?.fetchedAt {
                        Text("Updated \(at, format: .relative(presentation: .named))").foregroundStyle(.secondary)
                    }
                    Picker("Range", selection: Binding { model.connection.days } set: { days in Task { await model.setDays(days) } }) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        if model.loading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    Menu {
                        Button("Disconnect") { model.disconnect() }
                    } label: {
                        Label("Connection", systemImage: "iphone")
                    }
                }
            }
        }
        .navigationTitle(model.demo ? "Sample data" : "Health Data Relay")
    }

    @ViewBuilder private var detail: some View {
        if model.dashboard == nil {
            ContentUnavailableView("Nothing yet", systemImage: "iphone", description: Text(model.loading ? "Asking your iPhone…" : "Open Health Data Relay on your iPhone, then refresh."))
        } else if selection == "workouts" {
            WorkoutsView(workouts: model.dashboard?.workouts ?? [])
        } else if let s = model.dashboard?.series.first(where: { $0.name == selection }) {
            SeriesDetail(series: s)
        } else {
            OverviewView(series: model.dashboard?.series ?? [], open: { selection = $0 })
        }
    }
}

struct OverviewView: View {
    let series: [Dashboard.Series]
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                ForEach(series) { s in
                    Button {
                        open(s.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            if let latest = s.latest {
                                Text("\(latest.value.formatted(.number.precision(.fractionLength(0...1)))) \(s.units)")
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            SeriesChart(series: s, compact: true).frame(height: 60)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct SeriesDetail: View {
    let series: Dashboard.Series

    private var values: [Double] { series.points.map(\.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(series.title).font(.largeTitle.weight(.semibold))
            SeriesChart(series: series, compact: false)
            HStack(spacing: 28) {
                stat("Average", values.reduce(0, +) / Double(max(values.count, 1)))
                stat("Lowest", values.min() ?? 0)
                stat("Highest", values.max() ?? 0)
            }
        }
        .padding()
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(series.units)").font(.title3).monospacedDigit()
        }
    }
}

struct SeriesChart: View {
    let series: Dashboard.Series
    let compact: Bool

    var body: some View {
        Chart(series.points) { p in
            if series.bars {
                BarMark(x: .value("Date", p.date, unit: .day), y: .value(series.title, p.value))
            } else {
                if let low = p.low, let high = p.high {
                    AreaMark(x: .value("Date", p.date), yStart: .value("Low", low), yEnd: .value("High", high)).opacity(0.18)
                }
                LineMark(x: .value("Date", p.date), y: .value(series.title, p.value))
            }
        }
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
    }
}

struct WorkoutsView: View {
    let workouts: [Dashboard.Workout]

    var body: some View {
        Table(workouts) {
            TableColumn("Workout", value: \.name)
            TableColumn("When") { Text($0.start, format: .dateTime.month().day().hour().minute()) }
            TableColumn("Minutes") { Text(($0.duration / 60).formatted(.number.precision(.fractionLength(0)))).monospacedDigit() }
            TableColumn("Distance") { Text($0.distance ?? "") }
            TableColumn("Energy") { Text($0.energy ?? "") }
        }
        .overlay {
            if workouts.isEmpty { ContentUnavailableView("No workouts", systemImage: "figure.run") }
        }
    }
}
