import Foundation
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

    static func load() -> ClaudeOAuth? {
        let fromFile = loadFile()
        let fromKeychain = loadKeychain()
        switch (fromFile, fromKeychain) {
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
        try persist(updated)
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
        guard let text = securityPassword(service: service), let data = text.data(using: .utf8) else { return nil }
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

    private static func persist(_ oauth: ClaudeOAuth) throws {
        let url = CredentialPaths.claudeCredentials()
        var root: [String: Any] = [:]
        if let existing = try? Data(contentsOf: url), let object = try? JSONValue.object(from: existing) {
            root = object
        }
        var inner = root["claudeAiOauth"] as? [String: Any] ?? [:]
        inner["accessToken"] = oauth.accessToken
        inner["refreshToken"] = oauth.refreshToken
        inner["expiresAt"] = Int(oauth.expiresAt.timeIntervalSince1970 * 1000)
        if let subscription = oauth.subscriptionType {
            inner["subscriptionType"] = subscription
        }
        root["claudeAiOauth"] = inner
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        if oauth.source == .keychain || loadKeychain() != nil {
            let text = String(data: data, encoding: .utf8) ?? ""
            try securityUpdate(service: service, account: NSUserName(), password: text)
        }
    }

    private static func securityPassword(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func securityUpdate(service: String, account: String, password: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-s", service,
            "-a", account,
            "-w", password,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ProviderFailure.http(-1, "Claude 凭证已刷新，但钥匙串没有写回")
        }
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
        let entries = root.compactMap { $0.value as? [String: Any] }
        let preferred = entries.first { entry in
            (entry["auth_mode"] as? String) == "oidc" && (entry["key"] as? String)?.isEmpty == false
        } ?? entries.first { ($0["key"] as? String)?.isEmpty == false }
        guard let entry = preferred, let key = entry["key"] as? String else { return nil }
        return Session(
            accessToken: key,
            userID: entry["user_id"] as? String,
            expiresAt: JSONValue.date(entry["expires_at"])
        )
    }
}

enum CursorCredentials {
    static func load() -> (accessToken: String, membership: String?)? {
        let path = CredentialPaths.cursorState().path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3_000)
        let token = query(db, key: "cursorAuth/accessToken")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let token, !token.isEmpty else { return nil }
        let membership = query(db, key: "cursorAuth/stripeMembershipType")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (token, membership)
    }

    private static func query(_ db: OpaquePointer, key: String) -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let code: Int32 = key.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, nil)
            return sqlite3_step(statement)
        }
        guard code == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }
}
