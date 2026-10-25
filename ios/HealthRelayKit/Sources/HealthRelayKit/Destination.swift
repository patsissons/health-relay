import Foundation
import Security

/// Somewhere the user chose to send their days.
public struct Destination: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case http(HTTPEndpoint)
    }

    public var id: UUID
    public var name: String
    public var paused: Bool
    public var kind: Kind

    public init(id: UUID = UUID(), name: String, paused: Bool = false, kind: Kind) {
        self.id = id
        self.name = name
        self.paused = paused
        self.kind = kind
    }
}

/// An HTTP endpoint destination's settings; its bearer token is kept in a
/// TokenStore (the Keychain), never here.
public struct HTTPEndpoint: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public var url: URL
    public var headers: [Header]

    public init(url: URL, headers: [Header] = []) {
        self.url = url
        self.headers = headers
    }
}

/// What a destination made of a push.
public enum Verdict: String, Codable, Sendable {
    /// 2xx: the days are delivered.
    case accepted
    /// 401 or 403: the credential is gone; stop until the user fixes it.
    case authFailed
    /// Another 4xx: the body was refused; resending it would fail again.
    case rejected
    /// 5xx, 408, 429 or a network error: try again later.
    case retry
}

public struct Delivery: Codable, Sendable, Equatable {
    public var status: Int?
    public var verdict: Verdict
    /// The receiver's message, or a description of the failure.
    public var message: String

    public init(status: Int?, verdict: Verdict, message: String) {
        self.status = status
        self.verdict = verdict
        self.message = message
    }

    /// The verdict for an HTTP status; the status alone decides.
    public static func verdict(for status: Int) -> Verdict {
        switch status {
        case 200..<300: .accepted
        case 401, 403: .authFailed
        case 408, 429: .retry
        case 400..<500: .rejected
        default: .retry
        }
    }

    /// The answer to show: the receiver's `message` or `error`, else its
    /// other fields, else the start of the body, else the status.
    public static func message(status: Int, body: Data) -> String {
        if let json = JSON.parse(body), case .object(let fields) = json {
            if let m = fields["message"]?.stringValue, !m.isEmpty { return m }
            if let e = fields["error"]?.stringValue, !e.isEmpty { return e }
            let rest = fields.filter { $0.key != "ok" && $0.value != .null }.sorted { $0.key < $1.key }
            if !rest.isEmpty {
                return rest.map { "\($0.key) \($0.value.canonical.replacingOccurrences(of: "\"", with: ""))" }.joined(separator: ", ")
            }
        }
        let text = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }
}

/// A kind of destination: delivers one batch and reports the verdict. A
/// new kind (a file export, MQTT) implements only this.
public protocol DestinationType: Sendable {
    func deliver(_ body: Data) async -> Delivery
}

/// POSTs the batch as JSON.
public struct HTTPEndpointDestination: DestinationType {
    public static let timeout: TimeInterval = 30

    public let endpoint: HTTPEndpoint
    public let token: String?
    public let session: URLSession

    public init(endpoint: HTTPEndpoint, token: String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
    }

    public func request(_ body: Data) -> URLRequest {
        var r = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        r.httpMethod = "POST"
        for h in endpoint.headers where !h.name.isEmpty { r.setValue(h.value, forHTTPHeaderField: h.name) }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.httpBody = body
        return r
    }

    public func deliver(_ body: Data) async -> Delivery {
        do {
            let (data, response) = try await session.data(for: request(body))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Delivery(status: status, verdict: Delivery.verdict(for: status), message: Delivery.message(status: status, body: data))
        } catch {
            return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
        }
    }
}

/// Where destination secrets live.
public protocol TokenStore: Sendable {
    func token(for id: UUID) -> String?
    func setToken(_ token: String?, for id: UUID)
}

/// Tokens in the Keychain, readable after the first unlock so background
/// syncs can use them.
public struct KeychainTokenStore: TokenStore {
    public let service: String

    public init(service: String = "health-relay.destination-token") {
        self.service = service
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    public func token(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func setToken(_ token: String?, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var q = query(id)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Tokens in memory (tests, previews).
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    public init() {}

    public func token(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[id]
    }

    public func setToken(_ token: String?, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tokens[id] = token?.isEmpty == false ? token : nil
    }
}
