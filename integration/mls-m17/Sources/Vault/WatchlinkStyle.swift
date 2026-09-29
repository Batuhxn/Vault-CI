import SwiftUI

enum WatchlinkStyle {
    static let background = Color(light: 0xF5F1E8, dark: 0x131714)
    static let surface = Color(light: 0xFBF9F3, dark: 0x1B201C)
    static let surface2 = Color(light: 0xECE8DE, dark: 0x232924)
    static let tint = Color(light: 0x426B57, dark: 0x9CC2AA)
    static let soft = Color(light: 0xDDE7DF, dark: 0x223128)
    static let text = Color(light: 0x20231F, dark: 0xE9E6DC)
    static let secondary = Color(light: 0x676A62, dark: 0xA3A69C)
    static let sent = Color(light: 0xD6E3D9, dark: 0x2E4638)
    static let online = Color(light: 0x4F8A63, dark: 0x7DB592)
    static let away = Color(light: 0xA98A55, dark: 0xC9A56B)
    static let danger = Color(light: 0xA4493D, dark: 0xE08A7C)
    static let hairline = Color.primary.opacity(0.10)

    /// Spacing scale; layouts use these instead of literals.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let control: CGFloat = 14
        static let card: CGFloat = 18
        static let sheet: CGFloat = 20
    }

    /// Native text styles, so Dynamic Type scales everything. Default sizes
    /// match the existing literals (28 / 17 / 15 / 13 / 12).
    enum Typography {
        static let title = Font.title.weight(.semibold)
        static let heading = Font.headline
        static let body = Font.body
        static let secondary = Font.subheadline
        static let footnote = Font.footnote
        static let caption = Font.caption
    }

    /// Restrained motion. Callers pass `accessibilityReduceMotion`; reduced
    /// motion gets no animation rather than a smaller one.
    enum Motion {
        static func standard(_ reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)
        }
        static func gentle(_ reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: 0.6)
        }
    }
}

extension View {
    /// The one soft card surface. Used only for things that are waiting, never as permanent dashboard tiles.
    func watchlinkSurface() -> some View {
        padding(WatchlinkStyle.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: WatchlinkStyle.Radius.card))
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct WatchlinkMark: View {
    var size: CGFloat = 88
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27).fill(WatchlinkStyle.soft)
            HStack(spacing: size * 0.06) {
                Circle().stroke(WatchlinkStyle.tint, lineWidth: size * 0.018).frame(width: size * 0.20)
                Rectangle().fill(WatchlinkStyle.tint).frame(width: size * 0.16, height: size * 0.018)
                Circle().stroke(WatchlinkStyle.tint, lineWidth: size * 0.018).frame(width: size * 0.20)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Watchlink")
    }
}

struct WatchlinkPrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 50) }
            .buttonStyle(.plain)
            .foregroundStyle(WatchlinkStyle.background)
            .background(WatchlinkStyle.tint, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
}
