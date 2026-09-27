#if DEBUG
// Legacy plaintext LAN demo; excluded from Release and unreachable from WatchlinkRootView.
import Foundation

/// A single chat message shown in the conversation.
///
/// `isMine` drives alignment and styling: `true` renders right-aligned in the
/// accent colour, `false` renders left-aligned in the muted colour.
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isMine: Bool
    let time: String
}

#endif
