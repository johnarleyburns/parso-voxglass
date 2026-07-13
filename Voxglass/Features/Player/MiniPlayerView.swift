import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let session = playback.currentSession {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    BookArtworkView(title: session.book.title, size: 38, coverURL: session.book.coverURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.book.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(VoxglassTheme.ink)
                            .lineLimit(1)
                        Text(session.chapter.title)
                            .font(.caption)
                            .foregroundStyle(VoxglassTheme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .scaledFont(size: 16, weight: .bold)
                            .frame(width: 42, height: 42)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Circle().fill(VoxglassTheme.ink))
                    .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                }
                .padding(10)
                .glassPanel()
            }
            .buttonStyle(.plain)
        }
    }
}
