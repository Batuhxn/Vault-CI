#if DEBUG
// Legacy plaintext LAN demo; excluded from Release and unreachable from WatchlinkRootView.
import SwiftUI

/// A single message row: the coloured bubble plus its timestamp, pushed to the
/// trailing edge for own messages and the leading edge for received ones.
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isMine {
                Spacer(minLength: 60)
            }

            VStack(
                alignment: message.isMine ? .trailing : .leading,
                spacing: 4
            ) {
                Text(message.text)
                    .foregroundStyle(message.isMine ? .black : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                message.isMine
                                ? Color.white
                                : Color.white.opacity(0.10)
                            )
                    )

                Text(message.time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !message.isMine {
                Spacer(minLength: 60)
            }
        }
    }
}

#endif
