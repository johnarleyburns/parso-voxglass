import SwiftUI
import VoxglassCore

struct WatchBookDetailView: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices
    @State private var showNowPlaying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Cover placeholder
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

                // Action buttons
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
                                // Initiate download/transfer
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text("Download")
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.bookFetch)
                    }

                    Button {
                        // Add to My Books (import)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("Add to My Books")
                        }
                    }
                    .accessibilityIdentifier(WatchAccessibilityID.bookAdd)

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
