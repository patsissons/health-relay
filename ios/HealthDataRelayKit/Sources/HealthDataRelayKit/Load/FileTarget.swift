import Foundation

/// Saving a run's output as files: a folder in the Files app, Dropbox, or
/// Google Drive. An account's tokens live in the Keychain under its id.
public struct FileTarget: Codable, Sendable, Equatable {
    public enum Location: Codable, Sendable, Equatable {
        /// A folder the user picked, kept with a security-scoped bookmark.
        case folder(bookmark: Data, name: String)
        case dropbox(account: UUID, path: String)
        /// `sheets` turns a CSV into a Google Sheet as it's uploaded.
        case googleDrive(account: UUID, folderName: String, sheets: Bool)
    }

    public var location: Location
    /// True replaces a file of the same name; false keeps both.
    public var overwrite: Bool

    public init(location: Location, overwrite: Bool = true) {
        self.location = location
        self.overwrite = overwrite
    }

    public var summary: String {
        switch location {
        case .folder(_, let name): name
        case .dropbox(_, let path): "Dropbox \(path)"
        case .googleDrive(_, let folder, _): "Google Drive \(folder)"
        }
    }
}

/// Which features aren't on yet. Guideline 5.1.3(ii) says apps "may not store
/// personal health information in iCloud", so a folder there stays refused until
/// Apple has answered whether a file the user put there themselves counts.
public enum Features {
    public static let iCloudDriveFolders = false
}

/// Writes parts to a folder the user picked.
public struct FolderTransport: ArtifactTransport {
    public let bookmark: Data
    public let overwrite: Bool

    public init(bookmark: Data, overwrite: Bool) {
        self.bookmark = bookmark
        self.overwrite = overwrite
    }

    /// `name`, or `name 2.ext` and on if it's taken and shouldn't be replaced.
    static func available(_ name: String, in folder: URL, overwrite: Bool) -> URL {
        let first = folder.appendingPathComponent(name)
        guard !overwrite, FileManager.default.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        var stale = false
        let folder: URL
        do {
            #if os(iOS) || os(visionOS)
            folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
        } catch {
            return Delivery(status: nil, verdict: .authFailed, message: "That folder can't be reached any more. Choose it again.")
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if !Features.iCloudDriveFolders, (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            return Delivery(status: nil, verdict: .authFailed, message: "iCloud Drive isn't supported for health data yet. Choose a folder on this iPhone or use another service.")
        }
        do {
            let out = Self.available(part.filename, in: folder, overwrite: overwrite)
            // Written beside it and moved, so a reader never sees half a file.
            let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: file, to: temp)
            if FileManager.default.fileExists(atPath: out.path) {
                _ = try FileManager.default.replaceItemAt(out, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: out)
            }
            return Delivery(status: nil, verdict: .accepted, message: "Saved \(out.lastPathComponent)")
        } catch {
            return Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
        }
    }
}

// MARK: Accounts

/// A connected cloud account. Used by any number of pipelines.
public struct ConnectedAccount: Codable, Sendable, Equatable, Identifiable {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case dropbox, google

        public var title: String {
            switch self {
            case .dropbox: "Dropbox"
            case .google: "Google Drive"
            }
        }
    }

    public var id: UUID
    public var provider: Provider
    public var name: String

    public init(id: UUID = UUID(), provider: Provider, name: String) {
        self.id = id
        self.provider = provider
        self.name = name
    }
}

/// What's saved in the Keychain for an account.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String?
    public var expires: Date?

    public init(access: String, refresh: String?, expires: Date?) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
    }
}

/// OAuth 2 with PKCE, which needs no secret in the app.
public struct OAuthProvider: Sendable, Equatable {
    public var clientID: String
    public var authorize: URL
    public var token: URL
    public var redirect: String
    public var scope: String?
    public var extra: [String: String]

    public static func dropbox(clientID: String) -> OAuthProvider {
        OAuthProvider(clientID: clientID, authorize: URL(string: "https://www.dropbox.com/oauth2/authorize")!, token: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                      redirect: "healthdatarelay://oauth/dropbox", scope: "files.content.write", extra: ["token_access_type": "offline"])
    }

    /// Google wants the redirect's scheme to be the client ID reversed.
    public static func google(clientID: String) -> OAuthProvider {
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        return OAuthProvider(clientID: clientID, authorize: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, token: URL(string: "https://oauth2.googleapis.com/token")!,
                             redirect: "\(scheme):/oauth", scope: "https://www.googleapis.com/auth/drive.file", extra: ["access_type": "offline", "prompt": "consent"])
    }

    public var redirectScheme: String { String(redirect.prefix { $0 != ":" }) }

    public func authorizeURL(challenge: String, state: String) -> URL {
        var c = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: redirect),
                     URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state)]
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        items += extra.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = items
        return c.url!
    }

    private func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    private func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var r = URLRequest(url: token)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form(fields)
        return r
    }

    public func exchange(code: String, verifier: String, session: URLSession = .shared, now: Date = Date()) async throws -> OAuthTokens {
        try await send(tokenRequest(["grant_type": "authorization_code", "code": code, "client_id": clientID, "redirect_uri": redirect, "code_verifier": verifier]), session: session, now: now, keeping: nil)
    }

    public func refresh(_ tokens: OAuthTokens, session: URLSession = .shared, now: Date = Date()) async throws -> OAuthTokens {
        guard let refresh = tokens.refresh else { throw CloudError.signedOut }
        return try await send(tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]), session: session, now: now, keeping: refresh)
    }

    private func send(_ r: URLRequest, session: URLSession, now: Date, keeping refresh: String?) async throws -> OAuthTokens {
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let json = JSON.parse(data), let access = json["access_token"]?.stringValue else {
            if (400..<500).contains(status) { throw CloudError.signedOut }
            throw CloudError.failed(status, Delivery.message(status: status, body: data))
        }
        var expires: Date?
        if case .number(let seconds)? = json["expires_in"] { expires = now.addingTimeInterval(seconds - 60) }
        return OAuthTokens(access: access, refresh: json["refresh_token"]?.stringValue ?? refresh, expires: expires)
    }
}

public enum CloudError: Error, Equatable {
    /// Sign in again.
    case signedOut
    case failed(Int, String)
}

/// Saves and refreshes an account's tokens.
public struct AccountTokens: Sendable {
    public let store: TokenStore
    public let account: UUID
    public let provider: OAuthProvider?
    public let session: URLSession
    public let now: @Sendable () -> Date

    public init(store: TokenStore, account: UUID, provider: OAuthProvider?, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.account = account
        self.provider = provider
        self.session = session
        self.now = now
    }

    public func save(_ tokens: OAuthTokens) {
        let text = (try? JSONEncoder().encode(tokens)).map { String(decoding: $0, as: UTF8.self) }
        store.setToken(text, for: account)
    }

    private func load() throws -> OAuthTokens {
        guard let text = store.token(for: account), let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(text.utf8)) else { throw CloudError.signedOut }
        return tokens
    }

    /// A token that's good now.
    func current(forceRefresh: Bool = false) async throws -> String {
        let tokens = try load()
        if !forceRefresh, tokens.expires.map({ $0 > now() }) ?? true { return tokens.access }
        guard let provider else { throw CloudError.signedOut }
        let next = try await provider.refresh(tokens, session: session, now: now())
        save(next)
        return next.access
    }
}

// MARK: Resumable uploads

/// Where an interrupted upload had got to, kept beside the artifact.
struct UploadProgress: Codable, Equatable {
    var session: String
    var offset: Int
}

/// The size of a chunk, so a failure loses little.
enum CloudChunk {
    static let size = 8 << 20
}

/// Shared by both clouds: a request with a bearer token, retried once after a refresh.
private func authorized(_ tokens: AccountTokens, session: URLSession, _ make: (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
    var token = try await tokens.current()
    for attempt in 0..<2 {
        let (data, response) = try await session.data(for: try make(token))
        let http = response as! HTTPURLResponse
        if http.statusCode == 401 && attempt == 0 {
            token = try await tokens.current(forceRefresh: true)
            continue
        }
        return (data, http)
    }
    throw CloudError.signedOut
}

private func readChunk(_ file: URL, offset: Int, size: Int) throws -> Data {
    let h = try FileHandle(forReadingFrom: file)
    defer { try? h.close() }
    try h.seek(toOffset: UInt64(offset))
    return try h.read(upToCount: size) ?? Data()
}

private func outcome(_ error: Error) -> Delivery {
    switch error {
    case CloudError.signedOut: Delivery(status: nil, verdict: .authFailed, message: "Sign in to this account again, in Settings › Connected accounts.")
    case CloudError.failed(let status, let message): Delivery(status: status, verdict: Delivery.verdict(for: status), message: message)
    default: Delivery(status: nil, verdict: .retry, message: error.localizedDescription)
    }
}

/// Uploads to Dropbox: one request for a small file, an upload session in chunks
/// for a larger one, carrying on from the saved offset after an interruption.
public struct DropboxTransport: ArtifactTransport {
    public let path: String
    public let overwrite: Bool
    public let tokens: AccountTokens
    public let session: URLSession

    /// Dropbox's limit on one simple upload is far higher; this keeps retries cheap.
    static let simpleBytes = 8 << 20

    public init(path: String, overwrite: Bool, tokens: AccountTokens, session: URLSession = .shared) {
        self.path = path
        self.overwrite = overwrite
        self.tokens = tokens
        self.session = session
    }

    /// Dropbox's header carries JSON, with anything past ASCII escaped.
    static func apiArg(_ json: JSON) -> String {
        var out = ""
        for u in json.canonical.unicodeScalars {
            if u.value < 0x80 { out.unicodeScalars.append(u) } else {
                for unit in String(u).utf16 { out += String(format: "\\u%04x", unit) }
            }
        }
        return out
    }

    private func request(_ url: String, arg: JSON, token: String, body: Data) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        r.httpBody = body
        return r
    }

    func destination(_ name: String) -> String {
        let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (folder.hasPrefix("/") || folder.isEmpty ? folder : "/" + folder) + "/" + name.replacingOccurrences(of: "/", with: "-")
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        let commit: JSON = .object(["path": .string(destination(part.filename)), "mode": overwrite ? "overwrite" : "add", "autorename": .bool(!overwrite), "mute": .bool(true)])
        do {
            if part.bytes <= Self.simpleBytes {
                let body = try Data(contentsOf: file)
                let (data, http) = try await authorized(tokens, session: session) { request("https://content.dropboxapi.com/2/files/upload", arg: commit, token: $0, body: body) }
                return Delivery(status: http.statusCode, verdict: Delivery.verdict(for: http.statusCode), message: (200..<300).contains(http.statusCode) ? "Saved \(part.filename) to Dropbox" : Delivery.message(status: http.statusCode, body: data))
            }
            let progressFile = file.appendingPathExtension("upload")
            var progress = (try? Data(contentsOf: progressFile)).flatMap { try? JSONDecoder().decode(UploadProgress.self, from: $0) }
            if progress == nil {
                let (data, http) = try await authorized(tokens, session: session) { request("https://content.dropboxapi.com/2/files/upload_session/start", arg: ["close": .bool(false)], token: $0, body: Data()) }
                guard (200..<300).contains(http.statusCode), let id = JSON.parse(data)?["session_id"]?.stringValue else { throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data)) }
                progress = UploadProgress(session: id, offset: 0)
            }
            var state = progress!
            while state.offset < part.bytes {
                let chunk = try readChunk(file, offset: state.offset, size: CloudChunk.size)
                let arg: JSON = ["cursor": ["session_id": .string(state.session), "offset": .number(Double(state.offset))], "close": .bool(state.offset + chunk.count >= part.bytes)]
                let (data, http) = try await authorized(tokens, session: session) { request("https://content.dropboxapi.com/2/files/upload_session/append_v2", arg: arg, token: $0, body: chunk) }
                if http.statusCode == 409, case .number(let correct)? = JSON.parse(data)?["error"]?["correct_offset"] {
                    // The server has more than we thought: carry on from there.
                    state.offset = Int(correct)
                } else if (200..<300).contains(http.statusCode) {
                    state.offset += chunk.count
                } else {
                    throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data))
                }
                try JSONEncoder().encode(state).write(to: progressFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            let finish: JSON = ["cursor": ["session_id": .string(state.session), "offset": .number(Double(state.offset))], "commit": commit]
            let (data, http) = try await authorized(tokens, session: session) { request("https://content.dropboxapi.com/2/files/upload_session/finish", arg: finish, token: $0, body: Data()) }
            guard (200..<300).contains(http.statusCode) else { throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data)) }
            try? FileManager.default.removeItem(at: progressFile)
            return Delivery(status: http.statusCode, verdict: .accepted, message: "Saved \(part.filename) to Dropbox")
        } catch {
            return outcome(error)
        }
    }
}

/// Uploads to Google Drive with its resumable protocol. A CSV can become a
/// Google Sheet. The `drive.file` scope only reaches files this app made.
public struct GoogleDriveTransport: ArtifactTransport {
    public let folderName: String
    public let sheets: Bool
    public let overwrite: Bool
    public let tokens: AccountTokens
    public let session: URLSession
    public let folderCache: URL

    public init(folderName: String, sheets: Bool, overwrite: Bool, tokens: AccountTokens, folderCache: URL, session: URLSession = .shared) {
        self.folderName = folderName
        self.sheets = sheets
        self.overwrite = overwrite
        self.tokens = tokens
        self.folderCache = folderCache
        self.session = session
    }

    static let folderMime = "application/vnd.google-apps.folder"
    static let sheetMime = "application/vnd.google-apps.spreadsheet"

    /// Finds or makes the folder, once.
    private func folderID() async throws -> String? {
        guard !folderName.isEmpty else { return nil }
        if let saved = try? String(contentsOf: folderCache, encoding: .utf8), !saved.isEmpty { return saved }
        let existing = try await find(name: folderName, parent: nil, mime: Self.folderMime)
        if let existing {
            try? existing.write(to: folderCache, atomically: true, encoding: .utf8)
            return existing
        }
        let meta: JSON = ["name": .string(folderName), "mimeType": .string(Self.folderMime)]
        let (data, http) = try await authorized(tokens, session: session) { token in
            var r = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = meta.data
            return r
        }
        guard (200..<300).contains(http.statusCode), let id = JSON.parse(data)?["id"]?.stringValue else { throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data)) }
        try? id.write(to: folderCache, atomically: true, encoding: .utf8)
        return id
    }

    /// A query's text, with its quotes escaped.
    static func query(name: String, parent: String?, mime: String?) -> String {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
        var parts = ["name = '\(q(name))'", "trashed = false"]
        if let parent { parts.append("'\(q(parent))' in parents") }
        if let mime { parts.append("mimeType = '\(q(mime))'") }
        return parts.joined(separator: " and ")
    }

    private func find(name: String, parent: String?, mime: String?) async throws -> String? {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [URLQueryItem(name: "q", value: Self.query(name: name, parent: parent, mime: mime)), URLQueryItem(name: "fields", value: "files(id)"), URLQueryItem(name: "pageSize", value: "1")]
        let (data, http) = try await authorized(tokens, session: session) { token in
            var r = URLRequest(url: c.url!)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return r
        }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data)) }
        if case .array(let files)? = JSON.parse(data)?["files"] { return files.first?["id"]?.stringValue }
        return nil
    }

    public func deliver(part: ArtifactPart, file: URL, artifact: Artifact) async -> Delivery {
        let isCSV = part.contentType.hasPrefix("text/csv")
        let convert = sheets && isCSV
        let name = convert ? (part.filename as NSString).deletingPathExtension : part.filename
        let progressFile = file.appendingPathExtension("upload")
        do {
            var progress = (try? Data(contentsOf: progressFile)).flatMap { try? JSONDecoder().decode(UploadProgress.self, from: $0) }
            if progress == nil {
                let parent = try await folderID()
                let existing = overwrite ? try await find(name: name, parent: parent, mime: convert ? Self.sheetMime : nil) : nil
                var meta: [String: JSON] = ["name": .string(name)]
                if convert { meta["mimeType"] = .string(Self.sheetMime) }
                if existing == nil, let parent { meta["parents"] = [.string(parent)] }
                let bytes = part.bytes
                let mime = part.contentType
                let (data, http) = try await authorized(tokens, session: session) { token in
                    let base = "https://www.googleapis.com/upload/drive/v3/files"
                    var r = URLRequest(url: URL(string: existing.map { "\(base)/\($0)?uploadType=resumable" } ?? "\(base)?uploadType=resumable")!)
                    r.httpMethod = existing == nil ? "POST" : "PATCH"
                    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                    r.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
                    r.setValue(String(bytes), forHTTPHeaderField: "X-Upload-Content-Length")
                    if existing != nil { meta["parents"] = nil }
                    r.httpBody = JSON.object(meta).data
                    return r
                }
                guard (200..<300).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") else { throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data)) }
                progress = UploadProgress(session: location, offset: 0)
                try JSONEncoder().encode(progress!).write(to: progressFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                // Starting again after an interruption: ask how much arrived.
                let state = progress!
                var r = URLRequest(url: URL(string: state.session)!)
                r.httpMethod = "PUT"
                r.setValue("bytes */\(part.bytes)", forHTTPHeaderField: "Content-Range")
                let (_, response) = try await session.data(for: r)
                let http = response as! HTTPURLResponse
                if http.statusCode == 200 || http.statusCode == 201 {
                    try? FileManager.default.removeItem(at: progressFile)
                    return saved(name, http.statusCode)
                }
                if http.statusCode == 308 {
                    progress?.offset = Self.received(http.value(forHTTPHeaderField: "Range"))
                } else {
                    // The session has gone, which they do after a week.
                    try? FileManager.default.removeItem(at: progressFile)
                    throw CloudError.failed(503, "The upload session expired; the next run starts it again.")
                }
            }
            var state = progress!
            while true {
                let chunk = try readChunk(file, offset: state.offset, size: CloudChunk.size)
                var r = URLRequest(url: URL(string: state.session)!)
                r.httpMethod = "PUT"
                let last = state.offset + chunk.count - 1
                r.setValue(part.bytes == 0 ? "bytes */0" : "bytes \(state.offset)-\(last)/\(part.bytes)", forHTTPHeaderField: "Content-Range")
                r.httpBody = chunk
                let (data, response) = try await session.data(for: r)
                let http = response as! HTTPURLResponse
                if http.statusCode == 308 {
                    state.offset = http.value(forHTTPHeaderField: "Range").map { Self.received($0) } ?? state.offset
                    try JSONEncoder().encode(state).write(to: progressFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    continue
                }
                guard (200..<300).contains(http.statusCode) else { throw CloudError.failed(http.statusCode, Delivery.message(status: http.statusCode, body: data)) }
                try? FileManager.default.removeItem(at: progressFile)
                return saved(name, http.statusCode)
            }
        } catch {
            return outcome(error)
        }
    }

    private func saved(_ name: String, _ status: Int) -> Delivery {
        Delivery(status: status, verdict: .accepted, message: "Saved \(name) to Google Drive")
    }

    /// `bytes=0-524287` -> 524288. Nothing yet -> 0.
    static func received(_ range: String?) -> Int {
        guard let range, let dash = range.lastIndex(of: "-"), let last = Int(range[range.index(after: dash)...]) else { return 0 }
        return last + 1
    }
}
