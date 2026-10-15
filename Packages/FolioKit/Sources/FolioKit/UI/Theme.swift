import AppKit
import SwiftUI

/// Design tokens, the same as in Issues. Every colour has a light and a dark value.
public enum Theme {
    static let window = NSColor(light: 0xF1F2F4, dark: 0x0B0C0E)
    static let panel = NSColor(light: 0xFBFBFC, dark: 0x111214)
    static let panelBorder = NSColor(light: 0xE3E4E8, dark: 0x1F2126)
    static let separator = NSColor(light: 0xEDEEF1, dark: 0x1B1D21)
    static let card = NSColor(light: 0xFFFFFF, dark: 0x17181B)
    static let cardBorder = NSColor(light: 0xE6E7EB, dark: 0x24262B)
    static let hover = NSColor(light: 0xE8E9ED, dark: 0x1A1C20)
    static let selected = NSColor(light: 0xE3E4E8, dark: 0x202227)
    static let control = NSColor(light: 0xE7E8EC, dark: 0x191B1F)
    static let popover = NSColor(light: 0xFFFFFF, dark: 0x1B1D21)
    static let popoverBorder = NSColor(light: 0xDDDEE3, dark: 0x2C2F36)
    static let popoverSelected = NSColor(light: 0xEEEFF2, dark: 0x2A2D33)
    static let keycap = NSColor(light: 0xD0D2D8, dark: 0x3A3E46)

    static let text = NSColor(light: 0x1A1B1E, dark: 0xE8E9EB)
    static let textSecondary = NSColor(light: 0x5F636B, dark: 0x9A9FA8)
    static let textTertiary = NSColor(light: 0x6E727B, dark: 0x7C818A)
    static let textBody = NSColor(light: 0x2E3035, dark: 0xC9CCD1)
    /// Markdown punctuation shown next to the caret.
    static let faint = NSColor(light: 0xA3A7AF, dark: 0x5A5E66)

    static let accent = NSColor(light: 0x5B63D3, dark: 0x8F96F2)
    static let positive = NSColor(light: 0x2F9B67, dark: 0x4CB782)
    static let warning = NSColor(light: 0xB8791C, dark: 0xE5A84B)
    static let red = NSColor(light: 0xD64545, dark: 0xEB6A6A)
    static let blue = NSColor(light: 0x2F86B5, dark: 0x5AB0D8)
    static let purple = NSColor(light: 0x6E56CF, dark: 0xA08CF2)
    static let pdf = NSColor(light: 0xD64545, dark: 0xEB6A6A)
    static let image = NSColor(light: 0x2F86B5, dark: 0x5AB0D8)
    static let video = NSColor(light: 0x7C5CC4, dark: 0xA08CF2)

    static let code = NSColor(light: 0xF3F4F6, dark: 0x18191C)
    static let codeBorder = NSColor(light: 0xE8E9ED, dark: 0x222429)
    static let inlineCode = NSColor(light: 0xEEEFF2, dark: 0x22242A)
    static let searchMark = NSColor(srgbRed: 240 / 255, green: 180 / 255, blue: 41 / 255, alpha: 0.38)

    static let sidebarWidth: CGFloat = 248
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 28

    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let quick = Animation.easeOut(duration: 0.14)
}

extension NSColor {
    /// A colour that follows the appearance it is drawn in.
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    var swiftUI: Color { Color(nsColor: self) }
}

extension Color {
    static func theme(_ color: NSColor) -> Color { Color(nsColor: color) }
}

extension Font {
    static let ui = Font.system(size: 13)
    static let uiMedium = Font.system(size: 13, weight: .medium)
    static let uiSemibold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let tiny = Font.system(size: 11)
}
