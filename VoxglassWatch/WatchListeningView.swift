import SwiftUI
import VoxglassCore

struct WatchListeningView: View {
    @EnvironmentObject var services: WatchAppServices
    @State private var books: [BookWithChapters] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading")
            } else if books.isEmpty {
                VStack(spacing: 8) {
                    Text("No Books")
                        .font(.headline)
                    Text("Add books from the iOS app or search LibriVox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                List(books) { book in
                    NavigationLink {
                        WatchBookDetailView(book: book)
                            .accessibilityIdentifier(WatchAccessibilityID.bookDetail)
                    } label: {
                        WatchBookRow(book: book)
                    }
                }
                .accessibilityIdentifier(WatchAccessibilityID.rootListening)
            }
        }
        .task {
            await services.bootstrap()
            books = services.libraryStore.books
            isLoading = false
        }
    }
}

struct WatchBookRow: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.book.title)
                .font(.headline)
                .lineLimit(2)
            if let narrator = book.book.narratorLine {
                Text(narrator)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                if let duration = book.totalDuration {
                    Text(WatchTimeFormat.duration(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                let info = services.offlineManager.storageInfo(for: book.book.id)
                if info.state == .available {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
