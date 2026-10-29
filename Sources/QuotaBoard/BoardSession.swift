import AppKit
import SwiftUI

struct BoardTip: Equatable {
    var id: String
    var title: String
    var lines: [String]
}

enum BoardFloat: Equatable {
    case look
    case sort
    case card(String)
}

enum FeedPhase: Equatable {
    case unconfigured
    case loading
    case ready
    case failed
}

struct FeedSnapshot: Equatable {
    var phase: FeedPhase = .unconfigured
    var error: String?
    var items: [FeedItem] = []
    var updated: Date?
    var etag: String?
}

@MainActor
final class BoardSession: ObservableObject {
    let store: QuotaStore

    @Published var snapshots: [ProviderSnapshot] = []
    @Published var hidden: [ProviderSnapshot] = []
    @Published var refreshing = false
    @Published var lastUpdated: Date?
    @Published var sort: BoardSort = .expiry
    @Published var page: BoardPage = .quota
    @Published var viewMode: BoardViewMode = .list
    @Published var theme: PanelTheme = .system
    @Published var fees = FeeTable()
    @Published var feed = FeedSnapshot()
    @Published var editingKey: String?
    @Published var namingKey: String?
    @Published var draftDate = Date()
    @Published var draftName = ""
    @Published var editError: String?
    @Published var nameError: String?
    @Published var accountErrorKey: String?
    @Published var accountError: String?
    @Published var float: BoardFloat?
    @Published var tip: BoardTip?
    @Published var preferredHeight: CGFloat = 480

    var onChrome: ((PanelTheme) -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    var scrollOffset: CGFloat = -1

    private var feedTask: Task<Void, Never>?
    private var feedInFlight = false
    private enum Defaults {
        static let theme = "QuotaBoard.panelTheme"
        static let view = "QuotaBoard.boardView"
    }

    init(store: QuotaStore) {
        self.store = store
        if let raw = UserDefaults.standard.string(forKey: Defaults.theme), let saved = PanelTheme(rawValue: raw) {
            theme = saved
        }
        if UserDefaults.standard.string(forKey: Defaults.view) == BoardViewMode.chart.rawValue {
            viewMode = .chart
        }
        fees = FeeStore.load()
    }

    func syncFromStore() {
        snapshots = store.snapshots
        hidden = store.hidden
        refreshing = store.isRefreshing
        lastUpdated = store.lastUpdated
        sort = store.sort
        fees = FeeStore.load()
    }

    func reportHeight(_ height: CGFloat) {
        let next = height.rounded()
        guard next > 1, abs(next - preferredHeight) > 0.5 else { return }
        preferredHeight = next
        onHeight?(next)
    }

    func noteScroll(_ offset: CGFloat) {
        if scrollOffset >= 0, abs(scrollOffset - offset) > 1 {
            tip = nil
        }
        scrollOffset = offset
    }

    func panelOpened() {
        fees = FeeStore.load()
        syncFromStore()
    }

    func panelClosed() {
        float = nil
        tip = nil
        feedTask?.cancel()
        feedTask = nil
    }

    func setPage(_ page: BoardPage) {
        self.page = page
        float = nil
        tip = nil
    }

    func setView(_ mode: BoardViewMode) {
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Defaults.view)
        float = nil
        tip = nil
    }

    func toggleLook() {
        float = float == .look ? nil : .look
        tip = nil
    }

    func toggleSort() {
        float = float == .sort ? nil : .sort
        tip = nil
    }

    func pickTheme(_ theme: PanelTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Defaults.theme)
        float = nil
        onChrome?(theme)
    }

    func pickSort(_ sort: BoardSort) {
        float = nil
        guard store.setSort(sort) else { return }
        self.sort = sort
    }

    func toggleCardMenu(_ key: String) {
        tip = nil
        if float == .card(key) {
            float = nil
        } else {
            float = .card(key)
        }
    }

    func closeFloats() {
        float = nil
        tip = nil
    }

    func consumeEscape() -> Bool {
        if tip != nil {
            tip = nil
            return true
        }
        if float != nil {
            float = nil
            return true
        }
        return false
    }

    func showTip(id: String, title: String, lines: [String]) {
        let next = BoardTip(id: id, title: title, lines: lines)
        if tip != next { tip = next }
    }

    func hideTip(id: String) {
        if tip?.id == id { tip = nil }
    }

    func refresh() {
        Task { await store.refresh(userInitiated: true) }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func beginBilling(_ key: String) {
        float = nil
        editingKey = key
        namingKey = nil
        editError = nil
        nameError = nil
        if let billing = snapshots.first(where: { $0.billingIdentity == key })?.billing {
            draftDate = BillingCalendar.next(anchor: billing.at, renews: billing.renews)
        } else {
            draftDate = Date()
        }
    }

    func saveBilling(_ key: String) {
        if store.setManualBilling(key: key, day: draftDate) {
            editingKey = nil
            editError = nil
        } else {
            editError = "账单日没有写入"
        }
    }

    func clearBilling(_ key: String) {
        if store.clearManualBilling(key: key) {
            editingKey = nil
            editError = nil
        } else {
            editError = "账单日没有写入"
        }
    }

    func cancelBilling() {
        editingKey = nil
        editError = nil
    }

    func beginName(_ key: String) {
        float = nil
        namingKey = key
        editingKey = nil
        nameError = nil
        accountError = nil
        accountErrorKey = nil
        draftName = snapshots.first { $0.billingIdentity == key }?.name ?? ""
    }

    func saveName(_ key: String) {
        let raw = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            nameError = "名称不能为空"
            return
        }
        guard raw.count <= AccountDirectory.nameLimit else {
            nameError = "名称太长"
            return
        }
        if store.setAccountName(key: key, name: raw) {
            namingKey = nil
            nameError = nil
        } else {
            nameError = "名称没有写入"
        }
    }

    func clearName(_ key: String) {
        float = nil
        if store.clearAccountName(key: key) {
            namingKey = nil
            nameError = nil
        } else {
            nameError = "名称没有写入"
            namingKey = key
        }
    }

    func cancelName() {
        namingKey = nil
        nameError = nil
    }

    func hide(_ key: String) {
        float = nil
        if store.hideAccount(key: key) {
            if namingKey == key { namingKey = nil }
            if editingKey == key { editingKey = nil }
            nameError = nil
            accountError = nil
            accountErrorKey = nil
        } else {
            accountErrorKey = key
            accountError = "账号没有写入"
        }
    }

    func restore(_ key: String) {
        if store.restoreAccount(key: key) {
            accountError = nil
            accountErrorKey = nil
        } else {
            accountErrorKey = "hidden"
            accountError = "账号没有写入"
        }
    }

    func open(_ url: URL) {
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func price(for snapshot: ProviderSnapshot) -> MonthlyPrice? {
        fees.price(for: snapshot)
    }

    var upcomingNotices: Int {
        FeedLogic.upcomingCount(feed.items, snapshots: snapshots)
    }

    func refreshFeed() async {
        guard !feedInFlight else { return }
        let config = ResetFeedConfig.load()
        guard let url = config.endpoint(providers: providerQuery()) else {
            feed.phase = .unconfigured
            feed.error = nil
            return
        }
        feedInFlight = true
        defer { feedInFlight = false }
        if feed.items.isEmpty {
            feed.phase = .loading
            feed.error = nil
        }
        let token = KeychainSecret.password(service: "quota-board", account: "reset-feed")
        let result = await ResetFeedClient.fetch(url: url, etag: feed.etag, token: token)
        switch result {
        case let .success(success):
            if let document = success.document {
                feed.items = document.items
            }
            if let etag = success.etag {
                feed.etag = etag
            }
            feed.phase = .ready
            feed.error = nil
            feed.updated = Date()
        case let .failure(error):
            feed.phase = .failed
            feed.error = error.message
        }
    }

    private func providerQuery() -> String {
        let ids = (snapshots + hidden).compactMap { Mark.kind(for: $0)?.feedID }.filter { !$0.isEmpty }
        return Array(Set(ids)).sorted().joined(separator: ",")
    }
}
