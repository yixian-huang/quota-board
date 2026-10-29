import AppKit

private nonisolated(unsafe) var retainedDelegate: AppDelegate?

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(Int32(SelfTest.run()))
        }
        if CommandLine.arguments.contains("--dump") {
            Task {
                let listed = AccountStore.load().apply(await QuotaService.fetchAll()).visible
                let snapshots = BillingOverrides.apply(listed, manual: BillingStore.load())
                for snapshot in snapshots {
                    print(snapshot.dumpLine)
                }
                fflush(stdout)
                exit(0)
            }
            dispatchMain()
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            retainedDelegate = delegate
            app.delegate = delegate
            app.run()
        }
    }
}

@MainActor
final class QuotaStore {
    private var fetched: [ProviderSnapshot] = []
    private var manual: [String: Date] = BillingStore.load()
    private var accounts = AccountStore.load()
    var snapshots: [ProviderSnapshot] = []
    var hidden: [ProviderSnapshot] = []
    var isRefreshing = false
    var lastUpdated: Date?
    var onChange: (() -> Void)?

    func start() {
        Task { await loop() }
    }

    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        publish()
        let baseline = fetched
        let fresh = await QuotaService.fetchAll(
            force: userInitiated,
            onUpdate: { @MainActor snapshot in
                self.integrate(snapshot, baseline: baseline)
            },
            onCodex: { @MainActor snapshots in
                self.integrateCodex(snapshots, baseline: baseline)
            }
        )
        fetched = mergeSnapshots(previous: baseline, fresh: fresh)
        lastUpdated = Date()
        isRefreshing = false
        overlay()
        publish()
    }

    private func integrate(_ snapshot: ProviderSnapshot, baseline: [ProviderSnapshot]) {
        var next = fetched
        if let index = next.firstIndex(where: { $0.id == snapshot.id }) {
            next[index] = snapshot
        } else {
            next.append(snapshot)
        }
        fetched = mergeSnapshots(previous: baseline, fresh: next)
        overlay()
        publish()
    }

    private func integrateCodex(_ snapshots: [ProviderSnapshot], baseline: [ProviderSnapshot]) {
        let kept = fetched.filter { $0.id != "codex" && !$0.id.hasPrefix("codex-") }
        fetched = mergeSnapshots(previous: baseline, fresh: kept + snapshots)
        overlay()
        publish()
    }

    func setManualBilling(key: String, day: Date) -> Bool {
        var next = manual
        next[key] = Calendar.current.startOfDay(for: day)
        guard write(next) else { return false }
        manual = next
        overlay()
        publish()
        return true
    }

    func clearManualBilling(key: String) -> Bool {
        var next = manual
        next.removeValue(forKey: key)
        guard write(next) else { return false }
        manual = next
        overlay()
        publish()
        return true
    }

    func setAccountName(key: String, name: String) -> Bool {
        guard let name = AccountDirectory.normalize(name) else { return false }
        var next = accounts
        next.names[key] = name
        guard write(next) else { return false }
        accounts = next
        overlay()
        publish()
        return true
    }

    func clearAccountName(key: String) -> Bool {
        var next = accounts
        next.names.removeValue(forKey: key)
        guard write(next) else { return false }
        accounts = next
        overlay()
        publish()
        return true
    }

    func hideAccount(key: String) -> Bool {
        var next = accounts
        next.hidden.insert(key)
        guard write(next) else { return false }
        accounts = next
        overlay()
        publish()
        return true
    }

    func restoreAccount(key: String) -> Bool {
        var next = accounts
        next.hidden.remove(key)
        guard write(next) else { return false }
        accounts = next
        overlay()
        publish()
        return true
    }

    var sort: BoardSort { accounts.sort }

    func setSort(_ sort: BoardSort) -> Bool {
        var next = accounts
        next.sort = sort
        guard write(next) else { return false }
        accounts = next
        overlay()
        publish()
        return true
    }

    private func write(_ entries: [String: Date]) -> Bool {
        (try? BillingStore.save(entries)) != nil
    }

    private func write(_ directory: AccountDirectory) -> Bool {
        (try? AccountStore.save(directory)) != nil
    }

    private func overlay() {
        let listed = accounts.apply(fetched)
        snapshots = BillingOverrides.apply(listed.visible, manual: manual)
        hidden = listed.hidden
    }

    private func loop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    private func publish() {
        onChange?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = QuotaStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var panel: PanelController?
    private var session: BoardSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.setAccessibilityLabel("Quota Board")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let session = BoardSession(store: store)
        self.session = session
        let panel = PanelController(session: session)
        self.panel = panel
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panel
        popover.delegate = self
        self.popover = popover

        session.onChrome = { [weak self] _ in
            self?.panel?.applyChrome()
        }
        session.onHeight = { [weak self] height in
            let size = NSSize(width: 360, height: height)
            self?.panel?.preferredContentSize = size
            self?.popover?.contentSize = size
        }

        store.onChange = { [weak self] in
            self?.renderTitle()
            self?.session?.syncFromStore()
        }
        store.start()
        renderTitle()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        session?.panelClosed()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        session?.panelOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    private func renderTitle() {
        let spoken = MenuTitle.text(for: store.snapshots)
        statusItem?.button?.attributedTitle = MenuBarTitle.attributed(
            store.snapshots,
            appearance: statusItem?.button?.effectiveAppearance
        )
        statusItem?.button?.setAccessibilityLabel("Quota Board \(spoken)")
    }
}
