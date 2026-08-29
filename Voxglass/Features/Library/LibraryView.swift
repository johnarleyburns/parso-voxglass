import SwiftUI
import VoxglassCore

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @Binding var showingNowPlaying: Bool
    @State private var pendingDeletion: BookWithChapters?
    @State private var pendingWatchTransfer: BookWithChapters?
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var searchScope: LibrarySearchScope = .all
    @State private var isEditing = false
    @State private var bookOrder: [UUID] = []
    @AppStorage(AppPreferencesStore.Keys.soloOnlyEnabled) private var soloOnly = true

    var body: some View {
        VoxglassScreen(
            title: "My Books",
            headerActionTitle: libraryStore.books.isEmpty ? nil : (isEditing ? "Done" : "Edit"),
            headerAction: { withAnimation { isEditing.toggle() } }
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
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .contextMenu {
                            if phoneAudioRelay.isWatchAppInstalled {
                                Button {
                                    Task { await transferToWatch(book, allowCellular: false) }
                                } label: {
                                    Label(watchContextTitle(for: book), systemImage: "applewatch")
                                }
                                .disabled(phoneAudioRelay.isTransferringToWatch)
                            }
                            Button("Remove from My Books", role: .destructive) {
                                pendingDeletion = book
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = book
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
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
