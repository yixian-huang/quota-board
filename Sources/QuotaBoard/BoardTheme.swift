import AppKit
import SwiftUI

enum PanelTheme: String, Equatable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

enum BoardPage: String, Equatable {
    case quota
    case resets
}

enum BoardViewMode: String, Equatable {
    case list
    case chart
}

struct BoardPalette: Equatable {
    var dark: Bool
    var onScreen = false

    var plateTop: Color
    var plate: Color
    var plateBottom: Color
    var plateEdge: Color
    var bevel: Color
    var plateInk: Color
    var plateInk2: Color
    var plateInk3: Color
    var slot: Color
    var keyTop: Color
    var key: Color
    var keyHoverTop: Color
    var keyHover: Color
    var keyInk: Color
    var keyEdge: Color
    var keyDown: Color
    var plateGroove: Color
    var plateGrooveHi: Color
    var pick: Color
    var pickInk: Color
    var plateCue: Color

    var screenTop: Color
    var screen: Color
    var well: Color
    var sInk: Color
    var sInk2: Color
    var sInk3: Color
    var sLine: Color
    var sGroove: Color
    var sGrooveHi: Color
    var soft: Color
    var softHover: Color
    var softEdge: Color
    var softDown: Color
    var screenCue: Color
    var lip: Color

    var ledOff: Color
    var ledOk: Color
    var ledWarn: Color
    var ledHot: Color

    var ink: Color { onScreen ? sInk : plateInk }
    var ink2: Color { onScreen ? sInk2 : plateInk2 }
    var ink3: Color { onScreen ? sInk3 : plateInk3 }
    var cue: Color { onScreen ? screenCue : plateCue }

    func screened() -> BoardPalette {
        var copy = self
        copy.onScreen = true
        return copy
    }

    func tone(_ tone: MeterTone) -> Color {
        switch tone {
        case .ok: ledOk
        case .warn: ledWarn
        case .hot: ledHot
        }
    }

    func ghost(_ tone: MeterTone) -> Color {
        switch tone {
        case .ok: ledOk.opacity(0.14)
        case .warn: ledWarn.opacity(0.15)
        case .hot: ledHot.opacity(0.17)
        }
    }

    func glow(_ tone: MeterTone) -> Color {
        switch tone {
        case .ok: ledOk.opacity(0.55)
        case .warn: ledWarn.opacity(0.55)
        case .hot: ledHot.opacity(0.60)
        }
    }

    static func make(dark: Bool) -> BoardPalette {
        if dark { return darkPalette } else { return lightPalette }
    }

    static func windowBackground(dark: Bool) -> NSColor {
        if dark {
            return NSColor(srgbRed: 44 / 255, green: 43 / 255, blue: 41 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 244 / 255, green: 242 / 255, blue: 236 / 255, alpha: 1)
    }

    private static let lightPalette = BoardPalette(
        dark: false,
        plateTop: Color(hex: 0xf4f2ec),
        plate: Color(hex: 0xedeae3),
        plateBottom: Color(hex: 0xe6e3db),
        plateEdge: Color.black.opacity(0.20),
        bevel: Color.white.opacity(0.95),
        plateInk: Color(hex: 0x1a1917),
        plateInk2: Color(hex: 0x4a4843),
        plateInk3: Color(hex: 0x625f59),
        slot: Color(hex: 0xdedbd3),
        keyTop: Color(hex: 0xfdfcfa),
        key: Color(hex: 0xefeee9),
        keyHoverTop: Color.white,
        keyHover: Color(hex: 0xf5f4f0),
        keyInk: Color(hex: 0x1a1917),
        keyEdge: Color.black.opacity(0.20),
        keyDown: Color(hex: 0xe2e0da),
        plateGroove: Color.black.opacity(0.12),
        plateGrooveHi: Color.white.opacity(0.85),
        pick: Color(hex: 0x1a1917),
        pickInk: Color(hex: 0xf4f2ec),
        plateCue: Color(hex: 0x2a5fd6),
        screenTop: Color(hex: 0x22211e),
        screen: Color(hex: 0x1a1917),
        well: Color(hex: 0x100f0d),
        sInk: Color(hex: 0xf2efe7),
        sInk2: Color(hex: 0xb8b2a6),
        sInk3: Color(hex: 0x8f897d),
        sLine: Color.white.opacity(0.08),
        sGroove: Color.black.opacity(0.50),
        sGrooveHi: Color.white.opacity(0.06),
        soft: Color.white.opacity(0.07),
        softHover: Color.white.opacity(0.12),
        softEdge: Color.white.opacity(0.13),
        softDown: Color.black.opacity(0.35),
        screenCue: Color(hex: 0x7aa7ff),
        lip: Color.white.opacity(0.95),
        ledOff: Color(hex: 0x2b2925),
        ledOk: Color(hex: 0x3fe08a),
        ledWarn: Color(hex: 0xffb23e),
        ledHot: Color(hex: 0xff5b4d)
    )

    private static let darkPalette = BoardPalette(
        dark: true,
        plateTop: Color(hex: 0x2c2b29),
        plate: Color(hex: 0x252422),
        plateBottom: Color(hex: 0x1f1e1c),
        plateEdge: Color.white.opacity(0.12),
        bevel: Color.white.opacity(0.08),
        plateInk: Color(hex: 0xeeebe4),
        plateInk2: Color(hex: 0xbdb9b0),
        plateInk3: Color(hex: 0x9c978d),
        slot: Color(hex: 0x181715),
        keyTop: Color(hex: 0x3b3a37),
        key: Color(hex: 0x2f2e2b),
        keyHoverTop: Color(hex: 0x43423f),
        keyHover: Color(hex: 0x363532),
        keyInk: Color(hex: 0xeeebe4),
        keyEdge: Color.white.opacity(0.10),
        keyDown: Color(hex: 0x1b1a18),
        plateGroove: Color.black.opacity(0.55),
        plateGrooveHi: Color.white.opacity(0.06),
        pick: Color(hex: 0xeeebe4),
        pickInk: Color(hex: 0x1a1917),
        plateCue: Color(hex: 0x7aa7ff),
        screenTop: Color(hex: 0x171614),
        screen: Color(hex: 0x11100e),
        well: Color(hex: 0x090807),
        sInk: Color(hex: 0xf2efe7),
        sInk2: Color(hex: 0xb8b2a6),
        sInk3: Color(hex: 0x8f897d),
        sLine: Color.white.opacity(0.08),
        sGroove: Color.black.opacity(0.50),
        sGrooveHi: Color.white.opacity(0.06),
        soft: Color.white.opacity(0.07),
        softHover: Color.white.opacity(0.12),
        softEdge: Color.white.opacity(0.13),
        softDown: Color.black.opacity(0.35),
        screenCue: Color(hex: 0x7aa7ff),
        lip: Color.white.opacity(0.06),
        ledOff: Color(hex: 0x2b2925),
        ledOk: Color(hex: 0x3fe08a),
        ledWarn: Color(hex: 0xffb23e),
        ledHot: Color(hex: 0xff5b4d)
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

private struct BoardPaletteKey: EnvironmentKey {
    static let defaultValue = BoardPalette.make(dark: false)
}

extension EnvironmentValues {
    var boardPalette: BoardPalette {
        get { self[BoardPaletteKey.self] }
        set { self[BoardPaletteKey.self] = newValue }
    }
}
