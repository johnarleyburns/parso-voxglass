import SwiftUI
import VoxglassCore

struct WatchBookDetailView: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices
    @State private var showNowPlaying = false
    @State private var playbackError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 40, height: 40)

                Text(book.book.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(book.book.authorLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let narrator = book.book.narratorLine {
                    Text(narrator)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if let duration = book.totalDuration {
                        Label(WatchTimeFormat.duration(duration), systemImage: "clock")
                    }
                    Label("\(book.chapters.count) ch", systemImage: "list.number")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(WatchAccessibilityID.bookMeta)

                if let summary = book.book.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(10)
                }

                VStack(spacing: 8) {
                    Button {
                        Task {
                            await services.playbackCoordinator.play(book)
                            if services.playbackCoordinator.currentSession?.isPlaying == true {
                                showNowPlaying = true
                            } else {
                                playbackError = services.playbackCoordinator.playbackError
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.bookStream)

                    if let playbackError {
                        Text(playbackError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(4)
                    }

                    let info = services.offlineManager.storageInfo(for: book.book.id)
                    if info.state == .notAvailable {
                        Button {
                            Task { await services.downloadBook(book) }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text("Download")
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.bookFetch)
                    } else {
                        Button {
                            Task {
                                await services.offlineManager.deleteOffline(bookID: book.book.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "trash.circle")
                                Text("Remove Download")
                            }
                        }
                    }

                    NavigationLink {
                        WatchChaptersView(book: book, onChapterSelected: { chapter in
                            Task {
                                await services.playbackCoordinator.play(book, chapter: chapter)
                                if services.playbackCoordinator.currentSession?.isPlaying == true {
                                    showNowPlaying = true
                                } else {
                                    playbackError = services.playbackCoordinator.playbackError
                                }
                            }
                        })
                            .accessibilityIdentifier(WatchAccessibilityID.chaptersList)
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet")
                            Text("Chapters")
                        }
                    }
                }

                NavigationLink(destination: WatchNowPlayingView(), isActive: $showNowPlaying) {
                    EmptyView()
                }
                .hidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier(WatchAccessibilityID.bookDetail)
    }
}
