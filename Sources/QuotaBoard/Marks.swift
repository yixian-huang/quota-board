import AppKit

enum Mark {
    enum Kind: Equatable {
        case board
        case claude
        case codex
        case cursor
        case grok
    }

    static func kind(for snapshot: ProviderSnapshot) -> Kind? {
        let hay = "\(snapshot.id) \(snapshot.name) \(snapshot.shortName)".lowercased()
        if hay.contains("claude") { return .claude }
        if hay.contains("cursor") { return .cursor }
        if hay.contains("grok") { return .grok }
        if hay.contains("codex") || hay.contains("openai") { return .codex }
        return nil
    }

    /// Board is drawn. The four platforms are the icons shipped on their own sites.
    static func icon(_ kind: Kind, side: CGFloat, appearance: NSAppearance? = nil) -> NSImage {
        if kind == .board {
            return boardIcon(side: side)
        }
        guard let source = official(kind, appearance: appearance) else {
            return boardIcon(side: side)
        }
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: side, height: side)
        image.isTemplate = false
        return image
    }

    private static func official(_ kind: Kind, appearance: NSAppearance?) -> NSImage? {
        switch kind {
        case .board:
            return nil
        case .claude:
            return bundled("claude")
        case .codex:
            return bundled("codex")
        case .cursor:
            let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return bundled(dark ? "cursor-dark" : "cursor") ?? bundled("cursor")
        case .grok:
            return bundled("grok")
        }
    }

    private static func bundled(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func boardIcon(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            boardTile(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Deep green tile with three quota bars. Only the panel header uses this.
    private static func boardTile(in rect: NSRect) {
        let tile = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04)
        let plate = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.24, yRadius: tile.width * 0.24)
        NSColor(srgbRed: 0.11, green: 0.46, blue: 0.32, alpha: 1).setFill()
        plate.fill()
        NSColor.white.setStroke()
        plate.lineWidth = max(1, rect.width * 0.06)
        plate.stroke()
        let glyph = tile.insetBy(dx: tile.width * 0.2, dy: tile.height * 0.2)
        NSColor.white.setFill()
        let gap = glyph.height * 0.16
        let barHeight = (glyph.height - gap * 2) / 3
        let fractions: [CGFloat] = [1, 0.62, 0.3]
        for (index, fraction) in fractions.enumerated() {
            let y = glyph.minY + CGFloat(index) * (barHeight + gap)
            NSBezierPath(
                roundedRect: NSRect(x: glyph.minX, y: y, width: max(barHeight, glyph.width * fraction), height: barHeight),
                xRadius: barHeight / 2,
                yRadius: barHeight / 2
            ).fill()
        }
    }
}

enum MenuBarTitle {
    static func attributed(
        _ snapshots: [ProviderSnapshot],
        now: Date = .now,
        appearance: NSAppearance? = nil
    ) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let text: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        guard let item = MenuTitle.item(for: snapshots, now: now) else {
            let fallback = snapshots.contains { $0.error != nil } ? "额度不可用" : "读取中"
            return NSAttributedString(string: fallback, attributes: text)
        }
        let title = NSMutableAttributedString()
        if let kind = item.kind {
            title.append(piece(Mark.icon(kind, side: 14, appearance: appearance), font: font))
            title.append(NSAttributedString(string: " ", attributes: text))
        }
        title.append(NSAttributedString(string: "\(item.percent)%", attributes: text))
        return title
    }

    private static func piece(_ image: NSImage, font: NSFont) -> NSAttributedString {
        let side: CGFloat = 14
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        return NSAttributedString(attachment: attachment)
    }
}
