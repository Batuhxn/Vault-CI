import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// Shown once on each phone, the first time a pair opens: a greeting, four small
/// living scenes (chat, heartbeat, home, school) and, when the partner left one,
/// their note. Replayable from Biz.
struct WelcomeTour: View {
    let myName: String
    let partnerName: String
    let letters: LetterBox
    let done: () -> Void

    private enum Page: Int, CaseIterable { case hello, chat, heart, home, school, finale }

    @State private var page = Page.hello
    @State private var reading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var partner: String { partnerName.isEmpty ? "Partnerin" : partnerName }
    private var hasLetter: Bool { letters.partners != nil }

    var body: some View {
        ScreenScaffold {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page != .finale {
                        Button("Geç") { go(.finale) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Room.ink3)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, screenMargin)

                TabView(selection: $page) {
                    ForEach(Page.allCases, id: \.self) { page in
                        ScrollView { content(for: page).padding(.bottom, 12) }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollIndicators(.hidden)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                dots.padding(.vertical, 14)
                Button(action: advance) {
                    Text(buttonTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Room.cream)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Room.sage, in: Capsule())
                }
                .buttonStyle(Pressable())
                .padding(.horizontal, screenMargin)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $reading, onDismiss: done) {
            if let letter = letters.partners {
                LetterView(letter: letter, from: partner) { reading = false }
                    .onAppear { letters.markOpened() }
            }
        }
    }

    private var buttonTitle: String {
        switch page {
        case .finale: return hasLetter ? "Notu aç" : "Başlayalım"
        default: return "Devam"
        }
    }

    private func advance() {
        if page == .finale {
            if hasLetter { reading = true } else { done() }
        } else if let next = Page(rawValue: page.rawValue + 1) {
            go(next)
        }
    }

    private func go(_ next: Page) {
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) { page = next }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Page.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == page ? Room.sage : Room.rule)
                    .frame(width: item == page ? 18 : 7, height: 7)
            }
        }
        .animation(RelationshipMotion.resolve(RelationshipMotion.softSmall, reduceMotion: reduceMotion), value: page)
        .accessibilityElement()
        .accessibilityLabel("Sayfa \(page.rawValue + 1) / \(Page.allCases.count)")
    }

    @ViewBuilder
    private func content(for page: Page) -> some View {
        switch page {
        case .hello:
            slide(meta: partnerName.isEmpty ? "Watchlink" : "\(partnerName) seni bekliyordu",
                  headline: myName.isEmpty ? "Hoş geldin." : "Hoş geldin,\n\(myName).",
                  body: "Bu hat artık ikinizin. Sadece iki telefon arasında, sessiz ve şifreli. Birkaç küçük şeyi göstereyim.") {
                HelloScene(me: String(myName.prefix(1)), partner: String(partnerName.prefix(1)))
            }
        case .chat:
            slide(meta: "Sohbet", headline: "Konuşun.",
                  body: "Yaz, fotoğraf gönder ya da mikrofona basılı tutup sesli not bırak. Bir mesaja uzun basınca tepki verebilir ya da yanıtlayabilirsin.") {
                ChatScene(partner: partner)
            }
        case .heart:
            slide(meta: "Kalp atışı", headline: "Kalbini gönder.",
                  body: "Sohbetteki kalp tuşu kalp atışını gönderir. Gelen kalbe dokununca telefon onun ritmiyle atar. Biz sekmesinde onunki hep yanında: zorlandığında dokun.") {
                HeartScene()
            }
        case .home:
            slide(meta: "Ana sayfa", headline: "Gününüz bir bakışta.",
                  body: "Ana sayfa ikinizin haftasını yan yana koyar: sınavlar, teslimler, kim derste, ne zaman ikiniz de boşsunuz. Takvimini paylaşmak tek dokunuş.") {
                HomeScene(partner: partner)
            }
        case .school:
            slide(meta: "Okul", headline: "Okul da burada.",
                  body: "Biz sekmesinden ders programını SIS'teki PDF ile yükle: dersten önce sorar, devamsızlığını sayar. Mail Özeti de okul maillerinden önemlileri ayıklar.") {
                SchoolScene()
            }
        case .finale:
            if hasLetter {
                slide(meta: "Son bir şey", headline: "\(partner) sana\nbir not bıraktı.",
                      body: "Bir kez burada açılır, sonra Biz sekmesinde durur.") {
                    EnvelopeScene()
                }
            } else {
                slide(meta: "Hepsi bu", headline: "Hazırsınız.",
                      body: "Her şey iki telefonunuz arasında uçtan uca şifreli; sunucu bile okuyamaz. Bu tanıtımı Biz sekmesinden yeniden açabilirsin.") {
                    HelloScene(me: String(myName.prefix(1)), partner: String(partnerName.prefix(1)), together: true)
                }
            }
        }
    }

    private func slide<Scene: View>(meta: String, headline: String, body: String,
                                    @ViewBuilder scene: () -> Scene) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            scene()
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .padding(.horizontal, screenMargin)
                .padding(.top, 8)
            HeadlineBlock(meta: meta, headline: headline)
            Text(body)
                .font(.body)
                .foregroundStyle(Room.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, screenMargin)
                .padding(.top, 14)
        }
    }
}

// MARK: - Scenes

/// Scenes move gently and settle; still under Reduce Motion and in the UI tour
/// (it waits for an idle screen).
private struct SceneMotion {
    static func on(_ reduceMotion: Bool) -> Bool {
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
        return !reduceMotion
    }
}

private struct HelloScene: View {
    let me: String
    let partner: String
    var together = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Room.mist.opacity(0.7)).frame(width: 220, height: 220).scaleEffect(breathe ? 1.06 : 0.96)
            Circle().stroke(Room.sage.opacity(0.18), lineWidth: 1).frame(width: 250, height: 250).scaleEffect(breathe ? 1.02 : 0.98)
            PairMonogram(partner: partner, me: me, size: together ? 104 : 96)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard SceneMotion.on(reduceMotion) else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

private struct ChatScene: View {
    let partner: String
    @State private var shown = 0
    @State private var wave = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bubble("Vize nasıl geçti?", mine: false).opacity(shown > 0 ? 1 : 0).offset(y: shown > 0 ? 0 : 12)
            bubble("İyi geçti sanki 🙂 Akşam anlatırım", mine: true).opacity(shown > 1 ? 1 : 0).offset(y: shown > 1 ? 0 : 12)
            voice.opacity(shown > 2 ? 1 : 0).offset(y: shown > 2 ? 0 : 12)
        }
        .padding(18)
        .frame(maxWidth: 340)
        .wlCard(radius: 26)
        .accessibilityHidden(true)
        .task {
            guard SceneMotion.on(reduceMotion) else { shown = 3; return }
            for step in 1...3 {
                try? await Task.sleep(for: .milliseconds(step == 1 ? 250 : 650))
                withAnimation(RelationshipMotion.soft) { shown = step }
            }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { wave = true }
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Room.ink)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(mine ? Room.mine : Room.linen.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var voice: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(Room.cream)
                .frame(width: 30, height: 30)
                .background(Room.sage, in: Circle())
            HStack(spacing: 3) {
                ForEach(0..<18, id: \.self) { index in
                    let base = [0.35, 0.6, 0.9, 0.5, 0.75, 0.4, 1, 0.55][index % 8]
                    Capsule()
                        .fill(Room.sage.opacity(0.55))
                        .frame(width: 3, height: 22 * (wave ? base : 1 - base * 0.6))
                }
            }
            Text("0:07").font(.caption.monospacedDigit()).foregroundStyle(Room.ink3)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Room.mine, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct HeartScene: View {
    @State private var beat = false
    @State private var trace: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 74))
                .foregroundStyle(Room.sage)
                .scaleEffect(beat ? 1.12 : 1)
                .frame(maxWidth: 300)
                .frame(height: 150)
                .background(Room.mist, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Pulse()
                .trim(from: 0, to: trace)
                .stroke(Room.sage, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 260, height: 44)
            Text("72 bpm").font(.footnote.monospacedDigit()).foregroundStyle(Room.ink3)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard SceneMotion.on(reduceMotion) else { trace = 1; return }
            withAnimation(.easeOut(duration: 0.3).repeatForever(autoreverses: true)) { beat = true }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { trace = 1 }
        }
    }

    /// One ECG-like line: flat, a lub-dub spike, flat.
    private struct Pulse: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let mid = rect.midY, w = rect.width, h = rect.height
            path.move(to: CGPoint(x: 0, y: mid))
            for (x, y) in [(0.30, 0.0), (0.36, -0.15), (0.40, 0.0), (0.45, 0.0), (0.49, -0.5), (0.53, 0.5),
                           (0.57, -0.1), (0.62, 0.0), (0.70, 0.0), (0.75, -0.12), (0.80, 0.0), (1.0, 0.0)] {
                path.addLine(to: CGPoint(x: w * x, y: mid + h * y))
            }
            return path
        }
    }
}

private struct HomeScene: View {
    let partner: String
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Room.sage).frame(width: 8, height: 8)
                Text("\(partner) derste · PHYS 102").font(.subheadline.weight(.semibold)).foregroundStyle(Room.sageDeep)
                Spacer(minLength: 0)
                Text("11.40'a kadar").font(.caption).foregroundStyle(Room.ink3)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .wlCard(radius: 18)
            .offset(y: lifted ? 0 : 10).opacity(lifted ? 1 : 0)

            VStack(alignment: .leading, spacing: 10) {
                Text("Bu hafta").font(.footnote.weight(.semibold)).foregroundStyle(Room.sage)
                row(initial: String(partner.prefix(1)), title: "EE204 Vize", when: "Bugün 14.00", partner: true)
                row(initial: "", title: "Proje teslimi", when: "Yarın 23.59", partner: false)
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption)
                    Text("Cuma 15.00'ten sonra ikiniz de boşsunuz").font(.caption)
                }
                .foregroundStyle(Room.ink2)
            }
            .padding(16)
            .wlCard(radius: 22)
            .offset(y: lifted ? 0 : 18).opacity(lifted ? 1 : 0)
        }
        .frame(maxWidth: 340)
        .accessibilityHidden(true)
        .onAppear {
            guard SceneMotion.on(reduceMotion) else { lifted = true; return }
            withAnimation(RelationshipMotion.soft.delay(0.15)) { lifted = true }
        }
    }

    private func row(initial: String, title: String, when: String, partner: Bool) -> some View {
        HStack(spacing: 10) {
            Monogram(initial: initial, size: 24, partner: partner)
            Text(title).font(.subheadline).foregroundStyle(Room.ink)
            Spacer(minLength: 0)
            Text(when).font(.caption).foregroundStyle(Room.ink3)
        }
    }
}

private struct SchoolScene: View {
    @State private var dropped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(Room.sage)
                    Text("EE 303 · 10.00").font(.subheadline.weight(.semibold)).foregroundStyle(Room.ink)
                    Spacer(minLength: 0)
                    Text("10 dk sonra").font(.caption).foregroundStyle(Room.ink3)
                }
                Text("Derse gidiyor musun?").font(.subheadline).foregroundStyle(Room.ink2)
                HStack(spacing: 6) {
                    chip("Gidiyorum", filled: true)
                    chip("Gitmiyorum", filled: false)
                    chip("Ders iptal", filled: false)
                }
            }
            .padding(14)
            .wlCard(radius: 20)
            .offset(y: dropped ? 0 : -14).opacity(dropped ? 1 : 0)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.badge").foregroundStyle(Room.noticeInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Önemli").font(.caption.weight(.semibold)).foregroundStyle(Room.noticeInk)
                    Text("EE 303 vize salonu B201 oldu").font(.subheadline).foregroundStyle(Room.ink)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .wlCard(radius: 20)
            .offset(y: dropped ? 0 : 14).opacity(dropped ? 1 : 0)
        }
        .frame(maxWidth: 340)
        .accessibilityHidden(true)
        .onAppear {
            guard SceneMotion.on(reduceMotion) else { dropped = true; return }
            withAnimation(RelationshipMotion.soft.delay(0.15)) { dropped = true }
        }
    }

    private func chip(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(filled ? Room.cream : Room.sageDeep)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(filled ? Room.sage : Room.control, in: Capsule())
    }
}

/// A closed envelope, waiting. The seal breathes once in a while.
private struct EnvelopeScene: View {
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Room.paper)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Room.ink.opacity(0.06)))
                .shadow(color: Room.ink.opacity(0.10), radius: 18, y: 14)
            Flap()
                .fill(Room.linen)
                .overlay(Flap().stroke(Room.ink.opacity(0.06)))
            Circle()
                .fill(Room.sage)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(Room.cream))
                .offset(y: 8)
        }
        .frame(width: 240, height: 160)
        .rotationEffect(.degrees(float ? -1.5 : 1.5))
        .offset(y: float ? -5 : 5)
        .accessibilityHidden(true)
        .onAppear {
            guard SceneMotion.on(reduceMotion) else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { float = true }
        }
    }

    private struct Flap: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 6, y: rect.minY + 4))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 14))
            path.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.minY + 4))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - The note

/// The partner's note on paper: serif, unhurried, signed.
struct LetterView: View {
    let letter: SealedLetter
    let from: String
    let close: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScreenScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(letter.text)
                        .font(.system(.title3, design: .serif))
                        .lineSpacing(6)
                        .foregroundStyle(Room.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Text("— \(from)").wlWhisper(size: 19).foregroundStyle(Room.ink2)
                    }
                    Text(letter.at.formatted(.dateTime.day().month(.wide).year()))
                        .font(.caption)
                        .foregroundStyle(Room.ink3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(26)
                .wlCard(radius: 22)
                .padding(.horizontal, screenMargin)
                .padding(.top, 64)
                .offset(y: shown ? 0 : RelationshipMotion.letterRise)
                .opacity(shown ? 1 : 0)
                .padding(.bottom, 24)
            }
            // Always in reach, however long the note or large the text.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: close) {
                    Text("Kapat")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Room.sageDeep)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Room.control, in: Capsule())
                }
                .buttonStyle(Pressable())
                .padding(.horizontal, screenMargin)
                .padding(.vertical, 14)
                .background(Room.cream)
            }
        }
        .onAppear {
            withAnimation(RelationshipMotion.resolve(RelationshipMotion.softHero, reduceMotion: reduceMotion)) { shown = true }
        }
    }
}

/// Writing my note. It can be written before pairing; it goes to whoever I pair with.
struct LetterComposer: View {
    let letters: LetterBox
    let partnerName: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScreenScaffold {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(partnerName.isEmpty
                             ? "Notun, partnerin uygulamayı ilk açtığında karşılamanın sonunda çıkar. Sonra Biz sekmesinde durur."
                             : "Notun, \(partnerName) uygulamayı ilk açtığında karşılamanın sonunda çıkar. Sonra Biz sekmesinde durur.")
                            .font(.subheadline)
                            .foregroundStyle(Room.ink2)
                        TextEditor(text: $text)
                            .focused($focused)
                            .font(.system(.body, design: .serif))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 280)
                            .padding(14)
                            .wlCard(radius: 20)
                            .onChange(of: text) { _, value in
                                if value.count > LetterBox.maxLength { text = String(value.prefix(LetterBox.maxLength)) }
                            }
                        HStack {
                            Text("Uçtan uca şifreli; yalnızca onun telefonunda açılır.")
                            Spacer()
                            Text("\(text.count)/\(LetterBox.maxLength)").monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(Room.ink3)
                        if letters.mine != nil {
                            Button("Notu sil", role: .destructive) { letters.save(""); dismiss() }
                                .font(.subheadline)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, screenMargin)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Ona bir not")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { letters.save(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            text = letters.mine?.text ?? ""
            focused = text.isEmpty
        }
    }
}
