import Foundation
import Testing
@testable import HealthDataRelayKit

/// Answers requests as a cloud would, and records them.
final class CloudStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var log: [(request: URLRequest, body: Data)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let size = 1 << 16
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: size)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.withLock { Self.log.append((request, body)) }
        let (status, headers, data) = Self.handler!(request, body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [CloudStub.self]
        return URLSession(configuration: c)
    }

    static func reset(_ h: @escaping @Sendable (URLRequest, Data) -> (Int, [String: String], Data)) {
        lock.withLock {
            log = []
            handler = h
        }
    }

    static var paths: [String] { lock.withLock { log.map { $0.request.url!.path } } }
}

private let artifact = Artifact(createdAt: Date(), days: [], rows: 1, parts: [])

@Suite struct FolderTransportTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func setup() throws -> (URL, Data) {
        let folder = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("part")
        try Data("new".utf8).write(to: source)
        #if os(iOS)
        let bookmark = try folder.bookmarkData()
        #else
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope])
        #endif
        return (source, bookmark)
    }

    private let part = ArtifactPart(key: "k", filename: "a.csv", file: "f", contentType: "text/csv", bytes: 3)

    @Test func writesAndReplaces() async throws {
        let (source, bookmark) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out/a.csv")
        try Data("old".utf8).write(to: out)
        let d = await FolderTransport(bookmark: bookmark, overwrite: true).deliver(part: part, file: source, artifact: artifact)
        #expect(d.verdict == .accepted, "\(d.message)")
        #expect(try String(contentsOf: out, encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("out").path) == ["a.csv"])
    }

    @Test func keepsBothWhenAsked() async throws {
        let (source, bookmark) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out/a.csv")
        try Data("old".utf8).write(to: out)
        _ = await FolderTransport(bookmark: bookmark, overwrite: false).deliver(part: part, file: source, artifact: artifact)
        #expect(try String(contentsOf: out, encoding: .utf8) == "old")
        #expect(try String(contentsOf: dir.appendingPathComponent("out/a 2.csv"), encoding: .utf8) == "new")
    }

    @Test func aFolderThatsGoneNeedsChoosingAgain() async throws {
        let d = await FolderTransport(bookmark: Data("nope".utf8), overwrite: true).deliver(part: part, file: dir, artifact: artifact)
        #expect(d.verdict == .authFailed)
    }

    @Test func iCloudStaysOff() {
        #expect(!Features.iCloudDriveFolders)
    }
}

/// Together, because they share CloudStub's one handler.
@Suite(.serialized) enum CloudTests {
@Suite struct OAuthTests {
    private let provider = OAuthProvider.dropbox(clientID: "client")

    @Test func theAuthorizeURLUsesPKCE() {
        let url = provider.authorizeURL(challenge: "ch", state: "st").absoluteString
        #expect(url.hasPrefix("https://www.dropbox.com/oauth2/authorize?"))
        for part in ["client_id=client", "code_challenge=ch", "code_challenge_method=S256", "state=st", "response_type=code", "token_access_type=offline"] { #expect(url.contains(part), "\(part)") }
        // No secret anywhere.
        #expect(!url.contains("secret"))
    }

    @Test func googlesRedirectIsItsClientIDReversed() {
        let g = OAuthProvider.google(clientID: "123-abc.apps.googleusercontent.com")
        #expect(g.redirect == "com.googleusercontent.apps.123-abc:/oauth")
        #expect(g.redirectScheme == "com.googleusercontent.apps.123-abc")
        #expect(g.scope == "https://www.googleapis.com/auth/drive.file")
    }

    @Test func aCodeBecomesTokens() async throws {
        CloudStub.reset { _, _ in (200, [:], Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8)) }
        let now = Date(timeIntervalSince1970: 1000)
        let t = try await provider.exchange(code: "c", verifier: "v", session: CloudStub.session(), now: now)
        #expect(t == OAuthTokens(access: "a", refresh: "r", expires: now.addingTimeInterval(3540)))
        let sent = String(decoding: CloudStub.log[0].body, as: UTF8.self)
        #expect(sent.contains("code_verifier=v"))
        #expect(sent.contains("grant_type=authorization_code"))
    }

    @Test func anExpiredTokenRefreshesAndKeepsItsRefreshToken() async throws {
        CloudStub.reset { _, _ in (200, [:], Data(#"{"access_token":"fresh","expires_in":3600}"#.utf8)) }
        let store = MemoryTokenStore()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        let tokens = AccountTokens(store: store, account: id, provider: provider, session: CloudStub.session(), now: { now })
        tokens.save(OAuthTokens(access: "old", refresh: "r", expires: now.addingTimeInterval(-1)))
        #expect(try await tokens.current() == "fresh")
        // Saved, with the refresh token that wasn't sent back.
        let saved = try JSONDecoder().decode(OAuthTokens.self, from: Data(store.token(for: id)!.utf8))
        #expect(saved.refresh == "r")
        #expect(saved.access == "fresh")
    }

    @Test func aRefusedRefreshMeansSignInAgain() async {
        CloudStub.reset { _, _ in (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let store = MemoryTokenStore()
        let tokens = AccountTokens(store: store, account: UUID(), provider: provider, session: CloudStub.session(), now: { Date() })
        tokens.save(OAuthTokens(access: "old", refresh: "r", expires: .distantPast))
        await #expect(throws: CloudError.signedOut) { _ = try await tokens.current() }
    }
}

@Suite struct DropboxTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func transport(overwrite: Bool = true) -> DropboxTransport {
        let store = MemoryTokenStore()
        let tokens = AccountTokens(store: store, account: UUID(), provider: .dropbox(clientID: "c"), session: CloudStub.session())
        tokens.save(OAuthTokens(access: "tok", refresh: "r", expires: nil))
        return DropboxTransport(path: "/Health", overwrite: overwrite, tokens: tokens, session: CloudStub.session())
    }

    private func part(_ bytes: Int) throws -> (ArtifactPart, URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p\(bytes)")
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 4096) { data[i] = UInt8(truncatingIfNeeded: i >> 12) }
        try data.write(to: file)
        return (ArtifactPart(key: "k", filename: "é.csv", file: "f", contentType: "text/csv", bytes: bytes), file)
    }

    @Test func aSmallFileIsOneRequest() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        CloudStub.reset { _, _ in (200, [:], Data("{}".utf8)) }
        let (p, f) = try part(100)
        let d = await transport().deliver(part: p, file: f, artifact: artifact)
        #expect(d.verdict == .accepted, "\(d.message)")
        #expect(CloudStub.paths == ["/2/files/upload"])
        let arg = CloudStub.log[0].request.value(forHTTPHeaderField: "Dropbox-API-Arg")!
        // JSON, with anything past ASCII escaped, as Dropbox's header needs.
        #expect(arg.contains("\"path\":\"/Health/\\u00e9.csv\""))
        #expect(arg.contains(#""mode":"overwrite""#))
        #expect(CloudStub.log[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func keepingBothLetsDropboxRename() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        CloudStub.reset { _, _ in (200, [:], Data("{}".utf8)) }
        let (p, f) = try part(10)
        _ = await transport(overwrite: false).deliver(part: p, file: f, artifact: artifact)
        let arg = CloudStub.log[0].request.value(forHTTPHeaderField: "Dropbox-API-Arg")!
        #expect(arg.contains(#""mode":"add""#))
        #expect(arg.contains(#""autorename":true"#))
    }

    @Test func aLargeFileGoesInChunksAndAnInterruptionResumes() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = CloudChunk.size * 2 + 100
        let (p, f) = try part(size)
        let state = Box(0)
        let received = Box(Data())
        CloudStub.reset { r, body in
            switch r.url!.path {
            case "/2/files/upload_session/start": return (200, [:], Data(#"{"session_id":"s1"}"#.utf8))
            case "/2/files/upload_session/append_v2":
                state.current += 1
                // The second chunk's connection drops once.
                if state.current == 2 { return (500, [:], Data("{}".utf8)) }
                received.current.append(body)
                return (200, [:], Data("null".utf8))
            default: return (200, [:], Data("{}".utf8))
            }
        }
        let first = await transport().deliver(part: p, file: f, artifact: artifact)
        #expect(first.verdict == .retry)
        let second = await transport().deliver(part: p, file: f, artifact: artifact)
        #expect(second.verdict == .accepted, "\(second.message)")
        // Started once, the first chunk not sent twice, and every byte in order.
        #expect(CloudStub.paths.filter { $0.hasSuffix("/start") }.count == 1)
        #expect(received.current == (try Data(contentsOf: f)))
        #expect(CloudStub.paths.last == "/2/files/upload_session/finish")
    }

    @Test func theServersOffsetWins() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = CloudChunk.size + 50
        let (p, f) = try part(size)
        let once = Box(true)
        CloudStub.reset { r, _ in
            switch r.url!.path {
            case "/2/files/upload_session/start": return (200, [:], Data(#"{"session_id":"s1"}"#.utf8))
            case "/2/files/upload_session/append_v2":
                if once.current {
                    once.current = false
                    return (409, [:], Data(#"{"error":{".tag":"incorrect_offset","correct_offset":\#(CloudChunk.size)}}"#.utf8))
                }
                return (200, [:], Data("null".utf8))
            default: return (200, [:], Data("{}".utf8))
            }
        }
        let d = await transport().deliver(part: p, file: f, artifact: artifact)
        #expect(d.verdict == .accepted)
        let last = CloudStub.log.last { $0.request.url!.path.hasSuffix("append_v2") }!
        #expect(last.body.count == 50)
    }

    @Test func anExpiredTokenIsRefreshedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, f) = try part(10)
        CloudStub.reset { r, _ in
            if r.url!.host() == "api.dropboxapi.com" { return (200, [:], Data(#"{"access_token":"new"}"#.utf8)) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? (200, [:], Data("{}".utf8)) : (401, [:], Data("{}".utf8))
        }
        #expect(await transport().deliver(part: p, file: f, artifact: artifact).verdict == .accepted)
    }

    @Test func noAccountNeedsSigningIn() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, f) = try part(10)
        let tokens = AccountTokens(store: MemoryTokenStore(), account: UUID(), provider: nil)
        let d = await DropboxTransport(path: "/", overwrite: true, tokens: tokens, session: CloudStub.session()).deliver(part: p, file: f, artifact: artifact)
        #expect(d.verdict == .authFailed)
    }
}

@Suite struct GoogleDriveTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let session = "https://www.googleapis.com/upload/session/abc"

    private func transport(sheets: Bool = false, overwrite: Bool = true, folder: String = "Health") throws -> GoogleDriveTransport {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokens = AccountTokens(store: MemoryTokenStore(), account: UUID(), provider: .google(clientID: "c.apps"), session: CloudStub.session())
        tokens.save(OAuthTokens(access: "tok", refresh: "r", expires: nil))
        return GoogleDriveTransport(folderName: folder, sheets: sheets, overwrite: overwrite, tokens: tokens, folderCache: dir.appendingPathComponent("folder.txt"), session: CloudStub.session())
    }

    private func part(_ bytes: Int, type: String = "text/csv; charset=utf-8") throws -> (ArtifactPart, URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("p\(bytes)")
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 4096) { data[i] = UInt8(truncatingIfNeeded: i >> 12) }
        try data.write(to: file)
        return (ArtifactPart(key: "k", filename: "steps.csv", file: "f", contentType: type, bytes: bytes), file)
    }

    /// A drive with one folder, where uploads complete in one go.
    private func simpleDrive(existing: String? = nil) {
        let session = session
        CloudStub.reset { r, _ in
            let path = r.url!.path
            if path == "/drive/v3/files" && r.httpMethod == "GET" {
                let q = r.url!.query() ?? ""
                if q.contains("apps.folder") { return (200, [:], Data(#"{"files":[{"id":"folder1"}]}"#.utf8)) }
                return (200, [:], Data((existing.map { #"{"files":[{"id":"\#($0)"}]}"# } ?? #"{"files":[]}"#).utf8))
            }
            if path.hasPrefix("/upload/drive/v3/files") { return (200, ["Location": session], Data()) }
            if path == "/upload/session/abc" { return (200, [:], Data("{}".utf8)) }
            return (404, [:], Data())
        }
    }

    @Test func aCSVBecomesASheetInItsFolder() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        simpleDrive()
        let (p, f) = try part(100)
        let d = await try transport(sheets: true).deliver(part: p, file: f, artifact: artifact)
        #expect(d.verdict == .accepted, "\(d.message)")
        #expect(d.message.contains("steps to Google Drive"))
        let start = CloudStub.log.first { $0.request.url!.path.hasPrefix("/upload/drive") }!
        let meta = try #require(JSON.parse(start.body))
        #expect(meta["mimeType"] == .string(GoogleDriveTransport.sheetMime))
        // Named without .csv, or the Sheet would be called steps.csv.
        #expect(meta["name"] == "steps")
        #expect(meta["parents"] == ["folder1"])
        #expect(start.request.value(forHTTPHeaderField: "X-Upload-Content-Length") == "100")
    }

    @Test func otherFilesKeepTheirType() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        simpleDrive()
        let (p, f) = try part(10, type: "application/json")
        _ = await try transport(sheets: true).deliver(part: p, file: f, artifact: artifact)
        let start = CloudStub.log.first { $0.request.url!.path.hasPrefix("/upload/drive") }!
        #expect(JSON.parse(start.body)?["mimeType"] == nil)
    }

    @Test func overwritingUpdatesTheSameFile() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        simpleDrive(existing: "file9")
        let (p, f) = try part(10)
        _ = await try transport().deliver(part: p, file: f, artifact: artifact)
        let start = CloudStub.log.first { $0.request.url!.path.hasPrefix("/upload/drive") }!
        #expect(start.request.httpMethod == "PATCH")
        #expect(start.request.url!.path == "/upload/drive/v3/files/file9")
    }

    @Test func anInterruptedUploadAsksHowMuchArrived() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, f) = try part(CloudChunk.size + 100)
        let session = session
        let stage = Box(0)
        CloudStub.reset { r, _ in
            let path = r.url!.path
            if r.httpMethod == "GET" { return (200, [:], Data(#"{"files":[{"id":"x"}]}"#.utf8)) }
            if path.hasPrefix("/upload/drive") { return (200, ["Location": session], Data()) }
            stage.current += 1
            switch stage.current {
            case 1: return (503, [:], Data()) // the first chunk fails
            case 2: return (308, ["Range": "bytes=0-99"], Data()) // the status check: 100 arrived
            case 3: return (308, ["Range": "bytes=0-\(CloudChunk.size + 99)"], Data())
            default: return (200, [:], Data("{}".utf8))
            }
        }
        let first = await try transport().deliver(part: p, file: f, artifact: artifact)
        #expect(first.verdict == .retry)
        let second = await try transport().deliver(part: p, file: f, artifact: artifact)
        #expect(second.verdict == .accepted, "\(second.message)")
        let puts = CloudStub.log.filter { $0.request.url!.path == "/upload/session/abc" }
        #expect(puts[1].request.value(forHTTPHeaderField: "Content-Range") == "bytes */\(p.bytes)")
        #expect(puts[2].request.value(forHTTPHeaderField: "Content-Range") == "bytes 100-\(CloudChunk.size + 99)/\(p.bytes)")
    }

    @Test func aQueryEscapesItsQuotes() {
        let q = GoogleDriveTransport.query(name: "it's", parent: nil, mime: nil)
        #expect(q.contains(#"name = 'it\'s'"#))
    }

    @Test func rangesParse() {
        #expect(GoogleDriveTransport.received("bytes=0-99") == 100)
        #expect(GoogleDriveTransport.received(nil) == 0)
    }
}
}

@Suite struct AccountTests {
    @Test func anAccountsTokensAreKeptAndForgotten() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MemoryTokenStore()
        let engine = Engine(.init(store: FakeHealthStore(), files: FileStore(root: root), tokens: store, device: { Device(name: $0, model: "m", os: "o", app: "a") }))
        let account = ConnectedAccount(provider: .dropbox, name: "Dropbox")
        await engine.addAccount(account, tokens: OAuthTokens(access: "a", refresh: "r", expires: nil))
        #expect(await engine.accounts == [account])
        #expect(store.token(for: account.id)?.contains("\"a\"") == true)
        // Not in the state file.
        let state = String(decoding: try! Data(contentsOf: root.appendingPathComponent("state.json")), as: UTF8.self)
        #expect(!state.contains("\"refresh\""))
        await engine.removeAccount(account.id)
        #expect(store.token(for: account.id) == nil)
        #expect(await engine.accounts.isEmpty)
    }

    @Test func aDiagnosticsFileNamesTheKindOnly() {
        var state = EngineState()
        let id = UUID()
        let target = LoadTarget.file(FileTarget(location: .folder(bookmark: Data("secret-bookmark".utf8), name: "Mine")))
        state.destinations = [Destination(id: id, name: "n", kind: .target(target))]
        state.lanes = [id: Lane()]
        let text = Diagnostics.summary(state, info: .init(app: "a", os: "o", model: "m"), now: Date()).canonical
        #expect(text.contains("file folder"))
        #expect(!text.contains("secret-bookmark"))
    }
}
