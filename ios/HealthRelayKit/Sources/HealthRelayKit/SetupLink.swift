import Foundation

/// A destination's settings carried in a link, for a receiver to show as a
/// QR code: `healthrelay://destination?name=<label>&url=<push URL>&token=<bearer>`,
/// values percent-encoded. `url` is required; `name`, `token` and repeated
/// `header=<Name>: <Value>` are optional, and unknown parameters are ignored.
/// The app only fills the destination editor from it; the user saves.
public struct SetupLink: Sendable, Equatable {
    public static let scheme = "healthrelay"
    public static let action = "destination"

    public var endpoint: HTTPEndpoint
    public var token: String?
    public var name: String?

    public init(endpoint: HTTPEndpoint, token: String? = nil, name: String? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.name = name
    }

    /// nil unless it is a setup link with an http(s) URL that has a host.
    public init?(_ link: URL) {
        guard link.scheme?.lowercased() == Self.scheme, link.host()?.lowercased() == Self.action,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func first(_ key: String) -> String? {
            items.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let text = first("url"), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        let headers = items.filter { $0.name == "header" }.compactMap { item -> HTTPEndpoint.Header? in
            guard let value = item.value, let colon = value.firstIndex(of: ":") else { return nil }
            let name = value[..<colon].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .init(name: name, value: value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        self.init(endpoint: HTTPEndpoint(url: url, headers: headers), token: first("token"), name: first("name"))
    }

    /// The link, every value percent-encoded as `encodeURIComponent` does.
    public var url: URL {
        var query: [(String, String)] = []
        if let name { query.append(("name", name)) }
        query.append(("url", endpoint.url.absoluteString))
        if let token { query.append(("token", token)) }
        query += endpoint.headers.map { ("header", "\($0.name): \($0.value)") }
        let text = query.map { "\($0)=\(Self.encode($1))" }.joined(separator: "&")
        return URL(string: "\(Self.scheme)://\(Self.action)?\(text)")!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
}
