import SwiftUI
import VoxglassCore

/// Everything the user has ever listened to, most-recently-played first —
/// independent of whether a book was ever explicitly added to My Books
/// (browsing/previewing a catalog result no longer adds it automatically;
/// this is how the user finds their way back to it anyway).
struct HistoryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Binding var showingNowPlaying: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [(book: BookWithChapters, lastPlayedAt: Date)] = []
    @State private var selectedBookID: UUID?
    @State private var showClearAllConfirm = false
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    EmptyStatePanel(
                        title: "No Listening History Yet",
                        message: "Books you've played will show up here, in the order you listened to them.",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    List {
                        ForEach(entries, id: \.book.book.id) { entry in
                            Button {
                                selectedBookID = entry.book.book.id
                            } label: {
                                row(for: entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                        .onDelete(perform: removeEntries)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(VoxglassBackground())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Clear All History", role: .destructive) {
                                showClearAllConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("history.menu")
                    }
                }
            }
            .navigationDestination(item: $selectedBookID) { bookID in
                BookPageView(
                    book: libraryStore.book(withID: bookID),
                    showingNowPlaying: $showingNowPlaying
                )
            }
            .confirmationDialog(
                "Clear all listening history?",
                isPresented: $showClearAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    Task {
                        await libraryStore.clearAllListeningHistory()
                        entries = []
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone. Books already in My Books are not affected.")
            }
            .task { await load() }
        }
    }

    private func row(for entry: (book: BookWithChapters, lastPlayedAt: Date)) -> some View {
        HStack(spacing: 12) {
            BookArtworkView(title: entry.book.book.title, size: 48, coverURL: entry.book.book.coverURL, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.book.book.title)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(entry.book.book.authorLine)
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                Text(relativeDate(entry.lastPlayedAt))
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("history.row.\(entry.book.book.id.uuidString)")
    }

    private func load() async {
        entries = await libraryStore.fetchListeningHistory()
        isLoading = false
    }

    private func removeEntries(at offsets: IndexSet) {
        let removed = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        Task {
            for entry in removed {
                await libraryStore.removeListeningHistory(bookID: entry.book.book.id)
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
