import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// The pair, today: a vertical narrative, not a grid. Only real data is shown;
/// what doesn't exist yet says so once ("Arriving later") and does nothing.
struct UsView: View {
    let store: WatchlinkStore
    let relationship: RelationshipStore

    /// "Deniz\n& Ada." when both names exist; otherwise a name-free line.
    static func headline(me: Person, partner: Person) -> String {
        me.name.isEmpty || partner.name.isEmpty ? "Siz\nikiniz." : "\(me.name)\n& \(partner.name)."
    }

    /// Trust, in plain terms. No encryption claim: the MVP has none end-to-end.
    static func whereYouAre(_ state: SecurityState, connected: Bool) -> String {
        state == .secure && connected
            ? "İki telefonunuz arasında bağlı. Buradakileri sadece ikiniz görebilirsiniz."
            : SecurityStatusView.label(state, connected: connected) + "."
    }

    var body: some View {
        let profile = relationship.snapshot.profile
        ScreenScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // No pairing date is stored, so no "together since" line and never a day counter.
                    HeadlineBlock(meta: "Ortak alanınız", headline: Self.headline(me: profile.me, partner: profile.partner))
                    PairMonogram(partner: profile.partner.initial, me: profile.me.initial)
                        .padding(.horizontal, screenMargin)
                        .padding(.top, 28)
                    narrative(profile)
                        .padding(.top, 56)
                    Text("Bu alan sizinle birlikte büyür.")
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
            Chapter(title: "Kalp Atışı", marker: .filled) {
                HeartbeatChapter(store: store, partner: profile.partner)
            }
            Chapter(title: "Neredesiniz", marker: .filled) {
                Text(Self.whereYouAre(store.securityState, connected: store.connectionAvailable))
                    .wlTitle()
                    .foregroundStyle(Room.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chapter(title: "Tarihler", marker: .open) {
                if let next = relationship.snapshot.dates.sorted(by: { $0.date < $1.date }).first {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(next.date.formatted(.dateTime.day())).wlDisplay().foregroundStyle(Room.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.date.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                            Text(next.label).font(.subheadline).foregroundStyle(Room.ink2)
                        }
                    }
                }
                Text("Sizin için önemli günler burada toplanacak.")
                    .font(.subheadline)
                    .foregroundStyle(Room.ink3)
            }
            Chapter(title: "Anlar", marker: .later, trailing: "Yakında") {
                MomentsPlaceholder()
                Text("Saklamak istediğiniz fotoğraflar ve notlar, sadece aranızda.")
                    .font(.subheadline)
                    .foregroundStyle(Room.ink2)
            }
            Chapter(title: "Birbiriniz", marker: .later, trailing: "Yakında") {
                VStack(spacing: 0) {
                    person(profile.partner, partner: true, fallback: "Partnerin")
                    Rectangle().fill(Room.hairline).frame(height: 1).padding(.leading, 70)
                    person(profile.me, partner: false, fallback: "Sen")
                }
                .wlCard()
                Text("Birbirinize nasıl göründüğünüz.")
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

/// The partner's heartbeat, kept on this phone: tap the heart to feel it on the
/// Taptic Engine. Below it, your own rhythm, which is what your partner feels.
private struct HeartbeatChapter: View {
    let store: WatchlinkStore
    let partner: Person

    @State private var player = HeartbeatPlayer()
    @State private var playing = false
    @State private var pulse = false
    @State private var editingBPM: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: Double { 60.0 / Double(min(max(store.partnerBPM, 40), 180)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: toggle) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(Room.sage)
                    .scaleEffect(pulse ? 1.12 : 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 176)
                    .background(Room.mist, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(Pressable())
            .accessibilityLabel(playing ? "Kalp atışını durdur" : "\(partner.shownName) · kalp atışını hisset")

            VStack(alignment: .leading, spacing: 4) {
                Text("Zorlandığında, buna tutun.").wlTitle().foregroundStyle(Room.ink)
                Text("\(partner.shownName) · \(store.partnerBPM) bpm")
                    .font(.subheadline).foregroundStyle(Room.ink2)
            }

            HStack {
                Stepper(value: Binding(get: { editingBPM ?? store.myBPM }, set: { editingBPM = $0 }), in: 40...180) {
                    Text("Senin ritmin · \(editingBPM ?? store.myBPM) bpm").font(.subheadline).foregroundStyle(Room.ink2)
                }
            }
            if let editingBPM, editingBPM != store.myBPM {
                Button("Ritmimi kaydet") {
                    Task { await store.saveMyBPM(editingBPM); self.editingBPM = nil }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Room.sageDeep)
                .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { playing ? stop() : start() }

    private func start() {
        try? player.play(bpm: Double(store.partnerBPM), duration: 20)
        playing = true
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: period * 0.35).repeatForever(autoreverses: true)) { pulse = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            if playing { stop() }
        }
    }

    private func stop() {
        player.stop()
        playing = false
        withAnimation(.easeOut(duration: 0.2)) { pulse = false }
    }
}
