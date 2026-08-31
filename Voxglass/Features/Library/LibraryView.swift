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
    @AppStorage(AppPreferencesStore.Keys.soloOnlyEnabled) private var soloOnly = true

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
            Text("This deletes the book and its cached audio from this device.")
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
                        NavigationLink {
                            BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
                        } label: {
                            CompactBookRowView(
                                book: book,
                                sourceTitle: libraryStore.source(for: book.book)?.title,
                                accessory: .download(offlineManager.state(for: book.book.id), showsNavigation: true),
                                style: .grouped,
                                watchStorage: phoneAudioRelay.watchStorageInfo(for: book.book.id),
                                isMyNarration: libraryStore.source(for: book.book)?.kind == .localFiles
                                    && book.book.authors != ["Local Files"]
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
                .frame(height: CGFloat(max(1, books.count)) * 104)
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

    private var filteredBooks: [BookWithChapters] {
        var books = libraryStore.visibleBooks

        if soloOnly {
            books = books.filter { $0.narrationKind == .solo }
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

    var body: some View {
        NavigationStack {
            ZStack {
                VoxglassBackground()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Paste an Internet Archive item URL to add its audiobook to My Books.")
                        .scaledFont(size: 15)
                        .foregroundStyle(Palette.ink2)

                    VStack(alignment: .leading, spacing: 10) {
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

                        Button {
                            showingLocalFolderImporter = true
                        } label: {
                            Label("Import Local Audiobook Folder or ZIP", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
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
                allowedContentTypes: [.folder, .zip],
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
        Task { await importSelectedLocalSource(selectedURL) }
    }

    private func importSelectedLocalSource(_ selectedURL: URL) async {
        if selectedURL.pathExtension.lowercased() == "zip" {
            do {
                let extracted = try await Task.detached(priority: .userInitiated) {
                    try LocalZipExtractor.extract(selectedURL)
                }.value
                defer { try? FileManager.default.removeItem(at: extracted) }
                await importLocalFolder(extracted)
            } catch {
                libraryStore.importError = error.localizedDescription
            }
        } else {
            await importLocalFolder(selectedURL)
        }
    }

    private func importLocalFolder(_ folderURL: URL) async {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }

        do {
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

            let storedAudioURL = try copyIntoApplicationSupport(audioURL)
            if let imported = await libraryStore.importLocalSingleFile(
                folderURL: folderURL,
                folderName: audioURL.deletingPathExtension().lastPathComponent,
                audioURL: storedAudioURL,
                markers: markers,
                audioDuration: audioDuration
            ) {
                dismiss()
                await playback.present(imported)
                showingNowPlaying = true
            }
        } catch {
            libraryStore.importError = error.localizedDescription
        }
    }

    private func copyIntoApplicationSupport(_ sourceURL: URL) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Voxglass/LocalAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(UUID().uuidString).\(sourceURL.pathExtension)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func localFiles(in folderURL: URL) throws -> [URL] {
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
