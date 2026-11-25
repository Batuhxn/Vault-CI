import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// The Door. A preview only: no private content, no storage, no new crypto.
/// The shell animates one `progress` value; this layer turns it into a dark
/// halo that opens from the moon and closes back into it.
struct PrivateSpaceLayer: View {
    /// 0 = closed, 1 = open.
    let progress: CGFloat
    /// The moon's centre in global coordinates: the room changes around it.
    let anchor: CGPoint
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One reader for the whole layer (halo size); nothing per frame beyond transform/opacity.
        GeometryReader { geometry in
            let size = geometry.size
            let reach = hypot(size.width, size.height) * 2
            ZStack(alignment: .topLeading) {
                // The single allowed radial, centred on the moon. Static: only the mask moves.
                RadialGradient(colors: [Room.moss, Room.nightMid, Room.night],
                               center: UnitPoint(x: anchor.x / max(size.width, 1), y: anchor.y / max(size.height, 1)),
                               startRadius: 0, endRadius: max(size.width, size.height))
                preview
                    .padding(.horizontal, 28)
                    .padding(.top, size.height * 0.3)
                    .opacity(progress)
                    // Content arrives from the moon's direction.
                    .offset(x: reduceMotion ? 0 : 40 * (1 - progress), y: reduceMotion ? 0 : -40 * (1 - progress))
                Text("Dönmek için aya dokun ya da aşağı kaydır")
                    .font(.footnote)
                    .foregroundStyle(Room.nightSecondary.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 48)
                    .opacity(progress)
                moon.position(anchor)
            }
            .mask {
                if reduceMotion {
                    Rectangle()
                } else {
                    Circle()
                        .frame(width: reach, height: reach)
                        .scaleEffect(max(progress, 0.001))
                        .position(anchor)
                }
            }
            .opacity(reduceMotion ? progress : 1)
        }
        .ignoresSafeArea()
        // Leave by swiping down (or right from the edge), as well as by the moon.
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let down = value.translation.height > 90
                    let edgeRight = value.startLocation.x < 32 && value.translation.width > 80
                    if down || edgeRight { close() }
                }
        )
        .allowsHitTesting(progress > 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daha sessiz bir oda")
                .font(.footnote)
                .foregroundStyle(Room.nightSecondary)
            Text("Özel\nAlan.")
                .wlDisplay()
                .foregroundStyle(Room.nightText)
                .accessibilityAddTraits(.isHeader)
            Text("Watchlink içinde, sadece ikiniz arasında kalanlar için daha sessiz bir oda.")
                .font(.body)
                .foregroundStyle(Room.nightSecondary)
                .frame(maxWidth: 290, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Henüz açık değil")
                .font(.footnote)
                .foregroundStyle(Room.nightText.opacity(0.8))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(Capsule().stroke(Room.nightText.opacity(0.22), lineWidth: 1))
                .padding(.top, 8)
        }
    }

    /// The same moon, lit: it stays exactly where it was and leads back out.
    private var moon: some View {
        Button(action: close) {
            Image(systemName: "moon.fill")
                .font(.body)
                .foregroundStyle(Room.nightText)
                .frame(width: 40, height: 40)
                .background(Room.mist.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(Room.nightText.opacity(0.25), lineWidth: 1))
                .shadow(color: Room.sage.opacity(0.45 * progress), radius: 20)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
        .accessibilityLabel("Özel Alan'dan çık")
    }
}
