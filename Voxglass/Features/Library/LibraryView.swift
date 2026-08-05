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
    @AppStorage(AppPreferencesStore.Keys.soloOnlyEnabled) private var soloOnly = true

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
        }
    }

    @ViewBuilder
    private var myProductionsEntry: some View {
        let production = AppServices.shared.productionEnvironment
        NavigationLink {
            MyProductionsShelf(store: production.previewStore, sync: production.sync)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color(hex: 0x23303F), Color(hex: 0x3A4A5F)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "waveform.badge.mic")
                        .scaledFont(size: 18)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Productions")
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(Palette.ink)
                    Text("Previews you made in Voxglass Studio on your Mac")
                        .scaledFont(size: 12)
                        .foregroundStyle(Palette.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(size: 12).foregroundStyle(Palette.ink3)
            }
            .padding(13)
            .glassSurface(cornerRadius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.brass.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tactileTap()
        .accessibilityIdentifier("shelf.myProductions")
    }

    @ViewBuilder
    private var bookList: some View {
        VStack(alignment: .leading, spacing: 10) {
            myProductionsEntry
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

                let books = filteredBooks
                VStack(spacing: 0) {
                    ForEach(books.indices, id: \.self) { index in
                        let book = books[index]
                        NavigationLink {
                            BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
                        } label: {
                            CompactBookRowView(
                                book: book,
                                sourceTitle: libraryStore.source(for: book.book)?.title,
                                accessory: .download(offlineManager.state(for: book.book.id), showsNavigation: true),
                                style: .grouped,
                                watchStorage: phoneAudioRelay.watchStorageInfo(for: book.book.id)
                            )
                        }
                        .buttonStyle(.plain)
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
                        if index < books.count - 1 {
                            VoxglassListDivider()
                        }
                    }
                }
                .glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))
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
