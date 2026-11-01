import CryptoKit
import HealthDataRelayKit
import Observation
import SwiftUI

/// The on-device server: on only when asked, and only while the app is open.
@MainActor @Observable
final class ServerController {
    struct Settings: Codable, Equatable {
        var mcpOn = false
        var mcpPort = 8443
        var tcpOn = false
        var tcpPort = 9000
    }

    private(set) var settings = Settings()
    private(set) var running = false
    private(set) var problem: String?
    private(set) var token = ""
    private(set) var fingerprint = ""
    private(set) var certificatePEM = ""

    private let file: URL
    private let tokens: TokenStore
    private let handler: () -> MCPHandler
    private var mcp: LocalServer?
    private var tcp: LocalServer?

    /// Fixed ids for what's kept in the Keychain.
    private static let tokenID = UUID(uuidString: "5E7E1000-0000-4000-8000-000000000001")!
    private static let certificateID = UUID(uuidString: "5E7E1000-0000-4000-8000-000000000002")!

    private struct SavedCertificate: Codable {
        var der: Data
        var key: Data
        var names: [String]
    }

    init(root: URL, tokens: TokenStore, handler: @escaping () -> MCPHandler) {
        file = root.appendingPathComponent("server.json")
        self.tokens = tokens
        self.handler = handler
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Settings.self, from: data) { settings = saved }
        token = tokens.token(for: Self.tokenID) ?? ""
        if let saved = savedCertificate() { fingerprint = (try? LocalCertificate(der: saved.der, key: P256.Signing.PrivateKey(x963Representation: saved.key)).fingerprint) ?? "" }
    }

    func update(_ change: (inout Settings) -> Void) async {
        change(&settings)
        try? JSONEncoder().encode(settings).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        stop()
        await start()
    }

    func newToken() async {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        tokens.setToken(token, for: Self.tokenID)
        stop()
        await start()
    }

    private func savedCertificate() -> SavedCertificate? {
        tokens.token(for: Self.certificateID).flatMap { try? JSONDecoder().decode(SavedCertificate.self, from: Data($0.utf8)) }
    }

    /// The saved certificate, or a new one if this phone's addresses have changed.
    private func certificate() throws -> LocalCertificate {
        let names = ["localhost"] + Self.addresses()
        if let saved = savedCertificate(), Set(saved.names) == Set(names), let key = try? P256.Signing.PrivateKey(x963Representation: saved.key) {
            return LocalCertificate(der: saved.der, key: key)
        }
        let made = try LocalCertificate.make(names: ["localhost"], addresses: Self.addresses(), now: .now)
        let saved = SavedCertificate(der: made.der, key: made.key.x963Representation, names: names)
        tokens.setToken(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self), for: Self.certificateID)
        return made
    }

    func start() async {
        problem = nil
        guard settings.mcpOn || settings.tcpOn else {
            running = false
            return
        }
        do {
            if settings.mcpOn {
                if token.isEmpty { await newToken(); if running { return } }
                let cert = try certificate()
                fingerprint = cert.fingerprint
                certificatePEM = cert.pem
                let server = try LocalServer(kind: .http(MCPHTTPEndpoint(handler: handler(), token: token), identity: try cert.identity()), port: UInt16(settings.mcpPort))
                _ = try await server.start()
                mcp = server
            }
            if settings.tcpOn {
                let server = try LocalServer(kind: .tcp(handler()), port: UInt16(settings.tcpPort))
                _ = try await server.start()
                tcp = server
            }
            running = true
        } catch {
            problem = error.localizedDescription
            stop()
        }
    }

    func stop() {
        mcp?.stop()
        tcp?.stop()
        mcp = nil
        tcp = nil
        running = false
    }

    /// This phone's addresses on its networks, where a client would find it.
    static func addresses() -> [String] {
        var out: [String] = ["127.0.0.1"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var at: UnsafeMutablePointer<ifaddrs>? = first
        while let row = at {
            defer { at = row.pointee.ifa_next }
            guard let addr = row.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: row.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    var address: String { Self.addresses().last ?? "127.0.0.1" }
}

struct ServerView: View {
    @Environment(AppModel.self) private var model
    @State private var showToken = false

    private var server: ServerController { model.server }

    var body: some View {
        Form {
            Section {
                Toggle("MCP server", isOn: Binding { server.settings.mcpOn } set: { on in
                    Task {
                        if on { await model.allowEveryType() }
                        await server.update { $0.mcpOn = on }
                    }
                })
                .accessibilityIdentifier("mcp-toggle")
                if server.settings.mcpOn {
                    Stepper("Port \(String(server.settings.mcpPort))", value: Binding { server.settings.mcpPort } set: { port in
                        Task { await server.update { $0.mcpPort = port } }
                    }, in: 1024...65535)
                    LabeledContent("Address", value: "https://\(server.address):\(server.settings.mcpPort)/mcp")
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mcp-address")
                    Button(showToken ? "Hide token" : "Show token") { showToken.toggle() }
                        .accessibilityIdentifier("mcp-show-token")
                    if showToken {
                        Text(server.token)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("mcp-token")
                    }
                    Button("Make a new token") { Task { await server.newToken() } }
                }
            } header: {
                Text("For AI tools")
            } footer: {
                Text("Lets a tool on your network ask about your Health data, using this token. It runs only while this app is open, and everything stays between your iPhone and that tool.")
            }

            if server.settings.mcpOn, !server.certificatePEM.isEmpty {
                Section {
                    Text(server.fingerprint)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("mcp-fingerprint")
                    ShareLink("Share the certificate", item: server.certificatePEM, preview: SharePreview("health-data-relay.pem"))
                } header: {
                    Text("Certificate fingerprint")
                } footer: {
                    Text("This certificate was made on this iPhone, so a tool has to be told to trust it. Check this fingerprint, or give the tool the certificate.")
                }
            }

            Section {
                Toggle("Plain TCP server", isOn: Binding { server.settings.tcpOn } set: { on in
                    Task {
                        if on { await model.allowEveryType() }
                        await server.update { $0.tcpOn = on }
                    }
                })
                .accessibilityIdentifier("tcp-toggle")
                if server.settings.tcpOn {
                    Stepper("Port \(String(server.settings.tcpPort))", value: Binding { server.settings.tcpPort } set: { port in
                        Task { await server.update { $0.tcpPort = port } }
                    }, in: 1024...65535)
                    LabeledContent("Address", value: "\(server.address):\(server.settings.tcpPort)")
                        .textSelection(.enabled)
                }
            } footer: {
                Label("JSON-RPC, one message per line, for tools that can't use MCP. **Anyone on your network can read your Health data with this on: it has no password and no encryption.** Use it only on a network you trust, and turn it off afterwards.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(server.settings.tcpOn ? .red : .secondary)
            }

            if let problem = server.problem {
                Section { Text(problem).foregroundStyle(.red).accessibilityIdentifier("server-problem") }
            }
            if server.running {
                Section { Label("Running", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green).accessibilityIdentifier("server-running") }
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
    }
}
