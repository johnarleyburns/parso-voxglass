import SwiftUI
import VoxglassCore

struct BookPageOverflowSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    let book: BookWithChapters
    @Binding var showingNowPlaying: Bool
    @Binding var showRemoveOfflineConfirm: Bool
    @Binding var showCellularPrompt: Bool
    @Binding var showAddToLibraryConfirm: Bool
    @State private var showingPlaylistPicker = false
    @State private var showingBookmarks = false
    @State private var showingEQ = false
    @State private var showWatchCellularPrompt = false
    @State private var watchTransferError: String?
    @Binding var showRemoveConfirm: Bool
    @Binding var showReconnectAudio: Bool
    let genre: LibriVoxBrowseCategory?
    var audioOnly = false

    @Environment(\.dismiss) private var dismiss

    private var offlineState: OfflineState {
        offlineManager.state(for: book.book.id)
    }

    private var watchTransferEligible: Bool {
        WatchDownloadEligibility.allowsTransfer(
            isReadByAI: libraryStore.source(for: book.book)?.kind == .readWithAI,
            chapterExtensions: book.chapters.flatMap { [$0.localURL?.pathExtension, $0.remoteURL?.pathExtension].compactMap { $0 } }
        )
    }

    private func startWatchTransfer(allowCellular: Bool) async {
        let result = await phoneAudioRelay.transferBookToWatch(book, allowCellularOverride: allowCellular)
        switch result {
        case .started: break
        case .needsCellularConfirmation: showWatchCellularPrompt = true
        case .failed(let message): watchTransferError = message
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoxglassTheme.warmBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    List {
                        if audioOnly {
                            audioSection
                        } else {
                            detailsSection
                            discoverSection
                            thisBookSection
                            manageSection
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(audioOnly ? String(localized: "Playback") : String(localized: "Book Details"))
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
                    .environment(playback)
                    .environmentObject(libraryStore)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEQ) {
            NavigationStack {
                EQView()
                    .environment(playback)
            }
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Send to Apple Watch on cellular data?",
            isPresented: $showWatchCellularPrompt,
            titleVisibility: .visible
        ) {
            Button("Send now on cellular") { Task { await startWatchTransfer(allowCellular: true) } }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("Sending a book to the watch can use significant cellular data.")
        }
        .alert(
            "Couldn't Send to Apple Watch",
            isPresented: Binding(get: { watchTransferError != nil }, set: { if !$0 { watchTransferError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(watchTransferError ?? "")
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            Text(book.book.title).voxType(.bookTitle)
            if book.book.isPending {
                Button("Add to My Books") {
                    showAddToLibraryConfirm = true
                    dismiss()
                }
            } else {
                Label("In My Books", systemImage: "checkmark.circle.fill")
            }
            Text("\(book.chapters.count) chapters")
            if offlineState == .cached || libraryStore.source(for: book.book)?.kind == .localFiles {
                Label("Available offline", systemImage: "checkmark.circle")
            }
            if let source = libraryStore.source(for: book.book),
               source.kind == .librivox || source.kind == .readWithAI {
                Text("Public domain")
            }
            if let genre { Text(genre.title) }
            if let summary = book.book.summary, !summary.isEmpty { Text(summary) }
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
            if offlineState == .cached {
                Button(role: .destructive) {
                    showRemoveOfflineConfirm = true
                    dismiss()
                } label: {
                    overflowRow(icon: "trash", title: "Remove offline copy")
                }
                .accessibilityIdentifier("nowplaying.download")
            } else {
                Button {
                    Task {
                        _ = await offlineManager.makeAvailableOffline(
                            book: book,
                            isCellular: NetworkMonitor.shared.isCellular
                        )
                    }
                } label: {
                    overflowRow(icon: "arrow.down.circle", title: "Make available offline")
                }
                .accessibilityIdentifier("nowplaying.download")
            }
            if watchTransferEligible {
                if phoneAudioRelay.watchState(for: book.book.id) == .available {
                    Button(role: .destructive) {
                        Task { await phoneAudioRelay.removeBookFromWatch(bookID: book.book.id) }
                    } label: {
                        overflowRow(icon: "applewatch.slash", title: "Remove from Apple Watch")
                    }
                    .accessibilityIdentifier("nowplaying.watchRemove")
                } else {
                    Button {
                        Task { await startWatchTransfer(allowCellular: false) }
                    } label: {
                        overflowRow(
                            icon: "applewatch",
                            title: "Send to Apple Watch",
                            detail: phoneAudioRelay.watchBookStatus(for: book.book.id)
                        )
                    }
                    .accessibilityIdentifier("nowplaying.watchDownload")
                    .disabled(phoneAudioRelay.isTransferringToWatch)
                }
            } else {
                LabeledContent("Apple Watch") { ReadByAIWatchInfoButton() }
            }
        }
    }

    private var audioSection: some View {
        Section("Playback") {
            BookPageActionRow(
                isDetailList: true,
                book: book,
                showingEQ: $showingEQ,
                showingBookmarks: $showingBookmarks,
                showingOverflow: .constant(false),
                showCellularPrompt: $showCellularPrompt,
                showRemoveOfflineConfirm: $showRemoveOfflineConfirm
            )
            if libraryStore.source(for: book.book)?.kind == .readWithAI {
                NavigationLink {
                    ReadWithAIVoicePicker(bookID: book.book.id) { preference in
                        playback.selectReadWithAIVoice(preference, for: book.book.id)
                    }
                } label: {
                    Label("Select AI Voice", systemImage: "waveform.and.mic")
                }
                .accessibilityIdentifier("nowplaying.readWithAIVoice")
            }

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

            if libraryStore.source(for: book.book)?.kind == .localFiles {
                Button {
                    showReconnectAudio = true
                    dismiss()
                } label: {
                    overflowRow(icon: "link", title: "Reconnect Audio")
                }
                .accessibilityIdentifier("nowplaying.reconnectAudio")
            }

        }
    }

    @ViewBuilder
    private var discoverSection: some View {
        let author = book.book.displayAuthorLine ?? ""
        let narrator = book.book.narrators.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasAuthor = !author.isEmpty
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
                        .environment(playback)
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
                        .environment(playback)
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
                        .environment(playback)
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
            Button(role: .destructive) {
                showRemoveConfirm = true
                dismiss()
            } label: {
                overflowRow(icon: "trash", title: "Remove from My Books")
            }
        }
    }

    // `detail` is a plain String, not LocalizedStringKey: it carries dynamic,
    // already-resolved content (e.g. a live watch-transfer status), which
    // must never be reinterpreted as a localization/format key.
    private func overflowRow(icon: String, title: LocalizedStringKey, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .voxFont(.subheadline)
                .foregroundStyle(Palette.brass)
                .frame(width: 32, height: 32)
            Text(title)
                .voxFont(.subheadline, weight: .medium)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .voxFont(.caption2, weight: .semibold, design: .monospaced) // mono-exempt: storage estimate
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
