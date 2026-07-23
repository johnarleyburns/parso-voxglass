import SwiftUI
import VoxglassCore

struct WatchOnDeviceView: View {
    @EnvironmentObject var services: WatchAppServices

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Storage")
                        .font(.caption)
                    Spacer()
                    Text(WatchTimeFormat.duration(Double(services.offlineManager.totalBytes)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Books")
                        .font(.caption)
                    Spacer()
                        Text("\(services.offlineManager.totalBookCount)/\(WatchStoragePolicy.maxBooks)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On Watch")
            }

            Section {
                if services.offlineManager.onWatchBooks.isEmpty {
                    Text("No books downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(services.offlineManager.onWatchBooks.keys), id: \.self) { bookID in
                        if let book = services.libraryStore.books.first(where: { $0.book.id == bookID }) {
                            WatchOnDeviceRow(book: book)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(WatchAccessibilityID.rootOnWatch)
    }
}

struct WatchOnDeviceRow: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices

    var body: some View {
        let info = services.offlineManager.storageInfo(for: book.book.id)
        VStack(alignment: .leading, spacing: 2) {
            Text(book.book.title)
                .font(.caption)
                .lineLimit(1)
            HStack {
                if info.byteCount > 0 {
                    Text(WatchTimeFormat.duration(Double(info.byteCount)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch info.state {
                case .available:
                    Text("Ready")
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .transferring(let progress):
                    ProgressView(value: progress)
                        .frame(width: 40)
                case .failed:
                    Text("Failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                case .waitingForPhone:
                    Text("Phone needed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .queued:
                    Text("Queued")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .notAvailable:
                    EmptyView()
                }
            }
        }
    }
}
