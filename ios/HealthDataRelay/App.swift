import BackgroundTasks
import HealthDataRelayKit
import SwiftUI

/// What SwiftUI's app lifecycle doesn't cover: long background processing has
/// to be registered at launch, and background uploads report here.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.processingTask, using: nil) { task in
            let work = Task { @MainActor in
                await AppDelegate.model?.process()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        let done = UncheckedCompletion(completionHandler)
        MainActor.assumeIsolated {
            AppDelegate.model?.uploader.handleBackgroundEvents { done.call() }
        }
    }

    private struct UncheckedCompletion: @unchecked Sendable {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        func call() { DispatchQueue.main.async { body() } }
    }
}

@main
struct HealthDataRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                PipelinesView()
                    .tabItem { Label("Pipelines", systemImage: "arrow.triangle.branch") }
                TemplatesView()
                    .tabItem { Label("Templates", systemImage: "doc.text") }
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
            .onAppear { AppDelegate.model = model }
            .onOpenURL { url in Task { await model.open(url) } }
            .sheet(item: Binding(get: { model.setup }, set: { model.setup = $0 })) { setup in
                NavigationStack { PipelineEditor(existing: setup.existing, setup: setup.link) }
                    .environment(model)
            }
            .alert("Not a setup link", isPresented: Binding(get: { model.badLink }, set: { model.badLink = $0 })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Health Data Relay opens links of the form healthdatarelay://destination?url=…, usually from a destination's QR code.")
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
