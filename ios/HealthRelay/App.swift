import HealthRelayKit
import SwiftUI

@main
struct HealthRelayApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                PipelinesView()
                    .tabItem { Label("Pipelines", systemImage: "arrow.triangle.branch") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                #if DEBUG && targetEnvironment(simulator)
                // Simulator only, so a real phone's Health never gets synthetic data.
                // -hideSeed: screenshots without the tab.
                if !ProcessInfo.processInfo.arguments.contains("-hideSeed") {
                    SeedView()
                        .tabItem { Label("Seed", systemImage: "leaf") }
                }
                #endif
            }
            .environment(model)
            .onOpenURL { url in Task { await model.open(url) } }
            .sheet(item: Binding(get: { model.setup }, set: { model.setup = $0 })) { setup in
                NavigationStack { PipelineEditor(existing: setup.existing, setup: setup.link) }
                    .environment(model)
            }
            .alert("Not a setup link", isPresented: Binding(get: { model.badLink }, set: { model.badLink = $0 })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Health Relay opens links of the form healthrelay://destination?url=…, usually from a destination's QR code.")
            }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await model.becameActive() } } else { model.leftForeground() }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTask)) {
            await model.refresh()
        }
    }
}
