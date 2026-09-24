import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxglassCore
import VoxglassEncoders

enum MacDestination: String, CaseIterable, Hashable, Identifiable {
    case listen, books, discover, narration
    var id: Self { self }
    var title: String {
        switch self { case .listen: "Listen"; case .books: "My Books"; case .discover: "Discover"; case .narration: "Narration" }
    }
    var icon: String {
        switch self { case .listen: "headphones"; case .books: "books.vertical.fill"; case .discover: "sparkles"; case .narration: "mic.fill" }
    }
}

struct VoxglassMacRootView: View {
    let services: MacAppServices
    @StateObject private var router = MacCommandRouter()
    @EnvironmentObject private var library: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var selection: MacDestination = .listen
    @State private var searchRequest = 0
    @State private var newNarrationRequest = 0
    @State private var openProjectRequest = 0
    @State private var importBookRequest = 0
    @State private var audioSetupRequest = 0
    @State private var reviewExportRequest = 0
    @State private var noteRequest = 0
    @State private var showInspector = false
    @State private var showKeyboardShortcuts = false
    @State private var showRecordingTroubleshooting = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationSplitView {
            List(MacDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.icon)
                    .tag(destination)
                    .accessibilityIdentifier("native-mac.sidebar.\(destination.rawValue)")
            }
            .navigationTitle("Voxglass")
            .listStyle(.sidebar)
            .frame(minWidth: 210, idealWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selection {
                    case .listen:
                        MacListenView(onNavigate: { selection = $0 })
                    case .books:
                        MacBooksView(router: router, searchRequest: $searchRequest, importRequest: $importBookRequest)
                    case .discover:
                        MacDiscoverView(router: router, searchRequest: $searchRequest)
                    case .narration:
                        MacNarrationView(
                            services: services,
                            router: router,
                            newNarrationRequest: $newNarrationRequest,
                            openProjectRequest: $openProjectRequest,
                            audioSetupRequest: $audioSetupRequest,
                            reviewExportRequest: $reviewExportRequest,
                            noteRequest: $noteRequest
                        )
                    }
                }
                if let session = playback.currentSession,
                   let book = library.book(withID: session.book.id) {
                    MacMiniPlayer(session: session, book: book)
                }
            }
            .frame(minWidth: 720, minHeight: 560)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .accessibilityIdentifier("native-mac.toolbar.inspector")
                }
            }
            .inspector(isPresented: $showInspector) {
                MacInspectorView(selection: selection, services: services)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.voxglassMacCommandRouter, router)
        .onAppear {
            router.setDestination(selection)
            router.setHasPlaybackSession(playback.currentSession != nil)
            installRouter()
        }
        .onChange(of: selection) { _, destination in
            router.setDestination(destination)
            installRouter()
        }
        .onChange(of: playback.currentSession != nil) { _, hasSession in
            router.setHasPlaybackSession(hasSession)
        }
        .alert("Keyboard Shortcuts", isPresented: $showKeyboardShortcuts) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Listen ⌘1   My Books ⌘2   Discover ⌘3   Narration ⌘4\nSearch ⌘F   Play/Pause Space   Record ⌘R\nAccept ⌘Return   Retry ⌘⇧R   Next/Previous ⌘↓/⌘↑")
        }
        .alert("Recording troubleshooting", isPresented: $showRecordingTroubleshooting) {
            Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            Button("Done", role: .cancel) {}
        } message: {
            Text("Confirm Voxglass has microphone permission, select the intended input in Settings, and reconnect the device if its route disappeared.")
        }
        .alert("Diagnostics", isPresented: $showDiagnostics) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("For support, include the Voxglass version, macOS version, selected microphone, and the time of the problem. Recordings and local books are not sent automatically.")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func installRouter() {
        router.handler = { action in
            switch action {
            case .destination(let destination): selection = destination
            case .newNarration: selection = .narration; newNarrationRequest += 1
            case .search: searchRequest += 1
            case .openProject: selection = .narration; openProjectRequest += 1
            case .importBook: selection = .books; importBookRequest += 1
            case .importAudio: selection = .books; importBookRequest += 1
            case .toggleInspector: showInspector.toggle()
            case .showNowPlaying: services.playback.togglePlayPause()
            case .stopPlayback: services.playback.pause()
            case .previousChapter: Task { await services.playback.skipToPreviousChapter() }
            case .nextChapter: Task { await services.playback.skipToNextChapter() }
            case .addBookmark: services.playback.addBookmark()
            case .openAudioSetup: selection = .narration; audioSetupRequest += 1
            case .openReviewExport: selection = .narration; reviewExportRequest += 1
            case .addNote: selection = .narration; noteRequest += 1
            case .showKeyboardShortcuts: showKeyboardShortcuts = true
            case .showRecordingTroubleshooting: showRecordingTroubleshooting = true
            case .sendDiagnostics: showDiagnostics = true
            case .record, .acceptAndNext, .retry, .nextParagraph, .previousParagraph:
                // The focused narration workspace observes the typed command
                // event. No global notification broadcast is used.
                break
            }
        }
    }
}

struct MacMiniPlayer: View {
    let session: PlaybackSession
    let book: BookWithChapters
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        HStack(spacing: 12) {
            MacCover(title: book.book.title, size: CGSize(width: 34, height: 42))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.book.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(session.chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ProgressView(value: session.progress).frame(width: 150)
            Button(session.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("native-mac.miniplayer.toggle")
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

struct MacListenView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offlineDownloads: OfflineDownloadManager
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var recent: [BookWithChapters] = []

    let onNavigate: (MacDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MacPageHeader(eyebrow: "Listen", title: "Good to have you back.")
                if let session = playback.currentSession,
                   let book = library.book(withID: session.book.id) {
                    MacResumeCard(session: session, book: book)
                } else {
                    MacEmptyCard(title: "Nothing is playing", message: "Open My Books or Discover to start listening.", actions: [
                        ("Open My Books", "books.vertical.fill"), ("Discover", "sparkles")
                    ]) { title in
                        onNavigate(title == "Open My Books" ? .books : .discover)
                    }
                }
                MacSectionTitle(title: "Continue listening")
                if recent.isEmpty {
                    MacEmptyCard(title: "Your listening history will appear here", message: "Resume a book and Voxglass will keep your place.", actions: [])
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(recent) { book in MacBookRow(book: book, actionTitle: "Resume") }
                    }
                }
                MacSectionTitle(title: "Downloaded")
                LazyVStack(spacing: 10) {
                    ForEach(library.visibleBooks.filter { book in
                        if case .cached = offlineDownloads.state(for: book.book.id) { return true }
                        return false
                    }.prefix(4)) { book in MacBookRow(book: book, actionTitle: "Open") }
                }
            }
            .padding(28)
        }
        .task { recent = library.recentlyPlayed }
        .background(MacBackground())
    }

}

struct MacResumeCard: View {
    let session: PlaybackSession
    let book: BookWithChapters
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        HStack(spacing: 24) {
            MacCover(title: book.book.title, size: CGSize(width: 150, height: 190))
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue listening").macEyebrow()
                Text(book.book.title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Chapter \(session.chapter.index + 1) · \(session.chapter.title)").foregroundStyle(.secondary)
                ProgressView(value: session.progress)
                Text("\(formatTime(session.position)) · \(session.duration.map(formatTime) ?? "unknown")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button(session.isPlaying ? "Pause" : "Resume") { playback.togglePlayPause() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("native-mac.listen.resume")
                    Button("Open book") { Task { await playback.present(book) } }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(24)
        .background(MacPanel())
        .accessibilityIdentifier("native-mac.listen.current-session")
    }
}

struct MacBooksView: View {
    @ObservedObject var router: MacCommandRouter
    @EnvironmentObject private var library: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var searchRequest: Int
    @Binding var importRequest: Int
    @State private var query = ""
    @State private var isSearching = false
    @State private var showImporter = false
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    var filteredBooks: [BookWithChapters] {
        let books = library.visibleBooks
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return books }
        let needle = query.lowercased()
        return books.filter {
            $0.book.title.lowercased().contains(needle)
                || $0.book.authors.joined(separator: " ").lowercased().contains(needle)
                || $0.book.narrators.joined(separator: " ").lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(eyebrow: "My Books", title: "All books", trailing: AnyView(
                HStack {
                    Button { isSearching.toggle(); searchFocused = isSearching } label: { Label("Search", systemImage: "magnifyingglass") }
                    Button { showFilters.toggle() } label: { Label("Filter & Sort", systemImage: "line.3.horizontal.decrease.circle") }
                        .popover(isPresented: $showFilters) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Sort books").font(.headline)
                                ForEach(Array([
                                    (LibrarySort.recent, "Recently used"),
                                    (.title, "Title"),
                                    (.author, "Author"),
                                    (.narrator, "Narrator"),
                                    (.duration, "Duration"),
                                    (.progress, "Progress")
                                ].enumerated()), id: \.offset) { _, candidate in
                                    Button {
                                        library.sort = candidate.0
                                        showFilters = false
                                    } label: {
                                        Label(candidate.1, systemImage: library.sort == candidate.0 ? "checkmark" : "circle")
                                    }
                                }
                            }
                            .padding(16)
                            .frame(width: 190)
                        }
                    Button { showImporter = true } label: { Label("Add", systemImage: "plus") }
                }
            ))
            if isSearching {
                HStack { Image(systemName: "magnifyingglass"); TextField("Title, author, narrator", text: $query).focused($searchFocused); if !query.isEmpty { Button("Clear") { query = "" } } }
                    .padding(10).background(MacPanel()).padding(.horizontal, 28).padding(.top, 12)
            }
            HStack {
                MacFilterButton(title: "All", selected: library.progressFilter == .all) { library.progressFilter = .all }
                MacFilterButton(title: "In Progress", selected: library.progressFilter == .inProgress) { library.progressFilter = .inProgress }
                MacFilterButton(title: "Finished", selected: library.progressFilter == .finished) { library.progressFilter = .finished }
                Spacer()
                Text("\(filteredBooks.count) books").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 16)
            List(filteredBooks) { book in
                MacBookRow(book: book, actionTitle: "Open") { Task { await playback.present(book) } }
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("native-mac.books.row.\(book.book.id.uuidString)")
            }.listStyle(.inset)
        }
        .background(MacBackground())
        .onChange(of: searchRequest) { _, _ in isSearching = true; searchFocused = true }
        .onChange(of: importRequest) { _, _ in showImporter = true }
        .onChange(of: searchFocused) { _, focused in router.setTextEditorFocused(focused) }
        .onDisappear { router.setTextEditorFocused(false) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let folderURL) = result else { return }
            Task { await importLocalFolder(folderURL) }
        }
    }

    private func importLocalFolder(_ folderURL: URL) async {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await LocalAudiobookPreparer.prepare(folderURL: folderURL)
            }.value
            _ = await library.importLocalSingleFile(
                folderURL: folderURL,
                folderName: prepared.folderName,
                audioURL: prepared.audioURL,
                bookmark: prepared.bookmark,
                markers: prepared.markers,
                audioDuration: prepared.audioDuration,
                coverURL: prepared.coverURL
            )
            await library.refresh()
        } catch {
            library.importError = error.localizedDescription
        }
    }
}

struct MacDiscoverView: View {
    @ObservedObject var router: MacCommandRouter
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var library: LibraryStore
    @Binding var searchRequest: Int
    @State private var query = ""
    @State private var isSearching = false
    @State private var mode: DiscoverMode = .collections
    @State private var selectedCollection: IACollection?
    @State private var sort: CatalogSort = .popularity
    @State private var searchScope: SearchScope = .all
    @State private var showFilters = false
    @State private var infoCollection: IACollection?
    @FocusState private var searchFocused: Bool

    enum DiscoverMode: String, CaseIterable { case all = "All", collections = "Collections" }
    enum SearchScope: String, CaseIterable { case all = "All", title = "Title", author = "Author", narrator = "Narrator" }

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(eyebrow: "Discover", title: "Find something good.", trailing: AnyView(
                HStack {
                    Button { isSearching.toggle(); searchFocused = isSearching } label: { Label("Search", systemImage: "magnifyingglass") }
                    Button { showFilters.toggle() } label: { Label("Filter & Sort", systemImage: "line.3.horizontal.decrease.circle") }
                        .popover(isPresented: $showFilters) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Sort").font(.headline)
                                ForEach(CatalogSort.allCases.filter { $0 != .curation }) { candidate in
                                    Button { sort = candidate; showFilters = false; runSearch() } label: {
                                        let iconName = candidate == sort ? "checkmark" : "circle"
                                        Label(candidate.title, systemImage: iconName)
                                    }
                                }
                            }.padding(16).frame(width: 190)
                        }
                }
            ))
            if isSearching {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Title, author, narrator", text: $query)
                        .focused($searchFocused)
                        .onSubmit { runSearch() }
                    Picker("Search in", selection: $searchScope) {
                        ForEach(SearchScope.allCases, id: \.self, content: searchScopeRow)
                    }.pickerStyle(.menu).labelsHidden()
                    if !query.isEmpty { Button("Clear") { query = ""; catalog.resetResultsForNavigation() } }
                }
                    .padding(10).background(MacPanel()).padding(.horizontal, 28).padding(.top, 12)
            }
            HStack {
                ForEach(DiscoverMode.allCases, id: \.self) { item in MacFilterButton(title: item.rawValue, selected: mode == item) { mode = item } }
                if let selectedCollection {
                    HStack(spacing: 6) {
                        Text(selectedCollection.title).font(.callout.weight(.semibold))
                        Button { clearCollection() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear selected collection")
                    }.padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer()
            }.padding(.horizontal, 28).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if mode == .collections && selectedCollection == nil && query.isEmpty {
                        MacFeaturedCollections(collections: IACollectionStore.collections(for: [], languages: catalog.selectedLanguages), info: { infoCollection = $0 }) { collection in
                            selectedCollection = collection
                            mode = .all
                            runSearch()
                        }
                    }
                    if !catalog.results.isEmpty {
                        MacSectionTitle(title: "Catalog")
                        ForEach(catalog.results) { result in MacCatalogRow(result: result) }
                    } else if catalog.isSearching {
                        ProgressView("Searching catalog…").frame(maxWidth: .infinity, minHeight: 180)
                    } else if !query.isEmpty {
                        MacEmptyCard(title: "No matches", message: "Try a title, author, or narrator.", actions: [])
                    } else {
                        MacEmptyCard(title: "Search the catalog", message: "Discover public-domain audiobooks from the sources Voxglass supports.", actions: [])
                    }
                }.padding(28)
            }
        }
        .background(MacBackground())
        .onChange(of: searchRequest) { _, _ in isSearching = true; searchFocused = true }
        .onChange(of: searchFocused) { _, focused in router.setTextEditorFocused(focused) }
        .onDisappear { router.setTextEditorFocused(false) }
        .sheet(item: $infoCollection) { collection in
            MacCollectionInfoView(collection: collection)
        }
    }

    private func searchScopeRow(_ scope: SearchScope) -> some View {
        Text(scope.rawValue).tag(scope)
    }

    private func runSearch() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let selectedCollection {
                let scoped = term.isEmpty ? selectedCollection.archiveQuery : "(\(selectedCollection.archiveQuery)) AND (\(scopedQuery(term, includeCatalogScope: false)))"
                await catalog.searchAdvanced(scoped, sort: sort, collectionID: selectedCollection.id)
            } else if !term.isEmpty {
                mode = .all
                await catalog.searchAdvanced(scopedQuery(term), sort: sort)
            } else {
                catalog.resetResultsForNavigation()
            }
        }
    }

    private func scopedQuery(_ value: String, includeCatalogScope: Bool = true) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "")
        let scope = includeCatalogScope ? " AND \(LibriVoxCatalogScope.query)" : ""
        switch searchScope {
        case .all: return value + scope
        case .title: return "title:\"\(escaped)\"\(scope)"
        case .author: return "creator:\"\(escaped)\"\(scope)"
        case .narrator: return "(creator:\"\(escaped)\" OR description:\"\(escaped)\")\(scope)"
        }
    }

    private func clearCollection() {
        selectedCollection = nil
        query = ""
        catalog.resetResultsForNavigation()
        mode = .collections
    }
}

struct MacNarrationView: View {
    let services: MacAppServices
    @ObservedObject var router: MacCommandRouter
    @Binding var newNarrationRequest: Int
    @Binding var openProjectRequest: Int
    @Binding var audioSetupRequest: Int
    @Binding var reviewExportRequest: Int
    @Binding var noteRequest: Int
    @State private var projects: [AudiobookProject] = []
    @State private var selectedProjectID: UUID?
    @State private var showingSourceImporter = false
    @State private var showingProjectImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationSplitView {
            List(projects, selection: $selectedProjectID) { project in
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.metadata.title).fontWeight(.semibold)
                    Text("\(project.recordedCount) of \(project.totalCount) paragraphs")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: project.percentRecorded)
                }.tag(project.id)
            }
            .navigationTitle("Narration")
            .toolbar { Button { showingSourceImporter = true } label: { Label("New narration", systemImage: "plus") } }
        } detail: {
            if let selectedProject = projects.first(where: { $0.id == selectedProjectID }) {
                MacNarrationWorkspace(
                    project: selectedProject,
                    services: services,
                    router: router,
                    audioSetupRequest: $audioSetupRequest,
                    reviewExportRequest: $reviewExportRequest,
                    noteRequest: $noteRequest
                ) { reload() }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    MacEmptyCard(title: "Start or open a narration", message: "Choose an EPUB, Markdown, DOCX, or text source to create a project. Recording stays local and can continue without iCloud.", actions: [])
                    Button("New narration from source…") { showingSourceImporter = true }.buttonStyle(.borderedProminent)
                }.padding(32)
            }
        }
        .task { reload() }
        .onChange(of: newNarrationRequest) { _, _ in showingSourceImporter = true }
        .onChange(of: openProjectRequest) { _, _ in showingProjectImporter = true }
        .fileImporter(isPresented: $showingSourceImporter, allowedContentTypes: sourceImportContentTypes) { result in
            guard case .success(let url) = result else { return }
            Task { await createProject(from: url) }
        }
        .fileImporter(isPresented: $showingProjectImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do {
                    try await services.narrationRepository.importProjectPackage(from: url)
                    reload()
                } catch { importError = error.localizedDescription }
            }
        }
        .alert("Couldn't create narration", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func reload() {
        Task { projects = await services.narrationRepository.allProjects() }
    }

    private func createProject(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let importer = SourceImporterRegistry.importer(for: url) else {
                throw MacNarrationImportError.unsupportedFile
            }
            let document = try await importer.extract(from: url)
            let title = document.title ?? url.deletingPathExtension().lastPathComponent
            let build = NarrationProjectBuilder().build(
                document: document,
                title: title,
                author: document.author ?? "Unknown",
                narrator: UserDefaults.standard.string(forKey: "voxglass.narratorName") ?? "",
                sourceURL: url,
                ids: UUIDGenerator(),
                clock: SystemClock()
            )
            try await services.narrationRepository.save(build.project)
            reload()
            selectedProjectID = build.project.id
        } catch {
            importError = error.localizedDescription
        }
    }

    private var sourceImportContentTypes: [UTType] {
        var types: [UTType] = [.epub, .plainText, .text]
        if let markdown = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx") {
            types.append(docx)
        }
        return types
    }
}

private enum MacNarrationImportError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        "Voxglass could not identify this narration source. Choose an EPUB, Markdown, DOCX, or text file."
    }
}

struct MacNarrationWorkspace: View {
    @State private var project: AudiobookProject
    let services: MacAppServices
    @ObservedObject var router: MacCommandRouter
    @Binding var audioSetupRequest: Int
    @Binding var reviewExportRequest: Int
    @Binding var noteRequest: Int
    let onSaved: () -> Void
    @State private var selectedParagraphID: UUID?
    @State private var isRecording = false
    @State private var message: String?
    @State private var showingReview = false
    @State private var recordingStartedAt: Date?
    @State private var latestLevels: CaptureLevels?
    @State private var isMonitoring = false
    @State private var showDetails = false
    @State private var notes: [ReviewNote] = []
    @State private var noteDraft = ""
    @State private var showingTakeComparison = false
    @State private var showingAudioSetup = false

    init(
        project: AudiobookProject,
        services: MacAppServices,
        router: MacCommandRouter,
        audioSetupRequest: Binding<Int>,
        reviewExportRequest: Binding<Int>,
        noteRequest: Binding<Int>,
        onSaved: @escaping () -> Void
    ) {
        _project = State(initialValue: project)
        self.services = services
        self.router = router
        _audioSetupRequest = audioSetupRequest
        _reviewExportRequest = reviewExportRequest
        _noteRequest = noteRequest
        self.onSaved = onSaved
    }

    private var paragraphs: [Paragraph] {
        project.chapters.flatMap { chapter in chapter.paragraphs }
    }

    private var paragraph: Paragraph? { project.allParagraphs.first { $0.id == selectedParagraphID } ?? project.allParagraphs.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading) { Text(project.metadata.title).font(.title2.bold()); Text("\(project.recordedCount) of \(project.totalCount) recorded").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }.buttonStyle(.bordered); Button("Review & Export") { showingReview = true }.buttonStyle(.bordered); Button("Record next") { selectedParagraphID = project.allParagraphs.first(where: { $0.selectedTakeID == nil })?.id; startRecording() }.buttonStyle(.borderedProminent).accessibilityIdentifier("native-mac.projects.record-next") }.padding(20)
            Divider()
            HSplitView {
                List(selection: $selectedParagraphID) {
                    ForEach(paragraphs, id: \.id) { item in
                        Text(paragraphLabel(item))
                            .lineLimit(1)
                            .tag(item.id)
                    }
                }
                .frame(minWidth: 260, idealWidth: 330)
                VStack(alignment: .leading, spacing: 18) {
                    if let paragraph {
                        Text("PARAGRAPH \(paragraph.ordinal + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(paragraph.text).font(.system(size: 24, design: .serif)).lineSpacing(7).textSelection(.enabled)
                        if let message { Text(message).foregroundStyle(.orange) }
                        if isRecording || isMonitoring {
                            MacRecordingStatus(
                                startedAt: recordingStartedAt,
                                levels: latestLevels,
                                route: services.capture.currentRouteInfo
                            )
                        }
                        HStack {
                            Button(isRecording ? "Stop" : "Record") { isRecording ? stopRecording() : startRecording() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut("r", modifiers: .command)
                                .accessibilityIdentifier("native-mac.record.toggle")
                            if !isRecording {
                                Button(isMonitoring ? "Stop monitor" : "Monitor input") { toggleMonitoring() }
                                    .buttonStyle(.bordered)
                            }
                            Button("Accept and next") { acceptAndNext() }
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(paragraph.selectedTakeID == nil || isRecording)
                            Spacer()
                        }
                    } else { Text("Choose a paragraph").foregroundStyle(.secondary) }
                    Spacer()
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
                if showDetails {
                    MacNarrationDetails(
                        paragraph: paragraph,
                        notes: notes,
                        noteDraft: $noteDraft,
                        onSaveNote: saveNote,
                        onSelectTake: selectTake,
                        onCompare: { showingTakeComparison = true }
                    )
                    .frame(minWidth: 280, idealWidth: 320)
                }
            }
        }
        .onAppear { updateCommandContext() }
        .onChange(of: selectedParagraphID) { _, _ in
            updateCommandContext()
            loadDetails()
        }
        .onChange(of: audioSetupRequest) { _, _ in showingAudioSetup = true }
        .onChange(of: reviewExportRequest) { _, _ in showingReview = true }
        .onChange(of: noteRequest) { _, _ in showDetails = true }
        .onChange(of: project.recordedCount) { _, _ in updateCommandContext() }
        .onChange(of: router.latestEvent?.id) { _, _ in
            guard let action = router.latestEvent?.action else { return }
            switch action { case .record: isRecording ? stopRecording() : startRecording(); case .acceptAndNext: acceptAndNext(); case .nextParagraph: moveParagraph(by: 1); case .previousParagraph: moveParagraph(by: -1); case .retry: startRecording(); default: break }
        }
        .task(id: isRecording) {
            guard isRecording else { return }
            for await levels in services.capture.levels {
                guard !Task.isCancelled else { return }
                latestLevels = levels
            }
        }
        .task(id: selectedParagraphID) { loadDetails() }
        .onDisappear {
            if isMonitoring { Task { await services.capture.stopMonitoring() } }
        }
        .sheet(isPresented: $showingReview) {
            MacReviewExportView(project: project, services: services)
                .frame(minWidth: 620, minHeight: 520)
        }
        .sheet(isPresented: $showingAudioSetup) {
            MacAudioSetupView(services: services)
                .frame(minWidth: 520, minHeight: 300)
        }
        .sheet(isPresented: $showingTakeComparison) {
            if let paragraph {
                MacTakeComparisonView(
                    paragraph: paragraph,
                    services: services,
                    onSelectTake: selectTake
                )
                .frame(minWidth: 560, minHeight: 420)
            }
        }
    }

    private func updateCommandContext() {
        router.setWorkspaceSelection(hasParagraph: paragraph != nil, hasTake: paragraph?.selectedTakeID != nil)
    }

    private func loadDetails() {
        guard let paragraph else {
            notes = []
            noteDraft = ""
            return
        }
        Task {
            notes = (try? await services.narrationRepository.store(for: project.id).notes(forParagraph: paragraph.id)) ?? []
        }
    }

    private func saveNote() {
        guard let paragraph, !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let note = ReviewNote(
            id: services.narrationRepository.ids.next(),
            paragraphID: paragraph.id,
            text: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            device: .mac,
            createdAt: services.narrationRepository.clock.now
        )
        noteDraft = ""
        Task {
            try? await services.narrationRepository.insertNote(note, projectID: project.id)
            loadDetails()
        }
    }

    private func selectTake(_ takeID: UUID) {
        guard let paragraph else { return }
        guard paragraph.takes.contains(where: { $0.id == takeID }) else { return }
        for chapterIndex in project.chapters.indices {
            guard let paragraphIndex = project.chapters[chapterIndex].paragraphs.firstIndex(where: { $0.id == paragraph.id }) else { continue }
            project.chapters[chapterIndex].paragraphs[paragraphIndex].selectedTakeID = takeID
            project.chapters[chapterIndex].paragraphs[paragraphIndex].reviewState = .approved
            for takeIndex in project.chapters[chapterIndex].paragraphs[paragraphIndex].takes.indices {
                project.chapters[chapterIndex].paragraphs[paragraphIndex].takes[takeIndex].isArchived = project.chapters[chapterIndex].paragraphs[paragraphIndex].takes[takeIndex].id != takeID
            }
            project.modifiedAt = services.narrationRepository.clock.now
            Task {
                try? await services.narrationRepository.save(project)
                onSaved()
                updateCommandContext()
            }
            break
        }
    }

    private func toggleMonitoring() {
        Task {
            do {
                if isMonitoring {
                    await services.capture.stopMonitoring()
                    isMonitoring = false
                    latestLevels = nil
                } else {
                    try await services.capture.prepare(device: nil, format: project.profile.recording)
                    try await services.capture.startMonitoring()
                    isMonitoring = true
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func startRecording() {
        guard let paragraph else { return }
        Task {
            do {
                try await services.capture.prepare(device: nil, format: project.profile.recording)
                let url = services.narrationRepository.autosaveTakesURL(for: project.id).appendingPathComponent("mac-\(paragraph.id.uuidString).wav")
                try await services.capture.startRecording(to: url)
                isRecording = true
                isMonitoring = false
                recordingStartedAt = Date()
                latestLevels = nil
            } catch { message = error.localizedDescription }
        }
    }

    private func stopRecording() {
        Task {
            do {
                let captured = try await services.capture.stopRecording()
                isRecording = false
                recordingStartedAt = nil
                guard let paragraph else { return }
                let take = try await services.narrationRepository.ingestCapturedTake(fileURL: captured.fileURL, paragraphID: paragraph.id, projectID: project.id, captured: captured, textHash: paragraph.textHash, routeClass: CaptureRouteClassifier.classify(services.capture.currentRouteInfo))
                let store = services.narrationRepository.store(for: project.id)
                try await store.insertTake(take)
                try await store.setSelectedTake(take.id, forParagraph: paragraph.id)
                project = try await services.narrationRepository.load(project.id)
                message = "Take saved."
                onSaved()
            } catch { isRecording = false; recordingStartedAt = nil; message = error.localizedDescription }
        }
    }

    private func acceptAndNext() { moveParagraph(by: 1) }
    private func paragraphLabel(_ paragraph: Paragraph) -> String {
        "¶ " + String(paragraph.ordinal + 1) + "  " + String(paragraph.text.prefix(58))
    }

    private func moveParagraph(by offset: Int) {
        let paragraphs = project.allParagraphs
        let index = paragraphs.firstIndex { $0.id == (selectedParagraphID ?? paragraphs.first?.id) } ?? 0
        selectedParagraphID = paragraphs.indices.contains(index + offset) ? paragraphs[index + offset].id : selectedParagraphID
    }
}

struct MacReviewExportView: View {
    let project: AudiobookProject
    let services: MacAppServices
    @Environment(\.dismiss) private var dismiss
    @State private var issues: [ValidationIssue] = []
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var exportProgress = ExportProgress(phase: .validating)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading) { Text("Review & Export").font(.title.bold()); Text(project.metadata.title).foregroundStyle(.secondary) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.escape) }
            Divider()
            Text(issues.isEmpty ? "No validation blockers found." : "\(issues.count) item(s) need attention before export.")
                .font(.headline)
            if issues.isEmpty {
                MacEmptyCard(title: "Ready for export", message: "The current project graph passes validation. The shared resumable package pipeline will render and preserve progress if interrupted.", actions: [])
            } else {
                List(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).fontWeight(.semibold)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
            if isExporting {
                ProgressView(value: exportProgress.fractionCompleted) {
                    Text(exportProgress.currentFileName.map { "Exporting \($0)" } ?? "Preparing export…")
                } currentValueLabel: {
                    Text("\(Int(exportProgress.fractionCompleted * 100))%")
                }
                if let remaining = exportProgress.estimatedRemaining {
                    Text("About \(formatTime(remaining)) remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(isExporting ? "Exporting…" : "Export") { Task { await export() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || issues.contains(where: { $0.severity == .blocking }))
                    .accessibilityIdentifier("native-mac.export.start")
            }
            Spacer()
        }
        .padding(24)
        .task {
            issues = ValidationRuleEngine().evaluate(
                project: project,
                metrics: PackagingSupport.selectedTakeMetrics(project),
                profile: DestinationProfile.profile(for: project.profile.intendedDestination),
                eligibility: EligibilityProfile.evaluate(project),
                assembly: project.profile.assembly
            )
        }
    }

    private func export() async {
        let blockers = issues.filter { $0.severity == .blocking }
        guard blockers.isEmpty else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let builder: any PackageBuilder
            switch project.profile.intendedDestination {
            case .librivox: builder = LibriVoxPackageBuilder()
            case .internetArchive: builder = InternetArchivePackageBuilder()
            case .personalMaster, .acx, .appleBooksAggregator:
                builder = RetailMasterPackageBuilder(destination: project.profile.intendedDestination)
            }
            let exportsRoot = services.narrationRepository.applicationSupport
                .appendingPathComponent("Voxglass/Exports", isDirectory: true)
            let outcome = try await ResumableExportRunner(store: services.narrationRepository.store(for: project.id)).run(
                builder: builder,
                project: project,
                renders: AVChapterRenderer(assetsRoot: services.narrationRepository.layout(for: project.id).root),
                transcoder: VoxTranscoder(),
                assets: services.narrationRepository.fileStore(for: project.id),
                into: exportsRoot,
                options: ExportOptions(scope: .wholeBook, appVersion: "Voxglass macOS"),
                progress: { progress in
                    Task { @MainActor in exportProgress = progress }
                }
            )
            exportMessage = "Exported to \(outcome.bundle?.rootURL.path ?? "the Voxglass export folder")."
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

private struct MacNarrationDetails: View {
    let paragraph: Paragraph?
    let notes: [ReviewNote]
    @Binding var noteDraft: String
    let onSaveNote: () -> Void
    let onSelectTake: (UUID) -> Void
    let onCompare: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let paragraph {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TAKES").macEyebrow()
                        if paragraph.takes.isEmpty {
                            Text("No takes yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(paragraph.takes) { take in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(take.label ?? "Take")
                                            .font(.callout.weight(.semibold))
                                        Text("\(formatTime(take.duration)) · \(take.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if take.id == paragraph.selectedTakeID {
                                        Label("Selected", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else {
                                        Button("Use") { onSelectTake(take.id) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            if paragraph.takes.count >= 2 {
                                Button("Compare latest takes", action: onCompare)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("NOTES").macEyebrow()
                    if notes.isEmpty {
                        Text("No notes for this paragraph.").foregroundStyle(.secondary)
                    } else {
                        ForEach(notes) { note in
                            Text(note.text)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    TextField("Add a note…", text: $noteDraft, axis: .vertical)
                        .lineLimit(2...5)
                    Button("Save note", action: onSaveNote)
                        .buttonStyle(.borderedProminent)
                        .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(18)
        }
        .background(MacPanel())
    }
}

private struct MacTakeComparisonView: View {
    let paragraph: Paragraph
    let services: MacAppServices
    let onSelectTake: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var playingTakeID: UUID?
    @State private var sound: NSSound?

    private var comparedTakes: [Take] { Array(paragraph.takes.suffix(2).reversed()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Compare takes").font(.title2.bold())
                    Text("Choose the take that should be used for this paragraph.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { stopPlayback(); dismiss() }
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                ForEach(comparedTakes) { take in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(take.label ?? "Take").font(.headline)
                        Text("\(formatTime(take.duration)) · \(take.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let metrics = take.metrics {
                            LabeledContent("Peak", value: String(format: "%.1f dBFS", metrics.peakDBFS))
                            LabeledContent("RMS", value: String(format: "%.1f dBFS", metrics.rmsDBFS))
                        }
                        Button(playingTakeID == take.id ? "Stop" : "Play") { togglePlayback(take) }
                            .buttonStyle(.bordered)
                        Button(take.id == paragraph.selectedTakeID ? "Selected" : "Use this take") {
                            onSelectTake(take.id)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(take.id == paragraph.selectedTakeID)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MacPanel())
                }
            }
            Spacer()
        }
        .padding(24)
        .onDisappear { stopPlayback() }
    }

    private func togglePlayback(_ take: Take) {
        if playingTakeID == take.id {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let url = services.narrationRepository.takeURL(for: paragraph.id, take: take) else { return }
        sound = NSSound(contentsOf: url, byReference: true)
        sound?.play()
        playingTakeID = take.id
    }

    private func stopPlayback() {
        sound?.stop()
        sound = nil
        playingTakeID = nil
    }
}

struct MacSettingsView: View {
    let services: MacAppServices
    @State private var usage: AudioCache.StorageUsage?
    @State private var productionUsage: StorageReport?
    @State private var devices: [AudioDeviceInfo] = []
    @State private var selectedDeviceID = ""
    @State private var confirmStreamingClear = false
    @State private var confirmOfflineClear = false

    var body: some View {
        Form {
            Section("Storage") {
                if let usage {
                    LabeledContent("Streaming cache", value: ByteCountFormatter.string(fromByteCount: usage.streamingBytes, countStyle: .file))
                    LabeledContent("Offline books", value: ByteCountFormatter.string(fromByteCount: usage.durableBytes, countStyle: .file))
                    Button("Clear streaming cache (\(formatBytes(usage.streamingBytes)))") { confirmStreamingClear = true }
                    Button("Clear offline downloads (\(formatBytes(usage.durableBytes)))", role: .destructive) { confirmOfflineClear = true }
                }
                Text("Local book files and narration originals are not part of either cache and are never deleted by these actions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Narration storage") {
                if let productionUsage {
                    LabeledContent("Local narration originals", value: formatBytes(productionUsage.originalBytes))
                    LabeledContent("Regenerable render/proxy cache", value: formatBytes(productionUsage.renderBytes + productionUsage.proxyBytes))
                    LabeledContent("Export staging and packages", value: formatBytes(productionUsage.exportBytes))
                    LabeledContent("Unreferenced package files", value: formatBytes(productionUsage.orphanBytes + productionUsage.trashBytes))
                } else {
                    ProgressView("Calculating project storage…")
                }
                Text("The storage report scans each narration package. Clearing the listening cache cannot touch these originals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio & recording") {
                Picker("Input device", selection: $selectedDeviceID) { ForEach(devices) { Text($0.name).tag($0.id) } }
                    .onChange(of: selectedDeviceID) { _, value in services.capture.setPreferredInputDevice(value) }
                if devices.isEmpty {
                    Text("No microphone is available. Connect an input device and grant Voxglass microphone access in System Settings.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("The selected input is used for new takes. Route quality and warnings appear in the narration workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Sync") {
                Button("Check iCloud now") { Task { await services.syncLibrary() } }
                Text("Local recording never waits for iCloud. Projects sync through the existing production package and CloudKit transport.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .confirmationDialog("Clear streaming cache?", isPresented: $confirmStreamingClear) {
            Button("Clear \(formatBytes(usage?.streamingBytes ?? 0))", role: .destructive) { Task { await AudioCache.clearStreamingCache(); usage = await AudioCache.storageUsage() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only regenerable streaming audio will be removed.") }
        .confirmationDialog("Clear offline downloads?", isPresented: $confirmOfflineClear) {
            Button("Clear \(formatBytes(usage?.durableBytes ?? 0))", role: .destructive) { Task { await services.offlineDownloads.removeAllOffline(); await AudioCache.clearOfflineCache(); usage = await AudioCache.storageUsage() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Downloaded copies will be removed. Local book files and narration originals remain untouched.") }
        .task {
            usage = await AudioCache.storageUsage()
            productionUsage = await loadProductionStorage()
            devices = await services.capture.availableInputDevices()
            selectedDeviceID = devices.first(where: \.isDefault)?.id ?? devices.first?.id ?? ""
            services.capture.setPreferredInputDevice(selectedDeviceID.isEmpty ? nil : selectedDeviceID)
        }
    }

    private func loadProductionStorage() async -> StorageReport {
        var total = StorageReport()
        for project in await services.narrationRepository.allProjects() {
            guard let package = try? await ProjectPackage.open(services.narrationRepository.layout(for: project.id).root),
                  let report = try? await StorageAnalyzer().report(package: package, project: project) else { continue }
            total.originalBytes += report.originalBytes
            total.renderBytes += report.renderBytes
            total.proxyBytes += report.proxyBytes
            total.textBytes += report.textBytes
            total.artworkBytes += report.artworkBytes
            total.exportBytes += report.exportBytes
            total.trashBytes += report.trashBytes
            total.orphanBytes += report.orphanBytes
            total.estimatedProjectionBytes += report.estimatedProjectionBytes
        }
        return total
    }
}

private struct MacAudioSetupView: View {
    let services: MacAppServices
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [AudioDeviceInfo] = []
    @State private var selectedDeviceID = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Setup").font(.title2.bold())
                    Text("Choose the microphone used for the next take.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            Divider()
            if devices.isEmpty {
                Text("No microphone is available. Connect an input device and grant microphone access in System Settings.")
                    .foregroundStyle(.orange)
            } else {
                Picker("Input device", selection: $selectedDeviceID) {
                    ForEach(devices) { device in
                        Text("\(device.name) · \(device.transport)").tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, value in
                    services.capture.setPreferredInputDevice(value)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                }
                Button("Test monitor") {
                    Task {
                        do {
                            try await services.capture.prepare(device: selectedDeviceID, format: RecordingDefaults())
                            try await services.capture.startMonitoring()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
        .task {
            devices = await services.capture.availableInputDevices()
            selectedDeviceID = devices.first(where: \.isDefault)?.id ?? devices.first?.id ?? ""
            services.capture.setPreferredInputDevice(selectedDeviceID.isEmpty ? nil : selectedDeviceID)
        }
        .onDisappear {
            Task { await services.capture.stopMonitoring() }
        }
    }
}

struct MacInspectorView: View {
    let selection: MacDestination
    let services: MacAppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selection.title).font(.title3.bold())
            switch selection {
            case .listen:
                if let session = services.playback.currentSession {
                    LabeledContent("Book", value: session.book.title)
                    LabeledContent("Chapter", value: session.chapter.title)
                    LabeledContent("Position", value: formatTime(session.position))
                } else {
                    Text("Start a book to see playback details here.").foregroundStyle(.secondary)
                }
            case .books:
                LabeledContent("Books", value: "\(services.libraryStore.visibleBooks.count)")
                Text("Select a book row for playback and download actions.").foregroundStyle(.secondary)
            case .discover:
                LabeledContent("Results", value: "\(services.catalogStore.results.count)")
                Text("Collection explanations are available from each collection's info button.").foregroundStyle(.secondary)
            case .narration:
                Text("Select a project to see recording, take, validation, and storage details.").foregroundStyle(.secondary)
                Text("Recording remains local when iCloud is unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }
}

struct MacCatalogRow: View {
    let result: InternetArchiveSearchResult
    var body: some View { HStack { MacCover(title: result.title, size: CGSize(width: 45, height: 58)); VStack(alignment: .leading) { Text(result.title).fontWeight(.semibold); Text("\(result.authorLine) · \(result.recordingDetailsLine)").font(.caption).foregroundStyle(.secondary); if let narrator = result.narratorLine { Text(narrator).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button("Open book") { NSWorkspace.shared.open(result.detailsURL) }.buttonStyle(.bordered) }.padding(12).background(MacPanel()) }
}

private struct MacRecordingStatus: View {
    let startedAt: Date?
    let levels: CaptureLevels?
    let route: CaptureRouteInfo

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 8, height: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let startedAt {
                    Text(formatTime(context.date.timeIntervalSince(startedAt)))
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Monitoring")
                        .font(.caption)
                }
            }
            if let levels {
                ProgressView(value: Double(max(0, min(1, (levels.rmsDBFS + 60) / 60))))
                    .tint(levels.isClipping ? .red : .accentColor)
                    .frame(width: 140)
                Text(levels.isClipping ? "Clipping" : String(format: "%.1f dB", levels.rmsDBFS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(levels.isClipping ? .red : .secondary)
            }
            Text(route.transports.map(\.rawValue).sorted().joined(separator: ", ").capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct MacFeaturedCollections: View {
    let collections: [IACollection]
    let info: (IACollection) -> Void
    let select: (IACollection) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionTitle(title: "Featured Collections")
            LazyVStack(spacing: 10) {
                ForEach(collections) { collection in
                    HStack(spacing: 14) {
                        MacCover(title: collection.title, size: CGSize(width: 120, height: 76))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.title).fontWeight(.semibold)
                            Text(collection.summaryLine.isEmpty ? collection.subtitle : collection.summaryLine)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack { Text(collection.archiveIdentifier ?? "Curated catalog").font(.caption2).foregroundStyle(.tertiary); Spacer(); Button("Open collection") { select(collection) }.buttonStyle(.borderedProminent) }
                        }
                        Spacer(minLength: 0)
                        Button { info(collection) } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).accessibilityLabel("About \(collection.title)")
                    }.padding(12).background(MacPanel())
                }
            }
        }
    }
}

struct MacCollectionInfoView: View {
    let collection: IACollection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(collection.title).font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text(collection.subtitle).foregroundStyle(.secondary)
            if !collection.summaryLine.isEmpty { Text(collection.summaryLine).fontWeight(.semibold) }
            ScrollView { Text(collection.description.isEmpty ? "This collection groups public-domain recordings from the Voxglass catalog." : collection.description).textSelection(.enabled) }
            Spacer()
        }.padding(24)
    }
}

struct MacBookRow: View {
    let book: BookWithChapters
    let actionTitle: String
    var action: (() -> Void)?
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var offlineDownloads: OfflineDownloadManager
    @EnvironmentObject private var library: LibraryStore
    init(book: BookWithChapters, actionTitle: String, action: (() -> Void)? = nil) { self.book = book; self.actionTitle = actionTitle; self.action = action }
    var body: some View { HStack { MacCover(title: book.book.title, size: CGSize(width: 54, height: 70)); VStack(alignment: .leading, spacing: 4) { Text(book.book.title).fontWeight(.semibold); Text(book.book.authorLine).font(.caption).foregroundStyle(.secondary); if let narrator = book.book.narratorLine { Text(narrator).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button(actionTitle) { openBook() }.buttonStyle(.borderedProminent); Menu { Button("Play") { Task { await playback.play(book) } }; Button(book.book.isFavorite ? "Remove favorite" : "Add favorite") { Task { await library.setFavorite(!book.book.isFavorite, for: book.book.id) } }; Divider(); if case .cached = offlineDownloads.state(for: book.book.id) { Button("Remove offline copy") { Task { await offlineDownloads.removeOffline(book: book) } } } else { Button("Make available offline") { Task { _ = await offlineDownloads.makeAvailableOffline(book: book, isCellular: false) } } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).accessibilityLabel("More options for \(book.book.title)") }.padding(12).background(MacPanel()) }
    private func openBook() { if let action { action() } else { Task { await playback.present(book) } } }
}

struct MacFilterButton: View { let title: String; let selected: Bool; let action: () -> Void; var body: some View { Button(title, action: action).buttonStyle(.borderedProminent).tint(selected ? .accentColor : .gray.opacity(0.3)) } }
struct MacPageHeader: View { let eyebrow: String; let title: String; var trailing: AnyView? = nil; var body: some View { HStack(alignment: .bottom) { VStack(alignment: .leading, spacing: 6) { Text(eyebrow).macEyebrow(); Text(title).font(.system(size: 30, weight: .bold, design: .rounded)) }; Spacer(); if let trailing { trailing } }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 10) } }
struct MacSectionTitle: View { let title: String; var body: some View { HStack { Text(title).font(.title3.bold()); Spacer() } } }
struct MacEmptyCard: View { let title: String; let message: String; let actions: [(String, String)]; var action: ((String) -> Void)? = nil; var body: some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.title3.bold()); Text(message).foregroundStyle(.secondary); if !actions.isEmpty { HStack { ForEach(actions, id: \.0) { item in Button(item.0) { action?(item.0) }.buttonStyle(.borderedProminent).disabled(action == nil) } } } }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(MacPanel()) } }
struct MacCover: View { let title: String; let size: CGSize; var body: some View { RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.brown.opacity(0.8), .mint.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: size.width, height: size.height).overlay(Text(title.prefix(2).uppercased()).font(.system(size: min(size.width, size.height) / 3, weight: .heavy, design: .serif)).foregroundStyle(.white.opacity(0.85))) } }
struct MacBackground: View { var body: some View { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() } }
struct MacPanel: View { var body: some View { RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08))) } }
private extension Text { func macEyebrow() -> some View { self.font(.caption.bold()).foregroundStyle(.secondary).textCase(.uppercase) } }
private func formatTime(_ value: TimeInterval) -> String { let total = max(0, Int(value)); return String(format: "%d:%02d", total / 60, total % 60) }
private func formatBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
