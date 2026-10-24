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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.setAccessibilityLabel("Quota Board")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let panel = PanelController(store: store)
        self.panel = panel
        let popover = NSPopover()
        panel.popover = popover
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panel
        popover.delegate = self
        self.popover = popover

        store.onChange = { [weak self] in
            self?.renderTitle()
            self?.panel?.reload()
        }
        store.start()
        renderTitle()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        panel?.reload()
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

@MainActor
final class PanelController: NSViewController {
    private let store: QuotaStore
    weak var popover: NSPopover?
    private let root = NSStackView()
    private let cards = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeightConstraint: NSLayoutConstraint?
    private var headerRow: NSView?
    private var topSeparator: NSView?
    private var bottomSeparator: NSView?
    private var footerRow: NSView?
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updatedLabel = NSTextField(labelWithString: "等待第一次读取")
    private let refreshButton = NSButton()
    private var editingKey: String?
    private var draftDate = Date()
    private var editError: String?
    private weak var draftPicker: NSDatePicker?
    private var namingKey: String?
    private var draftName = ""
    private var nameError: String?
    private weak var draftField: NSTextField?
    private var accountErrorKey: String?
    private var accountError: String?
    private var hasRendered = false
    private var renderedSnapshots: [ProviderSnapshot] = []
    private var renderedHidden: [ProviderSnapshot] = []
    private var renderedEditing: String?
    private var renderedNaming: String?
    private var renderedEditError: String?
    private var renderedNameError: String?
    private var renderedAccountErrorKey: String?
    private var renderedAccountError: String?

    init(store: QuotaStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        view = background

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)

        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 6
        cards.setContentHuggingPriority(.required, for: .vertical)
        cards.setContentCompressionResistancePriority(.required, for: .vertical)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = cards
        cards.translatesAutoresizingMaskIntoConstraints = false
        let scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 120)
        scrollHeight.isActive = true
        scrollHeightConstraint = scrollHeight
        NSLayoutConstraint.activate([
            cards.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            cards.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            cards.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .secondaryLabelColor

        refreshButton.bezelStyle = .texturedRounded
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "刷新"

        sortButton.isBordered = false
        sortButton.controlSize = .small
        sortButton.font = .systemFont(ofSize: 11)
        sortButton.contentTintColor = .secondaryLabelColor
        sortButton.addItems(withTitles: ["按到期", "按名称"])
        sortButton.target = self
        sortButton.action = #selector(changeSort(_:))
        sortButton.setContentHuggingPriority(.required, for: .horizontal)

        let quit = NSButton(title: "退出", target: self, action: #selector(quit))
        quit.bezelStyle = .texturedRounded
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 11)
        quit.contentTintColor = .secondaryLabelColor

        let footer = NSStackView(views: [updatedLabel, NSView(), quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footerRow = footer

        let header = header()
        headerRow = header
        let topRule = separator()
        topSeparator = topRule
        let bottomRule = separator()
        bottomSeparator = bottomRule

        root.addArrangedSubview(header)
        root.addArrangedSubview(topRule)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(bottomRule)
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: 336),
            footer.widthAnchor.constraint(equalToConstant: 336),
        ])
        reload()
    }

    func reload() {
        commitBillingDraft()
        if let draftField {
            draftName = draftField.stringValue
        }
        updatedLabel.stringValue = store.lastUpdated.map { Format.updated($0) } ?? "等待第一次读取"
        refreshButton.isEnabled = !store.isRefreshing
        let sortIndex = store.sort == .name ? 1 : 0
        if sortButton.indexOfSelectedItem != sortIndex {
            sortButton.selectItem(at: sortIndex)
        }
        let unchanged = hasRendered
            && store.snapshots == renderedSnapshots
            && store.hidden == renderedHidden
            && editingKey == renderedEditing
            && namingKey == renderedNaming
            && editError == renderedEditError
            && nameError == renderedNameError
            && accountErrorKey == renderedAccountErrorKey
            && accountError == renderedAccountError
        if !unchanged {
            for view in cards.arrangedSubviews {
                cards.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if store.snapshots.isEmpty && store.hidden.isEmpty {
                cards.addArrangedSubview(text(
                    store.isRefreshing ? "正在读取本机登录…" : "还没有额度数据",
                    size: 13,
                    color: .secondaryLabelColor
                ))
            } else {
                for snapshot in store.snapshots {
                    cards.addArrangedSubview(card(snapshot))
                }
                if !store.hidden.isEmpty {
                    cards.addArrangedSubview(hiddenSection())
                }
            }
            renderedSnapshots = store.snapshots
            renderedHidden = store.hidden
            renderedEditing = editingKey
            renderedNaming = namingKey
            renderedEditError = editError
            renderedNameError = nameError
            renderedAccountErrorKey = accountErrorKey
            renderedAccountError = accountError
            hasRendered = true
        }
        fitPopover()
        if !unchanged, namingKey != nil, let draftField {
            DispatchQueue.main.async { [weak self] in
                self?.view.window?.makeFirstResponder(draftField)
            }
        }
    }

    private func commitBillingDraft() {
        guard let draftPicker else { return }
        // The Save button does not resign the field editor, so the typed day is still in the editor.
        draftPicker.validateEditing()
        if let editor = draftPicker.currentEditor() {
            draftPicker.endEditing(editor)
        }
        draftDate = draftPicker.dateValue
    }

    private func fitPopover() {
        let screenHeight = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maximumHeight = screenHeight - 48
        view.layoutSubtreeIfNeeded()
        let insets = root.edgeInsets.top + root.edgeInsets.bottom
        let chrome = chromeHeight()
        var contentHeight = cardsContentHeight()
        if contentHeight <= 1 {
            contentHeight = max(0, fallbackHeight() - chrome - insets)
        }
        let scroll = min(contentHeight, max(120, maximumHeight - chrome - insets))
        var preferred = chrome + scroll + insets
        if preferred < 140 { preferred = 140 }
        if preferred > maximumHeight { preferred = maximumHeight }
        scrollHeightConstraint?.constant = max(0, preferred - chrome - insets)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 360, height: preferred)
    }

    private func cardsContentHeight() -> CGFloat {
        let fitted = cards.fittingSize.height
        let intrinsic = cards.intrinsicContentSize.height
        if intrinsic > 1 {
            return max(fitted, intrinsic)
        }
        return fitted
    }

    private func chromeHeight() -> CGFloat {
        let measured = [headerRow, topSeparator, bottomSeparator, footerRow].reduce(CGFloat(0)) { sum, part in
            sum + (part?.fittingSize.height ?? 0)
        }
        if measured <= 1 { return 88 }
        return measured + root.spacing * 4
    }

    private func fallbackHeight() -> CGFloat {
        let windowRows = store.snapshots.reduce(0) { $0 + max($1.windows.count, $1.error == nil ? 0 : 1) }
        let estimated = CGFloat(84 + store.snapshots.count * 86 + store.hidden.count * 22 + windowRows * 18)
        let screenHeight = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return min(screenHeight - 48, max(160, estimated))
    }

    @objc private func refresh() {
        Task { await store.refresh(userInitiated: true) }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func header() -> NSView {
        let title = text("Quota Board", size: 13, weight: .semibold, color: .labelColor)
        let subtitle = text("剩余额度", size: 11, color: .secondaryLabelColor)
        let row = NSStackView(views: [logo(.board, side: 16), title, subtitle, NSView(), sortButton, refreshButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.widthAnchor.constraint(equalToConstant: 336).isActive = true
        return row
    }

    private func card(_ snapshot: ProviderSnapshot) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 336).isActive = true

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])

        let name = text(snapshot.name, size: 13, weight: .semibold, color: .labelColor)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var titleViews: [NSView] = [markView(snapshot), name]
        if let plan = snapshot.plan {
            titleViews.append(badge(plan))
        }
        titleViews.append(menuButton(snapshot))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        titleViews.append(spacer)
        if let tightest = snapshot.tightest {
            let value = text(Format.percent(tightest.remainingPercent), size: 16, weight: .semibold, color: tone(tightest.usedPercent))
            value.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            value.setContentHuggingPriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleViews.append(value)
        }
        let headline = NSStackView(views: titleViews)
        headline.orientation = .horizontal
        headline.alignment = .centerY
        headline.spacing = 6
        headline.widthAnchor.constraint(equalToConstant: 320).isActive = true
        column.addArrangedSubview(headline)
        column.addArrangedSubview(billingRow(snapshot))
        if namingKey == snapshot.billingIdentity {
            column.addArrangedSubview(nameEditor(snapshot))
        } else if accountErrorKey == snapshot.billingIdentity, let accountError {
            column.addArrangedSubview(text(accountError, size: 10, color: .systemRed))
        }

        if snapshot.windows.isEmpty, let error = snapshot.error {
            column.addArrangedSubview(wrapping(error, color: .secondaryLabelColor))
        } else {
            let showsPercent = snapshot.windows.count > 1
            for window in snapshot.windows {
                column.addArrangedSubview(windowRow(window, showsPercent: showsPercent))
            }
            if let note = snapshot.note {
                column.addArrangedSubview(text(note, size: 11, color: .secondaryLabelColor))
            }
            if snapshot.isStale, let error = snapshot.error {
                column.addArrangedSubview(wrapping("沿用上次读数 · \(error)", color: .systemOrange))
            }
        }
        return box
    }

    private func markView(_ snapshot: ProviderSnapshot) -> NSView {
        if let kind = Mark.kind(for: snapshot) {
            return logo(kind, side: 16)
        }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = tone(snapshot.tightest?.usedPercent).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return dot
    }

    private func logo(_ kind: Mark.Kind, side: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = Mark.icon(kind, side: side, appearance: NSApp.effectiveAppearance)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: side),
            view.heightAnchor.constraint(equalToConstant: side),
        ])
        return view
    }

    private func billingRow(_ snapshot: ProviderSnapshot) -> NSView {
        if editingKey == snapshot.billingIdentity {
            return billingEditor(snapshot)
        }
        let face = Format.billingFace(snapshot.billing)
        let caption = text("账单日", size: 11, color: .tertiaryLabelColor)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        let value = text(face.text, size: 11, color: snapshot.billing == nil ? .tertiaryLabelColor : .secondaryLabelColor)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [caption, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func menuButton(_ snapshot: ProviderSnapshot) -> NSButton {
        let button = KeyButton()
        button.key = snapshot.billingIdentity
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.target = self
        button.action = #selector(showCardMenu(_:))
        button.toolTip = "更多"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc private func showCardMenu(_ sender: KeyButton) {
        let key = sender.key
        let snapshot = (store.snapshots + store.hidden).first { $0.billingIdentity == key }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = key
            return item
        }
        menu.addItem(item(snapshot?.billing == nil ? "设置账单日" : "修改账单日", #selector(beginBillingEdit(_:))))
        if let snapshot, Mark.kind(for: snapshot) == .codex {
            menu.addItem(item("改名", #selector(beginNameEdit(_:))))
            if snapshot.nameIsManual {
                menu.addItem(item("清除名称", #selector(clearName(_:))))
            }
            menu.addItem(.separator())
            menu.addItem(item("移除", #selector(hideAccount(_:))))
        }
        let previous = popover?.behavior
        popover?.behavior = .applicationDefined
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        popover?.behavior = previous ?? .transient
    }

    @objc private func changeSort(_ sender: NSPopUpButton) {
        let sort: BoardSort = sender.indexOfSelectedItem == 1 ? .name : .expiry
        if !store.setSort(sort) {
            sender.selectItem(at: store.sort == .name ? 1 : 0)
        }
    }

    private func senderKey(_ sender: NSObject) -> String? {
        if let button = sender as? KeyButton { return button.key }
        if let item = sender as? NSMenuItem { return item.representedObject as? String }
        return nil
    }

    private func billingEditor(_ snapshot: ProviderSnapshot) -> NSView {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .yearMonthDay
        picker.font = .systemFont(ofSize: 11)
        picker.dateValue = draftDate
        picker.target = self
        picker.action = #selector(billingDraftChanged(_:))
        draftPicker = picker

        var views: [NSView] = [
            picker,
            keyedButton("保存", #selector(saveBilling(_:)), snapshot.billingIdentity),
        ]
        if snapshot.billing?.manual == true {
            views.append(keyedButton("清除", #selector(clearBilling(_:)), snapshot.billingIdentity))
        }
        views.append(keyedButton("取消", #selector(cancelBilling(_:)), snapshot.billingIdentity))
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.addArrangedSubview(row)
        if let editError {
            column.addArrangedSubview(text(editError, size: 10, color: .systemRed))
        }
        return column
    }

    @objc private func beginBillingEdit(_ sender: NSObject) {
        guard let key = senderKey(sender) else { return }
        editingKey = key
        namingKey = nil
        editError = nil
        draftPicker = nil
        if let billing = store.snapshots.first(where: { $0.billingIdentity == key })?.billing {
            draftDate = BillingCalendar.next(anchor: billing.at, renews: billing.renews)
        } else {
            draftDate = Date()
        }
        reload()
    }

    @objc private func billingDraftChanged(_ sender: NSDatePicker) {
        draftDate = sender.dateValue
    }

    @objc private func saveBilling(_ sender: KeyButton) {
        commitBillingDraft()
        if store.setManualBilling(key: sender.key, day: draftDate) {
            editingKey = nil
            editError = nil
        } else {
            editError = "账单日没有写入"
        }
        reload()
    }

    @objc private func clearBilling(_ sender: KeyButton) {
        if store.clearManualBilling(key: sender.key) {
            editingKey = nil
            editError = nil
        } else {
            editError = "账单日没有写入"
        }
        reload()
    }

    @objc private func cancelBilling(_ sender: KeyButton) {
        _ = sender
        editingKey = nil
        editError = nil
        reload()
    }

    private func nameEditor(_ snapshot: ProviderSnapshot) -> NSView {
        let field = NSTextField(string: draftName)
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "账号名称"
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.target = self
        field.action = #selector(nameDraftChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        draftField = field

        var views: [NSView] = [
            field,
            keyedButton("保存", #selector(saveName(_:)), snapshot.billingIdentity),
        ]
        if snapshot.nameIsManual {
            views.append(keyedButton("清除", #selector(clearName(_:)), snapshot.billingIdentity))
        }
        views.append(keyedButton("取消", #selector(cancelName(_:)), snapshot.billingIdentity))
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.addArrangedSubview(row)
        if let nameError {
            column.addArrangedSubview(text(nameError, size: 10, color: .systemRed))
        }
        return column
    }

    private func hiddenSection() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.addArrangedSubview(text("已隐藏", size: 11, color: .secondaryLabelColor))
        for snapshot in store.hidden {
            let name = text(snapshot.name, size: 12, color: .secondaryLabelColor)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [
                name,
                NSView(),
                keyedButton("恢复", #selector(restoreAccount(_:)), snapshot.billingIdentity),
            ])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.widthAnchor.constraint(equalToConstant: 320).isActive = true
            column.addArrangedSubview(row)
        }
        if accountErrorKey == "hidden", let accountError {
            column.addArrangedSubview(text(accountError, size: 10, color: .systemRed))
        }
        return column
    }

    @objc private func beginNameEdit(_ sender: NSObject) {
        guard let key = senderKey(sender) else { return }
        namingKey = key
        editingKey = nil
        nameError = nil
        accountError = nil
        accountErrorKey = nil
        draftName = store.snapshots.first { $0.billingIdentity == key }?.name ?? ""
        reload()
    }

    @objc private func nameDraftChanged(_ sender: NSTextField) {
        draftName = sender.stringValue
    }

    @objc private func saveName(_ sender: KeyButton) {
        let raw = (draftField?.stringValue ?? draftName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            nameError = "名称不能为空"
            reload()
            return
        }
        guard raw.count <= AccountDirectory.nameLimit else {
            nameError = "名称太长"
            reload()
            return
        }
        if store.setAccountName(key: sender.key, name: raw) {
            namingKey = nil
            nameError = nil
        } else {
            nameError = "名称没有写入"
        }
        reload()
    }

    @objc private func clearName(_ sender: NSObject) {
        guard let key = senderKey(sender) else { return }
        if store.clearAccountName(key: key) {
            namingKey = nil
            nameError = nil
        } else {
            nameError = "名称没有写入"
        }
        reload()
    }

    @objc private func cancelName(_ sender: KeyButton) {
        _ = sender
        namingKey = nil
        nameError = nil
        reload()
    }

    @objc private func hideAccount(_ sender: NSObject) {
        guard let key = senderKey(sender) else { return }
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
        reload()
    }

    @objc private func restoreAccount(_ sender: KeyButton) {
        if store.restoreAccount(key: sender.key) {
            accountError = nil
            accountErrorKey = nil
        } else {
            accountErrorKey = "hidden"
            accountError = "账号没有写入"
        }
        reload()
    }

    private func keyedButton(_ title: String, _ action: Selector, _ key: String) -> KeyButton {
        let button = KeyButton()
        button.key = key
        button.title = title
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func windowRow(_ window: QuotaWindow, showsPercent: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let label = text(window.label, size: 11, color: .secondaryLabelColor)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let meter = MeterView(usedPercent: window.usedPercent)
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.heightAnchor.constraint(equalToConstant: 4).isActive = true
        meter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        meter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(label)
        row.addArrangedSubview(meter)
        if showsPercent {
            let percent = text(Format.percent(window.remainingPercent), size: 11, weight: .medium, color: tone(window.usedPercent))
            percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            percent.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(percent)
        }
        if let resetsAt = window.resetsAt {
            let reset = text(Format.shortReset(resetsAt), size: 10, color: .tertiaryLabelColor)
            reset.setContentHuggingPriority(.required, for: .horizontal)
            reset.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(reset)
        }
        return row
    }

    private func badge(_ title: String) -> NSView {
        let label = text(title, size: 10, weight: .medium, color: .secondaryLabelColor)
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        wrap.layer?.cornerRadius = 7
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
        ])
        return wrap
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 336).isActive = true
        return box
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func wrapping(_ value: String, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: 11)
        field.textColor = color
        field.preferredMaxLayoutWidth = 320
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return field
    }

    private func tone(_ used: Double?) -> NSColor {
        guard let used else { return .secondaryLabelColor }
        if used >= 90 { return NSColor(calibratedRed: 0.84, green: 0.23, blue: 0.20, alpha: 1) }
        if used >= 70 { return NSColor(calibratedRed: 0.84, green: 0.52, blue: 0.10, alpha: 1) }
        return NSColor(calibratedRed: 0.16, green: 0.60, blue: 0.36, alpha: 1)
    }
}

private final class KeyButton: NSButton {
    var key = ""
}

final class MeterView: NSView {
    var usedPercent: Double {
        didSet { needsDisplay = true }
    }

    init(usedPercent: Double) {
        self.usedPercent = usedPercent
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let fraction = CGFloat(min(max(usedPercent, 0), 100) / 100)
        guard fraction > 0 else { return }
        var fill = bounds
        fill.size.width = max(6, bounds.width * fraction)
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }

    private var fillColor: NSColor {
        if usedPercent >= 90 { return NSColor(calibratedRed: 0.84, green: 0.23, blue: 0.20, alpha: 1) }
        if usedPercent >= 70 { return NSColor(calibratedRed: 0.84, green: 0.52, blue: 0.10, alpha: 1) }
        return NSColor(calibratedRed: 0.16, green: 0.60, blue: 0.36, alpha: 1)
    }
}
