import Foundation

struct QuotaWindow: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    /// 0...100, share already used.
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct BillingAnchor: Equatable, Sendable {
    /// Observed or chosen billing instant. A past monthly date rolls forward.
    var at: Date
    /// False means the paid period lapses on `at` and does not roll forward.
    var renews: Bool?
    /// A saved choice replaces the automatic reading until cleared.
    var manual: Bool
}

struct ProviderSnapshot: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let shortName: String
    let plan: String?
    let windows: [QuotaWindow]
    let note: String?
    let error: String?
    /// Previous reading kept after a failed refresh.
    let isStale: Bool
    /// Stable key for a hand-set billing day. Nil uses `id`.
    var billingKey: String? = nil
    var billing: BillingAnchor? = nil

    var billingIdentity: String { billingKey ?? id }

    var tightest: QuotaWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    func replacing(billing: BillingAnchor?, billingKey: String? = nil) -> ProviderSnapshot {
        var copy = self
        copy.billing = billing
        if let billingKey {
            copy.billingKey = billingKey
        }
        return copy
    }

    var dumpLine: String {
        let planText = plan.map { " \($0)" } ?? ""
        if windows.isEmpty {
            var line = "\(name)\(planText): \(error ?? "无数据")"
            if let billing {
                line += "；\(Format.billing(billing))"
            }
            return line
        }
        let parts = windows.map { window in
            let used = Int(window.usedPercent.rounded())
            let reset = window.resetsAt.map { "，\(Format.reset($0))" } ?? ""
            return "\(window.label) 剩余 \(Int(window.remainingPercent.rounded()))%（已用 \(used)%\(reset)）"
        }
        var line = "\(name)\(planText): " + parts.joined(separator: "；")
        if let billing {
            line += "；\(Format.billing(billing))"
        }
        if let note, !note.isEmpty {
            line += "；\(note)"
        }
        if let error {
            line += "；\(error)"
        }
        return line
    }
}

enum BillingCalendar {
    /// Next billing day. A future anchor stays put. A past one advances by calendar months, keeping the day of month and clamping short months.
    static func next(anchor: Date, renews: Bool?, now: Date = .now, calendar: Calendar = .current) -> Date {
        if renews == false { return anchor }
        let today = calendar.startOfDay(for: now)
        if calendar.startOfDay(for: anchor) >= today { return anchor }
        let day = calendar.component(.day, from: anchor)
        var year = calendar.component(.year, from: anchor)
        var month = calendar.component(.month, from: anchor)
        for _ in 0..<240 {
            month += 1
            if month > 12 {
                month = 1
                year += 1
            }
            guard let candidate = date(year: year, month: month, day: day, calendar: calendar) else { break }
            if calendar.startOfDay(for: candidate) >= today { return candidate }
        }
        return anchor
    }

    static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = year
        parts.month = month
        parts.day = 1
        guard
            let start = calendar.date(from: parts),
            let range = calendar.range(of: .day, in: .month, for: start)
        else { return nil }
        parts.day = min(max(day, 1), range.count)
        return calendar.date(from: parts)
    }
}

enum BillingOverrides {
    static func apply(_ snapshots: [ProviderSnapshot], manual: [String: Date]) -> [ProviderSnapshot] {
        snapshots.map { snapshot in
            guard let date = manual[snapshot.billingIdentity] else { return snapshot }
            return snapshot.replacing(billing: BillingAnchor(at: date, renews: nil, manual: true))
        }
    }
}

enum BillingStore {
    static func fileURL(home: URL = CredentialPaths.home) -> URL {
        home.appendingPathComponent(".quota-board/billing.json")
    }

    static func load(from url: URL = fileURL(), calendar: Calendar = .current) -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return parse(data, calendar: calendar)
    }

    static func parse(_ data: Data, calendar: Calendar = .current) -> [String: Date] {
        guard let object = try? JSONValue.object(from: data) else { return [:] }
        var result: [String: Date] = [:]
        for (key, value) in object {
            guard let text = JSONValue.string(value), let date = day(text, calendar: calendar) else { continue }
            result[key] = date
        }
        return result
    }

    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        return BillingCalendar.date(year: year, month: month, day: day, calendar: calendar)
    }

    static func save(_ entries: [String: Date], to url: URL = fileURL(), calendar: Calendar = .current) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: String] = [:]
        for (key, date) in entries {
            let year = calendar.component(.year, from: date)
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            object[key] = String(format: "%04d-%02d-%02d", year, month, day)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

enum Format {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func reset(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时\(minutes)分后重置" }
        return "\(minutes)分后重置"
    }

    /// One-line window caption. A reset already in the past is not "about to reset".
    static func shortReset(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "已重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时后" }
        if hours > 0 { return "\(hours)小时\(minutes)分后" }
        return "\(minutes)分后"
    }

    static func updated(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds) 秒前更新" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        return "\(minutes / 60) 小时前更新"
    }

    static func billing(_ anchor: BillingAnchor, now: Date = .now, calendar: Calendar = .current) -> String {
        let next = BillingCalendar.next(anchor: anchor.at, renews: anchor.renews, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        if anchor.renews == false, calendar.startOfDay(for: next) < today {
            return "账单已过"
        }
        let word = anchor.renews == true ? "续费" : (anchor.renews == false ? "到期" : "账单")
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: next)).day ?? 0
        if days <= 0 { return "今天\(word)" }
        if days < 7 { return "\(days)天后\(word)" }
        let month = calendar.component(.month, from: next)
        let day = calendar.component(.day, from: next)
        let year = calendar.component(.year, from: next)
        if year != calendar.component(.year, from: now) {
            return "\(word) \(year)年\(month)月\(day)日"
        }
        return "\(word) \(month)月\(day)日"
    }
}

enum MenuTitle {
    /// Menu bar shows every provider under 50% remaining, otherwise only the tightest one.
    static func text(for snapshots: [ProviderSnapshot]) -> String {
        let ranked = snapshots.compactMap { snapshot -> (String, Int)? in
            guard let window = snapshot.tightest else { return nil }
            return (snapshot.shortName, Int(window.remainingPercent.rounded()))
        }
        .sorted { $0.1 < $1.1 }

        if ranked.isEmpty {
            return snapshots.contains { $0.error != nil } ? "额度不可用" : "读取中"
        }
        let pressing = ranked.filter { $0.1 < 50 }
        let shown = pressing.isEmpty ? [ranked[0]] : pressing
        return shown.map { "\($0.0) \($0.1)%" }.joined(separator: " · ")
    }
}

enum JSONValue {
    static func object(from data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw ParseError.malformed
        }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        return Int(number.rounded())
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        }
        guard let number = number(value) else { return nil }
        if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
        if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        return nil
    }
}

enum ParseError: Error {
    case malformed
}

func windowLabel(forSeconds seconds: Int) -> String {
    if seconds >= 6 * 24 * 3_600 { return "每周" }
    if seconds > 0, seconds <= 6 * 3_600 { return "5 小时" }
    return "窗口"
}

func mergeSnapshots(previous: [ProviderSnapshot], fresh: [ProviderSnapshot]) -> [ProviderSnapshot] {
    fresh.map { item in
        guard item.windows.isEmpty, let old = previous.first(where: { $0.id == item.id }), !old.windows.isEmpty else {
            return item
        }
        return ProviderSnapshot(
            id: item.id,
            name: item.name,
            shortName: item.shortName,
            plan: item.plan ?? old.plan,
            windows: old.windows,
            note: old.note,
            error: item.error,
            isStale: true,
            billingKey: item.billingKey ?? old.billingKey,
            billing: item.billing ?? old.billing
        )
    }
}
