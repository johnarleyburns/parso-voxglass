import SwiftUI

struct WatchNowPlayingView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        ScrollView { VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10).fill(.blue.gradient).frame(width: 88, height: 88).overlay(Image(systemName: "book.closed")).accessibilityIdentifier("watch.player.artwork")
            Text(services.playing?.book.title ?? "Nothing playing").font(.caption).lineLimit(2).accessibilityIdentifier("watch.player.title")
            Text(services.playing.map { $0.book.chapters[$0.chapterIndex].title } ?? "").font(.caption2).lineLimit(1).accessibilityIdentifier("watch.player.chapter")
            Text("Apple Watch").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("watch.player.output")
            ProgressView(value: 0.25).accessibilityIdentifier("watch.player.elapsed")
            HStack(spacing: 2) {
                Button { services.previousChapter() } label: { Image(systemName: "backward.end.fill") }.frame(width: 44, height: 44).accessibilityLabel("Previous chapter").accessibilityIdentifier("watch.player.previousChapter")
                Button { services.togglePlayPause() } label: { Image(systemName: services.playing?.isPlaying == true ? "pause.fill" : "play.fill") }.frame(width: 44, height: 44).accessibilityLabel(services.playing?.isPlaying == true ? "Pause" : "Play").accessibilityIdentifier("watch.player.playPause")
                Button { services.nextChapter() } label: { Image(systemName: "forward.end.fill") }.frame(width: 44, height: 44).accessibilityLabel("Next chapter").accessibilityIdentifier("watch.player.nextChapter")
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 8) }.navigationTitle("").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("watch.nowPlaying")
    }
}
