import Foundation

/// Bright segments show what is left. A full bar means nothing has been used.
enum MeterTone: Equatable {
    case ok
    case warn
    case hot

    static func from(usedPercent: Double) -> MeterTone {
        if usedPercent >= 90 { return .hot }
        if usedPercent >= 70 { return .warn }
        return .ok
    }

    var rank: Int {
        switch self {
        case .ok: 0
        case .warn: 1
        case .hot: 2
        }
    }
}

enum MeterMath {
    static let segments = 20

    /// Lit segments are the remaining share, rounded up, so a sliver still lights one segment.
    static func litCount(_ remainingPercent: Double) -> Int {
        let clamped = min(100, max(0, remainingPercent))
        return Int((clamped / 100 * Double(segments)).rounded(.up))
    }
}

struct ResetSpan: Equatable {
    var text: String
    var rows: Int
}

enum ResetLayout {
    /// Consecutive windows that reset at the same moment share one caption.
    static func spans(_ windows: [QuotaWindow], text: (Date) -> String) -> [ResetSpan] {
        var result: [ResetSpan] = []
        var index = 0
        while index < windows.count {
            if let date = windows[index].resetsAt {
                var rows = 1
                while index + rows < windows.count, windows[index + rows].resetsAt == date {
                    rows += 1
                }
                result.append(ResetSpan(text: text(date), rows: rows))
                index += rows
            } else {
                result.append(ResetSpan(text: "", rows: 1))
                index += 1
            }
        }
        return result
    }
}

enum BoardFormat {
    /// Chart and timeline captions. Ten days and beyond keep only the day count.
    static func briefReset(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "已重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days >= 10 { return "\(days)天" }
        if days > 0 { return "\(days)天\(hours)时" }
        if hours > 0 { return "\(hours)时\(minutes)分" }
        return "\(minutes)分"
    }

    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%d月%d日 %02d:%02d", month, day, hour, minute)
    }

    static func ago(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)月\(day)日"
    }

    static func money(_ amount: Double, currency: String) -> String {
        let rounded = Int(amount.rounded())
        let sign: String
        switch currency {
        case "USD": sign = "$"
        case "CNY": sign = "¥"
        default: sign = "\(currency) "
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let digits = formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return sign + digits
    }

    static func resetLine(_ window: QuotaWindow, now: Date = .now) -> String {
        let percent = Format.percent(window.remainingPercent)
        guard let resetsAt = window.resetsAt else {
            return "\(window.label) 剩余 \(percent) · 没有重置时间"
        }
        if resetsAt > now {
            return "\(window.label) 剩余 \(percent) · \(Format.shortReset(resetsAt, now: now))重置（\(stamp(resetsAt))）"
        }
        return "\(window.label) 剩余 \(percent) · 已重置"
    }
}

struct MonthlyPrice: Equatable, Sendable {
    var amount: Double
    var currency: String
}

struct Worth: Equatable {
    var left: Double
    var total: Double
    var currency: String
}

struct BusTotal: Equatable {
    var left: Double
    var total: Double
    var currency: String
    var excluded: Int
    var ratio: Double

    var usedPercent: Double { max(0, min(100, 100 - ratio * 100)) }
}

enum WorthMath {
    /// Remaining value is the monthly price times the tightest window's remaining share.
    static func worth(_ snapshot: ProviderSnapshot, price: MonthlyPrice?) -> Worth? {
        guard let price, let best = snapshot.tightest else { return nil }
        return Worth(
            left: price.amount * best.remainingPercent / 100,
            total: price.amount,
            currency: price.currency
        )
    }

    /// Sums visible accounts that share the first counted currency. The caller passes visible cards only.
    static func bus(_ snapshots: [ProviderSnapshot], price: (ProviderSnapshot) -> MonthlyPrice?) -> BusTotal? {
        var left = 0.0
        var total = 0.0
        var excluded = 0
        var counted = 0
        var currency: String?
        for snapshot in snapshots {
            guard let value = worth(snapshot, price: price(snapshot)) else {
                excluded += 1
                continue
            }
            if let currency, value.currency != currency {
                excluded += 1
                continue
            }
            currency = value.currency
            left += value.left
            total += value.total
            counted += 1
        }
        guard counted > 0, let currency else { return nil }
        return BusTotal(left: left, total: total, currency: currency, excluded: excluded, ratio: total > 0 ? left / total : 0)
    }
}

enum TimelineMath {
    static let horizonMinutes = 30.0 * 24 * 60

    /// Logarithmic position, 0 at now and 100 at 30 days. Later instants sit on the right edge.
    static func position(minutes: Double) -> Double {
        let clamped = min(max(minutes, 0), horizonMinutes)
        return log1p(clamped / 60) / log1p(horizonMinutes / 60) * 100
    }

    static let ticks: [(minutes: Double, label: String)] = [
        (0, "现在"),
        (360, "6时"),
        (1_440, "1天"),
        (4_320, "3天"),
        (10_080, "7天"),
        (horizonMinutes, "30天"),
    ]

    struct Dot: Equatable {
        var position: Double
        var tone: MeterTone
    }

    /// One dot per future instant. Windows that reset together use the tighter tone.
    static func dots(_ windows: [QuotaWindow], now: Date = .now) -> [Dot] {
        var grouped: [Date: MeterTone] = [:]
        for window in windows {
            guard let resetsAt = window.resetsAt, resetsAt > now else { continue }
            let tone = MeterTone.from(usedPercent: window.usedPercent)
            if let existing = grouped[resetsAt] {
                grouped[resetsAt] = tone.rank > existing.rank ? tone : existing
            } else {
                grouped[resetsAt] = tone
            }
        }
        return grouped.keys.sorted().map { date in
            let minutes = date.timeIntervalSince(now) / 60
            return Dot(position: position(minutes: minutes), tone: grouped[date] ?? .ok)
        }
    }

    static func hasFutureReset(_ snapshots: [ProviderSnapshot], now: Date = .now) -> Bool {
        snapshots.contains { snapshot in
            snapshot.windows.contains { ($0.resetsAt ?? .distantPast) > now }
        }
    }
}

enum PlanSlug {
    static func make(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased().replacingOccurrences(of: "+", with: "-plus")
        return lower.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}

enum FeedStatus: String, Equatable, Sendable {
    case announced
    case confirmed
    case done
    case cancelled

    var title: String {
        switch self {
        case .announced: "预告"
        case .confirmed: "已确认"
        case .done: "已生效"
        case .cancelled: "已取消"
        }
    }

    var tone: MeterTone? {
        switch self {
        case .confirmed: .ok
        case .announced: .warn
        case .done, .cancelled: nil
        }
    }
}

struct FeedItem: Equatable, Identifiable, Sendable {
    var id: String
    var provider: String
    var status: FeedStatus
    var scheduledAt: Date?
    var effectiveAt: Date?
    /// Nil matches every plan on this provider. An account with no plan only matches nil.
    var plans: [String]?
    var windows: [String]?
    var summary: String
    var sourcePlatform: String
    var authorName: String
    var authorHandle: String?
    var sourceURL: URL
    var postedAt: Date
    var supersedes: String?

    var providerTitle: String {
        switch provider {
        case "codex": "Codex"
        case "claude": "Claude"
        case "cursor": "Cursor"
        case "grok": "Grok"
        default: provider
        }
    }

    var platformTitle: String {
        sourcePlatform == "x" ? "x.com" : sourcePlatform
    }

    func windowTitle() -> String {
        guard let windows else { return "全部窗口" }
        let names = windows.map { id -> String in
            switch id {
            case "5h": "5 小时"
            case "week": "每周"
            case "sonnet": "Sonnet 每周"
            case "opus": "Opus 每周"
            case "extra": "额外用量"
            default: id
            }
        }
        return names.joined(separator: "、")
    }
}

enum FeedLogic {
    static func pending(_ item: FeedItem, now: Date = .now) -> Bool {
        guard item.status == .announced || item.status == .confirmed, let at = item.scheduledAt else {
            return false
        }
        return at > now
    }

    static func split(_ items: [FeedItem], now: Date = .now) -> (upcoming: [FeedItem], past: [FeedItem]) {
        let replaced = Set(items.compactMap(\.supersedes))
        let live = items.filter { !replaced.contains($0.id) }
        let horizon = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let upcoming = live.filter { pending($0, now: now) }.sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
        let past = live.filter { item in
            guard !pending(item, now: now) else { return false }
            return when(item) >= horizon
        }.sorted { when($0) > when($1) }
        return (upcoming, past)
    }

    static func affected(_ item: FeedItem, snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.filter { snapshot in
            guard Mark.kind(for: snapshot)?.feedID == item.provider else { return false }
            guard let plans = item.plans else { return true }
            guard let slug = PlanSlug.make(snapshot.plan) else { return false }
            return plans.contains(slug)
        }
    }

    static func upcomingCount(_ items: [FeedItem], snapshots: [ProviderSnapshot], now: Date = .now) -> Int {
        split(items, now: now).upcoming.filter { !affected($0, snapshots: snapshots).isEmpty }.count
    }

    private static func when(_ item: FeedItem) -> Date {
        item.effectiveAt ?? item.scheduledAt ?? item.postedAt
    }
}

extension Mark.Kind {
    var feedID: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .grok: "grok"
        case .board: ""
        }
    }

    static func fromFeed(_ provider: String) -> Mark.Kind? {
        switch provider {
        case "claude": .claude
        case "codex": .codex
        case "cursor": .cursor
        case "grok": .grok
        default: nil
        }
    }
}
