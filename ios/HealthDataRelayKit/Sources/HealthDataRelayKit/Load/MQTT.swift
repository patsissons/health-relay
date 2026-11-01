import Foundation
import Network

/// A broker to publish to. Its password lives in the Keychain, with the
/// pipeline's id, like a bearer token.
public struct MQTTTarget: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var tls: Bool
    /// May be a template, rendered per part: `health/{{ partition.key }}`.
    public var topic: String
    public var clientID: String
    public var username: String
    public var qos: Int
    public var retain: Bool

    public init(host: String, port: Int = 1883, tls: Bool = false, topic: String, clientID: String = "health-data-relay", username: String = "", qos: Int = 1, retain: Bool = false) {
        self.host = host
        self.port = port
        self.tls = tls
        self.topic = topic
        self.clientID = clientID
        self.username = username
        self.qos = min(max(qos, 0), 2)
        self.retain = retain
    }
}

/// MQTT 3.1.1's packets, as far as publishing needs.
enum MQTTPacket {
    /// A broker's limit is usually far higher, but each message is held in memory.
    static let maxPayload = 64 << 20

    /// MQTT's variable-length integer.
    static func remainingLength(_ n: Int) -> Data {
        var out = Data()
        var x = n
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    private static func string(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
    }

    static func connect(clientID: String, username: String, password: String?, keepAlive: UInt16 = 60) -> Data {
        var flags: UInt8 = 0x02 // clean session
        var payload = string(clientID)
        if !username.isEmpty {
            flags |= 0x80
            payload += string(username)
            if let password, !password.isEmpty {
                flags |= 0x40
                payload += string(password)
            }
        }
        var body = string("MQTT")
        body.append(4) // protocol level 3.1.1
        body.append(flags)
        body.append(UInt8(keepAlive >> 8))
        body.append(UInt8(keepAlive & 0xFF))
        body += payload
        return Data([0x10]) + remainingLength(body.count) + body
    }

    static func publish(topic: String, payload: Data, qos: Int, retain: Bool, packetID: UInt16) -> Data {
        var first: UInt8 = 0x30 | UInt8(qos << 1)
        if retain { first |= 1 }
        var body = string(topic)
        if qos > 0 {
            body.append(UInt8(packetID >> 8))
            body.append(UInt8(packetID & 0xFF))
        }
        body += payload
        return Data([first]) + remainingLength(body.count) + body
    }

    static func pubrel(packetID: UInt16) -> Data {
        Data([0x62, 2, UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
    }

    static let disconnect = Data([0xE0, 0])

    /// What a CONNACK's return code means for the run.
    static func connectVerdict(_ code: UInt8) -> Delivery {
        switch code {
        case 0: Delivery(status: 0, verdict: .accepted, message: "Connected")
        case 1: Delivery(status: 1, verdict: .rejected, message: "The broker doesn't support this MQTT version")
        case 2: Delivery(status: 2, verdict: .rejected, message: "The broker refused this client ID")
        case 3: Delivery(status: 3, verdict: .retry, message: "The broker is unavailable")
        case 4: Delivery(status: 4, verdict: .authFailed, message: "The broker refused the username or password")
        case 5: Delivery(status: 5, verdict: .authFailed, message: "The broker refused this client")
        default: Delivery(status: Int(code), verdict: .rejected, message: "The broker answered with code \(code)")
        }
    }

    static func topicIsValid(_ topic: String) -> Bool {
        !topic.isEmpty && !topic.contains("+") && !topic.contains("#") && !topic.contains("\u{0}") && topic.utf8.count < 65_536
    }
}

/// Publishes each part as one message.
public struct MQTTTransport: ArtifactTransport {
    public let target: MQTTTarget
    public let password: String?
    public var timeout: Duration = .seconds(30)

    public init(target: MQTTTarget, password: String?) {
        self.target = target
        self.password = password
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        let topic = part.destination ?? target.topic
        guard MQTTPacket.topicIsValid(topic) else {
            return Delivery(status: nil, verdict: .rejected, message: "That topic can't be published to: \(topic)")
        }
        guard part.bytes <= MQTTPacket.maxPayload else {
            return Delivery(status: nil, verdict: .rejected, message: "A part is too large for one message. Split it with a partition in the template.")
        }
        guard let payload = try? Data(contentsOf: file) else {
            return Delivery(status: nil, verdict: .retry, message: "Couldn't read the output")
        }
        return await publish(topic: topic, payload: payload)
    }

    /// One connection per message: runs are minutes or hours apart.
    public func publish(topic: String, payload: Data) async -> Delivery {
        let connection = MQTTConnection(host: target.host, port: target.port, tls: target.tls)
        defer { connection.close() }
        do {
            return try await withThrowingTaskGroup(of: Delivery.self) { group in
                group.addTask { try await send(connection, topic: topic, payload: payload) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    connection.close()
                    return Delivery(status: nil, verdict: .retry, message: "The broker took too long to answer")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            return Delivery(status: nil, verdict: .retry, message: (error as? MQTTConnection.Failure)?.message ?? error.localizedDescription)
        }
    }

    private func send(_ c: MQTTConnection, topic: String, payload: Data) async throws -> Delivery {
        try await c.start()
        try await c.send(MQTTPacket.connect(clientID: target.clientID, username: target.username, password: password))
        let ack = try await c.readPacket()
        guard ack.type == 0x20, ack.body.count >= 2 else { throw MQTTConnection.Failure(message: "The broker didn't answer as an MQTT broker") }
        let connected = MQTTPacket.connectVerdict(ack.body[ack.body.startIndex + 1])
        guard connected.verdict == .accepted else { return connected }
        let id: UInt16 = 1
        try await c.send(MQTTPacket.publish(topic: topic, payload: payload, qos: target.qos, retain: target.retain, packetID: id))
        switch target.qos {
        case 1:
            let puback = try await c.readPacket()
            guard puback.type == 0x40 else { throw MQTTConnection.Failure(message: "The broker didn't confirm the message") }
        case 2:
            let pubrec = try await c.readPacket()
            guard pubrec.type == 0x50 else { throw MQTTConnection.Failure(message: "The broker didn't confirm the message") }
            try await c.send(MQTTPacket.pubrel(packetID: id))
            let pubcomp = try await c.readPacket()
            guard pubcomp.type == 0x70 else { throw MQTTConnection.Failure(message: "The broker didn't confirm the message") }
        default:
            break
        }
        try? await c.send(MQTTPacket.disconnect)
        return Delivery(status: 0, verdict: .accepted, message: "Published \(ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)) to \(topic)")
    }
}

/// A socket with just enough on top to read whole MQTT packets.
final class MQTTConnection: @unchecked Sendable {
    struct Failure: Error {
        let message: String
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mqtt")
    private let lock = NSLock()
    private var buffer = Data()
    private var started = false

    init(host: String, port: Int, tls: Bool) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)), using: tls ? .tls : .tcp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume()
                case .failed(let error): once.resume(throwing: Failure(message: "Couldn't reach the broker: \(error.localizedDescription)"))
                case .waiting(let error): once.resume(throwing: Failure(message: "Couldn't reach the broker: \(error.localizedDescription)"))
                case .cancelled: once.resume(throwing: Failure(message: "The connection closed"))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<Void, Error>?

        init(_ c: CheckedContinuation<Void, Error>) {
            self.c = c
        }

        private func take() -> CheckedContinuation<Void, Error>? {
            lock.withLock {
                defer { c = nil }
                return c
            }
        }

        func resume() { take()?.resume() }
        func resume(throwing error: Error) { take()?.resume(throwing: error) }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: Failure(message: error.localizedDescription)) } else { c.resume() }
            })
        }
    }

    private func read(_ count: Int) async throws -> Data {
        while lock.withLock({ buffer.count }) < count {
            let more: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                    if let error {
                        c.resume(throwing: Failure(message: error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        c.resume(returning: data)
                    } else if done {
                        c.resume(throwing: Failure(message: "The broker closed the connection"))
                    } else {
                        c.resume(returning: Data())
                    }
                }
            }
            lock.withLock { buffer.append(more) }
        }
        return lock.withLock {
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }
    }

    func readByte() async throws -> UInt8 {
        try await read(1)[0]
    }

    /// The next packet's type and body.
    func readPacket() async throws -> (type: UInt8, body: Data) {
        let first = try await read(1)[0]
        var length = 0
        var shift = 0
        while true {
            let byte = try await read(1)[0]
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift <= 21 else { throw Failure(message: "The broker sent a malformed packet") }
        }
        return (first & 0xF0, try await read(length))
    }

    func close() {
        connection.cancel()
    }
}
