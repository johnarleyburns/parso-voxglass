import SwiftUI
import VoxglassCore

struct WatchSettingsView: View {
    @EnvironmentObject var services: WatchAppServices
    @ObservedObject private var relay = WatchAudioRelay.shared
    @State private var isClearingCache = false
    @State private var isRefreshing = false

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

                Text("iPhone")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    syncDetail("Status", relay.isReachable ? "Reachable" : (relay.isCompanionAppInstalled ? "Not reachable" : "Not paired"))
                    syncDetail("My Books", "\(services.phoneBooks.count) from iPhone")
                    if let error = services.watchError ?? relay.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }

                    if isRefreshing {
                        ProgressView("Refreshing...")
                    } else {
                        Button {
                            Task {
                                isRefreshing = true
                                await services.refreshFromPhone()
                                await services.refreshLocalLibrary()
                                isRefreshing = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh from iPhone")
                            }
                        }
                    }
                }

                Divider()

                Text("Downloads")
                    .font(.headline)

                ForEach(services.books) { book in
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
                                Task { await services.downloadBook(book) }
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

    @ViewBuilder
    private func syncDetail(_ label: String, _ value: String) -> some View {
        HStack {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
        }
    }
}
