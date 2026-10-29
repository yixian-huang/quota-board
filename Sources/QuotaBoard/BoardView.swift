import AppKit
import SwiftUI

private struct AnchorMapKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct Measures: Equatable {
    var bus: CGFloat = 0
    var body: CGFloat = 0
}

private struct MeasureKey: PreferenceKey {
    static let defaultValue = Measures()
    static func reduce(value: inout Measures, nextValue: () -> Measures) {
        let next = nextValue()
        if next.bus > 0 { value.bus = next.bus }
        if next.body > 0 { value.body = next.body }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct BoardView: View {
    @ObservedObject var session: BoardSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights = Measures()

    private var palette: BoardPalette { BoardPalette.make(dark: colorScheme == .dark) }

    private var busTotal: BusTotal? {
        guard session.page == .quota else { return nil }
        return WorthMath.bus(session.snapshots) { session.price(for: $0) }
    }

    private var scrollLimit: CGFloat {
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return max(72, screen - 48 - 108 - heights.bus)
    }

    private var scrollHeight: CGFloat {
        let body = heights.body
        if body < 1 { return min(72, scrollLimit) }
        return min(body, scrollLimit)
    }

    private var panelHeight: CGFloat {
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return min(screen - 48, max(140, 108 + heights.bus + scrollHeight))
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            toolbar
            screen
            footer
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
        .frame(width: 360, height: panelHeight)
        .background { plate }
        .coordinateSpace(name: "board")
        .overlayPreferenceValue(AnchorMapKey.self) { anchors in
            GeometryReader { proxy in
                floatLayer(anchors: anchors, proxy: proxy)
            }
            .allowsHitTesting(session.float != nil)
        }
        .environment(\.boardPalette, palette)
        .onPreferenceChange(MeasureKey.self) { heights = $0 }
        .onPreferenceChange(ScrollOffsetKey.self) { session.noteScroll($0) }
        .onChange(of: panelHeight) { _, height in session.reportHeight(height) }
        .onAppear { session.reportHeight(panelHeight) }
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(
                stops: [
                    .init(color: palette.plateTop, location: 0),
                    .init(color: palette.plate, location: 0.4),
                    .init(color: palette.plateBottom, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(alignment: .top) {
                palette.bevel.frame(height: 1).padding(.horizontal, 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.plateEdge, lineWidth: 1)
            }
    }

    private var header: some View {
        HStack(spacing: 7) {
            MarkView(kind: .board, side: 16, onScreen: false)
            Text("Quota Board")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.plateInk)
            Spacer(minLength: 8)
            KeyCap(look: session.theme, help: "外观：\(session.theme.title)", role: .icon, down: session.float == .look) {
                session.toggleLook()
            }
            .anchorPreference(key: AnchorMapKey.self, value: .bounds) { ["look": $0] }
            KeyCap(
                icon: .refresh,
                help: "刷新",
                role: .icon,
                locked: session.refreshing,
                spinning: session.refreshing && !reduceMotion
            ) {
                session.refresh()
            }
        }
        .frame(height: 22)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                KeyCap(title: "剩余额度", role: .segment(session.page == .quota)) { session.setPage(.quota) }
                KeyCap(title: "重置预告", badge: session.upcomingNotices, role: .segment(session.page == .resets)) {
                    session.setPage(.resets)
                }
            }
            .padding(2)
            .background(palette.slot, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onMoveCommand { direction in
                guard direction == .left || direction == .right else { return }
                session.setPage(session.page == .quota ? .resets : .quota)
            }
            Spacer(minLength: 8)
            if session.page == .quota {
                HStack(spacing: 2) {
                    KeyCap(icon: .list, help: "列表视图", role: .segment(session.viewMode == .list)) {
                        session.setView(.list)
                    }
                    KeyCap(icon: .chart, help: "图表视图", role: .segment(session.viewMode == .chart)) {
                        session.setView(.chart)
                    }
                }
                .padding(2)
                .background(palette.slot, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                KeyCap(
                    title: session.sort == .name ? "按名称" : "按到期",
                    icon: .chevron,
                    help: "排序",
                    role: .plate,
                    down: session.float == .sort
                ) {
                    session.toggleSort()
                }
                .anchorPreference(key: AnchorMapKey.self, value: .bounds) { ["sort": $0] }
            }
        }
        .frame(height: 24)
    }

    private var screen: some View {
        VStack(spacing: 0) {
            if let busTotal {
                BusHeader(total: busTotal)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: MeasureKey.self, value: Measures(bus: proxy.size.height))
                    })
            }
            ScrollView {
                screenBody
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: MeasureKey.self, value: Measures(body: proxy.size.height))
                    })
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: proxy.frame(in: .named("board")).minY
                        )
                    })
            }
            .frame(height: scrollHeight)
        }
        .background { screenFill }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            palette.lip.frame(height: 1).offset(y: 1)
        }
        .environment(\.boardPalette, palette.screened())
        .environment(\.colorScheme, .dark)
    }

    private var screenFill: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [palette.screenTop, palette.screen], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(palette.dark ? 0.75 : 0.55), lineWidth: 1)
            }
    }

    @ViewBuilder private var screenBody: some View {
        if session.page == .resets {
            ResetsPlaceholder()
        } else if session.snapshots.isEmpty && session.hidden.isEmpty {
            EmptyPane(
                text: session.refreshing ? "正在读取本机登录…" : "还没有额度数据",
                scanning: session.refreshing && !reduceMotion
            )
        } else if session.viewMode == .chart {
            ChartBody(session: session)
        } else {
            ListBody(session: session)
        }
    }

    private var footer: some View {
        let date = session.page == .quota ? session.lastUpdated : session.feed.updated
        return HStack(spacing: 8) {
            Text(date.map { Format.updated($0) } ?? "等待第一次读取")
                .font(.system(size: 11))
                .foregroundStyle(palette.plateInk3)
                .monospacedDigit()
            Spacer(minLength: 8)
            KeyCap(title: "退出", role: .plate) { session.quit() }
        }
        .frame(height: 20)
    }

    @ViewBuilder private func floatLayer(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            if session.float != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { session.closeFloats() }
            }
            if let tip = session.tip, let anchor = anchors["tip-\(tip.id)"] {
                TipCard(tip: tip)
                    .offset(tipOffset(proxy[anchor], in: proxy.size))
                    .allowsHitTesting(false)
            }
            if let float = session.float {
                menu(float, anchors: anchors, proxy: proxy)
            }
        }
    }

    @ViewBuilder private func menu(_ float: BoardFloat, anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        let rows = menuRows(float)
        let anchorID: String = switch float {
        case .look: "look"
        case .sort: "sort"
        case .card(let key): "card-\(key)"
        }
        if let anchor = anchors[anchorID] {
            let origin = menuOrigin(float, rect: proxy[anchor], rows: rows, in: proxy.size)
            MenuList(onScreen: menuOnScreen(float), rows: rows)
                .offset(x: origin.x, y: origin.y)
        }
    }

    private func menuOnScreen(_ float: BoardFloat) -> Bool {
        if case .card = float { return true }
        return false
    }

    private func menuOrigin(_ float: BoardFloat, rect: CGRect, rows: [MenuRow], in size: CGSize) -> CGPoint {
        let height = menuHeight(rows)
        let width: CGFloat = 168
        let alignRight: Bool = if case .card = float { false } else { true }
        var x = alignRight ? rect.maxX - width : rect.minX
        var y = rect.maxY + 4
        if y + height > size.height - 8 { y = max(8, rect.minY - height - 4) }
        x = min(max(8, x), max(8, size.width - width - 8))
        return CGPoint(x: x, y: y)
    }

    private func menuRows(_ float: BoardFloat) -> [MenuRow] {
        switch float {
        case .look:
            return PanelTheme.allCases.map { theme in
                MenuRow(id: theme.rawValue, title: theme.title, checked: session.theme == theme) {
                    session.pickTheme(theme)
                }
            }
        case .sort:
            return [
                MenuRow(id: "expiry", title: "按到期", checked: session.sort == .expiry) { session.pickSort(.expiry) },
                MenuRow(id: "name", title: "按名称", checked: session.sort == .name) { session.pickSort(.name) },
            ]
        case .card(let key):
            guard let snapshot = session.snapshots.first(where: { $0.billingIdentity == key }) else { return [] }
            return cardRows(snapshot)
        }
    }

    private func cardRows(_ snapshot: ProviderSnapshot) -> [MenuRow] {
        let key = snapshot.billingIdentity
        var rows = [
            MenuRow(id: "billing", title: snapshot.billing == nil ? "设置账单日" : "修改账单日") {
                session.beginBilling(key)
            },
        ]
        if Mark.kind(for: snapshot) == .codex {
            rows.append(MenuRow(id: "rename", title: "改名") { session.beginName(key) })
            if snapshot.nameIsManual {
                rows.append(MenuRow(id: "clear-name", title: "清除名称") { session.clearName(key) })
            }
            rows.append(MenuRow(id: "sep", title: "", separator: true) {})
            rows.append(MenuRow(id: "hide", title: "移除") { session.hide(key) })
        }
        return rows
    }

    private func menuHeight(_ rows: [MenuRow]) -> CGFloat {
        let items = rows.filter { !$0.separator }.count
        let separators = rows.filter(\.separator).count
        return CGFloat(items) * 22 + CGFloat(separators) * 10 + 8
    }

    private func tipOffset(_ rect: CGRect, in size: CGSize) -> CGSize {
        let width: CGFloat = min(280, size.width - 16)
        var x = rect.midX - width / 2
        x = min(max(8, x), max(8, size.width - width - 8))
        let above = rect.minY > 78
        let y = above ? rect.minY - 70 : rect.maxY + 6
        return CGSize(width: x, height: y)
    }
}

extension PanelTheme: CaseIterable {
    static var allCases: [PanelTheme] { [.system, .light, .dark] }
}

private struct BusHeader: View {
    @Environment(\.boardPalette) private var palette
    var total: BusTotal

    var body: some View {
        let tone = MeterTone.from(usedPercent: total.usedPercent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("剩余价值")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(palette.ink3)
                    Text(BoardFormat.money(total.left, currency: total.currency))
                        .font(.system(size: 30, weight: .medium, design: .monospaced))
                        .tracking(-0.6)
                        .foregroundStyle(palette.tone(tone))
                        .shadow(color: palette.glow(tone), radius: 7)
                        .lineLimit(1)
                }
                VStack(alignment: .trailing, spacing: 3) {
                    Text("共 \(BoardFormat.money(total.total, currency: total.currency)) 每月")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink2)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    MeterBar(remaining: total.ratio * 100, tone: tone, thickness: 10)
                    HStack {
                        ForEach(["0", "25", "50", "75", "100"], id: \.self) { tick in
                            Text(tick)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(palette.ink3)
                                .frame(maxWidth: .infinity, alignment: tick == "0" ? .leading : (tick == "100" ? .trailing : .center))
                        }
                    }
                }
            }
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Groove(dark: palette.sGroove, light: palette.sGrooveHi)
        }
    }

    private var note: String {
        var text = "按月费 × 最紧一档的剩余比例估算"
        if total.excluded > 0 {
            text += " · 不含没有月费或读不到的 \(total.excluded) 个账号"
        }
        return text
    }
}

private struct ListBody: View {
    @ObservedObject var session: BoardSession
    @Environment(\.boardPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(session.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 {
                    Groove(dark: palette.sGroove, light: palette.sGrooveHi)
                }
                AccountCard(session: session, snapshot: snapshot)
                    .padding(.top, index == 0 ? 10 : 14)
                    .padding(.bottom, lastCard(index) ? 10 : 14)
            }
            if !session.hidden.isEmpty {
                if !session.snapshots.isEmpty {
                    Groove(dark: palette.sGroove, light: palette.sGrooveHi)
                }
                hiddenBlock
                    .padding(.top, session.snapshots.isEmpty ? 10 : 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 10)
    }

    private func lastCard(_ index: Int) -> Bool {
        index == session.snapshots.count - 1 && session.hidden.isEmpty
    }

    private var hiddenBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已隐藏")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.ink3)
            ForEach(session.hidden) { snapshot in
                HStack(spacing: 6) {
                    Text(snapshot.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    KeyCap(title: "恢复", role: .soft) { session.restore(snapshot.billingIdentity) }
                }
            }
            if session.accountErrorKey == "hidden", let accountError = session.accountError {
                SignalRow(kind: .error, text: accountError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountCard: View {
    @ObservedObject var session: BoardSession
    var snapshot: ProviderSnapshot
    @Environment(\.boardPalette) private var palette

    private var key: String { snapshot.billingIdentity }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline
            if session.namingKey == key {
                NameEditor(session: session, key: key)
            } else if session.accountErrorKey == key, let accountError = session.accountError {
                SignalRow(kind: .error, text: accountError)
            }
            if snapshot.windows.isEmpty, let error = snapshot.error {
                SignalRow(kind: .fault, text: error)
            } else {
                if !snapshot.windows.isEmpty {
                    DialView(windows: snapshot.windows)
                }
                if let note = snapshot.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.isStale, let error = snapshot.error {
                    SignalRow(kind: .stale, text: "沿用上次读数 · \(error)")
                }
            }
            if session.editingKey == key {
                BillingEditor(session: session, snapshot: snapshot)
            } else {
                billingRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: some View {
        HStack(spacing: 6) {
            MarkView(kind: Mark.kind(for: snapshot), tone: nil, side: 16)
            Text(snapshot.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            if let plan = snapshot.plan {
                Text(plan)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }
            KeyCap(more: true, help: "更多", role: .flat, down: session.float == .card(key)) {
                session.toggleCardMenu(key)
            }
            .anchorPreference(key: AnchorMapKey.self, value: .bounds) { ["card-\(key)": $0] }
            Spacer(minLength: 8)
            if let tightest = snapshot.tightest {
                Readout(
                    text: Format.percent(tightest.remainingPercent),
                    tone: MeterTone.from(usedPercent: tightest.usedPercent)
                )
            }
        }
        .frame(height: 24)
    }

    private var billingRow: some View {
        let face = Format.billingFace(snapshot.billing)
        let worth = WorthMath.worth(snapshot, price: session.price(for: snapshot))
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("账单日")
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
            Text(face.text)
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
                .monospacedDigit()
            Spacer(minLength: 8)
            if let worth {
                HStack(spacing: 0) {
                    Text(BoardFormat.money(worth.left, currency: worth.currency))
                        .foregroundStyle(palette.ink2)
                    Text(" / \(BoardFormat.money(worth.total, currency: worth.currency))")
                        .foregroundStyle(palette.ink3)
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(.top, 2)
    }
}

private struct DialView: View {
    @Environment(\.boardPalette) private var palette
    var windows: [QuotaWindow]

    private var showsPercent: Bool { windows.count > 1 }
    private var spans: [ResetSpan] {
        ResetLayout.spans(windows) { Format.shortReset($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    Text(window.label)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                        .frame(height: 14, alignment: .leading)
                }
            }
            .frame(width: 66, alignment: .leading)
            VStack(spacing: 9) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    MeterBar(
                        remaining: window.remainingPercent,
                        tone: MeterTone.from(usedPercent: window.usedPercent)
                    )
                    .frame(height: 14)
                }
            }
            .frame(maxWidth: .infinity)
            if showsPercent {
                VStack(alignment: .trailing, spacing: 9) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        Text(Format.percent(window.remainingPercent))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.tone(MeterTone.from(usedPercent: window.usedPercent)))
                            .shadow(color: palette.glow(MeterTone.from(usedPercent: window.usedPercent)), radius: 3)
                            .frame(height: 14, alignment: .trailing)
                    }
                }
                .frame(width: 30, alignment: .trailing)
            }
            VStack(spacing: 9) {
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    resetCell(span)
                        .frame(height: CGFloat(span.rows) * 14 + CGFloat(max(span.rows - 1, 0)) * 9)
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func resetCell(_ span: ResetSpan) -> some View {
        HStack(spacing: 3) {
            if span.rows > 1 {
                BracketMark()
                    .stroke(palette.sLine, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .frame(width: 6)
            }
            Text(span.text)
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

private struct NameEditor: View {
    @ObservedObject var session: BoardSession
    var key: String
    @FocusState private var focused: Bool
    @Environment(\.boardPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("账号名称", text: $session.draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink)
                    .focused($focused)
                    .onSubmit { session.saveName(key) }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(palette.well, in: RoundedRectangle(cornerRadius: 4))
                KeyCap(title: "保存", role: .commit) { session.saveName(key) }
                if session.snapshots.first(where: { $0.billingIdentity == key })?.nameIsManual == true {
                    KeyCap(title: "清除", role: .soft) { session.clearName(key) }
                }
                KeyCap(title: "取消", role: .soft) { session.cancelName() }
            }
            if let nameError = session.nameError {
                SignalRow(kind: .error, text: nameError)
            }
        }
        .onAppear { focused = true }
    }
}

private struct BillingEditor: View {
    @ObservedObject var session: BoardSession
    var snapshot: ProviderSnapshot
    @Environment(\.boardPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("账单日")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                DatePicker("", selection: $session.draftDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(maxWidth: .infinity, alignment: .leading)
                KeyCap(title: "保存", role: .commit) { session.saveBilling(snapshot.billingIdentity) }
                if snapshot.billing?.manual == true {
                    KeyCap(title: "清除", role: .soft) { session.clearBilling(snapshot.billingIdentity) }
                }
                KeyCap(title: "取消", role: .soft) { session.cancelBilling() }
            }
            if let editError = session.editError {
                SignalRow(kind: .error, text: editError)
            }
        }
    }
}

private struct ChartBody: View {
    @ObservedObject var session: BoardSession
    @Environment(\.boardPalette) private var palette

    private let band: CGFloat = 174
    private let below: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !session.snapshots.isEmpty {
                bridge
                    .padding(.top, 10)
                if TimelineMath.hasFutureReset(session.snapshots) {
                    TimelineBody(session: session)
                }
            }
            if !session.hidden.isEmpty {
                Text("已隐藏 \(session.hidden.count) 个，在列表视图里恢复")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, session.hidden.isEmpty ? 10 : 0)
    }

    private var bridge: some View {
        GeometryReader { geo in
            let count = CGFloat(max(session.snapshots.count, 1))
            let column = max(48, (geo.size.width - 22) / count)
            let width = max(geo.size.width, 22 + column * count)
            ScrollView(.horizontal, showsIndicators: width > geo.size.width + 1) {
                HStack(alignment: .top, spacing: 0) {
                    scaleGutter
                        .frame(width: 22, height: band)
                    ForEach(session.snapshots) { snapshot in
                        StripColumn(session: session, snapshot: snapshot, band: band)
                            .frame(width: column)
                    }
                }
                .frame(width: width, alignment: .leading)
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.well)
                        .frame(height: band)
                    gridLines
                        .frame(height: band)
                        .padding(.leading, 18)
                        .padding(.trailing, 6)
                }
            }
        }
        .frame(height: band + below)
    }

    private var scaleGutter: some View {
        ZStack(alignment: .topTrailing) {
            tick("100", y: 29)
            tick("50", y: 29 + 58)
            tick("0", y: 29 + 116)
            BoardIcon(kind: .reset, size: 10)
                .foregroundStyle(palette.ink3)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 9)
                .padding(.trailing, 3)
        }
    }

    private func tick(_ text: String, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(palette.ink3)
            .position(x: 8, y: y)
    }

    private var gridLines: some View {
        GeometryReader { proxy in
            let top: CGFloat = 29
            let mid = top + 58
            let low = top + 116
            Path { path in
                for y in [top, mid, low] {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(palette.sLine, lineWidth: 1)
        }
    }
}

private struct StripColumn: View {
    @ObservedObject var session: BoardSession
    var snapshot: ProviderSnapshot
    var band: CGFloat
    @Environment(\.boardPalette) private var palette
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    private var tipID: String { snapshot.id }

    var body: some View {
        let best = snapshot.tightest
        let tone = best.map { MeterTone.from(usedPercent: $0.usedPercent) }
        let worth = WorthMath.worth(snapshot, price: session.price(for: snapshot))
        VStack(spacing: 3) {
            VStack(spacing: 4) {
                if let best, let tone {
                    Text(Format.percent(best.remainingPercent))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.tone(tone))
                        .shadow(color: palette.glow(tone), radius: 4)
                        .frame(height: 16)
                } else {
                    LedDot(tone: .hot).frame(height: 16)
                }
                MeterBar(remaining: best?.remainingPercent ?? 0, tone: tone, vertical: true)
                    .padding(.bottom, 2)
                Text(best.flatMap { window in window.resetsAt.map { BoardFormat.briefReset($0) } } ?? (best == nil ? "" : "—"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .frame(height: 14)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .frame(height: band)
            .background(hovered || focused ? palette.sLine : .clear, in: RoundedRectangle(cornerRadius: 4))
            MarkView(kind: Mark.kind(for: snapshot), tone: tone, side: 16)
                .padding(.top, 2)
            Text(snapshot.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            Text(best?.label ?? "")
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
                .frame(height: 13)
            Text(worth.map { BoardFormat.money($0.left, currency: $0.currency) } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(best: best, worth: worth))
        .anchorPreference(key: AnchorMapKey.self, value: .bounds) { ["tip-\(tipID)": $0] }
        .onHover { inside in
            hovered = inside
            if inside { showTip(best: best, worth: worth) } else if !focused { session.hideTip(id: tipID) }
        }
        .onChange(of: focused) { _, on in
            if on { showTip(best: best, worth: worth) } else if !hovered { session.hideTip(id: tipID) }
        }
    }

    private func showTip(best: QuotaWindow?, worth: Worth?) {
        if let best {
            var lines = [BoardFormat.resetLine(best)]
            if let worth {
                lines.append("剩余价值 \(BoardFormat.money(worth.left, currency: worth.currency)) / \(BoardFormat.money(worth.total, currency: worth.currency))")
            }
            session.showTip(id: tipID, title: snapshot.name, lines: lines)
        } else {
            session.showTip(id: tipID, title: snapshot.name, lines: [snapshot.error ?? "读取失败"])
        }
    }

    private func accessibilityText(best: QuotaWindow?, worth: Worth?) -> String {
        guard let best else { return "\(snapshot.name) \(snapshot.error ?? "")" }
        var text = "\(snapshot.name) \(BoardFormat.resetLine(best))"
        if let worth {
            text += "，剩余价值 \(BoardFormat.money(worth.left, currency: worth.currency))"
        }
        return text
    }
}

private struct TimelineBody: View {
    @ObservedObject var session: BoardSession
    @Environment(\.boardPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("重置时间线")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.ink3)
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(session.snapshots) { snapshot in
                            TimelineLane(session: session, snapshot: snapshot)
                        }
                    }
                    laneGrid
                        .padding(.leading, 72)
                        .padding(.trailing, 54)
                        .allowsHitTesting(false)
                }
                axis
                    .padding(.leading, 72)
                    .padding(.trailing, 54)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .background(palette.well, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var laneGrid: some View {
        GeometryReader { proxy in
            ForEach(Array(TimelineMath.ticks.enumerated()), id: \.offset) { index, tick in
                Rectangle()
                    .fill(index == 0 ? palette.ink3 : palette.sLine)
                    .frame(width: 1)
                    .position(x: proxy.size.width * TimelineMath.position(minutes: tick.minutes) / 100, y: proxy.size.height / 2)
            }
        }
    }

    private var axis: some View {
        GeometryReader { proxy in
            ForEach(Array(TimelineMath.ticks.enumerated()), id: \.offset) { index, tick in
                Text(tick.label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(palette.ink3)
                    .position(x: axisX(index: index, count: TimelineMath.ticks.count, width: proxy.size.width, minutes: tick.minutes), y: 9)
            }
        }
        .frame(height: 18)
    }

    private func axisX(index: Int, count: Int, width: CGFloat, minutes: Double) -> CGFloat {
        let raw = width * TimelineMath.position(minutes: minutes) / 100
        if index == 0 { return 12 }
        if index == count - 1 { return max(12, width - 14) }
        return raw
    }
}

private struct TimelineLane: View {
    @ObservedObject var session: BoardSession
    var snapshot: ProviderSnapshot
    @Environment(\.boardPalette) private var palette
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    private var tipID: String { "lane-\(snapshot.id)" }
    private var dots: [TimelineMath.Dot] { TimelineMath.dots(snapshot.windows) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                MarkView(kind: Mark.kind(for: snapshot), tone: snapshot.tightest.map { MeterTone.from(usedPercent: $0.usedPercent) }, side: 12)
                Text(snapshot.name)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
            }
            .frame(width: 64, alignment: .leading)
            track
            Text(nextLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 20)
        .background(hovered || focused ? palette.sLine : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .focusable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .anchorPreference(key: AnchorMapKey.self, value: .bounds) { ["tip-\(tipID)": $0] }
        .onHover { inside in
            hovered = inside
            if inside { showTip() } else if !focused { session.hideTip(id: tipID) }
        }
        .onChange(of: focused) { _, on in
            if on { showTip() } else if !hovered { session.hideTip(id: tipID) }
        }
    }

    private var nextLabel: String {
        guard let date = snapshot.windows.compactMap(\.resetsAt).filter({ $0 > Date() }).min() else { return "" }
        return BoardFormat.briefReset(date)
    }

    @ViewBuilder private var track: some View {
        if snapshot.windows.isEmpty {
            HStack(spacing: 5) {
                LedDot(tone: .hot)
                Text("读取失败")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.ink3)
                Spacer(minLength: 0)
            }
        } else if dots.isEmpty {
            Text("没有重置时间")
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GeometryReader { proxy in
                Rectangle()
                    .fill(palette.sLine)
                    .frame(height: 1)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(palette.tone(dot.tone))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(palette.well, lineWidth: 2))
                        .shadow(color: palette.glow(dot.tone), radius: 3)
                        .position(x: proxy.size.width * dot.position / 100, y: proxy.size.height / 2)
                }
            }
        }
    }

    private var orderedLines: [String] {
        if snapshot.windows.isEmpty { return [snapshot.error ?? "读取失败"] }
        return snapshot.windows.sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }.map { BoardFormat.resetLine($0) }
    }

    private var accessibilityText: String {
        "\(snapshot.name)：\(orderedLines.joined(separator: "；"))"
    }

    private func showTip() {
        session.showTip(id: tipID, title: snapshot.name, lines: orderedLines)
    }
}

private struct ResetsPlaceholder: View {
    @Environment(\.boardPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("重置预告还没接上")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text("这一页先占着。汇总服务接上之前，这里不会列出预告。")
                .font(.system(size: 12))
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Quota Board 不直接读取 x.com。")
                .font(.system(size: 10))
                .foregroundStyle(palette.ink3)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
    }
}

private struct ResetsBody: View {
    @ObservedObject var session: BoardSession
    var reduceMotion: Bool
    @Environment(\.boardPalette) private var palette

    var body: some View {
        let split = FeedLogic.split(session.feed.items)
        VStack(alignment: .leading, spacing: 0) {
            if session.feed.phase == .loading, session.feed.items.isEmpty {
                EmptyPane(text: "正在读取重置预告…", scanning: !reduceMotion)
            } else if session.feed.phase == .failed, session.feed.items.isEmpty, let error = session.feed.error {
                SignalRow(kind: .fault, text: error)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
            } else {
                if session.feed.phase == .failed, let error = session.feed.error {
                    SignalRow(kind: .stale, text: "沿用上次同步 · \(error)")
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                }
                if session.feed.items.isEmpty {
                    EmptyPane(text: "暂时没有重置预告", scanning: false)
                }
                if !split.upcoming.isEmpty {
                    noticeSection("即将重置", items: split.upcoming, first: session.feed.phase != .failed)
                }
                if !split.past.isEmpty {
                    noticeSection("已过", items: split.past, first: split.upcoming.isEmpty && session.feed.phase != .failed)
                }
                Text("重置预告由第三方汇总服务提供，Quota Board 不直接读取 x.com。")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
        }
    }

    private func noticeSection(_ title: String, items: [FeedItem], first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first {
                Groove(dark: palette.sGroove, light: palette.sGrooveHi)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.ink3)
                .padding(.top, first ? 10 : 14)
                .padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                NoticeCard(session: session, item: item)
                    .padding(.bottom, index == items.count - 1 ? 0 : 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
    }
}

private struct NoticeCard: View {
    @ObservedObject var session: BoardSession
    var item: FeedItem
    @Environment(\.boardPalette) private var palette

    private var upcoming: Bool { FeedLogic.pending(item) }
    private var when: Date? { item.effectiveAt ?? item.scheduledAt }

    var body: some View {
        let hits = FeedLogic.affected(item, snapshots: session.snapshots)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                MarkView(kind: Mark.Kind.fromFeed(item.provider), tone: nil, side: 16)
                Text(item.providerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    LedDot(tone: item.status.tone)
                    Text(item.status.title)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink2)
                }
                Spacer(minLength: 8)
                if let label = readout {
                    Readout(text: label, tone: nil, compact: true, struck: item.status == .cancelled)
                }
            }
            .frame(minHeight: 24)
            Text(item.summary)
                .font(.system(size: 12))
                .foregroundStyle(upcoming ? palette.ink : palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if hits.isEmpty {
                Text("不影响你的账号")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            } else {
                Text("\(item.status == .cancelled ? "原定影响" : "影响") \(hits.map(\.name).joined(separator: "、")) · \(item.windowTitle())")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(sourceLine)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                KeyCap(title: "原帖", role: .soft) { session.open(item.sourceURL) }
            }
        }
        .padding(.vertical, 8)
    }

    private var readout: String? {
        guard let when else { return nil }
        if upcoming, let scheduled = item.scheduledAt { return Format.shortReset(scheduled) }
        return BoardFormat.stamp(when)
    }

    private var sourceLine: String {
        let who = item.authorHandle.map { "\(item.authorName) @\($0)" } ?? item.authorName
        return "\(who) · \(item.platformTitle) · \(BoardFormat.ago(item.postedAt))"
    }
}

private struct EmptyPane: View {
    @Environment(\.boardPalette) private var palette
    var text: String
    var scanning: Bool
    @State private var sweep = false

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .overlay {
                if scanning {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, palette.sLine, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.4)
                            .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.4)
                            .onAppear {
                                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                                    sweep = true
                                }
                            }
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
    }
}

private struct TipCard: View {
    @Environment(\.boardPalette) private var palette
    var tip: BoardTip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tip.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.sInk)
            ForEach(Array(tip.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.sInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: 280, alignment: .leading)
        .background(palette.screen, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.sLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

private final class ChromeHook: @unchecked Sendable {
    weak var controller: PanelController?

    init(controller: PanelController) {
        self.controller = controller
    }

    func fire() {
        MainActor.assumeIsolated { controller?.applyChrome() }
    }
}

@MainActor
final class PanelController: NSHostingController<BoardView> {
    let session: BoardSession
    private var escapeMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private var chromeHook: ChromeHook?

    init(session: BoardSession) {
        self.session = session
        super.init(rootView: BoardView(session: session))
        sizingOptions = [.preferredContentSize]
        preferredContentSize = NSSize(width: 360, height: 480)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        applyChrome()
        installEscape()
        let hook = ChromeHook(controller: self)
        chromeHook = hook
        appearanceObservation = view.observe(\.effectiveAppearance) { _, _ in
            hook.fire()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        appearanceObservation = nil
        chromeHook = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    func applyChrome() {
        let appearance: NSAppearance?
        let dark: Bool
        switch session.theme {
        case .system:
            appearance = nil
            dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .light:
            appearance = NSAppearance(named: .aqua)
            dark = false
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
            dark = true
        }
        if view.appearance?.name != appearance?.name {
            view.appearance = appearance
        }
        view.window?.backgroundColor = BoardPalette.windowBackground(dark: dark)
    }

    private func installEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { self?.session.consumeEscape() ?? false }
            return consumed ? nil : event
        }
    }
}
