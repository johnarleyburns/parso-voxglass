import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import VoxglassCore
import VoxglassWatchProtocol

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(CatalogStore.self) private var catalogStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @Binding var showingNowPlaying: Bool
    @State private var pendingDeletion: BookWithChapters?
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var isEditing = false
    @ScaledMetric(relativeTo: .footnote) private var libraryRowMinimumHeight = BookListRow.libraryRowMinimumHeight
    @State private var showingAddArchiveURL = false
    @State private var lastPlayedAt: [UUID: Date] = [:]
    @State private var selectedBookID: UUID?
    // Discovery preferences must not silently hide saved books.
    @State private var soloOnly = false
    @State private var onMyWatchOnly = false

    var body: some View {
        VoxglassScreen(
            title: "My Books",
            headerTrailingContent: AnyView(libraryHeaderActions)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                shelfPicker
                if onMyWatchOnly { watchMirror } else { bookList }
            }
            .padding(.top, 12)
            // The tab bar and expanded mini-player are outside the screen's
            // scroll content safe area. Leave enough trailing room for the
            // final book to scroll completely above both accessories.
            .padding(.bottom, 156)
            // Must be inside VoxglassScreen's trailing closure, not chained
            // after the VoxglassScreen(...) call: VoxglassScreen wraps this
            // content in its own internal `NavigationStack`, and
            // `.navigationDestination(item:)` only registers when attached
            // to a view INSIDE that stack. Attached outside (as it was),
            // setting `selectedBookID` did nothing visible — no crash, no
            // navigation — which is exactly what broke "tap a book" after
            // the NavigationLink → Button migration.
            .navigationDestination(item: $selectedBookID) { bookID in
                BookPageView(
                    book: libraryStore.books.first { $0.book.id == bookID },
                    showingNowPlaying: $showingNowPlaying
                )
            }
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                libraryStore.importError = nil
            }
        } message: {
            Text(libraryStore.importError ?? "")
        }
        .sheet(isPresented: $showingAddArchiveURL) {
            AddArchiveURLSheet(showingNowPlaying: $showingNowPlaying)
                .environmentObject(libraryStore)
                .environment(catalogStore)
                .environment(playback)
        }
        .confirmationDialog(
            pendingDeletion.map { "Remove \"\($0.book.title)\" from your books?" } ?? "",
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
            if let pendingDeletion, libraryStore.source(for: pendingDeletion.book)?.kind == .localFiles {
                Text("This removes the book from My Books. The audio file and its folder are not touched — they stay exactly where they are in Files.")
            } else {
                Text("This deletes the book and its cached audio from this device.")
            }
        }
        .task {
            if libraryStore.progressFilter == .all { libraryStore.progressFilter = .inProgress }
            libraryStore.sort = .recent
            await libraryStore.refresh()
        }
        .task(id: libraryStore.recentlyPlayed.map(\.id)) {
            let history = await libraryStore.fetchListeningHistory()
            lastPlayedAt = Dictionary(uniqueKeysWithValues: history.map { ($0.book.id, $0.lastPlayedAt) })
        }
        .onChange(of: showingNowPlaying) { _, presented in
            guard !presented else { return }
            Task { await libraryStore.refresh() }
        }
    }

    private var orderedWatchBooks: [WatchBookDTO] {
        phoneAudioRelay.watchCatalogBooks.sorted { lhs, rhs in
            let left = UUID(uuidString: lhs.id.rawValue).flatMap { lastPlayedAt[$0] } ?? .distantPast
            let right = UUID(uuidString: rhs.id.rawValue).flatMap { lastPlayedAt[$0] } ?? .distantPast
            if left != right { return left > right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    @ViewBuilder
    private var watchMirror: some View {
        if phoneAudioRelay.watchCatalogBooks.isEmpty {
            EmptyStatePanel(title: "Nothing on My Watch", message: "Choose books in Sync to listen on Apple Watch.", systemImage: "applewatch", usesThreeSizeTypography: true)
        } else {
            ForEach(orderedWatchBooks, id: \.id) { book in
                let id = UUID(uuidString: book.id.rawValue)
                let storage = id.flatMap { phoneAudioRelay.watchStorageInfo(for: $0) }
                let desired = phoneAudioRelay.watchDesiredStates[book.id]
                let resolved = WatchDisplayStateResolver.resolve(desiredState: desired, storageState: storage?.state)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).voxFont(LibraryScreenTypography.card, weight: .medium)
                            if let author = book.author { Text(author).voxFont(LibraryScreenTypography.card).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if resolved == .available {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Installed on Apple Watch")
                        }
                    }
                    Text(resolved == .available ? String(localized: "On My Watch") : String(localized: "Open Sync to manage this book"))
                        .voxFont(LibraryScreenTypography.card).foregroundStyle(.secondary)
                }.voxFont(LibraryScreenTypography.card).padding(14).raisedSurface()
            }
        }
    }

    @ViewBuilder
    private var bookList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "No Audiobooks Yet",
                    message: "Search the catalog in Discover or add an audiobook to build your shelf. Everything you play is cached here automatically.",
                    systemImage: "books.vertical",
                    usesThreeSizeTypography: true
                )
            } else {
                if showSearch {
                    searchBar
                }

                let books = orderedFilteredBooks
                if books.isEmpty {
                    filteredEmptyState
                } else {
                    List {
                        ForEach(books) { book in
                        // Plain `Button` + `.navigationDestination(item:)`
                        // rather than `NavigationLink` — a List row that IS
                        // (or contains, even hidden via `.background`) a
                        // NavigationLink gets extra automatic chrome from
                        // List itself (a disclosure chevron, and apparently
                        // row insets too) that turned out to be applied
                        // inconsistently depending on the row's own content:
                        // "My Narration" rows (more populated optional lines
                        // — a real narrator, watch status) got a doubled
                        // chevron, then a missing one, then different left/
                        // right insets than every other row, across three
                        // rounds of trying to coax List's own NavigationLink
                        // detection into behaving the same for every row. A
                        // plain Button is never detected as a nav row by
                        // List at all, so there is nothing left to behave
                        // inconsistently — every row gets exactly the insets
                        // and chevron this view draws itself, always.
                        Button {
                            playback.selectAndPlay(book)
                            showingNowPlaying = true
                        } label: { libraryRowLabel(book) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playActionLabel(for: book))
                        .accessibilityHint("Opens the player")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .contextMenu {
                            Button("Open Details") {
                                selectedBookID = book.book.id
                            }
                            Button("Remove from My Books", role: .destructive) {
                                pendingDeletion = book
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pendingDeletion = book
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        }
                        .onDelete { offsets in
                            guard let index = offsets.first, books.indices.contains(index) else { return }
                            pendingDeletion = books[index]
                        }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                    // Use a minimum rather than an exact height: grouped
                    // rows grow when narrator, watch, or progress metadata is
                    // present. An exact row-count frame clipped the final
                    // book and sometimes clipped the metadata of earlier
                    // rows as well.
                    .frame(minHeight: CGFloat(max(1, books.count)) * libraryRowMinimumHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private var filteredEmptyState: some View {
        if onMyWatchOnly {
            EmptyStatePanel(title: "Nothing on My Watch", message: "Choose books in Sync to listen on Apple Watch.", systemImage: "applewatch", usesThreeSizeTypography: true)
        } else if libraryStore.downloadedOnly {
            EmptyStatePanel(
                title: "No Downloads Yet",
                message: "Books you cache for offline listening will appear here.",
                systemImage: "arrow.down.circle",
                usesThreeSizeTypography: true
            )
            .accessibilityIdentifier("library.downloadedEmptyState")
        } else if libraryStore.favoriteOnly {
            EmptyStatePanel(
                title: "No Favorite Books",
                message: "Favorite a book to keep it in this view.",
                systemImage: "heart",
                usesThreeSizeTypography: true
            )
            .accessibilityIdentifier("library.favoritesEmptyState")
        } else if soloOnly {
            EmptyStatePanel(
                title: "No Single-narrator Books",
                message: "Turn off Single narrator to see the rest of this view.",
                systemImage: "mic",
                usesThreeSizeTypography: true
            )
            .accessibilityIdentifier("library.soloEmptyState")
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStatePanel(
                title: "No Matching Books",
                message: "Try a different title, author, or narrator.",
                systemImage: "magnifyingglass",
                usesThreeSizeTypography: true
            )
            .accessibilityIdentifier("library.filteredEmptyState")
        } else {
            EmptyStatePanel(
                title: "No Books in This View",
                message: "Try another filter to see more of your saved books.",
                systemImage: "books.vertical",
                usesThreeSizeTypography: true
            )
            .accessibilityIdentifier("library.filteredEmptyState")
        }
    }

    private func libraryRowLabel(_ book: BookWithChapters) -> some View {
        let isFinished = libraryStore.progressByBook[book.book.id]?.isFinished == true
        return CompactBookRowView(
            book: book,
            sourceTitle: libraryStore.source(for: book.book)?.title,
            metadata: progressText(for: book),
            accessory: .play,
            style: .grouped,
            isMyNarration: isMyNarration(book),
            progress: progressFraction(for: book),
            usesThreeSizeTypography: true
        )
        .accessibilityIdentifier("library.play.\(book.book.id.uuidString)")
        .accessibilityActions {
            Button("Resume") {
                playback.selectAndPlay(book)
                showingNowPlaying = true
            }
            Button("Download") {
                Task {
                    _ = await offlineManager.makeAvailableOffline(
                        book: book,
                        isCellular: NetworkMonitor.shared.isCellular
                    )
                }
            }
            Button(isFinished ? "Mark unfinished" : "Mark finished") { // l10n-exempt: state-dependent accessibility or status copy
                Task {
                    await playback.setBookFinished(book, finished: !isFinished)
                    await libraryStore.refresh()
                }
            }
        }
    }

    private var shelfPicker: some View {
        ViewThatFits(in: .horizontal) {
            shelfOptions
            ScrollView(.horizontal, showsIndicators: false) { shelfOptions }
        }
    }

    private var shelfOptions: some View {
        HStack(spacing: 8) {
            shelfOption("In Progress", selected: !onMyWatchOnly && libraryStore.progressFilter == .inProgress) {
                onMyWatchOnly = false
                libraryStore.progressFilter = .inProgress
            }
            shelfOption("Finished", selected: !onMyWatchOnly && libraryStore.progressFilter == .finished) {
                onMyWatchOnly = false
                libraryStore.progressFilter = .finished
            }
            shelfOption("On My Watch", selected: onMyWatchOnly) { onMyWatchOnly = true }
        }
    }

    private func shelfOption(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .voxFont(LibraryScreenTypography.controls)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(selected ? Palette.brass : Palette.ink)
                .glassEffect(.regular.tint(selected ? Palette.brass.opacity(0.2) : .clear).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var libraryHeaderActions: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch.toggle()
                    if !showSearch {
                        searchText = ""
                    }
                }
            } label: {
                Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(showSearch ? "Close search" : "Search my books") // l10n-exempt: state-dependent accessibility or status copy
            .accessibilityIdentifier("library.searchButton")

            Button {
                showingAddArchiveURL = true
            } label: {
                Text("+")
                    .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Add audiobook from archive.org URL")
            .accessibilityIdentifier("library.addButton")

            Menu {
                Section("Show") {
                    Toggle("Favorites", isOn: $libraryStore.favoriteOnly)
                        .accessibilityIdentifier("library.favoritesFilter")
                    Toggle("Downloaded", isOn: $libraryStore.downloadedOnly)
                        .accessibilityIdentifier("library.downloadedFilter")
                    Toggle("Single narrator", isOn: $soloOnly)
                }
                Divider()
                Button(isEditing ? "Done editing" : "Edit books") { // l10n-exempt: state-dependent accessibility or status copy
                    withAnimation { isEditing.toggle() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("More My Books options")
            .accessibilityIdentifier("library.moreMenu")
        }
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.ink3)

                TextField("", text: $searchText, prompt: Text("Search my books").foregroundStyle(Palette.ink3))
                    .foregroundStyle(Palette.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Search My Books")
                    .accessibilityIdentifier("library.booksSearch")

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.ink3)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .voxFont(LibraryScreenTypography.controls)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .raisedSurface()


        }
    }

    private func isMyNarration(_ book: BookWithChapters) -> Bool {
        libraryStore.source(for: book.book)?.kind == .localFiles && book.book.authors != ["Local Files"]
    }

    private func playActionLabel(for book: BookWithChapters) -> String {
        let hasResumePoint = libraryStore.progressByBook[book.book.id].map {
            $0.lastPosition > 0 && !$0.isFinished
        } ?? false
        return hasResumePoint
            ? String(localized: "Resume \(book.book.title)")
            : String(localized: "Play \(book.book.title)")
    }

    private func progressText(for book: BookWithChapters) -> String? {
        guard let progress = libraryStore.progressByBook[book.book.id] else { return nil }
        if progress.isFinished { return String(localized: "Finished") }
        guard progress.lastPosition > 0 else { return nil }
        guard let totalDuration = book.totalDuration, totalDuration > 0 else {
            return String(localized: "In progress")
        }
        let percent = Int((min(max(progress.lastPosition / totalDuration, 0), 1) * 100).rounded())
        return "\(percent)% listened"
    }

    private func progressFraction(for book: BookWithChapters) -> Double? {
        guard let progress = libraryStore.progressByBook[book.book.id],
              let totalDuration = book.totalDuration,
              totalDuration > 0,
              progress.lastPosition > 0,
              !progress.isFinished else { return nil }
        return min(max(progress.lastPosition / totalDuration, 0), 1)
    }

    private var filteredBooks: [BookWithChapters] {
        var books = libraryStore.visibleBooks
        if onMyWatchOnly {
            books = books.filter {
                phoneAudioRelay.watchSelectedBookIDs.contains($0.book.id)
                    || phoneAudioRelay.watchStorageInfo(for: $0.book.id) != nil
            }
        }

        if soloOnly {
            books = books.filter { $0.narrationKind == .solo }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }

        return books.filter { book in
            book.book.title.localizedCaseInsensitiveContains(query)
                || book.book.authors.contains { $0.localizedCaseInsensitiveContains(query) }
                || book.book.narrators.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var orderedFilteredBooks: [BookWithChapters] {
        let books = filteredBooks
        return books.sorted { lhs, rhs in
            let left = lastPlayedAt[lhs.book.id] ?? .distantPast
            let right = lastPlayedAt[rhs.book.id] ?? .distantPast
            if left != right { return left > right }
            if lhs.book.updatedAt != rhs.book.updatedAt { return lhs.book.updatedAt > rhs.book.updatedAt }
            return lhs.book.id.uuidString < rhs.book.id.uuidString
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

private struct AddArchiveURLSheet: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(CatalogStore.self) private var catalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Binding var showingNowPlaying: Bool
    @State private var archiveURL = ""
    @State private var showingLocalFolderImporter = false
    @State private var showingEPUBImporter = false
    @State private var isImportingLocalFolder = false
    @State private var showingChapterFileExample = false

    var body: some View {
        NavigationStack {
            ZStack {
                VoxglassBackground()
                VStack(alignment: .leading, spacing: 18) {
                    // MARK: Internet Archive
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Add from Internet Archive", systemImage: "globe")
                            .voxFont(.subheadline, weight: .semibold)
                            .foregroundStyle(Palette.ink)
                        Text("Paste an Internet Archive item URL to add its audiobook to My Books.")
                            .voxFont(.footnote)
                            .foregroundStyle(Palette.ink2)

                        TextField("archive.org/details/...", text: $archiveURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit { Task { await addBook() } }

                        Button {
                            Task { await addBook() }
                        } label: {
                            HStack {
                                if catalogStore.isResolvingURL {
                                    ProgressView()
                                }
                                Text(catalogStore.isResolvingURL ? "Adding…" : "Add Audiobook") // l10n-exempt: state-dependent accessibility or status copy
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.brass)
                        .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
                    }
                    .padding(14)
                    .raisedSurface()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Read a document with AI", systemImage: "text.book.closed")
                            .voxFont(.subheadline, weight: .semibold)
                            .foregroundStyle(Palette.ink)
                        Text("Choose an EPUB or text-based PDF from Files. Voxglass keeps a local text copy and reads it with the iPhone’s built-in voice.")
                            .voxFont(.footnote)
                            .foregroundStyle(Palette.ink2)
                        Button("Choose EPUB or PDF") { showingEPUBImporter = true }
                            .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .raisedSurface()

                    // MARK: Local folder
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Add from a Local Folder", systemImage: "folder")
                            .voxFont(.subheadline, weight: .semibold)
                            .foregroundStyle(Palette.ink)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("The folder should contain:")
                                .voxFont(.footnote)
                                .foregroundStyle(Palette.ink2)
                            localFolderRequirement(
                                icon: "waveform",
                                text: "One audio file — the whole book as a single track."
                            )
                            localFolderRequirement(
                                icon: "doc.text",
                                text: "One .txt file listing chapter names and where each one starts."
                            )
                            localFolderRequirement(
                                icon: "photo",
                                text: "Optional: an image file (JPEG, PNG, HEIC, etc.) to use as the cover."
                            )
                        }

                        Button {
                            showingChapterFileExample = true
                        } label: {
                            Label("See an example chapter file", systemImage: "questionmark.circle")
                                .voxFont(.caption, weight: .medium)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.brass)

                        Button {
                            showingLocalFolderImporter = true
                        } label: {
                            HStack {
                                if isImportingLocalFolder {
                                    ProgressView()
                                }
                                Text(isImportingLocalFolder ? "Importing…" : "Choose Folder") // l10n-exempt: state-dependent accessibility or status copy
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isImportingLocalFolder)

                        Text("The audio file is never copied — it stays exactly where it is on disk.")
                            .voxFont(.caption2)
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(14)
                    .raisedSurface()

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Add Audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingLocalFolderImporter,
                allowedContentTypes: [.folder],
                onCompletion: handleFolderSelection
            )
            .fileImporter(
                isPresented: $showingEPUBImporter,
                allowedContentTypes: [.epub, .pdf],
                onCompletion: handleEPUBSelection
            )
            .alert("Couldn't Add Audiobook", isPresented: errorBinding) {
                Button("OK", role: .cancel) {
                    catalogStore.catalogError = nil
                    libraryStore.importError = nil
                }
            } message: {
                Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
            }
            .sheet(isPresented: $showingChapterFileExample) {
                ChapterFileExampleView()
            }
        }
    }

    private func localFolderRequirement(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .voxFont(.caption, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .frame(width: 16)
            Text(text)
                .voxFont(.caption)
                .foregroundStyle(Palette.ink2)
        }
    }

    private func addBook() async {
        guard !catalogStore.isResolvingURL else { return }
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            dismiss()
            await playback.present(imported)
            showingNowPlaying = true
        }
        await libraryStore.refresh()
    }

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        guard case .success(let selectedURL) = result else { return }
        Task { await importLocalFolder(selectedURL) }
    }

    private func handleEPUBSelection(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let request = try await ReadWithAIImporter.prepare(documentURL: url, sourceTitle: "Files")
                guard let imported = await libraryStore.importReadWithAI(request) else { return }
                dismiss()
                await playback.present(imported)
                showingNowPlaying = true
            } catch { libraryStore.importError = error.localizedDescription }
        }
    }

    /// The heavy per-file work — enumerating the folder, parsing the chapter
    /// text, probing duration, and creating a security-scoped bookmark for
    /// the audio file — runs in `LocalAudiobookPreparer.prepare`, off the
    /// main actor. This never copies the audio: the file stays exactly
    /// where it is on disk, and the bookmark is what lets the app read it
    /// again after relaunch. A >1GB local import used to do all of this
    /// inline in a plain (non-detached) `Task`, and additionally deep-copied
    /// the file into Application Support — for a huge file the synchronous
    /// `FileManager.copyItem` blocked MainActor long enough to trip the
    /// watchdog (killed with no crash report, since that's not a
    /// signal-based crash), and the copy was never cleaned up on failure,
    /// silently consuming device storage. Only the result — small,
    /// already-computed values — crosses back to MainActor here.
    private func importLocalFolder(_ folderURL: URL) async {
        isImportingLocalFolder = true
        defer { isImportingLocalFolder = false }

        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await LocalAudiobookPreparer.prepare(folderURL: folderURL)
            }.value

            if let imported = await libraryStore.importLocalSingleFile(
                folderURL: folderURL,
                folderName: prepared.folderName,
                audioURL: prepared.audioURL,
                bookmark: prepared.bookmark,
                markers: prepared.markers,
                audioDuration: prepared.audioDuration,
                coverURL: prepared.coverURL
            ) {
                dismiss()
                await playback.present(imported)
                showingNowPlaying = true
            } else {
                libraryStore.importError = String(localized: "Couldn't add this audiobook to your library.")
            }
        } catch {
            libraryStore.importError = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            catalogStore.catalogError != nil || libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        }
    }
}

/// Off-MainActor work for importing a local audiobook folder. See the
/// doc comment on `AddArchiveURLSheet.importLocalFolder` for why this is
/// its own nonisolated type rather than plain instance methods.
private enum LocalAudiobookPreparer {
    struct Prepared: Sendable {
        let folderName: String
        /// The audio file's own on-disk location — never copied.
        let audioURL: URL
        /// A security-scoped bookmark for `audioURL`, so the app can read it
        /// again after relaunch (`PlaybackSourceResolver`).
        let bookmark: Data
        let markers: [LocalChapterMarker]
        let audioDuration: TimeInterval
        /// The first supported image file found in the folder, copied into
        /// Application Support and used as the book's cover — nil if the
        /// folder has none. Unlike the audio file, a cover image is small
        /// enough that copying it costs nothing meaningful, and doing so
        /// means artwork display needs no security-scoped bookmark handling
        /// of its own.
        let coverURL: URL?
    }

    static func prepare(folderURL: URL) async throws -> Prepared {
        let files = try localFiles(in: folderURL)

        guard let audioURL = files.first(where: {
            AudioFormatSelection.allPlayableExtensions.contains($0.pathExtension.lowercased())
        }) else {
            throw LocalAudiobookImportError.missingAudio
        }
        guard let textURL = files.first(where: { $0.pathExtension.lowercased() == "txt" }) else {
            throw LocalAudiobookImportError.missingChapterText
        }

        let text = try String(contentsOf: textURL, encoding: .utf8)
        let markers = try LocalChapterParser.parse(text)
        let asset = AVURLAsset(url: audioURL)
        let cmDuration = try await asset.load(.duration)
        let audioDuration = CMTimeGetSeconds(cmDuration).isFinite ? CMTimeGetSeconds(cmDuration) : nil
        guard let audioDuration, audioDuration > markers.last!.startTime else {
            throw LocalAudiobookImportError.invalidChapterTiming
        }

        // Bookmark the file itself (not just the folder) — the folder's own
        // security scope, active for the caller's duration, is what makes
        // this bookmark-creation call succeed; the bookmark is what lets a
        // later, separate app launch regain read access to this exact file.
        let bookmark = try audioURL.bookmarkData()

        let coverSource = files.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
        let coverURL = coverSource.flatMap { try? copyCoverIntoApplicationSupport($0) }

        return Prepared(
            folderName: audioURL.deletingPathExtension().lastPathComponent,
            audioURL: audioURL,
            bookmark: bookmark,
            markers: markers,
            audioDuration: audioDuration,
            coverURL: coverURL
        )
    }

    private static func copyCoverIntoApplicationSupport(_ sourceURL: URL) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Voxglass/LocalArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(UUID().uuidString).\(sourceURL.pathExtension)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private static func localFiles(in folderURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}

/// Shows a worked example of the chapter `.txt` format `LocalChapterParser`
/// expects, so a user assembling a local folder doesn't have to guess the
/// syntax from an error message alone.
private struct ChapterFileExampleView: View {
    @Environment(\.dismiss) private var dismiss

    private static let example = """
    Chapter 1: The Texan 0:00
    Chapter 2: Yossarian 20:50
    Chapter 3: Hungry Joe 45:12
    Chapter 4: Doc Daneeka 1:02:30
    """

    var body: some View {
        NavigationStack {
            ZStack {
                VoxglassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Each line names one chapter and the timestamp — from the start of the audio file — where it begins. One chapter per line, in order.")
                            .voxFont(.footnote)
                            .foregroundStyle(Palette.ink2)

                        Text(Self.example)
                            .voxFont(.footnote, design: .monospaced) // mono-exempt: progress percentage
                            .foregroundStyle(Palette.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .raisedSurface()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Format: Chapter <number>: <title> <timestamp>")
                                .voxFont(.caption, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Text("Timestamps can be h:mm:ss (1:02:30) or mm:ss (20:50) — use whichever fits. Chapters must be listed in order, each starting later than the one before.")
                                .voxFont(.caption)
                                .foregroundStyle(Palette.ink3)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Chapter File Example")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private enum LocalAudiobookImportError: LocalizedError {
    case missingAudio
    case missingChapterText
    case invalidChapterTiming

    var errorDescription: String? {
        switch self {
        case .missingAudio:
            return String(localized: "No supported audio file was found in that folder.")
        case .missingChapterText:
            return String(localized: "No chapter text file was found in that folder.")
        case .invalidChapterTiming:
            return String(localized: "The chapter timestamps do not fit within the selected audio file.")
        }
    }
}
