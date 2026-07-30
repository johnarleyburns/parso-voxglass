import SwiftUI
import VoxglassCore

struct WatchNowPlayingView: View {
    @EnvironmentObject var services: WatchAppServices
    @State private var showFetchStatus = false
    @State private var showChapters = false
    @State private var showSpeedSleep = false

    var session: PlaybackSession? {
        services.playbackCoordinator.currentSession
    }

    var currentPosition: TimeInterval {
        session?.position ?? 0
    }

    var duration: TimeInterval {
        session?.duration ?? 0
    }

    var isPlaying: Bool {
        session?.isPlaying ?? false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Cover
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 40, height: 40)

                // Title & Chapter
                VStack(spacing: 2) {
                    if let title = session?.book.title {
                        Text(title)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    if let chapterTitle = session?.chapter.title {
                        Text(chapterTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let narrator = session?.book.narratorLine {
                        Text(narrator)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(isPlaying ? "Playing" : "Paused")
                        .font(.caption2)
                        .foregroundStyle(isPlaying ? .green : .secondary)
                        .accessibilityIdentifier(WatchAccessibilityID.npState)
                }

                // Progress
                VStack(spacing: 2) {
                    ProgressView(value: duration > 0 ? currentPosition / duration : 0)
                        .tint(.accentColor)
                    HStack {
                        Text(WatchTimeFormat.time(currentPosition))
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        Text(WatchTimeFormat.time(duration))
                            .font(.caption2.monospacedDigit())
                    }
                }

                // Error display
                if let error = services.playbackCoordinator.playbackError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                // Transport controls
                HStack(spacing: 16) {
                    Button {
                        Task { await services.playbackCoordinator.skipBackward() }
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title3)
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.npBack15)

                    Button {
                        services.playbackCoordinator.togglePlayPause()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.npPlayPause)

                    Button {
                        Task { await services.playbackCoordinator.skipForward() }
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.title3)
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.npForward30)
                }
                .frame(height: 44)

                // Chapter navigation
                HStack(spacing: 24) {
                    Button {
                        Task { await services.playbackCoordinator.previousChapter() }
                    } label: {
                        Label("Previous", systemImage: "backward.end.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                    }
                    .disabled(!services.playbackCoordinator.canGoToPreviousChapter)
                    .accessibilityIdentifier(WatchAccessibilityID.npChapterPrev)

                    Button {
                        Task { await services.playbackCoordinator.nextChapter() }
                    } label: {
                        Label("Next", systemImage: "forward.end.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                    }
                    .disabled(!services.playbackCoordinator.canGoToNextChapter)
                    .accessibilityIdentifier(WatchAccessibilityID.npChapterNext)
                }
                .frame(height: 34)

                // Tool row
                HStack(spacing: 12) {
                    Button {
                        // Route picker
                    } label: {
                        Image(systemName: "airpodspro")
                            .font(.caption)
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.npRoute)

                    Button {
                        showSpeedSleep = true
                    } label: {
                        Image(systemName: "timer")
                            .font(.caption)
                    }

                    NavigationLink {
                        if let book = services.books.first(where: { $0.book.id == session?.book.id }) {
                            WatchChaptersView(book: book, onChapterSelected: { chapter in
                                Task {
                                    await services.playbackCoordinator.skipToChapter(chapter, in: book)
                                }
                            })
                            .accessibilityIdentifier(WatchAccessibilityID.chaptersList)
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.caption)
                    }

                    Button {
                        showFetchStatus = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                    }
                }
                .frame(height: 34)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showFetchStatus) {
            if let book = services.books.first(where: { $0.book.id == session?.book.id }) {
                WatchFetchStatusView(book: book)
            }
        }
        .sheet(isPresented: $showSpeedSleep) {
            WatchSpeedSleepView()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}
