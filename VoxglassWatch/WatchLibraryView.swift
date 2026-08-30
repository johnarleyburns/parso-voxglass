import SwiftUI
import VoxglassWatchProtocol

struct WatchLibraryView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        Group {
            if services.visibleBooks.isEmpty {
                VStack(spacing: 8) { Image(systemName: "arrow.down.circle").font(.title2); Text("No downloaded books").font(.headline); Text("In My Books on iPhone, choose Download to Apple Watch.").font(.caption).multilineTextAlignment(.center) }
                    .accessibilityIdentifier("watch.empty.downloads")
            } else {
                List(services.visibleBooks, id: \.id) { book in
                    NavigationLink { WatchBookDetailView(book: book) } label: { WatchBookRow(book: book) }.accessibilityIdentifier("watch.book.\(book.id.rawValue)")
                }
                .accessibilityIdentifier("watch.library")
            }
        }
        .navigationTitle("My Books")
        .safeAreaInset(edge: .top) { HStack { Circle().fill(services.isConnected ? .green : .orange).frame(width: 7, height: 7); Text(services.isConnected ? "iPhone connected" : "On This Watch").font(.caption2) }.accessibilityIdentifier("watch.connection") }
    }
}

private struct WatchBookRow: View {
    let book: WatchBookDTO
    @EnvironmentObject private var services: WatchAppServices
    var body: some View { HStack { VStack(alignment: .leading) { Text(book.title).font(.headline).lineLimit(2); Text(book.author ?? "").font(.caption2).foregroundStyle(.secondary) }; Spacer(); Image(systemName: services.downloaded.contains(book.id) ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(services.downloaded.contains(book.id) ? .green : .secondary) } }
}
