import Foundation
import LocalAuthentication
import os
import Security
import SQLite3

enum CredentialPaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func claudeCredentials() -> URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        return root.appendingPathComponent(".credentials.json")
    }

    static func codexAuth() -> URL {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return root.appendingPathComponent("auth.json")
    }

    static func grokAuth() -> URL {
        let root = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".grok")
        return root.appendingPathComponent("auth.json")
    }

    static func cursorState() -> URL {
        home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
}

struct ClaudeOAuth: Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var subscriptionType: String?
    var source: Source

    enum Source: Sendable {
        case file
        case keychain
    }

    var isExpired: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}

enum ClaudeCredentials {
    private static let service = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    // Rotated refresh token survives a failed keychain write for the next load() in this process.
    private static let latest = OSAllocatedUnfairLock<ClaudeOAuth?>(initialState: nil)

    private enum KeychainItem {
        case found(data: Data, account: String?)
        case missing
        case failed
    }

    static func load() -> ClaudeOAuth? {
        let stored = newer(loadFile(), loadKeychain())
        let memory = latest.withLock { $0 }
        guard let memory else { return stored }
        guard let stored else { return memory }
        return memory.expiresAt > stored.expiresAt ? memory : stored
    }

    static func refresh(_ oauth: ClaudeOAuth) async throws -> ClaudeOAuth {
        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": oauth.refreshToken,
            "client_id": clientID,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw refreshFailure(status: status, data: data)
        }
        let object = try JSONValue.object(from: data)
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw ParseError.malformed
        }
        let refresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? oauth.refreshToken
        let expiresIn = JSONValue.number(object["expires_in"]) ?? 3600
        let updated = ClaudeOAuth(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            subscriptionType: oauth.subscriptionType,
            source: oauth.source
        )
        persist(updated)
        return updated
    }

    private static func refreshFailure(status: Int, data: Data) -> ProviderFailure {
        let error = (try? JSONValue.object(from: data))?["error"] as? [String: Any]
        let type = error?["type"] as? String
        if status == 429 || type == "rate_limit_error" {
            return .claudeRefreshLimited
        }
        if type == "invalid_grant" || status == 401 {
            return .expired("Claude 登录已失效，请重新执行 claude login")
        }
        return .http(status, "Claude 登录刷新失败")
    }

    private static func loadFile() -> ClaudeOAuth? {
        guard let data = try? Data(contentsOf: CredentialPaths.claudeCredentials()) else { return nil }
        return parse(data, source: .file)
    }

    private static func loadKeychain() -> ClaudeOAuth? {
        guard case let .found(data, _) = readKeychainItem() else { return nil }
        return parse(data, source: .keychain)
    }

    private static func parse(_ data: Data, source: ClaudeOAuth.Source) -> ClaudeOAuth? {
        guard let root = try? JSONValue.object(from: data) else { return nil }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard
            let access = oauth["accessToken"] as? String, !access.isEmpty,
            let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty
        else { return nil }
        let expires = JSONValue.date(oauth["expiresAt"]) ?? .distantPast
        let subscription = oauth["subscriptionType"] as? String
        return ClaudeOAuth(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expires,
            subscriptionType: subscription,
            source: source
        )
    }

    private static func newer(_ file: ClaudeOAuth?, _ keychain: ClaudeOAuth?) -> ClaudeOAuth? {
        switch (file, keychain) {
        case let (file?, keychain?):
            return keychain.expiresAt >= file.expiresAt ? keychain : file
        case let (file?, nil):
            return file
        case let (nil, keychain?):
            return keychain
        case (nil, nil):
            return nil
        }
    }

    private static func persist(_ oauth: ClaudeOAuth) {
        latest.withLock { $0 = oauth }
        attempt { writeFile(oauth) }
        attempt { writeKeychain(oauth) }
    }

    private static func attempt(_ write: () -> Bool) {
        if write() { return }
        _ = write()
    }

    private static func writeFile(_ oauth: ClaudeOAuth) -> Bool {
        let url = CredentialPaths.claudeCredentials()
        let exists = FileManager.default.fileExists(atPath: url.path)
        // A keychain-only secret must not create a credentials file.
        guard exists || oauth.source == .file else { return true }
        let existing: [String: Any]?
        if exists {
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONValue.object(from: data)
            else { return false }
            existing = object
        } else {
            existing = nil
        }
        guard let data = jsonData(merging(oauth, into: existing)) else { return false }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func writeKeychain(_ oauth: ClaudeOAuth) -> Bool {
        switch readKeychainItem() {
        case let .found(data, account):
            guard let account else { return false }
            guard let object = try? JSONValue.object(from: data) else { return false }
            guard let encoded = jsonData(merging(oauth, into: object)) else { return false }
            return updateKeychain(account: account, data: encoded)
        case .missing:
            guard oauth.source == .keychain else { return true }
            guard let encoded = jsonData(merging(oauth, into: nil)) else { return false }
            return addKeychain(account: NSUserName(), data: encoded)
        case .failed:
            return false
        }
    }

    private static func merging(_ oauth: ClaudeOAuth, into existing: [String: Any]?) -> [String: Any] {
        var root = existing ?? [:]
        var inner = root["claudeAiOauth"] as? [String: Any] ?? [:]
        inner["accessToken"] = oauth.accessToken
        inner["refreshToken"] = oauth.refreshToken
        inner["expiresAt"] = Int(oauth.expiresAt.timeIntervalSince1970 * 1000)
        if let subscription = oauth.subscriptionType {
            inner["subscriptionType"] = subscription
        }
        root["claudeAiOauth"] = inner
        return root
    }

    private static func jsonData(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func silentKeychainContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func readKeychainItem() -> KeychainItem {
        // No account: Claude's item is not always NSUserName(). A locked context never prompts.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: silentKeychainContext(),
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let item = result as? NSDictionary else { return .failed }
        guard let data = item[kSecValueData as String] as? Data else { return .failed }
        let account = (item[kSecAttrAccount as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .found(data: data, account: account)
    }

    private static func updateKeychain(account: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: silentKeychainContext(),
        ]
        // Password bytes only; the item's ACL stays as it is.
        let changes: [String: Any] = [
            kSecValueData as String: data,
        ]
        return SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecSuccess
    }

    private static func addKeychain(account: String, data: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseAuthenticationContext as String: silentKeychainContext(),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

enum CodexCredentials {
    struct Session: Sendable {
        var accessToken: String
        var accountID: String?
        var idToken: String?
    }

    static func load() -> Session? {
        guard
            let data = try? Data(contentsOf: CredentialPaths.codexAuth()),
            let root = try? JSONValue.object(from: data),
            let tokens = root["tokens"] as? [String: Any],
            let access = tokens["access_token"] as? String,
            !access.isEmpty
        else { return nil }
        let idToken = JSONValue.string(tokens["id_token"]) ?? JSONValue.string(root["id_token"])
        return Session(
            accessToken: access,
            accountID: tokens["account_id"] as? String,
            idToken: idToken
        )
    }
}

enum GrokCredentials {
    struct Session: Sendable {
        var accessToken: String
        var userID: String?
        var expiresAt: Date?
    }

    static func load() -> Session? {
        guard
            let data = try? Data(contentsOf: CredentialPaths.grokAuth()),
            let root = try? JSONValue.object(from: data)
        else { return nil }
        if let entry = activeEntry(in: root), let session = session(from: entry) {
            return session
        }
        let entries = accountEntries(in: root)
        let oidc = entries.filter { isOIDC($0) }
        let pool = oidc.isEmpty ? entries.filter(hasKey) : oidc
        guard let entry = pool.sorted(by: preferredOrder).first else { return nil }
        return session(from: entry)
    }

    private static func activeEntry(in root: [String: Any]) -> [String: Any]? {
        for name in ["active", "active_account"] {
            guard
                let identifier = root[name] as? String,
                let entry = root[identifier] as? [String: Any],
                hasKey(entry)
            else { continue }
            return entry
        }
        return nil
    }

    private static func accountEntries(in root: [String: Any]) -> [[String: Any]] {
        root.compactMap { key, value in
            guard var entry = value as? [String: Any] else { return nil }
            if JSONValue.string(entry["profile"]) == nil {
                entry["profile"] = key
            }
            return entry
        }
    }

    private static func isOIDC(_ entry: [String: Any]) -> Bool {
        hasKey(entry) && (entry["auth_mode"] as? String) == "oidc"
    }

    private static func hasKey(_ entry: [String: Any]) -> Bool {
        (entry["key"] as? String)?.isEmpty == false
    }

    private static func profile(_ entry: [String: Any]) -> String {
        (entry["profile"] as? String) ?? ""
    }

    private static func preferredOrder(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        let leftProfile = profile(lhs)
        let rightProfile = profile(rhs)
        if leftProfile != rightProfile { return leftProfile < rightProfile }
        switch (JSONValue.date(lhs["expires_at"]), JSONValue.date(rhs["expires_at"])) {
        case let (left?, right?):
            return left > right
        case (.some, .none):
            return true
        case (.none, .some), (.none, .none):
            return false
        }
    }

    private static func session(from entry: [String: Any]) -> Session? {
        guard let key = entry["key"] as? String, !key.isEmpty else { return nil }
        return Session(
            accessToken: key,
            userID: entry["user_id"] as? String,
            expiresAt: JSONValue.date(entry["expires_at"])
        )
    }
}

enum CursorRead: Sendable {
    case ready(accessToken: String, membership: String?)
    case missing
    case unreadable
}

enum CursorCredentials {
    static func load() -> (accessToken: String, membership: String?)? {
        if case let .ready(accessToken, membership) = read() { return (accessToken, membership) }
        return nil
    }

    static func read() -> CursorRead {
        let source = CredentialPaths.cursorState()
        guard FileManager.default.fileExists(atPath: source.path) else { return .missing }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-board-cursor-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .unreadable
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try copyDatabase(source, to: directory)
        } catch {
            return .unreadable
        }

        let database = directory.appendingPathComponent(source.lastPathComponent)
        var handle: OpaquePointer?
        // Open the copy. A readonly open of the live file still creates -shm beside it.
        let status = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer {
            if let handle { sqlite3_close(handle) }
        }
        guard status == SQLITE_OK, let db = handle else { return .unreadable }
        sqlite3_busy_timeout(db, 3_000)

        let token: String
        switch query(db, key: "cursorAuth/accessToken") {
        case .failed:
            return .unreadable
        case .none:
            return .missing
        case let .value(raw):
            let trimmed = unquoted(raw)
            guard !trimmed.isEmpty else { return .missing }
            token = trimmed
        }

        let membership: String?
        switch query(db, key: "cursorAuth/stripeMembershipType") {
        case .failed:
            return .unreadable
        case .none:
            membership = nil
        case let .value(raw):
            membership = unquoted(raw)
        }
        return .ready(accessToken: token, membership: membership)
    }

    private static func copyDatabase(_ source: URL, to directory: URL) throws {
        let name = source.lastPathComponent
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try FileManager.default.copyItem(
                at: sidecar,
                to: directory.appendingPathComponent(name + suffix)
            )
        }
    }

    private enum Row {
        case value(String)
        case none
        case failed
    }

    private static func query(_ db: OpaquePointer, key: String) -> Row {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let query = statement else {
            if let statement { sqlite3_finalize(statement) }
            return .failed
        }
        defer { sqlite3_finalize(query) }
        let code: Int32 = key.withCString { pointer in
            let bound = sqlite3_bind_text(query, 1, pointer, -1, nil)
            guard bound == SQLITE_OK else { return bound }
            return sqlite3_step(query)
        }
        switch code {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(query, 0) else { return .none }
            return .value(String(cString: text))
        case SQLITE_DONE:
            return .none
        default:
            return .failed
        }
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
