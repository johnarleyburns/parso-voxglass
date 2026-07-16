import SwiftUI
import VoxglassCore

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @Binding var showingNowPlaying: Bool
    @State private var pendingDeletion: BookWithChapters?

    var body: some View {
        VoxglassScreen(title: "My Books") {
            VStack(alignment: .leading, spacing: 18) {
                bookList
            }
            .padding(.top, 12)
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                libraryStore.importError = nil
            }
        } message: {
            Text(libraryStore.importError ?? "")
        }
        .confirmationDialog(
            pendingDeletion.map { "Remove \"\($0.book.title)\" from My Books?" } ?? "",
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Remove from My Books", role: .destructive) {
                if let book = pendingDeletion {
                    Task { await libraryStore.delete(book: book) }
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This deletes the book and its cached audio from this device.")
        }
        .task {
            await libraryStore.refresh()
            await libraryStore.refreshRecentlyPlayed()
        }
    }

    @ViewBuilder
    private var bookList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "No Audiobooks Yet",
                    message: "Search LibriVox or add an Internet Archive URL from Explore to build your shelf. Everything you play is cached here automatically.",
                    systemImage: "books.vertical"
                )
            } else {
                offlinePinMeter
                filterSortBar
                VStack(spacing: 6) {
                    ForEach(libraryStore.visibleBooks) { book in
                        NavigationLink {
                            BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                        } label: {
                            CompactBookRowView(
                                book: book,
                                sourceTitle: libraryStore.source(for: book.book)?.title
                            )
                            .overlay(alignment: .topTrailing) {
                                downloadBadge(for: book.book.id)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from My Books", role: .destructive) {
                                pendingDeletion = book
                            }
                        }
                    }
                }
            }
        }
    }

    private var filterSortBar: some View {
        VStack(spacing: 10) {
            Picker("Filter", selection: Binding<LibraryBookFilter>(
                get: { libraryStore.filter },
                set: { libraryStore.filter = $0 }
            )) {
                Text("All").tag(LibraryBookFilter.all)
                Text("Favorites").tag(LibraryBookFilter.favorites)
                Text("In Progress").tag(LibraryBookFilter.inProgress)
                Text("Finished").tag(LibraryBookFilter.finished)
            }
            .pickerStyle(.segmented)
            .tint(Palette.brass)

            Picker("Sort", selection: Binding<LibrarySort>(
                get: { libraryStore.sort },
                set: { libraryStore.sort = $0 }
            )) {
                Text("Recent").tag(LibrarySort.recent)
                Text("Title").tag(LibrarySort.title)
                Text("Author").tag(LibrarySort.author)
                Text("Narrator").tag(LibrarySort.narrator)
            }
            .pickerStyle(.segmented)
            .tint(Palette.brass)
        }
    }

    @ViewBuilder
    private func downloadBadge(for bookID: UUID) -> some View {
        let state = offlineManager.state(for: bookID)
        switch state {
        case .cached:
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.brass)
                .padding(6)
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(Palette.ink3.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(Palette.brass, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .scaledFont(size: 7)
                    .foregroundStyle(Palette.brass)
            }
            .frame(width: 18, height: 18)
            .padding(6)
        case .notCached:
            Image(systemName: "arrow.down.circle")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.ink3)
                .padding(6)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.danger)
                .padding(6)
        }
    }

    @ViewBuilder
    private var offlinePinMeter: some View {
        if !StoreManager.shared.isPro {
            let used = OfflineDownloadManager.pinCount(states: offlineManager.state)
            HStack(spacing: 8) {
                Image(systemName: used >= 2 ? "tray.full.fill" : "tray.fill")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(used >= 2 ? Palette.ink3 : Palette.brass)
                Text("\(used) of 2 free downloads used")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(used >= 2 ? Palette.ink3 : Palette.brass)
                if used >= 2 {
                    Text("· Pro to pin more")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.brass)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding {
            pendingDeletion != nil
        } set: { isPresented in
            if !isPresented {
                pendingDeletion = nil
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                libraryStore.importError = nil
            }
        }
    }
}
