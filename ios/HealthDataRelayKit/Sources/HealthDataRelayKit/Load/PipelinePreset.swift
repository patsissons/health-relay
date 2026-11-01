import Foundation

/// A sensible starting point for a common job. It fills in the editor, and
/// everything can still be changed.
public struct PipelinePreset: Identifiable, Sendable {
    public var name: String
    public var note: String
    public var template: String
    public var extract: ExtractSpec
    public var trigger: PipelineTrigger
    /// What to fill in for the destination, when the job implies one.
    public var target: LoadTarget?

    public var id: String { name }

    public static func all(now: Date = Date()) -> [PipelinePreset] {
        [
            PipelinePreset(name: "Dashboard, each morning", note: "Yesterday's metrics and workouts as JSON, for dashboards and databases.",
                           template: BuiltInTemplates.metricsJSONv2,
                           extract: ExtractSpec(sections: [.metrics, .workouts], range: .yesterday, grouping: .automatic),
                           trigger: .every(Schedule(count: 1, unit: .days, since: now))),
            PipelinePreset(name: "New data, as it arrives", note: "Everything since the last run as JSON, whenever Health changes.",
                           template: BuiltInTemplates.metricsJSONv2,
                           extract: ExtractSpec(sections: [.metrics, .workouts], range: .sinceLastRun, grouping: .automatic),
                           trigger: .whenHealthChanges),
            PipelinePreset(name: "Weekly spreadsheet", note: "The last week by day, one CSV a week.",
                           template: BuiltInTemplates.metricsCSV,
                           extract: ExtractSpec(sections: [.metrics], range: .previousDays(7), grouping: .days),
                           trigger: .every(Schedule(count: 1, unit: .weeks, since: now))),
            PipelinePreset(name: "Daily notes", note: "Yesterday as Markdown, for notes apps.",
                           template: BuiltInTemplates.healthReportMarkdown,
                           extract: ExtractSpec(sections: [.metrics, .workouts], range: .yesterday, grouping: .hours),
                           trigger: .every(Schedule(count: 1, unit: .days, since: now))),
            PipelinePreset(name: "Workout routes", note: "A GPX file for each new workout with a route.",
                           template: BuiltInTemplates.workoutRoutesGPX,
                           extract: ExtractSpec(sections: [.workouts], range: .sinceLastRun, grouping: .days),
                           trigger: .whenHealthChanges),
            PipelinePreset(name: "Home Assistant sensors", note: "Each metric's latest value as a sensor, every hour. Use a long-lived access token.",
                           template: BuiltInTemplates.homeAssistantStates,
                           extract: ExtractSpec(sections: [.metrics], range: .today, grouping: .days),
                           trigger: .every(Schedule(count: 1, unit: .hours, since: now)),
                           target: .web(WebTarget(url: "http://homeassistant.local:8123/api/states/sensor.health_{{ partition.key }}", automationHeaders: false))),
            PipelinePreset(name: "Workouts on my calendar", note: "Each new workout as a calendar event.",
                           template: BuiltInTemplates.workoutsCalendar,
                           extract: ExtractSpec(sections: [.workouts], range: .previousDays(7), grouping: .days),
                           trigger: .every(Schedule(count: 1, unit: .days, since: now)),
                           target: .calendar(CalendarTarget(calendarID: nil, calendarName: "Default calendar"))),
        ]
    }
}
