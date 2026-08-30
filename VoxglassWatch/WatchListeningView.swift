import SwiftUI
import VoxglassCore

struct WatchListeningView: View {
    @EnvironmentObject var services: WatchAppServices

    var body: some View {
        Group {
            if services.visibleBooks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                    Text(services.isConnected ? "No Books" : "No downloaded books")
                        .font(.headline)
                    Text(services.isConnected ? "Add books in My Books on iPhone" : "In My Books on iPhone, choose Download to Apple Watch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let error = services.watchError {
                        Divider()
                        Label("Connection", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                List(services.visibleBooks) { book in
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
        .navigationTitle("My Books")
        .safeAreaInset(edge: .top) {
            HStack(spacing: 5) {
                Circle().fill(services.isConnected ? .green : .orange).frame(width: 7, height: 7)
                Text(services.isConnected ? "iPhone connected" : "On This Watch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(WatchAccessibilityID.connection)
            .accessibilityLabel(services.isConnected ? "iPhone connected" : "iPhone unavailable. On This Watch")
        }
    }
}

/// A clean, title-only row for the My Books list. A downloaded book gets a small
/// green dot so offline availability is glanceable without cluttering the title.
struct WatchBookRow: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices

    var body: some View {
        HStack(spacing: 6) {
            Text(book.book.title)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
            if services.offlineManager.storageInfo(for: book.book.id).state == .available {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded on Apple Watch")
            } else if services.isConnected {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Download to Apple Watch")
            }
        }
        .padding(.vertical, 4)
    }
}
