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

extension WatchlinkStyle {
    /// The room palette. Fixed values: the product shell is light-only until a
    /// dark theme ships, and Private Space uses the night set explicitly.
    enum Room {
        static let cream = Color(hex: 0xF5F1E8)      // e0 ground, every screen
        static let paper = Color(hex: 0xFBF9F4)      // e1 surfaces, incoming bubbles
        static let linen = Color(hex: 0xEDE7DA)      // sunken, placeholders
        static let control = Color(hex: 0xECE6D8)    // round controls (moon)
        static let mine = Color(hex: 0xE3EAE1)       // outgoing bubbles
        static let mist = Color(hex: 0xE1E8DF)       // partner monogram
        static let sage = Color(hex: 0x426B57)       // the one live action
        static let sageDeep = Color(hex: 0x34574A)
        static let ink = Color(hex: 0x23271F)
        static let ink2 = Color(hex: 0x585C53)
        static let ink3 = Color(hex: 0x6B6E65)
        static let hairline = Color(hex: 0xE3DCCD)
        static let rule = Color(hex: 0xDDD5C4)
        static let bar = Color(hex: 0xF1ECE1)
        static let notice = Color(hex: 0xF3E9D6)
        static let noticeInk = Color(hex: 0x8A5A22)
        static let blocking = Color(hex: 0x9B3B2E)
        static let night = Color(hex: 0x161A17)
        static let nightMid = Color(hex: 0x1B221E)
        static let moss = Color(hex: 0x2E4136)
        static let nightText = Color(hex: 0xF1F2EC)
        static let nightSecondary = Color(hex: 0xAEB8AF)
    }
}

extension View {
    /// New York display (greetings, Us headline). Scales with Dynamic Type.
    func wlDisplay() -> some View { modifier(ScaledSerif(size: 44, relativeTo: .largeTitle, tracking: -0.6)) }
    /// New York title (names, Chat heading).
    func wlTitle() -> some View { modifier(ScaledSerif(size: 24, relativeTo: .title2)) }
    /// New York italic whisper (day separators, quiet lines).
    func wlWhisper(size: CGFloat = 14) -> some View { modifier(ScaledSerif(size: size, relativeTo: .footnote, italic: true)) }
}

private struct ScaledSerif: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let tracking: CGFloat
    let italic: Bool

    init(size: CGFloat, relativeTo style: Font.TextStyle, tracking: CGFloat = 0, italic: Bool = false) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.tracking = tracking
        self.italic = italic
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: .regular, design: .serif)
        content.font(italic ? font.italic() : font).tracking(tracking)
    }
}

private extension Color {
    init(hex value: UInt32) {
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }
}
