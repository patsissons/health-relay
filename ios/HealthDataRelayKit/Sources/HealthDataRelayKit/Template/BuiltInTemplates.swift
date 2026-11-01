import Foundation

/// The templates that ship with the app, read from its bundle.
public enum BuiltInTemplates {
    /// The apple-push/1 schema as a template. Production keeps the native
    /// path; this is there to copy, and a test holds it to the fixture.
    public static let healthDataRelay = "health-data-relay"

    public static let metricsJSONv2 = "metrics-json-v2"
    public static let healthReportMarkdown = "health-report-markdown"
    public static let workoutRoutesGPX = "workout-routes-gpx"
    public static let metricsCSV = "metrics-csv"
    public static let healthSummaryHTML = "health-summary-html"

    /// What the app offers, in order. The native format's twin comes last: it
    /// reads the same data as the native push and is there to copy.
    public static let all = [metricsJSONv2, metricsCSV, healthReportMarkdown, healthSummaryHTML, workoutRoutesGPX, healthDataRelay]

    public static func source(_ id: String) -> String? {
        guard let url = Bundle.module.url(forResource: id, withExtension: "liquid", subdirectory: "Templates") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func template(_ id: String) throws -> ParsedTemplate {
        guard let text = source(id) else { throw TemplateError(message: "No built-in template named \(id)") }
        return try ParsedTemplate(source: text)
    }
}
