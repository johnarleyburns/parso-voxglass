import SwiftUI

struct WatchNowPlayingView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        ScrollView { VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8).fill(.blue.gradient).frame(width: 40, height: 40).overlay(Image(systemName: "book.closed")).accessibilityIdentifier("watch.player.artwork")
            Text(services.playbackBook?.title ?? "Nothing playing").font(.caption).lineLimit(1).accessibilityIdentifier("watch.player.title")
            Text(chapterTitle).font(.caption2).lineLimit(1).accessibilityIdentifier("watch.player.chapter")
            HStack(spacing: 2) {
                Button { services.previousChapter() } label: { Image(systemName: "backward.end.fill") }.frame(width: 44, height: 44).disabled(!services.playback.canGoPrevious).accessibilityLabel("Previous chapter").accessibilityIdentifier("watch.player.previousChapter")
                Button { services.togglePlayPause() } label: { Image(systemName: services.playback.isActuallyPlaying ? "pause.fill" : "play.fill") }.frame(width: 44, height: 44).disabled(transportBusy).accessibilityLabel(services.playback.isActuallyPlaying ? "Pause" : "Play").accessibilityIdentifier("watch.player.playPause")
                Button { services.nextChapter() } label: { Image(systemName: "forward.end.fill") }.frame(width: 44, height: 44).disabled(!services.playback.canGoNext).accessibilityLabel("Next chapter").accessibilityIdentifier("watch.player.nextChapter")
            }.frame(maxWidth: .infinity)
            Text("Apple Watch").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("watch.player.output")
            Text(services.playback.statusText).font(.caption2).foregroundStyle(statusColor).lineLimit(2).accessibilityIdentifier("watch.player.phase")
            if indeterminateProgress {
                ProgressView().accessibilityIdentifier("watch.player.progress")
            } else {
                ProgressView(value: services.playback.progress).accessibilityIdentifier("watch.player.progress")
            }
            HStack {
                Text(format(services.playback.position)).accessibilityIdentifier("watch.player.elapsed")
                Spacer()
                Text("−\(format(max(0, services.playback.duration - services.playback.position)))").accessibilityIdentifier("watch.player.remaining")
            }.font(.caption2).monospacedDigit()
            Text(services.playback.sourceKind == .downloaded ? "Downloaded" : services.playback.sourceKind == .stream ? "Streaming" : "")
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("watch.player.source")
            if case .failed = services.playback.phase {
                Button("Retry") { services.retryPlayback() }.accessibilityIdentifier("watch.player.retry")
            }
        }.padding(.horizontal, 8) }.navigationTitle("").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("watch.nowPlaying")
    }

    private var chapterTitle: String {
        guard let book = services.playbackBook, book.chapters.indices.contains(services.playback.chapterIndex) else { return "" }
        return book.chapters[services.playback.chapterIndex].title
    }

    private var transportBusy: Bool {
        switch services.playback.phase {
        case .idle, .preparing, .waitingForOutput: true
        default: false
        }
    }

    private var indeterminateProgress: Bool {
        switch services.playback.phase {
        case .idle, .preparing, .waitingForOutput, .buffering: true
        default: false
        }
    }

    private var statusColor: Color {
        if case .failed = services.playback.phase { return .red }
        return .secondary
    }

    private func format(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
