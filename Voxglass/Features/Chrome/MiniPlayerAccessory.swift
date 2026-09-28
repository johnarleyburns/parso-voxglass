import SwiftUI
import VoxglassCore

struct MiniPlayerAccessory: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MiniPlayerPresentationRouter.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let session = playback.currentSession,
           router.shouldShowMiniPlayer(currentBookID: session.book.id) {
            HStack(spacing: 10) {
                Button {
                    router.presentNowPlayingFromMiniPlayer(currentBookID: session.book.id)
                } label: {
                    HStack(spacing: 10) {
                        CoverPlate(title: session.book.title, author: session.book.authorLine, coverURL: session.book.coverURL, size: placement == .inline ? 28 : 32, shape: .circle)
                        titleText(session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                Spacer(minLength: 4)
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("chrome.miniPlayer.playPause")
                if placement == .expanded {
                    Button { Task { await playback.skipToNextChapter() } } label: {
                        Image(systemName: SkipSymbol.forward(30))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward")
                    .accessibilityIdentifier("chrome.miniPlayer.skipForward")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: placement == .inline ? 50 : 60)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("chrome.miniPlayer")
            .accessibilityElement(children: .contain)
        } else {
            // Keep the accessory structurally registered (which avoids the iOS
            // launch loop) without leaving an empty capsule on non-player tabs.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func titleText(_ session: PlaybackSession) -> some View {
        Text(session.book.title)
            .voxType(.body)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
    }
}
