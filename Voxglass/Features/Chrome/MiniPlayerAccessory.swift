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
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.book.title).voxType(.body).lineLimit(1)
                            if placement == .expanded {
                                Text(session.chapter.title).voxType(.eyebrow).lineLimit(1)
                                Text(remainingText(session)).voxType(.timecode).foregroundStyle(Palette.ink2)
                            }
                        }
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
            .frame(minHeight: placement == .inline ? 44 : 60)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("chrome.miniPlayer")
            .accessibilityElement(children: .contain)
        }
    }

    private func remainingText(_ session: PlaybackSession) -> String {
        guard let duration = session.duration else { return "" }
        return "\(TimeFormatting.clock(max(duration - session.position, 0))) left"
    }
}
