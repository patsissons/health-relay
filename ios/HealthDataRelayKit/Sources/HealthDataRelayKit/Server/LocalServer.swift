import CryptoKit
import Foundation
import Network
import Security

/// Serves on this device's network while the app is open: iOS suspends a
/// backgrounded app, and a listener with it.
public final class LocalServer: @unchecked Sendable {
    public enum Kind: @unchecked Sendable {
        /// HTTP, over TLS when given an identity. Each request is one connection.
        case http(MCPHTTPEndpoint, identity: sec_identity_t?)
        /// Newline-separated JSON-RPC with no authentication, for older clients.
        case tcp(MCPHandler)
    }

    private let kind: Kind
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-server")

    public init(kind: Kind, port: UInt16) throws {
        self.kind = kind
        let parameters: NWParameters
        if case .http(_, let identity?) = kind {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
    }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let once = StartOnce(c)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): once.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A listener can report a state more than once; its start answers once.
    private final class StartOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<UInt16, Error>?

        init(_ c: CheckedContinuation<UInt16, Error>) {
            self.c = c
        }

        private func take() -> CheckedContinuation<UInt16, Error>? {
            lock.withLock {
                defer { c = nil }
                return c
            }
        }

        func resume(returning port: UInt16) { take()?.resume(returning: port) }
        func resume(throwing error: Error) { take()?.resume(throwing: error) }
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        switch kind {
        case .http(let endpoint, _): readHTTP(connection, endpoint, Data())
        case .tcp(let handler): readTCP(connection, handler, Data())
        }
    }

    private func readHTTP(_ c: NWConnection, _ endpoint: MCPHTTPEndpoint, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            switch HTTPParser.parse(next) {
            case .incomplete:
                if done || error != nil { c.cancel() } else { self.readHTTP(c, endpoint, next) }
            case .invalid(let status):
                self.finish(c, HTTPParser.response(status: status))
            case .done(let request, _):
                Task {
                    let out = await endpoint.respond(request)
                    self.finish(c, out)
                }
            }
        }
    }

    private func finish(_ c: NWConnection, _ data: Data) {
        c.send(content: data, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Each line in gets one line out, in order.
    private func readTCP(_ c: NWConnection, _ handler: MCPHandler, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= HTTPParser.maxBody else {
                c.cancel()
                return
            }
            Task {
                while let newline = next.firstIndex(of: 10) {
                    let line = Data(next[next.startIndex..<newline])
                    next = Data(next[(newline + 1)...])
                    guard !line.isEmpty else { continue }
                    let reply: JSON?
                    if let message = JSON.parse(line) {
                        reply = await handler.handle(message)
                    } else {
                        reply = ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "That isn't JSON."]]
                    }
                    if let reply { c.send(content: reply.data + Data([10]), completion: .idempotent) }
                }
                if done || error != nil { c.cancel() } else { self.readTCP(c, handler, next) }
            }
        }
    }
}

/// A self-signed certificate for this phone, made on this phone. A client
/// trusts it once, by fingerprint or by installing it: there's no public name
/// for a certificate authority to vouch for on a home network.
public struct LocalCertificate: Sendable {
    public let der: Data
    public let key: P256.Signing.PrivateKey

    public init(der: Data, key: P256.Signing.PrivateKey) {
        self.der = der
        self.key = key
    }

    /// Hex SHA-256 of the certificate, as `openssl x509 -fingerprint -sha256` shows.
    public var fingerprint: String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The longest Apple's clients accept for a server certificate.
    static let validDays = 825

    public static func make(names: [String], addresses: [String], now: Date, key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) throws -> LocalCertificate {
        let sigAlg = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let name = DER.sequence(DER.set(DER.sequence(DER.oid([2, 5, 4, 3]) + DER.utf8("Health Data Relay on this iPhone"))))
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        serial[0] |= 0x40
        let validity = DER.sequence(DER.time(now.addingTimeInterval(-3600)) + DER.time(now.addingTimeInterval(Double(validDays) * 86400)))
        var alt = Data()
        for n in names { alt += DER.tagged(0x82, Data(n.utf8)) }
        for a in addresses {
            if let v4 = IPv4Address(a) { alt += DER.tagged(0x87, v4.rawValue) } else if let v6 = IPv6Address(a) { alt += DER.tagged(0x87, v6.rawValue) }
        }
        func ext(_ oid: [UInt64], critical: Bool, _ value: Data) -> Data {
            DER.sequence(DER.oid(oid) + (critical ? DER.tagged(0x01, Data([0xFF])) : Data()) + DER.tagged(0x04, value))
        }
        let extensions = DER.tagged(0xA3, DER.sequence(
            ext([2, 5, 29, 19], critical: true, DER.sequence(DER.tagged(0x01, Data([0xFF])))) +
            ext([2, 5, 29, 15], critical: true, DER.tagged(0x03, Data([0x02, 0x84]))) + // digitalSignature, keyCertSign
            ext([2, 5, 29, 37], critical: false, DER.sequence(DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))) +
            ext([2, 5, 29, 17], critical: false, DER.sequence(alt))))
        let tbs = DER.sequence(DER.tagged(0xA0, DER.integer(Data([2]))) + DER.integer(Data(serial)) + sigAlg + name + validity + name + key.publicKey.derRepresentation + extensions)
        let signature = try key.signature(for: tbs).derRepresentation
        let der = DER.sequence(tbs + sigAlg + DER.bitString(signature))
        return LocalCertificate(der: der, key: key)
    }

    /// For sharing, in the text form tools read.
    public var pem: String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    #if os(iOS)
    /// Files the key and certificate in the Keychain, where iOS can pair them
    /// into the identity TLS needs. Replaces any earlier one.
    public func identity(label: String = "health-data-relay.server") throws -> sec_identity_t {
        func fail(_ what: String) -> NSError { NSError(domain: "LocalCertificate", code: 1, userInfo: [NSLocalizedDescriptionKey: what]) }
        for cls in [kSecClassKey, kSecClassCertificate] {
            SecItemDelete([kSecClass: cls, kSecAttrLabel: label] as CFDictionary)
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw fail("The certificate didn't parse") }
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, &error) else { throw fail("The key didn't load") }
        let keyStatus = SecItemAdd([kSecClass: kSecClassKey, kSecValueRef: secKey, kSecAttrLabel: label, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else { throw fail("Couldn't save the key: \(keyStatus)") }
        let certStatus = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label] as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else { throw fail("Couldn't save the certificate: \(certStatus)") }
        var found: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecAttrLabel: label, kSecReturnRef: true] as CFDictionary, &found)
        guard status == errSecSuccess, let found else { throw fail("Couldn't make an identity: \(status)") }
        guard let identity = sec_identity_create(found as! SecIdentity) else { throw fail("Couldn't use the identity") }
        return identity
    }
    #endif
}

/// Just enough ASN.1 DER for one certificate.
enum DER {
    static func length(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var x = n
        while x > 0 {
            bytes.insert(UInt8(x & 0xFF), at: 0)
            x >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func tagged(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
    static func set(_ content: Data) -> Data { tagged(0x31, content) }
    static func utf8(_ s: String) -> Data { tagged(0x0C, Data(s.utf8)) }
    static func bitString(_ content: Data) -> Data { tagged(0x03, Data([0]) + content) }

    static func integer(_ value: Data) -> Data {
        var v = value
        while v.count > 1, v.first == 0, (v[v.startIndex + 1] & 0x80) == 0 { v = v.dropFirst() }
        if let f = v.first, f & 0x80 != 0 { v.insert(0, at: v.startIndex) }
        return tagged(0x02, Data(v))
    }

    static func oid(_ parts: [UInt64]) -> Data {
        var out = Data([UInt8(parts[0] * 40 + parts[1])])
        for p in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(p & 0x7F)]
            var x = p >> 7
            while x > 0 {
                chunk.insert(UInt8(x & 0x7F) | 0x80, at: 0)
                x >>= 7
            }
            out.append(contentsOf: chunk)
        }
        return tagged(0x06, out)
    }

    /// UTCTime before 2050, as the standard says, GeneralizedTime after.
    static func time(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        if c.year! < 2050 {
            return tagged(0x17, Data(String(format: "%02d%02d%02d%02d%02d%02dZ", c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!).utf8))
        }
        return tagged(0x18, Data(String(format: "%04d%02d%02d%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!).utf8))
    }
}
