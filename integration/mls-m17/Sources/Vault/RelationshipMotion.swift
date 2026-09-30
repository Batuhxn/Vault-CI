import SwiftUI

/// The whole motion vocabulary. Nothing outside this file names a duration.
/// `.smooth` is a zero-bounce spring, so every move settles and is retargetable mid-flight.
enum RelationshipMotion {
    /// Soft spring: surfaces, cards, composer resize, bubble insertion.
    static let soft = Animation.smooth(duration: 0.42)
    /// The Opening (Home surface -> Chat).
    static let softHero = Animation.smooth(duration: 0.52)
    /// Send control, corner joins, glyphs.
    static let softSmall = Animation.smooth(duration: 0.30)
    /// Slow ease: tone, brightness, Private Space darkening.
    static let slow = Animation.timingCurve(0.45, 0, 0.15, 1, duration: 0.75)
    /// The Door's halo, the only move allowed past 0.75 s.
    static let halo = Animation.timingCurve(0.45, 0, 0.15, 1, duration: 0.9)
    /// Micro response: touch-down and release.
    static let microIn = Animation.snappy(duration: 0.14)
    static let microOut = Animation.smooth(duration: 0.26)
    /// The Opening's proxy fading out once Chat is underneath it.
    static let handoff = Animation.smooth(duration: 0.12)

    /// Reduce Motion turns every move into a short crossfade in place.
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// Distances (pt): press drift, entrance rise, tab glide, Letter rise, Tuck drop.
    static let rise: CGFloat = 12
    static let glide: CGFloat = 24
    static let letterRise: CGFloat = 28
    static let tuckDrop: CGFloat = 64

    /// Pressed scale for surfaces and for 36–44 pt round controls.
    static let pressSurface: CGFloat = 0.985
    static let pressControl: CGFloat = 0.97

    /// Haptics: send, tab and the door only. Nothing else vibrates.
    static let sendFeedback = SensoryFeedback.impact(flexibility: .soft, intensity: 0.55)
    static let doorFeedback = SensoryFeedback.impact(flexibility: .soft, intensity: 0.4)
}

/// The one press style: a slight give on touch-down, no colour flash, no bounce.
struct Pressable: ButtonStyle {
    var scale: CGFloat = RelationshipMotion.pressSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .brightness(pressed ? -0.01 : 0)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(pressed ? RelationshipMotion.microIn : RelationshipMotion.microOut, value: pressed)
    }
}

extension AnyTransition {
    /// The Letter: a new bubble lifts out of the composer and settles.
    static func letter(mine: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .offset(y: mine ? RelationshipMotion.letterRise : RelationshipMotion.rise)
                .combined(with: .scale(scale: 0.97, anchor: mine ? .bottomTrailing : .bottomLeading))
                .combined(with: .opacity),
            removal: .opacity)
    }

    /// The Tuck: a resolved card drops behind the surface below it, shrinks slightly and merges.
    static var tuck: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -RelationshipMotion.rise)),
                    removal: .offset(y: RelationshipMotion.tuckDrop).combined(with: .scale(scale: 0.96)).combined(with: .opacity))
    }
}

extension View {
    /// Reduce Motion swaps any spatial transition for a plain crossfade.
    func wlTransition(_ transition: AnyTransition, reduceMotion: Bool) -> some View {
        self.transition(reduceMotion ? .opacity : transition)
    }

    /// Tab continuity: content glides in 24 pt from the side it lives on; the ground stays put.
    func tabEntrance(from direction: CGFloat) -> some View { modifier(TabEntrance(direction: direction)) }
}

private struct TabEntrance: ViewModifier {
    let direction: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Starts unsettled so the first frame is already offset; reset on disappear so every visit glides.
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .offset(x: settled || reduceMotion ? 0 : direction * RelationshipMotion.glide)
            .opacity(settled ? 1 : 0)
            .onAppear {
                guard direction != 0 else { settled = true; return }
                withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft.delay(0.06), reduceMotion: reduceMotion)) {
                    settled = true
                }
            }
            .onDisappear { settled = false }
    }
}
