import SwiftUI
import VoxglassCore

struct WatchNowPlayingView: View {
    @EnvironmentObject var services: WatchAppServices
    private var session: PlaybackSession? { services.playbackCoordinator.currentSession }
    private var position: TimeInterval { session?.position ?? 0 }
    private var duration: TimeInterval { session?.duration ?? 0 }
    private var playing: Bool { session?.isPlaying ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                AsyncImage(url: session?.book.coverURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.3))
                }
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("watch.player.artwork")
                Text(session?.book.title ?? "Nothing playing").font(.caption).lineLimit(2)
                    .accessibilityIdentifier("watch.player.title")
                Text(session?.chapter.title ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("watch.player.chapter")
                Text("Apple Watch").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.player.output")
                ProgressView(value: duration > 0 ? position / duration : 0)
                    .accessibilityLabel("Playback progress")
                HStack {
                    Text(WatchTimeFormat.time(position)).monospacedDigit().accessibilityIdentifier("watch.player.elapsed")
                    Spacer()
                    Text("-\(WatchTimeFormat.time(max(duration - position, 0)))").monospacedDigit().accessibilityIdentifier("watch.player.remaining")
                }.font(.caption2)
                HStack(spacing: 2) {
                    Button { Task { await services.playbackCoordinator.previousChapter() } } label: { Image(systemName: "backward.end.fill") }
                        .frame(width: 44, height: 44).accessibilityLabel("Previous chapter")
                        .accessibilityIdentifier("watch.player.previousChapter")
                        .disabled(!services.playbackCoordinator.canGoToPreviousChapter)
                    Button { services.playbackCoordinator.togglePlayPause() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3) }
                        .frame(width: 44, height: 44).accessibilityLabel(playing ? "Pause" : "Play")
                        .accessibilityIdentifier("watch.player.playPause")
                    Button { Task { await services.playbackCoordinator.nextChapter() } } label: { Image(systemName: "forward.end.fill") }
                        .frame(width: 44, height: 44).accessibilityLabel("Next chapter")
                        .accessibilityIdentifier("watch.player.nextChapter")
                        .disabled(!services.playbackCoordinator.canGoToNextChapter)
                }.frame(maxWidth: .infinity).accessibilitySortPriority(2)
                if let error = services.playbackCoordinator.playbackError {
                    Text(error).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 8).padding(.vertical, 4)
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("watch.nowPlaying")
    }
}
