import SwiftUI
import VoxglassCore

struct WatchListeningView: View {
    @EnvironmentObject var services: WatchAppServices

    var body: some View {
        Group {
            if services.books.isEmpty {
                VStack(spacing: 8) {
                    Text("No Books")
                        .font(.headline)
                    Text("Open Voxglass on iPhone or search LibriVox")
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
                List(services.books) { book in
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
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Downloaded")
            }
        }
        .padding(.vertical, 4)
    }
}
