import SwiftUI
import VoxglassCore

struct WatchBookDetailView: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices
    @State private var showNowPlaying = false

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
                            showNowPlaying = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.bookStream)

                    let info = services.offlineManager.storageInfo(for: book.book.id)
                    if info.state == .notAvailable {
                        Button {
                            Task {
                                for chapter in book.chapters {
                                    guard services.offlineManager.localURL(for: chapter) == nil else { continue }
                                    try? await services.offlineManager.downloadChapter(chapter, bookID: book.book.id)
                                }
                            }
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
                        WatchChaptersView(book: book)
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
