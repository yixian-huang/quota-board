import Foundation

/// Built-in monthly list prices, then `~/.quota-board/fees.json` overrides.
struct FeeTable: Equatable, Sendable {
    var plans: [String: MonthlyPrice] = [:]
    var accounts: [String: MonthlyPrice] = [:]

    func price(for snapshot: ProviderSnapshot) -> MonthlyPrice? {
        if let specific = accounts[snapshot.billingIdentity] { return specific }
        guard let slug = PlanSlug.make(snapshot.plan) else { return nil }
        if let override = plans[slug] { return override }
        return PlanCatalog.price(provider: Mark.kind(for: snapshot), slug: slug)
    }

    static func parse(_ data: Data) -> FeeTable {
        guard let object = try? JSONValue.object(from: data) else { return FeeTable() }
        return FeeTable(
            plans: prices(object["plans"]),
            accounts: prices(object["accounts"])
        )
    }

    private static func prices(_ value: Any?) -> [String: MonthlyPrice] {
        guard let object = value as? [String: Any] else { return [:] }
        var result: [String: MonthlyPrice] = [:]
        for (key, raw) in object {
            guard !key.isEmpty, let price = price(raw) else { continue }
            result[key] = price
        }
        return result
    }

    private static func price(_ value: Any?) -> MonthlyPrice? {
        if let amount = JSONValue.number(value), amount >= 0 {
            return MonthlyPrice(amount: amount, currency: "USD")
        }
        guard let object = value as? [String: Any], let amount = JSONValue.number(object["amount"]), amount >= 0 else {
            return nil
        }
        let currency = JSONValue.string(object["currency"]) ?? "USD"
        return MonthlyPrice(amount: amount, currency: currency)
    }
}

/// US monthly list prices checked on 2026-10-29. Annual discounts are not used.
/// A plan with two published prices, or no published monthly price, is absent.
enum PlanCatalog {
    static func price(provider: Mark.Kind?, slug: String) -> MonthlyPrice? {
        guard let provider, let amount = amounts[provider]?[slug] else { return nil }
        return MonthlyPrice(amount: amount, currency: "USD")
    }

    private static let amounts: [Mark.Kind: [String: Double]] = [
        .claude: [
            "free": 0,
            "pro": 20,
            "max-5x": 100,
            "max-20x": 200,
        ],
        .codex: [
            "free": 0,
            "go": 8,
            "plus": 20,
            "pro-100": 100,
            "pro-200": 200,
            "pro-500": 500,
        ],
        .cursor: [
            "free": 0,
            "plus": 8,
            "premium": 30,
            "super": 100,
            "ultra": 200,
            "pro": 20,
            "pro-plus": 60,
        ],
        .grok: [
            "free": 0,
            "plus": 8,
            "premium": 30,
            "super": 100,
            "ultra": 200,
            "supergrok": 30,
        ],
    ]
}

enum FeeStore {
    static func fileURL(home: URL = CredentialPaths.home) -> URL {
        home.appendingPathComponent(".quota-board/fees.json")
    }

    static func load(from url: URL = fileURL()) -> FeeTable {
        guard let data = try? Data(contentsOf: url) else { return FeeTable() }
        return FeeTable.parse(data)
    }
}
