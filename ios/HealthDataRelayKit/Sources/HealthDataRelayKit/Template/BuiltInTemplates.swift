import Foundation

/// The templates that ship with the app, read from its bundle.
public enum BuiltInTemplates {
    /// The apple-push/1 schema as a template. Production keeps the native
    /// path; this is there to copy, and a test holds it to the fixture.
    public static let healthDataRelay = "health-data-relay"

    public static let metricsJSONv2 = "metrics-json-v2"

    /// What the app offers to start from, in order.
    public static let all = [healthDataRelay, metricsJSONv2]

    public static func source(_ id: String) -> String? {
        guard let url = Bundle.module.url(forResource: id, withExtension: "liquid", subdirectory: "Templates") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func template(_ id: String) throws -> ParsedTemplate {
        guard let text = source(id) else { throw TemplateError(message: "No built-in template named \(id)") }
        return try ParsedTemplate(source: text)
    }
}
