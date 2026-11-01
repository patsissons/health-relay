import AppIntents
import HealthDataRelayKit

/// A pipeline, as Shortcuts sees it.
struct PipelineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pipeline"
    static let defaultQuery = PipelineQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PipelineQuery: EntityQuery {
    @MainActor
    private func all() async -> [PipelineEntity] {
        await AppModel.shared.pipelines().map { PipelineEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [UUID]) async throws -> [PipelineEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PipelineEntity] {
        await all()
    }
}

/// Runs a pipeline from Shortcuts, including on an automation's schedule.
struct RunPipelineIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Pipeline"
    static let description = IntentDescription("Runs a Health Data Relay pipeline now.")
    static let openAppWhenRun = false

    @Parameter(title: "Pipeline") var pipeline: PipelineEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$pipeline)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let message = await AppModel.shared.runForShortcut(pipeline.id)
        return .result(value: message)
    }
}

/// Today's value for a metric, to use in a shortcut.
struct TodayValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Health Value"
    static let description = IntentDescription("Reads a metric's value for today, such as your steps so far.")
    static let openAppWhenRun = false

    @Parameter(title: "Metric", default: .steps) var metric: MetricChoice

    static var parameterSummary: some ParameterSummary { Summary("Get today's \(\.$metric)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await AppModel.shared.todayText(metric: metric.rawValue) ?? "No data yet")
    }
}

enum MetricChoice: String, AppEnum {
    case steps = "step_count"
    case energy = "active_energy"
    case exercise = "apple_exercise_time"
    case restingHeartRate = "resting_heart_rate"
    case sleep = "sleep_analysis"
    case weight = "weight_body_mass"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    static let caseDisplayRepresentations: [MetricChoice: DisplayRepresentation] = [
        .steps: "Steps", .energy: "Active Energy", .exercise: "Exercise Minutes",
        .restingHeartRate: "Resting Heart Rate", .sleep: "Sleep", .weight: "Weight",
    ]
}

struct HealthDataRelayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunPipelineIntent(), phrases: ["Run a pipeline in \(.applicationName)"], shortTitle: "Run Pipeline", systemImageName: "play.fill")
        AppShortcut(intent: TodayValueIntent(), phrases: ["Get today's health value from \(.applicationName)"], shortTitle: "Today's Value", systemImageName: "heart.text.square")
    }
}
