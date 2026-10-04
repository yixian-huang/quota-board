import Foundation

enum ProviderFailure: Error, Equatable {
    case notSignedIn(String)
    case expired(String)
    case claudeRefreshLimited
    case http(Int, String)
    case malformed

    var message: String {
        switch self {
        case let .notSignedIn(name):
            return "\(name) 未登录"
        case let .expired(hint):
            return hint
        case .claudeRefreshLimited:
            return "Claude 登录已过期，刷新被限流。稍后再试，或重新执行 claude login"
        case let .http(code, message):
            return code > 0 ? "\(message)（HTTP \(code)）" : message
        case .malformed:
            return "用量数据无法解析"
        }
    }
}

enum HTTP {
    static func data(for request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    static func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        try await send(url, method: "GET", headers: headers, body: nil)
    }

    static func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Int, Data) {
        try await send(url, method: "POST", headers: headers, body: body)
    }

    private static func send(
        _ url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body
        return try await data(for: request)
    }
}

enum QuotaService {
    static func fetchAll() async -> [ProviderSnapshot] {
        async let claude = ClaudeProvider.fetch()
        async let cursor = CursorProvider.fetch()
        async let grok = GrokProvider.fetch()
        async let codex = codexSnapshots()
        let codexItems = await codex
        return [await claude] + codexItems + [await cursor, await grok]
    }

    private static func codexSnapshots() async -> [ProviderSnapshot] {
        async let local = CodexProvider.fetchReading()
        async let remote = UpstreamService.fetchCodex()
        let localReading = await local
        let remoteReadings = await remote
        let merged = AccountDeduper.merge([localReading] + remoteReadings)
        return merged.sorted { lhs, rhs in
            let left = lhs.tightest?.remainingPercent ?? 101
            let right = rhs.tightest?.remainingPercent ?? 101
            if left != right { return left < right }
            return lhs.name < rhs.name
        }
    }
}

enum ClaudeProvider {
    static func fetch() async -> ProviderSnapshot {
        do {
            guard var oauth = ClaudeCredentials.load() else {
                throw ProviderFailure.notSignedIn("Claude")
            }
            if oauth.isExpired {
                oauth = try await ClaudeCredentials.refresh(oauth)
            }
            let snapshot = try await usage(token: oauth.accessToken, plan: planName(oauth.subscriptionType))
            if snapshot.windows.isEmpty, snapshot.error == nil {
                return failed("claude", "Claude", "Claude", plan: snapshot.plan, .malformed)
            }
            return snapshot
        } catch let error as ProviderFailure {
            if case .http(401, _) = error, let oauth = ClaudeCredentials.load() {
                do {
                    let refreshed = try await ClaudeCredentials.refresh(oauth)
                    return try await usage(token: refreshed.accessToken, plan: planName(refreshed.subscriptionType))
                } catch let refreshError as ProviderFailure {
                    return failed("claude", "Claude", "Claude", plan: planName(oauth.subscriptionType), refreshError)
                } catch {
                    return failed("claude", "Claude", "Claude", plan: nil, .http(-1, "Claude 请求失败"))
                }
            }
            return failed("claude", "Claude", "Claude", plan: nil, error)
        } catch {
            return failed("claude", "Claude", "Claude", plan: nil, .http(-1, "Claude 请求失败"))
        }
    }

    static func parse(_ data: Data, plan: String?) throws -> ProviderSnapshot {
        let root = try JSONValue.object(from: data)
        let specs: [(String, String)] = [
            ("five_hour", "5 小时"),
            ("seven_day", "每周"),
            ("seven_day_sonnet", "Sonnet 每周"),
            ("seven_day_opus", "Opus 每周"),
        ]
        var windows: [QuotaWindow] = []
        for (key, label) in specs {
            guard
                let bucket = root[key] as? [String: Any],
                let used = JSONValue.number(bucket["utilization"])
            else { continue }
            windows.append(QuotaWindow(
                id: "claude-\(key)",
                label: label,
                usedPercent: used,
                resetsAt: JSONValue.date(bucket["resets_at"])
            ))
        }
        var note: String?
        if let extra = root["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            if let used = JSONValue.number(extra["utilization"]) {
                windows.append(QuotaWindow(
                    id: "claude-extra",
                    label: "额外用量",
                    usedPercent: used,
                    resetsAt: nil
                ))
            } else {
                note = "已开启额外用量"
            }
        }
        return ProviderSnapshot(
            id: "claude",
            name: "Claude",
            shortName: "Claude",
            plan: plan,
            windows: windows,
            note: note,
            error: nil,
            isStale: false
        )
    }

    private static func usage(token: String, plan: String?) async throws -> ProviderSnapshot {
        let (status, data) = try await HTTP.get(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
                "User-Agent": "claude-code/2.1.0",
            ]
        )
        guard status == 200 else {
            throw ProviderFailure.http(status, status == 401 ? "Claude 登录已过期" : "Claude 用量请求失败")
        }
        return try parse(data, plan: plan)
    }

    private static func planName(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case nil, "": return nil
        default: return raw?.capitalized
        }
    }
}

enum CodexProvider {
    static func fetchReading() async -> AccountReading {
        let credentials = CodexCredentials.load()
        let accountID = credentials?.accountID
        let billing = credentials?.idToken.flatMap(OpenAISubscription.anchor(in:))
        do {
            guard let credentials else {
                throw ProviderFailure.notSignedIn("Codex")
            }
            var headers = [
                "Authorization": "Bearer \(credentials.accessToken)",
                "Accept": "application/json",
                "User-Agent": "codex-cli",
            ]
            if let accountID = credentials.accountID, !accountID.isEmpty {
                headers["ChatGPT-Account-Id"] = accountID
            }
            let (status, data) = try await HTTP.get(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                headers: headers
            )
            guard status == 200 else {
                let message = status == 401 ? "Codex 登录已过期，在终端重新打开 codex" : "Codex 用量请求失败"
                throw ProviderFailure.http(status, message)
            }
            let snapshot = try parse(data).replacing(billing: billing)
            let identity = identity(in: data)
            return AccountReading(
                snapshot: snapshot,
                accountID: accountID ?? identity.accountID,
                userID: identity.userID,
                email: identity.email,
                freshness: 3,
                label: nil,
                source: "local"
            )
        } catch let error as ProviderFailure {
            return AccountReading(
                snapshot: failed("codex", "Codex", "Codex", plan: nil, error).replacing(billing: billing),
                accountID: accountID,
                userID: nil,
                email: nil,
                freshness: 3,
                label: nil,
                source: "local"
            )
        } catch {
            return AccountReading(
                snapshot: failed("codex", "Codex", "Codex", plan: nil, .http(-1, "Codex 请求失败")).replacing(billing: billing),
                accountID: accountID,
                userID: nil,
                email: nil,
                freshness: 3,
                label: nil,
                source: "local"
            )
        }
    }

    static func identity(in data: Data) -> (accountID: String?, userID: String?, email: String?) {
        guard let root = try? JSONValue.object(from: data) else {
            return (nil, nil, nil)
        }
        return (
            JSONValue.string(root["account_id"]) ?? JSONValue.string(root["chatgpt_account_id"]),
            JSONValue.string(root["user_id"]),
            JSONValue.string(root["email"])
        )
    }

    static func parse(_ data: Data) throws -> ProviderSnapshot {
        let root = try JSONValue.object(from: data)
        let plan = planName(root["plan_type"] as? String)
        let rateLimit = root["rate_limit"] as? [String: Any] ?? [:]
        var windows: [QuotaWindow] = []
        if let primary = rateLimit["primary_window"] as? [String: Any], let window = window(primary, slot: "primary") {
            windows.append(window)
        }
        if let secondary = rateLimit["secondary_window"] as? [String: Any], let window = window(secondary, slot: "secondary") {
            windows.append(window)
        }
        var notes: [String] = []
        if let credits = root["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true {
            if let balance = credits["balance"] as? String, let value = Int(balance) {
                notes.append("点数 \(grouped(value))")
            } else if let balance = JSONValue.int(credits["balance"]) {
                notes.append("点数 \(grouped(balance))")
            }
        }
        if let resets = root["rate_limit_reset_credits"] as? [String: Any], let count = JSONValue.int(resets["available_count"]) {
            notes.append("重置次数 \(count)")
        }
        return ProviderSnapshot(
            id: "codex",
            name: "Codex",
            shortName: "Codex",
            plan: plan,
            windows: windows,
            note: notes.isEmpty ? nil : notes.joined(separator: " · "),
            error: windows.isEmpty ? ProviderFailure.malformed.message : nil,
            isStale: false
        )
    }

    private static func window(_ object: [String: Any], slot: String) -> QuotaWindow? {
        guard let used = JSONValue.number(object["used_percent"]) else { return nil }
        let seconds = JSONValue.int(object["limit_window_seconds"]) ?? 0
        let label = windowLabel(forSeconds: seconds)
        let idSuffix = label == "窗口" ? slot : label
        return QuotaWindow(
            id: "codex-\(idSuffix)",
            label: label,
            usedPercent: used,
            resetsAt: JSONValue.date(object["reset_at"])
        )
    }

    static func planName(_ raw: String?) -> String? {
        switch raw {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case nil, "": return nil
        default: return raw?.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum CursorProvider {
    static func fetch() async -> ProviderSnapshot {
        do {
            guard let credentials = CursorCredentials.load() else {
                throw ProviderFailure.notSignedIn("Cursor")
            }
            let (status, data) = try await HTTP.get(
                URL(string: "https://api2.cursor.sh/auth/usage-summary")!,
                headers: [
                    "Authorization": "Bearer \(credentials.accessToken)",
                    "Accept": "application/json",
                    "User-Agent": "Cursor/1.0",
                ]
            )
            guard status == 200 else {
                let message = status == 401 ? "Cursor 登录已过期，打开 Cursor 重新登录" : "Cursor 用量请求失败"
                throw ProviderFailure.http(status, message)
            }
            return try parse(data, membership: credentials.membership)
        } catch let error as ProviderFailure {
            return failed("cursor", "Cursor", "Cursor", plan: nil, error)
        } catch {
            return failed("cursor", "Cursor", "Cursor", plan: nil, .http(-1, "Cursor 请求失败"))
        }
    }

    static func parse(_ data: Data, membership: String?) throws -> ProviderSnapshot {
        let root = try JSONValue.object(from: data)
        let plan = planName((root["membershipType"] as? String) ?? membership)
        let individual = root["individualUsage"] as? [String: Any]
        let planUsage = individual?["plan"] as? [String: Any] ?? [:]
        let reset = JSONValue.date(root["billingCycleEnd"])
        let billing = reset.map { BillingAnchor(at: $0, renews: nil, manual: false) }
        let specs: [(String, String)] = [
            ("apiPercentUsed", "API"),
            ("autoPercentUsed", "Auto"),
            ("totalPercentUsed", "总计"),
        ]
        let windows = specs.compactMap { key, label -> QuotaWindow? in
            guard let used = JSONValue.number(planUsage[key]) else { return nil }
            return QuotaWindow(id: "cursor-\(key)", label: label, usedPercent: used, resetsAt: reset)
        }
        var note: String?
        if let onDemand = individual?["onDemand"] as? [String: Any], (onDemand["enabled"] as? Bool) == true {
            if let used = JSONValue.number(onDemand["used"]) {
                note = "按量已用 \(Int(used.rounded()))"
            }
        }
        return ProviderSnapshot(
            id: "cursor",
            name: "Cursor",
            shortName: "Cursor",
            plan: plan,
            windows: windows,
            note: note,
            error: windows.isEmpty ? ProviderFailure.malformed.message : nil,
            isStale: false,
            billing: billing
        )
    }

    private static func planName(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "pro": return "Pro"
        case "pro_plus", "proplus": return "Pro+"
        case "ultra": return "Ultra"
        case "free": return "Free"
        case "business", "enterprise": return raw?.capitalized
        case nil, "": return nil
        default: return raw?.capitalized
        }
    }
}

enum GrokProvider {
    static func fetch() async -> ProviderSnapshot {
        do {
            guard let session = GrokCredentials.load() else {
                throw ProviderFailure.notSignedIn("Grok")
            }
            if let expires = session.expiresAt, expires.timeIntervalSinceNow < 60 {
                throw ProviderFailure.expired("Grok 登录即将过期或已过期。打开一次 grok，让它自己刷新登录")
            }
            var headers = [
                "Authorization": "Bearer \(session.accessToken)",
                "Accept": "application/json",
                "X-XAI-Token-Auth": "xai-grok-cli",
                "User-Agent": "xai-grok-cli",
            ]
            if let userID = session.userID, !userID.isEmpty {
                headers["x-userid"] = userID
            }
            let (status, data) = try await HTTP.get(
                URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
                headers: headers
            )
            guard status == 200 else {
                if status == 401 || status == 403 {
                    throw ProviderFailure.expired("Grok 登录已失效。打开一次 grok，让它自己刷新登录")
                }
                throw ProviderFailure.http(status, "Grok 用量请求失败")
            }
            let plan = await planName(headers: headers)
            var snapshot = try parse(data, plan: plan)
            if snapshot.billing == nil {
                snapshot = await monthlyBilling(snapshot, headers: headers)
            }
            return snapshot
        } catch let error as ProviderFailure {
            return failed("grok", "Grok", "Grok", plan: nil, error)
        } catch {
            return failed("grok", "Grok", "Grok", plan: nil, .http(-1, "Grok 请求失败"))
        }
    }

    static func parse(_ data: Data, plan: String?) throws -> ProviderSnapshot {
        let root = try JSONValue.object(from: data)
        guard let config = root["config"] as? [String: Any] else { throw ParseError.malformed }
        let used = JSONValue.number(config["creditUsagePercent"]) ?? 0
        let period = config["currentPeriod"] as? [String: Any]
        let periodType = (period?["type"] as? String) ?? ""
        let label = periodType.contains("WEEK") ? "每周" : (periodType.contains("MONTH") ? "每月" : "额度")
        let reset = JSONValue.date(period?["end"])
        let billing = JSONValue.date(config["billingPeriodEnd"]).map {
            BillingAnchor(at: $0, renews: nil, manual: false)
        }
        var windows = [
            QuotaWindow(id: "grok-main", label: label, usedPercent: used, resetsAt: reset)
        ]
        if let products = config["productUsage"] as? [[String: Any]] {
            for product in products {
                guard
                    let name = product["product"] as? String,
                    let percent = JSONValue.number(product["usagePercent"]),
                    abs(percent - used) > 0.5
                else { continue }
                windows.append(QuotaWindow(
                    id: "grok-\(name)",
                    label: name,
                    usedPercent: percent,
                    resetsAt: reset
                ))
            }
        }
        var note: String?
        let cap = JSONValue.number((config["onDemandCap"] as? [String: Any])?["val"]) ?? 0
        let onDemandUsed = JSONValue.number((config["onDemandUsed"] as? [String: Any])?["val"]) ?? 0
        if cap > 0 {
            note = "按量 \(Int(onDemandUsed.rounded()))/\(Int(cap.rounded()))"
        }
        return ProviderSnapshot(
            id: "grok",
            name: "Grok",
            shortName: "Grok",
            plan: plan,
            windows: windows,
            note: note,
            error: nil,
            isStale: false,
            billing: billing
        )
    }

    /// Weekly credits omit the monthly bill date. The unscoped billing route carries it.
    private static func monthlyBilling(_ snapshot: ProviderSnapshot, headers: [String: String]) async -> ProviderSnapshot {
        guard
            let (status, data) = try? await HTTP.get(
                URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!,
                headers: headers
            ),
            status == 200,
            let billing = try? parse(data, plan: snapshot.plan).billing
        else { return snapshot }
        return snapshot.replacing(billing: billing)
    }

    private static func planName(headers: [String: String]) async -> String? {
        guard
            let (status, data) = try? await HTTP.get(
                URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
                headers: headers
            ),
            status == 200,
            let root = try? JSONValue.object(from: data)
        else { return nil }
        let keys = ["subscription_tier_display", "subscriptionTierDisplay", "plan_name", "planName"]
        for key in keys {
            if let value = root[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

enum OpenAISubscription {
    /// Reads `chatgpt_subscription_active_until` from a Codex id token. The signature is not checked; the token is only a local claim bag.
    static func anchor(in token: String) -> BillingAnchor? {
        guard
            let payload = jwtPayload(token),
            let auth = payload["https://api.openai.com/auth"] as? [String: Any],
            let until = JSONValue.date(auth["chatgpt_subscription_active_until"])
        else { return nil }
        return BillingAnchor(at: until, renews: nil, manual: false)
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var text = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 {
            text += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: text) else { return nil }
        return try? JSONValue.object(from: data)
    }
}

func failed(
    _ id: String,
    _ name: String,
    _ shortName: String,
    plan: String?,
    _ error: ProviderFailure
) -> ProviderSnapshot {
    ProviderSnapshot(
        id: id,
        name: name,
        shortName: shortName,
        plan: plan,
        windows: [],
        note: nil,
        error: error.message,
        isStale: false
    )
}

private func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}
