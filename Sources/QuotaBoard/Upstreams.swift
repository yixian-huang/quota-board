import Foundation

struct AccountReading: Sendable {
    var snapshot: ProviderSnapshot
    var accountID: String?
    var userID: String?
    var email: String?
    /// Higher means the usage was read live rather than from a stored observation.
    var freshness: Int
    var label: String?
    var source: String
    /// Keep an empty failure visible even when another Codex account loaded.
    var retain: Bool = false

    var identityKeys: [String] {
        var keys: [String] = []
        if let accountID = normalized(accountID) { keys.append("acct:\(accountID.lowercased())") }
        if let userID = normalized(userID) { keys.append("user:\(userID.lowercased())") }
        if let email = normalized(email)?.lowercased() { keys.append("mail:\(email)") }
        return keys
    }

    func normalized() -> AccountReading {
        var copy = self
        copy.accountID = normalized(accountID)
        copy.userID = normalized(userID)
        copy.email = normalized(email)?.lowercased()
        return copy
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AccountDeduper {
    static func merge(_ readings: [AccountReading]) -> [ProviderSnapshot] {
        let items = readings.map { $0.normalized() }
        let hasWindows = items.contains { !$0.snapshot.windows.isEmpty }
        let kept = items.enumerated().filter { index, reading in
            if hasWindows, reading.identityKeys.isEmpty, reading.snapshot.windows.isEmpty, !reading.retain {
                return false
            }
            _ = index
            return true
        }.map(\.element)
        guard !kept.isEmpty else { return [] }

        var parent = Array(kept.indices)
        func find(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func unite(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs)
            let right = find(rhs)
            if left != right { parent[right] = left }
        }

        var seen: [String: Int] = [:]
        for index in kept.indices {
            var keys = kept[index].identityKeys
            if keys.isEmpty {
                keys = ["row:\(kept[index].snapshot.id)#\(index)"]
            }
            for key in keys {
                if let other = seen[key] {
                    unite(index, other)
                } else {
                    seen[key] = index
                }
            }
        }

        var groups: [Int: [AccountReading]] = [:]
        for index in kept.indices {
            groups[find(index), default: []].append(kept[index])
        }
        let ordered = groups.values.sorted { canonical($0) < canonical($1) }
        let accounts = ordered.filter(isAccountGroup)
        let failures = ordered.filter { !isAccountGroup($0) }
        let names = displayNames(for: accounts)
        let snapshots = zip(accounts, names).map { group, name in
            present(group, name: name, single: accounts.count == 1)
        }
        return snapshots + failures.map { $0[0].snapshot }
    }

    private static func isAccountGroup(_ group: [AccountReading]) -> Bool {
        group.contains { !$0.identityKeys.isEmpty || !$0.snapshot.windows.isEmpty || !$0.retain }
    }

    static func isUnsafeLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("@") { return true }
        if trimmed.compare("codex", options: .caseInsensitive) == .orderedSame { return true }
        let hex = trimmed.lowercased().filter { $0 != "-" }
        if hex.count >= 32, hex.allSatisfy(\.isHexDigit), trimmed.count <= 36 { return true }
        return false
    }

    private static func displayNames(for groups: [[AccountReading]]) -> [String] {
        if groups.count == 1 { return ["Codex"] }
        var used: [String: Int] = [:]
        var anonymous = 0
        return groups.map { group in
            if let label = group.compactMap(\.label).first(where: { !isUnsafeLabel($0) }) {
                return unique(label, used: &used)
            }
            anonymous += 1
            return unique(anonymous == 1 ? "Codex" : "Codex \(anonymous)", used: &used)
        }
    }

    private static func unique(_ name: String, used: inout [String: Int]) -> String {
        let count = used[name, default: 0] + 1
        used[name] = count
        return count == 1 ? name : "\(name) \(count)"
    }

    private static func canonical(_ group: [AccountReading]) -> String {
        if let accountID = group.compactMap(\.accountID).map({ $0.lowercased() }).sorted().first {
            return "acct:\(accountID)"
        }
        if let userID = group.compactMap(\.userID).map({ $0.lowercased() }).sorted().first {
            return "user:\(userID)"
        }
        if let email = group.compactMap(\.email).sorted().first {
            return "mail:\(email)"
        }
        return "row:" + group.map(\.snapshot.id).sorted().joined(separator: "|")
    }

    private static func present(_ group: [AccountReading], name: String, single: Bool) -> ProviderSnapshot {
        let best = group.max { score($0) < score($1) } ?? group[0]
        let plan = best.snapshot.plan ?? group.compactMap(\.snapshot.plan).first
        var note = best.snapshot.note
        if best.source == "cpa", best.snapshot.windows.isEmpty == false, note == nil {
            note = "CPA 最近一次观察"
        }
        let canonicalKey = canonical(group)
        let billing = group
            .filter { $0.snapshot.billing != nil }
            .max { score($0) < score($1) }?
            .snapshot.billing
        return ProviderSnapshot(
            id: single ? "codex" : "codex-\(fnv(canonicalKey))",
            name: name,
            shortName: name,
            plan: plan,
            windows: best.snapshot.windows,
            note: note,
            error: best.snapshot.windows.isEmpty ? best.snapshot.error : nil,
            isStale: best.snapshot.isStale,
            billingKey: canonicalKey,
            billing: billing
        )
    }

    private static func score(_ reading: AccountReading) -> (Int, Int, Int, Int) {
        (
            reading.snapshot.windows.isEmpty ? 0 : 1,
            reading.freshness,
            reading.snapshot.windows.count,
            reading.snapshot.note == nil ? 0 : 1
        )
    }

    private static func fnv(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct UpstreamSpec: Equatable {
    var kind: String
    var name: String
    var baseURL: String
    var userID: String?
    var keychainService: String
    var keychainAccount: String
}

enum UpstreamConfig {
    static func load(from url: URL = fileURL) -> (specs: [UpstreamSpec], error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        guard let data = try? Data(contentsOf: url) else { return ([], "上游配置无法读取") }
        do {
            return (try parse(data), nil)
        } catch {
            return ([], "上游配置无法解析")
        }
    }

    static func parse(_ data: Data) throws -> [UpstreamSpec] {
        let root = try JSONValue.object(from: data)
        let items = root["upstreams"] as? [[String: Any]] ?? []
        return try items.map { item in
            guard let kind = JSONValue.string(item["kind"])?.lowercased() else {
                throw ParseError.malformed
            }
            guard let baseURL = JSONValue.string(item["baseURL"]) else {
                throw ParseError.malformed
            }
            guard let keychainAccount = JSONValue.string(item["keychainAccount"]) else {
                throw ParseError.malformed
            }
            let name = JSONValue.string(item["name"]) ?? kind
            return UpstreamSpec(
                kind: kind,
                name: name,
                baseURL: baseURL,
                userID: JSONValue.string(item["userID"]),
                keychainService: JSONValue.string(item["keychainService"]) ?? "quota-board",
                keychainAccount: keychainAccount
            )
        }
    }

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["QUOTA_BOARD_UPSTREAMS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return CredentialPaths.home.appendingPathComponent(".quota-board/upstreams.json")
    }
}

enum KeychainSecret {
    static func password(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
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
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

enum UpstreamService {
    static func fetchCodex() async -> [AccountReading] {
        let loaded = UpstreamConfig.load()
        if let message = loaded.error {
            return [failure("upstreams", message)]
        }
        guard !loaded.specs.isEmpty else { return [] }
        return await withTaskGroup(of: [AccountReading].self) { group in
            for spec in loaded.specs {
                group.addTask { await fetch(spec) }
            }
            var readings: [AccountReading] = []
            for await batch in group {
                readings.append(contentsOf: batch)
            }
            return readings
        }
    }

    private static func fetch(_ spec: UpstreamSpec) async -> [AccountReading] {
        guard let secret = KeychainSecret.password(service: spec.keychainService, account: spec.keychainAccount) else {
            return [failure(spec.name, "\(spec.name) 未配置管理凭证")]
        }
        switch spec.kind {
        case "sub2api":
            return await Sub2APICodex.fetch(spec: spec, secret: secret)
        case "new-api":
            return await NewAPICodex.fetch(spec: spec, secret: secret)
        case "cpa":
            return await CPACodex.fetch(spec: spec, secret: secret)
        default:
            return [failure(spec.name, "\(spec.name) 的上游类型无法识别")]
        }
    }

    private static func failure(_ name: String, _ message: String) -> AccountReading {
        AccountReading(
            snapshot: failed("upstream-\(name)", name, name, plan: nil, .http(-1, message)),
            accountID: nil,
            userID: nil,
            email: nil,
            freshness: 0,
            label: name,
            source: name,
            retain: true
        )
    }
}

enum UpstreamHTTP {
    static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil
        else { return nil }
        if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let root = components.string else { return nil }
        return URL(string: root + path)
    }

    static func message(status: Int, name: String) -> String {
        if status == 401 || status == 403 { return "\(name) 管理凭证已失效" }
        return "\(name) 用量读取失败（HTTP \(status)）"
    }
}

enum Sub2APICodex {
    struct Account {
        var id: Int
        var name: String?
        var accountID: String?
        var userID: String?
        var email: String?
        var plan: String?
        /// nil when the list did not say. Zero means sub2api stored a 5-hour slot that is not a real window.
        var fiveHourMinutes: Int?
        var subscriptionExpiresAt: Date?
    }

    struct Page {
        var accounts: [Account]
        var total: Int
    }

    static func fetch(spec: UpstreamSpec, secret: String) async -> [AccountReading] {
        var page = 1
        var accounts: [Account] = []
        while page <= 20 {
            guard let url = UpstreamHTTP.endpoint(
                spec.baseURL,
                "/api/v1/admin/accounts?platform=openai&type=oauth&page=\(page)&page_size=100"
            ) else {
                return [upstreamFailure(spec.name, "\(spec.name) 地址无法解析")]
            }
            let status: Int
            let data: Data
            do {
                (status, data) = try await HTTP.get(url, headers: authHeaders(secret))
            } catch {
                return [upstreamFailure(spec.name, "\(spec.name) 用量读取失败")]
            }
            guard status == 200 else {
                return [upstreamFailure(spec.name, UpstreamHTTP.message(status: status, name: spec.name))]
            }
            guard let parsed = try? parsePage(data) else {
                return [upstreamFailure(spec.name, "\(spec.name) 账号列表无法解析")]
            }
            accounts.append(contentsOf: parsed.accounts)
            if accounts.count >= parsed.total || parsed.accounts.isEmpty { break }
            page += 1
        }
        guard !accounts.isEmpty else { return [] }
        return await usage(spec: spec, secret: secret, accounts: accounts)
    }

    static func parsePage(_ data: Data) throws -> Page {
        let root = try JSONValue.object(from: data)
        if let code = JSONValue.int(root["code"]), code != 0 {
            throw ParseError.malformed
        }
        let envelope = root["data"] as? [String: Any] ?? [:]
        let items = envelope["items"] as? [[String: Any]] ?? []
        let accounts = items.compactMap(account(from:))
        return Page(accounts: accounts, total: JSONValue.int(envelope["total"]) ?? items.count)
    }

    static func readings(accounts: [Account], usage data: Data, source: String) -> [AccountReading] {
        guard
            let root = try? JSONValue.object(from: data),
            JSONValue.int(root["code"]) ?? 0 == 0,
            let envelope = root["data"] as? [String: Any]
        else {
            return accounts.map { account in
                identified(
                    account,
                    snapshot: failed("sub2api-\(account.id)", "Codex", "Codex", plan: account.plan, .malformed),
                    source: source
                )
            }
        }
        let usage = envelope["usage"] as? [String: Any] ?? [:]
        let errors = envelope["errors"] as? [String: Any] ?? [:]
        return accounts.map { account in
            let key = String(account.id)
            if let payload = usage[key] as? [String: Any] {
                return identified(
                    account,
                    snapshot: snapshot(
                        from: payload,
                        id: account.id,
                        plan: account.plan,
                        fiveHourMinutes: account.fiveHourMinutes
                    ),
                    source: source
                )
            }
            let message = errors[key] == nil ? "用量数据无法解析" : "\(source) 用量读取失败"
            return identified(
                account,
                snapshot: failed("sub2api-\(account.id)", "Codex", "Codex", plan: account.plan, .http(-1, message)),
                source: source
            )
        }
    }

    private static func usage(spec: UpstreamSpec, secret: String, accounts: [Account]) async -> [AccountReading] {
        guard let url = UpstreamHTTP.endpoint(spec.baseURL, "/api/v1/admin/accounts/usage/batch") else {
            return [upstreamFailure(spec.name, "\(spec.name) 地址无法解析")]
        }
        let body = try? JSONSerialization.data(withJSONObject: [
            "account_ids": accounts.map(\.id),
            "force": false,
        ])
        guard let body else {
            return [upstreamFailure(spec.name, "\(spec.name) 用量读取失败")]
        }
        var headers = authHeaders(secret)
        headers["Content-Type"] = "application/json"
        let status: Int
        let data: Data
        do {
            (status, data) = try await HTTP.post(url, headers: headers, body: body)
        } catch {
            return [upstreamFailure(spec.name, "\(spec.name) 用量读取失败")]
        }
        guard status == 200 else {
            return [upstreamFailure(spec.name, UpstreamHTTP.message(status: status, name: spec.name))]
        }
        return readings(accounts: accounts, usage: data, source: spec.name)
    }

    private static func account(from item: [String: Any]) -> Account? {
        guard let id = JSONValue.int(item["id"]) else { return nil }
        if let parent = item["parent_account_id"], !(parent is NSNull), JSONValue.int(parent) != nil {
            return nil
        }
        if let platform = JSONValue.string(item["platform"]), platform != "openai" { return nil }
        if let type = JSONValue.string(item["type"]), type != "oauth" { return nil }
        if let status = JSONValue.string(item["status"]), status != "active" { return nil }
        let credentials = item["credentials"] as? [String: Any] ?? [:]
        let extra = item["extra"] as? [String: Any] ?? [:]
        return Account(
            id: id,
            name: displayLabel(JSONValue.string(item["name"])),
            accountID: JSONValue.string(credentials["chatgpt_account_id"]),
            userID: JSONValue.string(credentials["chatgpt_user_id"]),
            email: JSONValue.string(credentials["email"]) ?? JSONValue.string(credentials["chatgpt_email"]),
            plan: CodexProvider.planName(JSONValue.string(credentials["plan_type"])),
            fiveHourMinutes: fiveHourMinutes(in: extra),
            subscriptionExpiresAt: JSONValue.date(credentials["subscription_expires_at"])
        )
    }

    /// Pro 200 has no 5-hour Codex window. sub2api still emits `five_hour` from a stored zero-length slot.
    static func includesFiveHour(plan: String?, windowMinutes: Int?) -> Bool {
        if plan == "Pro 200" { return false }
        if let windowMinutes, windowMinutes <= 0 { return false }
        return true
    }

    private static func fiveHourMinutes(in extra: [String: Any]) -> Int? {
        guard extra.keys.contains("codex_5h_window_minutes") else { return nil }
        return JSONValue.int(extra["codex_5h_window_minutes"]) ?? 0
    }

    private static func snapshot(
        from payload: [String: Any],
        id: Int,
        plan: String?,
        fiveHourMinutes: Int?
    ) -> ProviderSnapshot {
        var windows: [QuotaWindow] = []
        if includesFiveHour(plan: plan, windowMinutes: fiveHourMinutes),
           let window = progress(payload["five_hour"], label: "5 小时", id: "sub2api-\(id)-5h") {
            windows.append(window)
        }
        if let window = progress(payload["seven_day"], label: "每周", id: "sub2api-\(id)-7d") {
            windows.append(window)
        }
        return ProviderSnapshot(
            id: "sub2api-\(id)",
            name: "Codex",
            shortName: "Codex",
            plan: plan,
            windows: windows,
            note: nil,
            error: windows.isEmpty ? ProviderFailure.malformed.message : nil,
            isStale: false
        )
    }

    private static func progress(_ value: Any?, label: String, id: String) -> QuotaWindow? {
        guard let bucket = value as? [String: Any], let used = JSONValue.number(bucket["utilization"]) else {
            return nil
        }
        return QuotaWindow(id: id, label: label, usedPercent: used, resetsAt: JSONValue.date(bucket["resets_at"]))
    }

    private static func identified(_ account: Account, snapshot: ProviderSnapshot, source: String) -> AccountReading {
        let billing = snapshot.billing ?? account.subscriptionExpiresAt.map {
            BillingAnchor(at: $0, renews: nil, manual: false)
        }
        return AccountReading(
            snapshot: snapshot.replacing(billing: billing),
            accountID: account.accountID,
            userID: account.userID,
            email: account.email,
            freshness: 2,
            label: account.name,
            source: source,
            retain: false
        )
    }

    private static func authHeaders(_ secret: String) -> [String: String] {
        let value = secret.lowercased().hasPrefix("bearer ") ? secret : "Bearer \(secret)"
        return ["Authorization": value, "Accept": "application/json"]
    }
}

enum NewAPICodex {
    struct Channel {
        var id: Int
        var name: String?
    }

    struct Page {
        var channels: [Channel]
        var total: Int
    }

    static func fetch(spec: UpstreamSpec, secret: String) async -> [AccountReading] {
        guard let userID = spec.userID else {
            return [upstreamFailure(spec.name, "\(spec.name) 缺少 userID")]
        }
        var page = 1
        var channels: [Channel] = []
        var total = Int.max
        while page <= 20 && channels.count < total {
            guard let url = UpstreamHTTP.endpoint(
                spec.baseURL,
                "/api/channel/?p=\(page)&page_size=100&type=57"
            ) else {
                return [upstreamFailure(spec.name, "\(spec.name) 地址无法解析")]
            }
            let status: Int
            let data: Data
            do {
                (status, data) = try await HTTP.get(url, headers: authHeaders(secret, userID: userID))
            } catch {
                return [upstreamFailure(spec.name, "\(spec.name) 用量读取失败")]
            }
            guard status == 200 else {
                return [upstreamFailure(spec.name, UpstreamHTTP.message(status: status, name: spec.name))]
            }
            guard let parsed = try? parsePage(data) else {
                return [upstreamFailure(spec.name, "\(spec.name) 渠道列表无法解析")]
            }
            total = parsed.total
            channels.append(contentsOf: parsed.channels)
            if parsed.channels.count < 100 { break }
            page += 1
        }
        guard !channels.isEmpty else { return [] }
        return await withTaskGroup(of: AccountReading.self) { group in
            for channel in channels {
                group.addTask {
                    await usage(spec: spec, secret: secret, userID: userID, channel: channel)
                }
            }
            var readings: [AccountReading] = []
            for await reading in group {
                readings.append(reading)
            }
            return readings
        }
    }

    static func parsePage(_ data: Data) throws -> Page {
        let root = try JSONValue.object(from: data)
        if (root["success"] as? Bool) == false { throw ParseError.malformed }
        let envelope = root["data"] as? [String: Any] ?? [:]
        let items = envelope["items"] as? [[String: Any]] ?? []
        let channels = items.compactMap(channel(from:))
        return Page(channels: channels, total: JSONValue.int(envelope["total"]) ?? items.count)
    }

    static func reading(channel: Channel, body: Data, source: String) -> AccountReading {
        guard
            let root = try? JSONValue.object(from: body),
            (root["success"] as? Bool) == true,
            let payload = root["data"],
            !(payload is NSNull),
            let payloadData = try? JSONSerialization.data(withJSONObject: payload),
            let snapshot = try? CodexProvider.parse(payloadData)
        else {
            return AccountReading(
                snapshot: failed("new-api-\(channel.id)", "Codex", "Codex", plan: nil, .malformed),
                accountID: nil,
                userID: nil,
                email: nil,
                freshness: 3,
                label: channel.name,
                source: source
            )
        }
        let identity = CodexProvider.identity(in: payloadData)
        return AccountReading(
            snapshot: ProviderSnapshot(
                id: "new-api-\(channel.id)",
                name: snapshot.name,
                shortName: snapshot.shortName,
                plan: snapshot.plan,
                windows: snapshot.windows,
                note: snapshot.note,
                error: snapshot.error,
                isStale: false
            ),
            accountID: identity.accountID,
            userID: identity.userID,
            email: identity.email,
            freshness: 3,
            label: channel.name,
            source: source
        )
    }

    private static func usage(spec: UpstreamSpec, secret: String, userID: String, channel: Channel) async -> AccountReading {
        guard let url = UpstreamHTTP.endpoint(spec.baseURL, "/api/channel/\(channel.id)/codex/usage") else {
            return upstreamFailure(spec.name, "\(spec.name) 地址无法解析")
        }
        do {
            let (status, data) = try await HTTP.get(url, headers: authHeaders(secret, userID: userID))
            guard status == 200 else {
                return AccountReading(
                    snapshot: failed(
                        "new-api-\(channel.id)",
                        "Codex",
                        "Codex",
                        plan: nil,
                        .http(status, UpstreamHTTP.message(status: status, name: spec.name))
                    ),
                    accountID: nil,
                    userID: nil,
                    email: nil,
                    freshness: 3,
                    label: channel.name,
                    source: spec.name
                )
            }
            return reading(channel: channel, body: data, source: spec.name)
        } catch {
            return AccountReading(
                snapshot: failed("new-api-\(channel.id)", "Codex", "Codex", plan: nil, .http(-1, "\(spec.name) 用量读取失败")),
                accountID: nil,
                userID: nil,
                email: nil,
                freshness: 3,
                label: channel.name,
                source: spec.name
            )
        }
    }

    private static func channel(from item: [String: Any]) -> Channel? {
        guard let id = JSONValue.int(item["id"]) else { return nil }
        if let type = JSONValue.int(item["type"]), type != 57 { return nil }
        if let status = JSONValue.int(item["status"]), status != 1 { return nil }
        return Channel(id: id, name: displayLabel(JSONValue.string(item["name"])))
    }

    private static func authHeaders(_ secret: String, userID: String) -> [String: String] {
        [
            "Authorization": secret,
            "New-Api-User": userID,
            "Accept": "application/json",
        ]
    }
}

enum CPACodex {
    static func fetch(spec: UpstreamSpec, secret: String) async -> [AccountReading] {
        guard let url = UpstreamHTTP.endpoint(spec.baseURL, "/v0/management/auth-files") else {
            return [upstreamFailure(spec.name, "\(spec.name) 地址无法解析")]
        }
        let status: Int
        let data: Data
        do {
            (status, data) = try await HTTP.get(url, headers: [
                "X-Management-Key": secret,
                "Accept": "application/json",
            ])
        } catch {
            return [upstreamFailure(spec.name, "\(spec.name) 用量读取失败")]
        }
        guard status == 200 else {
            return [upstreamFailure(spec.name, UpstreamHTTP.message(status: status, name: spec.name))]
        }
        guard let readings = try? readings(from: data, source: spec.name) else {
            return [upstreamFailure(spec.name, "\(spec.name) 账号列表无法解析")]
        }
        return readings
    }

    static func readings(from data: Data, source: String) throws -> [AccountReading] {
        let root = try JSONValue.object(from: data)
        let files = root["files"] as? [[String: Any]] ?? []
        return files.enumerated().compactMap { index, file in
            let provider = (JSONValue.string(file["provider"]) ?? JSONValue.string(file["type"]) ?? "").lowercased()
            guard provider == "codex" else { return nil }
            if (file["disabled"] as? Bool) == true { return nil }
            let claims = file["id_token"] as? [String: Any] ?? [:]
            let quota = file["quota"] as? [String: Any] ?? [:]
            let signals = quota["signals"] as? [String: Any] ?? [:]
            let observed = JSONValue.date(quota["observed_at"]) ?? JSONValue.date(root["observed_at"])
            let plan = CodexProvider.planName(
                signal(signals, "X-Codex-Plan-Type") ?? JSONValue.string(claims["plan_type"])
            )
            let billing = JSONValue.date(claims["chatgpt_subscription_active_until"]).map {
                BillingAnchor(at: $0, renews: nil, manual: false)
            }
            var windows: [QuotaWindow] = []
            if let window = window(signals, prefix: "X-Codex-Primary", observed: observed, slot: "primary") {
                windows.append(window)
            }
            if let window = window(signals, prefix: "X-Codex-Secondary", observed: observed, slot: "secondary") {
                windows.append(window)
            }
            let name = displayLabel(JSONValue.string(file["label"]) ?? JSONValue.string(file["name"]))
            return AccountReading(
                snapshot: ProviderSnapshot(
                    id: "cpa-\(index)",
                    name: "Codex",
                    shortName: "Codex",
                    plan: plan,
                    windows: windows,
                    note: nil,
                    error: windows.isEmpty ? "还没有用量观察" : nil,
                    isStale: false,
                    billing: billing
                ),
                accountID: JSONValue.string(claims["chatgpt_account_id"]),
                userID: nil,
                email: JSONValue.string(file["email"]),
                freshness: 1,
                label: name,
                source: "cpa"
            )
        }
    }

    private static func window(
        _ signals: [String: Any],
        prefix: String,
        observed: Date?,
        slot: String
    ) -> QuotaWindow? {
        guard let used = JSONValue.number(signal(signals, "\(prefix)-Used-Percent")) else { return nil }
        let minutes = JSONValue.int(signal(signals, "\(prefix)-Window-Minutes")) ?? 0
        let label = minutes > 0 ? windowLabel(forSeconds: minutes * 60) : "窗口"
        var resetsAt = JSONValue.date(signal(signals, "\(prefix)-Reset-At"))
        if resetsAt == nil, let after = JSONValue.int(signal(signals, "\(prefix)-Reset-After-Seconds")), let observed {
            resetsAt = observed.addingTimeInterval(TimeInterval(after))
        }
        return QuotaWindow(id: "cpa-\(slot)-\(label)", label: label, usedPercent: used, resetsAt: resetsAt)
    }

    private static func signal(_ signals: [String: Any], _ name: String) -> String? {
        for (key, value) in signals {
            let lower = key.lowercased()
            if lower.contains("bengalfox") || lower.contains("additional") { continue }
            guard lower == name.lowercased() else { continue }
            if let text = JSONValue.string(value) { return text }
            if let number = JSONValue.number(value) { return String(number) }
        }
        return nil
    }
}

private func displayLabel(_ text: String?) -> String? {
    guard var text else { return nil }
    if text.lowercased().hasSuffix(".json") {
        text = String(text.dropLast(5))
    }
    return text
}

private func upstreamFailure(_ name: String, _ message: String) -> AccountReading {
    AccountReading(
        snapshot: failed("upstream-\(name)", name, name, plan: nil, .http(-1, message)),
        accountID: nil,
        userID: nil,
        email: nil,
        freshness: 0,
        label: name,
        source: name,
        retain: true
    )
}
