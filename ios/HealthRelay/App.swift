import HealthRelayKit
import SwiftUI

@main
struct HealthRelayApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                StatusView()
                    .tabItem { Label("Status", systemImage: "heart.text.square") }
                DestinationsView()
                    .tabItem { Label("Destinations", systemImage: "paperplane") }
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
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await model.becameActive() } }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTask)) {
            await model.refresh()
        }
    }
}
