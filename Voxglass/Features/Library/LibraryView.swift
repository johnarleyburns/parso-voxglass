import SwiftUI

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
            SectionTitle(title: "My Audiobooks", subtitle: "On This Device")

            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "No Audiobooks Yet",
                    message: "Search LibriVox or add an Internet Archive URL from Explore to build your shelf. Everything you play is cached here automatically.",
                    systemImage: "books.vertical"
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(libraryStore.books) { book in
                        NavigationLink {
                            BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                        } label: {
                            CompactBookRowView(
                                book: book,
                                sourceTitle: libraryStore.source(for: book.book)?.title
                            )
                            .overlay(alignment: .topTrailing) {
                                if offlineManager.state(for: book.book.id) == .cached {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.brass)
                                        .padding(6)
                                }
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
