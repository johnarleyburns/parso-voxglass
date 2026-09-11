import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import VoxglassCore

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @Binding var showingNowPlaying: Bool
    @State private var pendingDeletion: BookWithChapters?
    @State private var pendingWatchTransfer: BookWithChapters?
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var searchScope: LibrarySearchScope = .all
    @State private var isEditing = false
    @State private var showingAddArchiveURL = false
    @State private var bookOrder: [UUID] = []
    @State private var selectedBookID: UUID?
    @AppStorage(AppPreferencesStore.Keys.soloOnlyEnabled) private var soloOnly = true
    @State private var myNarrationOnly = false

    var body: some View {
        VoxglassScreen(
            title: "My Books",
            headerActionTitle: libraryStore.books.isEmpty ? nil : (isEditing ? "Done" : "Edit"),
            headerAction: { withAnimation { isEditing.toggle() } },
            headerSecondaryActionTitle: "+",
            headerSecondaryAction: { showingAddArchiveURL = true },
            headerSecondaryActionAccessibilityLabel: "Add audiobook from archive.org URL"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                bookList
            }
            .padding(.top, 12)
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
                .environmentObject(catalogStore)
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
        .confirmationDialog(
            "Send to Apple Watch on cellular data?",
            isPresented: watchCellularBinding,
            titleVisibility: .visible
        ) {
            Button("Send now on cellular") {
                if let book = pendingWatchTransfer {
                    Task { await transferToWatch(book, allowCellular: true) }
                }
            }
            Button("Wait for Wi-Fi", role: .cancel) {
                pendingWatchTransfer = nil
            }
        } message: {
            Text("Sending a book to the watch can use significant cellular data.")
        }
        .alert(
            "Couldn't Send to Apple Watch",
            isPresented: watchTransferErrorBinding
        ) {
            Button("OK", role: .cancel) {
                phoneAudioRelay.watchTransferError = nil
            }
        } message: {
            Text(phoneAudioRelay.watchTransferError ?? "")
        }
        .task {
            libraryStore.sort = .recent
            await libraryStore.refresh()
            await libraryStore.refreshRecentlyPlayed()
            bookOrder = libraryStore.books.map { $0.book.id }
        }
        .onChange(of: libraryStore.books) { _, books in
            let ids = books.map { $0.book.id }
            bookOrder = bookOrder.filter(ids.contains) + ids.filter { !bookOrder.contains($0) }
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
                filterBar
                if showSearch {
                    searchBar
                }

                let books = orderedFilteredBooks
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
                            selectedBookID = book.book.id
                        } label: {
                            CompactBookRowView(
                                book: book,
                                sourceTitle: libraryStore.source(for: book.book)?.title,
                                accessory: .download(
                                    // A local-files import (bookmark-referenced, never
                                    // copied) has no entry in OfflineDownloadManager's
                                    // state dictionary — it never went through a
                                    // "download" job, so `.state(for:)` always falls
                                    // through to `.notCached` for it, even though the
                                    // audio genuinely is on-device. It always is, by
                                    // definition, so it always reads as `.cached`.
                                    libraryStore.source(for: book.book)?.kind == .localFiles
                                        ? .cached
                                        : offlineManager.state(for: book.book.id),
                                    showsNavigation: true,
                                    watchAvailable: phoneAudioRelay.watchStorageInfo(for: book.book.id)?.state == .available
                                ),
                                style: .grouped,
                                watchStorage: phoneAudioRelay.watchStorageInfo(for: book.book.id),
                                isMyNarration: isMyNarration(book)
                            )
                            .accessibilityIdentifier("library.watchStatus.\(book.book.id.uuidString)")
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .contextMenu {
                            Button {
                                Task {
                                    if phoneAudioRelay.watchStorageInfo(for: book.book.id)?.state == .available {
                                        await phoneAudioRelay.removeBookFromWatch(bookID: book.book.id)
                                    } else {
                                        await transferToWatch(book, allowCellular: false)
                                    }
                                }
                            } label: {
                                Label(watchContextTitle(for: book), systemImage: "applewatch")
                            }
                            .disabled(phoneAudioRelay.isTransferringToWatch)
                            .accessibilityIdentifier(
                                (phoneAudioRelay.watchStorageInfo(for: book.book.id)?.state == .available
                                    ? "library.watchRemove."
                                    : "library.watchDownload.") + book.book.id.uuidString
                            )
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
                    .onMove { source, destination in
                        var ids = books.map { $0.book.id }
                        ids.move(fromOffsets: source, toOffset: destination)
                        bookOrder = ids + bookOrder.filter { !ids.contains($0) }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                .frame(height: CGFloat(max(1, books.count)) * BookListRow.fixedRowHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            HStack(spacing: 8) {
                FilterChip(title: "Solo Narration", isSelected: soloOnly) {
                    soloOnly.toggle()
                }
                FilterChip(title: "My Narration", isSelected: myNarrationOnly) {
                    myNarrationOnly.toggle()
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if !showSearch {
                            searchText = ""
                            searchScope = .all
                        }
                    }
                } label: {
                    Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .scaledFont(size: 18, weight: .semibold)
                        .foregroundStyle(Palette.brass)
                        .frame(width: 36, height: 36)
                        .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.08))
                }
                .accessibilityLabel(showSearch ? "Close search" : "Search my books")
            }
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
            .scaledFont(size: 14)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
            .glassSurface(cornerRadius: 18)

            Picker("Scope", selection: $searchScope) {
                ForEach(LibrarySearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .tint(Palette.brass)
        }
    }

    private func isMyNarration(_ book: BookWithChapters) -> Bool {
        libraryStore.source(for: book.book)?.kind == .localFiles && book.book.authors != ["Local Files"]
    }

    private var filteredBooks: [BookWithChapters] {
        var books = libraryStore.visibleBooks

        if soloOnly {
            books = books.filter { $0.narrationKind == .solo }
        }

        if myNarrationOnly {
            books = books.filter { isMyNarration($0) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }

        return books.filter { book in
            switch searchScope {
            case .all:
                return book.book.title.localizedCaseInsensitiveContains(query)
                    || book.book.authors.contains { $0.localizedCaseInsensitiveContains(query) }
                    || book.book.narrators.contains { $0.localizedCaseInsensitiveContains(query) }
            case .title:
                return book.book.title.localizedCaseInsensitiveContains(query)
            case .author:
                return book.book.authors.contains { $0.localizedCaseInsensitiveContains(query) }
            case .narrator:
                return book.book.narrators.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
    }

    private var orderedFilteredBooks: [BookWithChapters] {
        let books = filteredBooks
        let ranks = Dictionary(uniqueKeysWithValues: bookOrder.enumerated().map { ($1, $0) })
        return books.sorted { lhs, rhs in
            (ranks[lhs.book.id] ?? Int.max) < (ranks[rhs.book.id] ?? Int.max)
        }
    }

    private func watchContextTitle(for book: BookWithChapters) -> String {
        guard let storage = phoneAudioRelay.watchStorageInfo(for: book.book.id) else {
            return "Download to Apple Watch"
        }
        switch storage.state {
        case .available:
            return "Downloaded on Apple Watch"
        case .transferring, .queued, .waitingForPhone:
            return "Downloading to Apple Watch…"
        case .failed:
            return "Retry Download to Apple Watch"
        case .notAvailable:
            return "Download to Apple Watch"
        }
    }

    private func transferToWatch(_ book: BookWithChapters, allowCellular: Bool) async {
        let start = await phoneAudioRelay.transferBookToWatch(
            book,
            allowCellularOverride: allowCellular
        )
        switch start {
        case .needsCellularConfirmation:
            pendingWatchTransfer = book
        case .failed(let message):
            phoneAudioRelay.watchTransferError = message
        case .started:
            pendingWatchTransfer = nil
        }
    }

    private var watchCellularBinding: Binding<Bool> {
        Binding {
            pendingWatchTransfer != nil
        } set: { isPresented in
            if !isPresented {
                pendingWatchTransfer = nil
            }
        }
    }

    private var watchTransferErrorBinding: Binding<Bool> {
        Binding {
            phoneAudioRelay.watchTransferError != nil
        } set: { isPresented in
            if !isPresented {
                phoneAudioRelay.watchTransferError = nil
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

private struct AddArchiveURLSheet: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Binding var showingNowPlaying: Bool
    @State private var archiveURL = ""
    @State private var showingLocalFolderImporter = false
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
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(Palette.ink)
                        Text("Paste an Internet Archive item URL to add its audiobook to My Books.")
                            .scaledFont(size: 13)
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
                                Text(catalogStore.isResolvingURL ? "Adding…" : "Add Audiobook")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.brass)
                        .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
                    }
                    .padding(14)
                    .glassSurface(cornerRadius: 18)

                    // MARK: Local folder
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Add from a Local Folder", systemImage: "folder")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(Palette.ink)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("The folder should contain:")
                                .scaledFont(size: 13)
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
                                .scaledFont(size: 12.5, weight: .medium)
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
                                Text(isImportingLocalFolder ? "Importing…" : "Choose Folder")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isImportingLocalFolder)

                        Text("The audio file is never copied — it stays exactly where it is on disk.")
                            .scaledFont(size: 11.5)
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(14)
                    .glassSurface(cornerRadius: 18)

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
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .frame(width: 16)
            Text(text)
                .scaledFont(size: 12.5)
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
                libraryStore.importError = "Couldn't add this audiobook to your library."
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
        /// again after relaunch (`SecurityScopedBookmarkAccess`).
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
                            .scaledFont(size: 13.5)
                            .foregroundStyle(Palette.ink2)

                        Text(Self.example)
                            .scaledFont(size: 13, design: .monospaced)
                            .foregroundStyle(Palette.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassSurface(cornerRadius: 12)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Format: Chapter <number>: <title> <timestamp>")
                                .scaledFont(size: 12.5, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Text("Timestamps can be h:mm:ss (1:02:30) or mm:ss (20:50) — use whichever fits. Chapters must be listed in order, each starting later than the one before.")
                                .scaledFont(size: 12)
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
            return "No supported audio file was found in that folder."
        case .missingChapterText:
            return "No chapter text file was found in that folder."
        case .invalidChapterTiming:
            return "The chapter timestamps do not fit within the selected audio file."
        }
    }
}

private enum LibrarySearchScope: CaseIterable, Identifiable, Hashable {
    case all
    case title
    case author
    case narrator

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .title: return "Title"
        case .author: return "Author"
        case .narrator: return "Narrator"
        }
    }
}
