import Foundation

struct FeedDocument: Equatable, Sendable {
    var items: [FeedItem]
}

enum ResetFeedParser {
    static let schema = "quota-board.reset-feed/v1"
    private static let providers: Set<String> = ["codex", "claude", "cursor", "grok"]

    static func parse(_ data: Data) throws -> FeedDocument {
        let root = try JSONValue.object(from: data)
        guard JSONValue.string(root["schema"]) == schema else { throw ParseError.malformed }
        guard let rawItems = root["items"] as? [Any] else { throw ParseError.malformed }
        var items: [FeedItem] = []
        for raw in rawItems.prefix(50) {
            guard let object = raw as? [String: Any], let item = item(object) else { continue }
            items.append(item)
        }
        return FeedDocument(items: items)
    }

    private static func item(_ object: [String: Any]) -> FeedItem? {
        guard
            let id = JSONValue.string(object["id"]),
            let provider = JSONValue.string(object["provider"]),
            providers.contains(provider),
            let status = JSONValue.string(object["status"]).flatMap(FeedStatus.init(rawValue:)),
            let summary = JSONValue.string(object["summary"]),
            let source = object["source"] as? [String: Any],
            let platform = JSONValue.string(source["platform"]),
            let author = source["author"] as? [String: Any],
            let authorName = JSONValue.string(author["name"]),
            let urlText = JSONValue.string(source["url"]),
            let url = URL(string: urlText),
            url.scheme == "https",
            let postedAt = JSONValue.date(source["postedAt"])
        else { return nil }
        let scope = object["scope"] as? [String: Any]
        return FeedItem(
            id: id,
            provider: provider,
            status: status,
            scheduledAt: JSONValue.date(object["scheduledAt"]),
            effectiveAt: JSONValue.date(object["effectiveAt"]),
            plans: strings(scope?["plans"]),
            windows: strings(scope?["windows"]),
            summary: summary,
            sourcePlatform: platform,
            authorName: authorName,
            authorHandle: JSONValue.string(author["handle"]),
            sourceURL: url,
            postedAt: postedAt,
            supersedes: JSONValue.string(object["supersedes"])
        )
    }

    /// A JSON null, or a missing key, means every plan or window. An array restricts the match.
    private static func strings(_ value: Any?) -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let list = value as? [Any] else { return nil }
        return list.compactMap { JSONValue.string($0) }
    }
}

struct ResetFeedConfig: Equatable, Sendable {
    var baseURL: URL?

    static func load(home: URL = CredentialPaths.home) -> ResetFeedConfig {
        if let raw = ProcessInfo.processInfo.environment["QUOTA_BOARD_RESET_FEED"], let url = URL(string: raw), url.scheme == "https" {
            return ResetFeedConfig(baseURL: url)
        }
        let file = home.appendingPathComponent(".quota-board/reset-feed.json")
        guard
            let data = try? Data(contentsOf: file),
            let object = try? JSONValue.object(from: data),
            let text = JSONValue.string(object["baseURL"]),
            let url = URL(string: text),
            url.scheme == "https"
        else { return ResetFeedConfig(baseURL: nil) }
        return ResetFeedConfig(baseURL: url)
    }

    func endpoint(providers: String) -> URL? {
        guard let baseURL else { return nil }
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        guard var components = URLComponents(string: root + "/v1/resets") else { return nil }
        if !providers.isEmpty {
            components.queryItems = [URLQueryItem(name: "providers", value: providers)]
        }
        return components.url
    }
}

struct ResetFeedError: Error, Sendable {
    var message: String
}

enum ResetFeedClient {
    struct Success: Sendable {
        var document: FeedDocument?
        var etag: String?
        var notModified: Bool
    }

    static func fetch(url: URL, etag: String?, token: String?) async -> Result<Success, ResetFeedError> {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let status: Int
        let data: Data
        let headers: [AnyHashable: Any]
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? -1
            headers = http?.allHeaderFields ?? [:]
            data = body
        } catch {
            return .failure(ResetFeedError(message: "重置预告读取失败"))
        }
        if status == 304 {
            return .success(Success(document: nil, etag: header("Etag", headers) ?? etag, notModified: true))
        }
        guard status == 200 else {
            return .failure(ResetFeedError(message: "重置预告读取失败（HTTP \(status)）"))
        }
        do {
            let document = try ResetFeedParser.parse(data)
            return .success(Success(document: document, etag: header("Etag", headers), notModified: false))
        } catch {
            return .failure(ResetFeedError(message: "重置预告无法解析"))
        }
    }

    private static func header(_ name: String, _ headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers {
            guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return JSONValue.string(value) ?? (value as? String)
        }
        return nil
    }
}
