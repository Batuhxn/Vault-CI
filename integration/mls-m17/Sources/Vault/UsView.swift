import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// The pair, today: a vertical narrative, not a grid. Only real data is shown;
/// what doesn't exist yet says so once ("Arriving later") and does nothing.
struct UsView: View {
    let store: WatchlinkStore
    let relationship: RelationshipStore

    /// "Deniz\n& Ada." when both names exist; otherwise a name-free line.
    static func headline(me: Person, partner: Person) -> String {
        me.name.isEmpty || partner.name.isEmpty ? "The two\nof you." : "\(me.name)\n& \(partner.name)."
    }

    /// Trust, from the security layer's own state. No device or verification claims it doesn't make.
    static func whereYouAre(_ state: SecurityState, connected: Bool) -> String {
        state == .secure && connected
            ? "Linked and end-to-end encrypted, between your two devices."
            : SecurityStatusView.label(state, connected: connected) + "."
    }

    var body: some View {
        let profile = relationship.snapshot.profile
        ScreenScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // No pairing date is stored, so no "together since" line and never a day counter.
                    HeadlineBlock(meta: "Your shared space", headline: Self.headline(me: profile.me, partner: profile.partner))
                    PairMonogram(partner: profile.partner.initial, me: profile.me.initial)
                        .padding(.horizontal, screenMargin)
                        .padding(.top, 28)
                    narrative(profile)
                        .padding(.top, 56)
                    Text("This space grows as you do.")
                        .wlWhisper(size: 17)
                        .foregroundStyle(Room.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 64)
                        .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func narrative(_ profile: CoupleProfile) -> some View {
        VStack(alignment: .leading, spacing: 48) {
            Chapter(title: "Where you are", marker: .filled) {
                Text(Self.whereYouAre(store.securityState, connected: store.connectionAvailable))
                    .wlTitle()
                    .foregroundStyle(Room.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chapter(title: "Dates", marker: .open) {
                if let next = relationship.snapshot.dates.sorted(by: { $0.date < $1.date }).first {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(next.date.formatted(.dateTime.day())).wlDisplay().foregroundStyle(Room.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.date.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                            Text(next.label).font(.subheadline).foregroundStyle(Room.ink2)
                        }
                    }
                }
                Text("The days that matter to you two will gather here.")
                    .font(.subheadline)
                    .foregroundStyle(Room.ink3)
            }
            Chapter(title: "Moments", marker: .later, trailing: "Arriving later") {
                MomentsPlaceholder()
                Text("Photos and notes you want to keep, only between you.")
                    .font(.subheadline)
                    .foregroundStyle(Room.ink2)
            }
            Chapter(title: "Each other", marker: .later, trailing: "Arriving later") {
                VStack(spacing: 0) {
                    person(profile.partner, partner: true, fallback: "Your partner")
                    Rectangle().fill(Room.hairline).frame(height: 1).padding(.leading, 70)
                    person(profile.me, partner: false, fallback: "You")
                }
                .wlCard()
                Text("How you appear to one another.")
                    .font(.subheadline)
                    .foregroundStyle(Room.ink2)
            }
        }
        .padding(.leading, screenMargin)
        .padding(.trailing, screenMargin)
        .background(alignment: .topLeading) {
            // The thread the chapters hang from.
            Rectangle().fill(Room.rule).frame(width: 1).padding(.leading, screenMargin + 5).padding(.vertical, 8)
        }
    }

    private func person(_ person: Person, partner: Bool, fallback: String) -> some View {
        HStack(spacing: 14) {
            Monogram(initial: person.initial, size: 40, partner: partner)
            Text(person.name.isEmpty ? fallback : person.name).wlTitle().foregroundStyle(Room.ink)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

private struct Chapter<Content: View>: View {
    enum Marker { case filled, open, later }
    let title: String
    let marker: Marker
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Circle()
                .fill(marker == .filled ? Room.sage : Room.cream)
                .overlay(Circle().stroke(marker == .later ? Room.ink3.opacity(0.5) : Room.sage, lineWidth: marker == .filled ? 0 : 1.5))
                .frame(width: 11, height: 11)
                .background(Circle().fill(Room.cream).frame(width: 19, height: 19))
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(marker == .later ? Room.ink2 : Room.sage)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(Room.ink3) }
                }
                content
            }
        }
    }
}

/// Blank, slightly tilted paper frames: suggests photographs without faking any.
private struct MomentsPlaceholder: View {
    var body: some View {
        ZStack {
            frame(Color(red: 0.89, green: 0.855, blue: 0.78), angle: -6, x: -62, y: 4, lifted: false)
            frame(Color(red: 0.965, green: 0.95, blue: 0.918), angle: 4, x: 0, y: -4, lifted: true)
            frame(Room.paper, angle: -2, x: 62, y: 8, lifted: true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 196)
        .background(Room.linen, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityHidden(true)
    }

    private func frame(_ fill: Color, angle: Double, x: CGFloat, y: CGFloat, lifted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fill)
            .shadow(color: Room.ink.opacity(lifted ? 0.12 : 0), radius: 13, y: 10)
            .frame(width: 108, height: 128)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
    }
}
