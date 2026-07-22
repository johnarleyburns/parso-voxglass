import SwiftUI
import VoxglassCore

struct BookPageOverflowSheet: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    let book: BookWithChapters
    @Binding var showingNowPlaying: Bool
    @Binding var showRemoveOfflineConfirm: Bool
    @State private var showingPlaylistPicker = false
    @State private var showingBookmarks = false
    @State private var showingEQ = false
    @Binding var showRemoveConfirm: Bool
    let genre: LibriVoxBrowseCategory?

    @Environment(\.dismiss) private var dismiss

    private var offlineState: OfflineState {
        offlineManager.state(for: book.book.id)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoxglassTheme.warmBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 36, height: 5)
                        .padding(.top, 6)

                    List {
                        thisBookSection
                        audioSection
                        discoverSection
                        manageSection
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.ink2)
                }
            }
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            NavigationStack {
                AddToPlaylistSheet(bookID: book.book.id)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingBookmarks) {
            NavigationStack {
                BookmarksView()
                    .environmentObject(playback)
                    .environmentObject(libraryStore)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEQ) {
            NavigationStack {
                EQView()
                    .environmentObject(playback)
            }
            .presentationDragIndicator(.visible)
        }
    }

    private var thisBookSection: some View {
        Section("This book") {
            ShareLink(item: shareText) {
                overflowRow(icon: "square.and.arrow.up", title: "Share")
            }

            Button {
                showingPlaylistPicker = true
            } label: {
                overflowRow(icon: "text.badge.plus", title: "Add to Playlist…")
            }

            if let count = playback.bookmarkCount, count > 0 {
                Button {
                    showingBookmarks = true
                } label: {
                    overflowRow(icon: "bookmark.fill", title: "Bookmarks", detail: "\(count)")
                }
            }

            NavigationLink {
                ChaptersView(book: book, showingNowPlaying: $showingNowPlaying)
            } label: {
                overflowRow(icon: "list.bullet", title: "All Chapters", detail: "\(book.chapters.count) total")
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Button {
                showingEQ = true
            } label: {
                overflowRow(icon: "slider.horizontal.3", title: "Equalizer", detail: playback.isEQEngaged ? "On" : "Off")
            }
            .accessibilityIdentifier("nowplaying.eq")

            Button {
                let current = UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.volumeNormalizationEnabled)
                playback.setVolumeNormalizationEnabled(!current)
                UserDefaults.standard.set(!current, forKey: AppPreferencesStore.Keys.volumeNormalizationEnabled)
            } label: {
                let enabled = UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.volumeNormalizationEnabled)
                overflowRow(icon: "speaker.wave.2", title: "Volume normalization", detail: enabled ? "On" : "Off")
            }
        }
    }

    @ViewBuilder
    private var discoverSection: some View {
        let author = book.book.authors.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let narrator = book.book.narrators.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasAuthor = !author.isEmpty && author.localizedCaseInsensitiveCompare("Unknown author") != .orderedSame
        let hasNarrator = !narrator.isEmpty

        if hasAuthor || hasNarrator || genre != nil {
            Section("Discover") {
                if hasAuthor {
                    NavigationLink {
                        CatalogDiscoveryView(
                            title: author,
                            archiveQuery: BookPageView.authorQuery(author),
                            showingNowPlaying: $showingNowPlaying
                        )
                        .environmentObject(playback)
                        .environmentObject(libraryStore)
                    } label: {
                        overflowRow(icon: "person.fill", title: "More by \(author)")
                    }
                }
                if hasNarrator {
                    NavigationLink {
                        CatalogDiscoveryView(
                            title: narrator,
                            archiveQuery: BookPageView.narratorQuery(narrator),
                            showingNowPlaying: $showingNowPlaying
                        )
                        .environmentObject(playback)
                        .environmentObject(libraryStore)
                    } label: {
                        overflowRow(icon: "mic.fill", title: "More read by \(narrator)")
                    }
                }
                if let genre {
                    NavigationLink {
                        CatalogDiscoveryView(
                            title: genre.title,
                            archiveQuery: BookPageView.genreQuery(genre),
                            showingNowPlaying: $showingNowPlaying
                        )
                        .environmentObject(playback)
                        .environmentObject(libraryStore)
                    } label: {
                        overflowRow(icon: genre.systemImage, title: "More in \(genre.title)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manageSection: some View {
        Section("Manage") {
            if offlineState == .cached {
                Button(role: .destructive) {
                    showRemoveOfflineConfirm = true
                    dismiss()
                } label: {
                    overflowRow(icon: "trash", title: "Remove offline copy")
                }
            }

            Button(role: .destructive) {
                showRemoveConfirm = true
                dismiss()
            } label: {
                overflowRow(icon: "trash", title: "Remove from My Books")
            }
        }
    }

    private func overflowRow(icon: String, title: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 14)
                .foregroundStyle(Palette.brass)
                .frame(width: 32, height: 32)
            Text(title)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .scaledFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                    }
            }
        }
        .padding(.vertical, 4)
    }

    private var shareText: String {
        "\(book.book.title) by \(book.book.authorLine)"
    }
}
