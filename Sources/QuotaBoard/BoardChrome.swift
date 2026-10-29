import AppKit
import SwiftUI

struct BoardGlyph: Shape {
    enum Kind {
        case refresh
        case chevron
        case list
        case chart
        case lookSystem
        case lookLight
        case lookDark
        case reset
    }

    var kind: Kind

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 8) * scale, y: rect.midY + (y - 8) * scale)
        }
        var path = Path()
        switch kind {
        case .refresh, .reset:
            path.addArc(
                center: at(8, 8.6),
                radius: 5.2 * scale,
                startAngle: .degrees(-50),
                endAngle: .degrees(230),
                clockwise: false
            )
            path.move(to: at(12.2, 1.8))
            path.addLine(to: at(12.2, 5.1))
            path.addLine(to: at(8.9, 5.1))
        case .chevron:
            path.move(to: at(3.2, 6.2))
            path.addLine(to: at(8, 10.2))
            path.addLine(to: at(12.8, 6.2))
        case .list:
            for y in [4.5, 8, 11.5] as [CGFloat] {
                path.move(to: at(2.6, y))
                path.addLine(to: at(13.4, y))
            }
        case .chart:
            path.move(to: at(4, 13.2))
            path.addLine(to: at(4, 8))
            path.move(to: at(8, 13.2))
            path.addLine(to: at(8, 3.2))
            path.move(to: at(12, 13.2))
            path.addLine(to: at(12, 6.2))
        case .lookSystem:
            path.addEllipse(in: CGRect(x: at(2.4, 2.4).x, y: at(2.4, 2.4).y, width: 11.2 * scale, height: 11.2 * scale))
        case .lookLight:
            path.addEllipse(in: CGRect(x: at(5.1, 5.1).x, y: at(5.1, 5.1).y, width: 5.8 * scale, height: 5.8 * scale))
            for end in [(8, 1.8, 8, 3.4), (8, 12.6, 8, 14.2), (1.8, 8, 3.4, 8), (12.6, 8, 14.2, 8), (3.6, 3.6, 4.8, 4.8), (11.2, 11.2, 12.4, 12.4), (3.6, 12.4, 4.8, 11.2), (11.2, 4.8, 12.4, 3.6)] {
                path.move(to: at(CGFloat(end.0), CGFloat(end.1)))
                path.addLine(to: at(CGFloat(end.2), CGFloat(end.3)))
            }
        case .lookDark:
            path.move(to: at(13.2, 9.6))
            path.addCurve(to: at(6.4, 2.8), control1: at(13.2, 6.2), control2: at(10.2, 3.2))
            path.addCurve(to: at(13.2, 9.6), control1: at(8.6, 4.6), control2: at(11.4, 8.2))
        }
        return path
    }
}

struct BoardIcon: View {
    var kind: BoardGlyph.Kind
    var size: CGFloat = 14

    var body: some View {
        BoardGlyph(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: kind == .chart || kind == .reset ? 1.7 : 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct HalfDisk: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

struct MoreDots: View {
    var body: some View {
        HStack(spacing: 2.4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 2.4, height: 2.4)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct LookIcon: View {
    var theme: PanelTheme

    var body: some View {
        ZStack {
            switch theme {
            case .system:
                BoardIcon(kind: .lookSystem)
                HalfDisk().fill().padding(2.6)
            case .light:
                BoardIcon(kind: .lookLight)
            case .dark:
                BoardIcon(kind: .lookDark)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct KeyCap: View {
    @Environment(\.boardPalette) private var palette
    var title: String?
    var badge: Int?
    var icon: BoardGlyph.Kind?
    var more = false
    var look: PanelTheme?
    var help: String?
    var role: Role = .plate
    var down = false
    var locked = false
    var spinning = false
    var action: () -> Void

    enum Role {
        case plate
        case icon
        case segment(Bool)
        case soft
        case commit
        case flat
    }

    var body: some View {
        Button {
            if !locked { action() }
        } label: {
            label
                .font(.system(size: 11, weight: emphasized ? .semibold : .medium))
                .padding(.horizontal, horizontalPad)
                .frame(width: fixedWidth, height: height)
                .background(background)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1))
                .shadow(color: shadow, radius: downState ? 0 : 1, y: downState ? 0 : 1)
                .offset(y: downState ? 1 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? title ?? "")
        .accessibilityLabel(help ?? title ?? "")
    }

    private var selected: Bool {
        if case let .segment(on) = role { return on }
        return false
    }

    private var emphasized: Bool {
        if case .commit = role { return true }
        return selected
    }

    private var downState: Bool { down || locked }

    private var height: CGFloat {
        switch role {
        case .icon: 22
        case .segment: 20
        default: 20
        }
    }

    private var fixedWidth: CGFloat? {
        switch role {
        case .icon: 22
        case .segment where icon != nil || more || look != nil: 24
        default: nil
        }
    }

    private var horizontalPad: CGFloat {
        if fixedWidth != nil { return 0 }
        if case .segment = role { return 8 }
        return title == nil ? 0 : 9
    }

    @State private var hovered = false

    @ViewBuilder private var label: some View {
        HStack(spacing: 3) {
            Group {
                if let look {
                    LookIcon(theme: look)
                } else if more {
                    MoreDots()
                } else if let icon {
                    iconView(icon)
                }
                if let title {
                    Text(title)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.sInk)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 14)
                    .background(palette.screen, in: Capsule())
            }
        }
    }

    @ViewBuilder private func iconView(_ icon: BoardGlyph.Kind) -> some View {
        if icon == .refresh {
            TimelineView(.animation(minimumInterval: spinning ? 1 / 30 : 60)) { context in
                let turns = spinning ? context.date.timeIntervalSinceReferenceDate / 0.9 : 0
                BoardIcon(kind: icon, size: icon == .chevron ? 8 : 14)
                    .rotationEffect(.degrees(turns * 360))
            }
        } else {
            BoardIcon(kind: icon, size: icon == .chevron || icon == .reset ? 9 : 14)
        }
    }

    private var foreground: Color {
        switch role {
        case .commit:
            return palette.screen
        case .flat:
            return down || hovered ? palette.ink : palette.ink3
        case let .segment(on):
            return on ? palette.keyInk : palette.ink2
        default:
            return downState ? palette.ink3 : palette.keyInk
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(fill)
    }

    private var fill: Color {
        switch role {
        case .commit:
            return palette.sInk
        case .flat:
            if down { return palette.softDown }
            return hovered ? palette.soft : .clear
        case let .segment(on):
            if !on { return hovered ? palette.ink.opacity(0.06) : .clear }
            return downState ? palette.keyDown : palette.key
        case .soft:
            if downState { return palette.softDown }
            return hovered ? palette.softHover : palette.soft
        default:
            return downState ? palette.keyDown : palette.key
        }
    }

    private var border: Color {
        switch role {
        case .commit:
            return palette.sInk
        case .flat:
            return down || hovered ? palette.softEdge : .clear
        case let .segment(on):
            return on ? palette.keyEdge : .clear
        case .soft:
            return palette.softEdge
        default:
            return palette.keyEdge
        }
    }

    private var shadow: Color {
        switch role {
        case .soft, .commit, .flat:
            return .clear
        case let .segment(on):
            return on && !downState ? .black.opacity(0.12) : .clear
        default:
            return downState ? .clear : .black.opacity(palette.dark ? 0.45 : 0.14)
        }
    }
}

struct MeterBar: View {
    @Environment(\.boardPalette) private var palette
    var remaining: Double
    var tone: MeterTone?
    var vertical = false
    var thickness: CGFloat = 8

    var body: some View {
        let lit = tone == nil ? 0 : MeterMath.litCount(remaining)
        Group {
            if vertical {
                VStack(spacing: 2) {
                    ForEach((0..<MeterMath.segments).reversed(), id: \.self) { index in
                        segment(on: index < lit)
                    }
                }
                .frame(width: 20, height: 116)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<MeterMath.segments, id: \.self) { index in
                        segment(on: index < lit)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: thickness)
            }
        }
    }

    private func segment(on: Bool) -> some View {
        let color: Color = {
            guard let tone else { return palette.ledOff }
            return on ? palette.tone(tone) : palette.ghost(tone)
        }()
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color)
            .shadow(color: on && tone != nil ? palette.glow(tone!) : .clear, radius: on ? 2 : 0)
    }
}

struct LedDot: View {
    @Environment(\.boardPalette) private var palette
    var tone: MeterTone?

    var body: some View {
        Circle()
            .fill(tone.map { palette.tone($0) } ?? palette.ledOff)
            .frame(width: 7, height: 7)
            .overlay {
                if tone == nil {
                    Circle().strokeBorder(palette.sLine, lineWidth: 1)
                }
            }
            .shadow(color: tone.map { palette.glow($0) } ?? .clear, radius: tone == nil ? 0 : 3)
    }
}

struct MarkView: View {
    var kind: Mark.Kind?
    var tone: MeterTone?
    var side: CGFloat = 16
    var onScreen = true

    var body: some View {
        if let kind {
            Image(nsImage: Mark.icon(
                kind,
                side: side,
                appearance: onScreen ? NSAppearance(named: .darkAqua) : nil
            ))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
        } else {
            LedDot(tone: tone)
                .padding(.horizontal, side >= 16 ? 4.5 : 2.5)
        }
    }
}

struct Readout: View {
    @Environment(\.boardPalette) private var palette
    var text: String
    var tone: MeterTone?
    var compact = false
    var struck = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 11 : 15, weight: compact ? .medium : .semibold, design: .monospaced))
            .foregroundStyle(color)
            .strikethrough(struck)
            .shadow(color: compact || tone == nil ? .clear : (tone.map { palette.glow($0) } ?? .clear), radius: 4.5)
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(minWidth: compact ? 0 : 52, minHeight: compact ? 22 : 24)
            .background(palette.well, in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        if struck { return palette.ink3 }
        if compact, tone == nil { return palette.ink }
        return tone.map { palette.tone($0) } ?? palette.ink
    }
}

struct SignalRow: View {
    @Environment(\.boardPalette) private var palette
    enum Kind { case fault, stale, error }
    var kind: Kind
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            LedDot(tone: kind == .stale ? .warn : .hot)
                .padding(.top, 3.5)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch kind {
        case .fault: palette.ink2
        case .stale: palette.ledWarn
        case .error: palette.ledHot
        }
    }
}

struct Groove: View {
    var dark: Color
    var light: Color

    var body: some View {
        VStack(spacing: 0) {
            dark.frame(height: 1)
            light.frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BracketMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + 3
        let bottom = rect.maxY - 3
        let left = rect.minX + 1
        path.move(to: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: left + 2, y: top))
        path.addQuadCurve(to: CGPoint(x: left, y: top + 2), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - 2))
        path.addQuadCurve(to: CGPoint(x: left + 2, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom))
        return path
    }
}

struct MenuRow: Identifiable {
    var id: String
    var title: String
    var checked = false
    var separator = false
    var action: () -> Void
}

struct MenuList: View {
    @Environment(\.boardPalette) private var palette
    var onScreen: Bool
    var rows: [MenuRow]
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if row.separator {
                    Groove(dark: onScreen ? palette.sGroove : palette.plateGroove, light: onScreen ? palette.sGrooveHi : palette.plateGrooveHi)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                } else {
                    Button {
                        row.action()
                    } label: {
                        Text(row.title)
                            .font(.system(size: 13))
                            .foregroundStyle(itemInk(row))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 22)
                            .padding(.trailing, 14)
                            .frame(height: 22)
                            .background(itemFill(row), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(alignment: .leading) {
                                if row.checked {
                                    Text("✓")
                                        .font(.system(size: 11))
                                        .foregroundStyle(itemInk(row))
                                        .padding(.leading, 7)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hovered = inside ? row.id : (hovered == row.id ? nil : hovered)
                    }
                }
            }
        }
        .padding(4)
        .frame(minWidth: 148)
        .background(background)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(onScreen ? palette.softEdge : palette.plateEdge, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(palette.dark || onScreen ? 0.45 : 0.22), radius: 16, y: 8)
    }

    private var background: some View {
        LinearGradient(
            colors: onScreen ? [palette.screenTop, palette.screen] : [palette.keyTop, palette.key],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func itemFill(_ row: MenuRow) -> Color {
        guard hovered == row.id else { return .clear }
        return onScreen ? palette.softHover : palette.pick
    }

    private func itemInk(_ row: MenuRow) -> Color {
        if !onScreen, hovered == row.id { return palette.pickInk }
        return onScreen ? palette.sInk : palette.plateInk
    }
}
