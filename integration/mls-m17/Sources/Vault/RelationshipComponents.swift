import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// Side margin for screen content: applied inside the ground, never as a fixed width.
let screenMargin: CGFloat = 20

/// Every product screen. The cream ground is the outermost layer and ignores the
/// safe area, so it fills the display edge to edge; content lives inside it and
/// never defines where the colour ends. Wide windows cap content at 560 pt, centred.
struct ScreenScaffold<Content: View>: View {
    var ground: Color = Room.cream
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            ground.ignoresSafeArea()
            content
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The Anchor Line: Home and Us share this block (same margin, same top), so
/// switching tabs changes only the words, never where the eye lands.
struct HeadlineBlock: View {
    let meta: String
    let headline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meta)
                .font(.subheadline)
                .foregroundStyle(Room.ink2)
            Text(headline)
                .wlDisplay()
                .lineSpacing(4)
                .foregroundStyle(Room.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, screenMargin)
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// e1 resting paper: tone step, faint edge, one long low shadow on the shape only (cheap to composite).
    func wlCard(radius: CGFloat = 24, fill: Color = Room.paper) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Room.ink.opacity(0.045), lineWidth: 1))
                .shadow(color: Room.ink.opacity(0.08), radius: 18, y: 14)
        }
    }
}

/// An initial in New York on mist (partner) or linen (you). Empty initial = a quiet disc.
struct Monogram: View {
    let initial: String
    var size: CGFloat = 36
    var partner = true

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.46, design: .serif))
            .foregroundStyle(partner ? Room.sageDeep : Room.ink2)
            .frame(width: size, height: size)
            .background(partner ? Room.mist : Room.control, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Two overlapping monograms with a ground-coloured ring: the nested-rings identity, no hearts.
struct PairMonogram: View {
    let partner: String
    let me: String
    var size: CGFloat = 76

    var body: some View {
        HStack(spacing: -size * 0.24) {
            Monogram(initial: partner, size: size, partner: true)
                .overlay(Circle().stroke(Room.cream, lineWidth: 4))
            Monogram(initial: me, size: size, partner: false)
                .overlay(Circle().stroke(Room.cream, lineWidth: 4))
        }
        .accessibilityHidden(true)
    }
}

/// Trust, not presence: "End-to-end encrypted" only when the security layer
/// reports an established, connected session; otherwise its own wording.
struct EncryptionLabel: View {
    let state: SecurityState
    let connected: Bool

    static func text(_ state: SecurityState, connected: Bool) -> String {
        state == .secure && connected ? "End-to-end encrypted" : SecurityStatusView.label(state, connected: connected)
    }

    var body: some View {
        HStack(spacing: 4) {
            if state == .secure && connected {
                Image(systemName: "lock").imageScale(.small)
            }
            Text(Self.text(state, connected: connected))
        }
        .font(.caption)
        .foregroundStyle(Room.ink3)
        .accessibilityElement(children: .combine)
    }
}

/// Partner monogram, serif name and the trust line. Shared by the Home surface,
/// the Chat header and The Opening's proxy, so the name lands where it started.
struct ConversationHeader: View {
    let partner: Person
    let state: SecurityState
    let connected: Bool
    var presence = PartnerPresence.unknown

    var body: some View {
        HStack(spacing: 12) {
            Monogram(initial: partner.initial)
                .background {
                    // Presence is drawn only when real; `.unknown` renders nothing extra.
                    if presence == .together { Circle().fill(Room.sage.opacity(0.18)).scaleEffect(1.3) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(partner.shownName).wlTitle().foregroundStyle(Room.ink).lineLimit(1)
                EncryptionLabel(state: state, connected: connected)
            }
        }
    }
}
