import SwiftUI
import VoxglassCore

struct WatchSettingsView: View {
    @EnvironmentObject var services: WatchAppServices
    @State private var isClearingCache = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Storage")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Used: \(WatchTimeFormat.bytes(services.offlineManager.totalBytes))")
                        .font(.caption)
                    Text("Books: \(services.offlineManager.totalBookCount)/\(WatchStoragePolicy.maxBooks)")
                        .font(.caption)
                    Text("Limit: \(WatchTimeFormat.bytes(WatchStoragePolicy.maxBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                if isClearingCache {
                    ProgressView("Clearing cache...")
                } else {
                    Button(role: .destructive) {
                        Task {
                            isClearingCache = true
                            await services.offlineManager.clearAllCache()
                            isClearingCache = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Watch Cache")
                        }
                    }
                }

                Divider()

                Text("Sync")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("iCloud:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if services.syncEngine?.shouldSync == true {
                            Text("Synced")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Standalone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = services.syncEngine?.syncError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Divider()

                Text("Downloads")
                    .font(.headline)

                ForEach(services.libraryStore.books) { book in
                    let info = services.offlineManager.storageInfo(for: book.book.id)
                    HStack {
                        VStack(alignment: .leading) {
                            Text(book.book.title)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(info.chapterCount) chapters, \(WatchTimeFormat.bytes(info.byteCount))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if info.state == .available {
                            Button {
                                Task {
                                    await services.offlineManager.deleteOffline(bookID: book.book.id)
                                }
                            } label: {
                                Image(systemName: "trash.circle")
                            }
                        } else {
                            Button {
                                Task {
                                    await downloadBook(book)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding()
        }
        .navigationTitle("Settings")
    }

    private func downloadBook(_ book: BookWithChapters) async {
        for chapter in book.chapters {
            guard services.offlineManager.localURL(for: chapter) == nil else { continue }
            try? await services.offlineManager.downloadChapter(chapter, bookID: book.book.id)
        }
    }
}
