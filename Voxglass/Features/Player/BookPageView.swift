import SwiftUI
import VoxglassCore

struct BookPageView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    @Environment(MiniPlayerPresentationRouter.self) private var miniPlayerRouter
    @Environment(\.voxglassZoomNamespace) private var zoomNamespace
    @Environment(\.dismiss) private var dismiss
    var book: BookWithChapters?
    @Binding var showingNowPlaying: Bool
    var presentationContext: BookPagePresentationContext = .pushedDetail
    @State private var showingEQ = false
    @State private var showingBookmarks = false
    @State private var showingOverflow = false
    @State private var showCellularPrompt = false
    @State private var showRemoveConfirm = false
    @State private var showRemoveOfflineConfirm = false
    @State private var showAddToLibraryConfirm = false
    @State private var showingPlaylistPicker = false
    @State private var genre: LibriVoxBrowseCategory?
    @State private var bookmarkCount: Int?
    @State private var isDescriptionExpanded = false
    @State private var ambientPalette = ArtworkPalette(
        dominant: PlateRGB(red: 0.16, green: 0.12, blue: 0.08),
        vivid: PlateRGB(red: 0.32, green: 0.20, blue: 0.08),
        deep: PlateRGB(red: 0.04, green: 0.03, blue: 0.02)
    )
    @State private var showCompactHeader = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(RecentlyViewedBooksStore.key) private var recentlyViewedRaw = ""

    private var resolved: BookWithChapters? {
        if let book { return libraryStore.book(withID: book.book.id) ?? book }
        guard let s = playback.currentSession else { return nil }
        return libraryStore.book(withID: s.book.id) ?? BookWithChapters(book: s.book, chapters: s.chapters)
    }

    private var isActiveSession: Bool {
        guard let resolved else { return false }
        return playback.currentSession?.book.id == resolved.book.id
    }

    private var offlineState: OfflineState {
        guard let resolved else { return .notCached }
        return offlineManager.state(for: resolved.book.id)
    }

    var body: some View {
        ZStack {
            ArtworkAmbientBackground(palette: ambientPalette)
                .ignoresSafeArea()

            if let resolved {
                NavigationStack {
                    VStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 0) {
                                    Spacer().frame(height: 16)
                                    coverSection(resolved)
                                    Spacer().frame(height: 22)
                                    metadataSection(resolved)
                                    libraryAction(resolved)
                                    chipRow(resolved)
                                    scrubber(resolved)
                                    transportControls(resolved)
                                    actionRow(resolved)
                                    Button("Chapters · About · Bookmarks") {
                                        withAnimation(Motion.standard) {
                                            proxy.scrollTo("nowplaying.details", anchor: .top)
                                        }
                                    }
                                    .voxType(.meta)
                                    .foregroundStyle(Palette.ink2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("nowplaying.detailsHint")
                                    aboutSection(resolved)
                                        .id("nowplaying.details")
                                    chapterList(resolved)
                                    discoveryLinks(resolved)
                                    Spacer(minLength: 24)
                                }
                                .padding(.horizontal, 24)
                                .padding(.bottom, 20)
                            }
                            .safeAreaPadding(.bottom, Spacing.section)
                            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                                geometry.contentOffset.y + geometry.contentInsets.top
                            } action: { _, offset in
                                showCompactHeader = offset > 320
                            }
                        }
                    }
                    .navigationTitle(resolved.book.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .overlay(alignment: .top) {
                        if showCompactHeader {
                            compactHeader(resolved)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .task(id: resolved.book.id) {
                    await loadGenre(for: resolved)
                }
                .task(id: resolved.book.coverURL) {
                    await loadAmbientPalette(for: resolved.book.coverURL)
                }
                .task {
                    await playback.refreshBookmarkCount(for: resolved.book.id)
                    bookmarkCount = playback.bookmarkCount
                }
                .onAppear {
                    recentlyViewedRaw = RecentlyViewedBooksStore.recording(
                        bookID: resolved.book.id,
                        in: recentlyViewedRaw
                    )
                    if presentationContext == .pushedDetail {
                        miniPlayerRouter.playerPushed()
                    }
                }
                .onDisappear {
                    if presentationContext == .pushedDetail {
                        miniPlayerRouter.playerPopped()
                    }
                }
                .onChange(of: playback.bookmarkCount) { _, newValue in
                    bookmarkCount = newValue
                }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "headphones")
                .foregroundStyle(.white)
            }
        }
        .confirmationDialog(
            "Add to My Books?",
            isPresented: $showAddToLibraryConfirm,
            titleVisibility: .visible
        ) {
            Button("Add") {
                guard let bookID = resolved?.book.id else { return }
                Task { await libraryStore.confirmAddToLibrary(bookID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep this book in My Books so it's easy to find again.")
        }
        .sheet(isPresented: $showingEQ) {
            NavigationStack {
                EQView()
                    .environment(playback)
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
        .sheet(isPresented: $showingOverflow) {
            BookPageOverflowSheet(
                book: resolved ?? BookWithChapters(book: Book(title: "", authors: [], sourceID: UUID()), chapters: []),
                showingNowPlaying: $showingNowPlaying,
                showRemoveOfflineConfirm: $showRemoveOfflineConfirm,
                showRemoveConfirm: $showRemoveConfirm,
                genre: genre
            )
            .environment(playback)
            .environmentObject(libraryStore)
            .environmentObject(offlineManager)
            .environmentObject(phoneAudioRelay)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            NavigationStack {
                AddToPlaylistSheet(bookID: resolved?.book.id ?? UUID())
            }
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "You're on cellular data",
            isPresented: $showCellularPrompt,
            titleVisibility: .visible
        ) {
            Button("Cache now on cellular") {
                Task { await startOffline(allowCellular: true) }
            }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("Caching a whole book can use significant cellular data.")
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
        .alert("Playback Interrupted", isPresented: playbackErrorBinding) {
            if let failure = playbackFailure, failure.isRetryable {
                Button("Try Again") {
                    playback.playbackError = nil
                    playback.retryPlayback()
                }
            }
            Button("OK", role: .cancel) {
                playback.playbackError = nil
            }
        } message: {
            Text(playback.playbackError ?? "")
        }
        .confirmationDialog(
            "Remove the offline copy?",
            isPresented: $showRemoveOfflineConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove offline copy", role: .destructive) {
                Task {
                    guard let book = resolved else { return }
                    await offlineManager.removeOffline(book: book)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The book stays in My Books; only its cached audio is freed.")
        }
        .confirmationDialog(
            resolved.map { "Remove \"\($0.book.title)\" from My Books?" } ?? "",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove from My Books", role: .destructive) {
                Task {
                    guard let book = resolved else { return }
                    await libraryStore.delete(book: book)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the book and its cached audio from this device.")
        }
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding {
            playback.playbackError != nil
        } set: { isPresented in
            if !isPresented { playback.playbackError = nil }
        }
    }

    private var playbackFailure: PlaybackFailure? {
        guard case .failed(let failure) = playback.playbackPhase else { return nil }
        return failure
    }

    @ViewBuilder
    private func libraryAction(_ resolved: BookWithChapters) -> some View {
        if resolved.book.isPending {
            VStack(alignment: .leading, spacing: 8) {
                previewStateLabel(isPending: true)
                Button {
                    showAddToLibraryConfirm = true
                } label: {
                    Label("Add to My Books", systemImage: "plus")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .raisedSurface()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bookpage.addToLibrary")
            }
            .padding(.top, 15)
        } else {
            previewStateLabel(isPending: false)
                .padding(.top, 15)
        }
    }

    private func previewStateLabel(isPending: Bool) -> some View {
        Label(
            isPending ? "Previewing" : "In My Books",
            systemImage: isPending ? "eye" : "checkmark.circle.fill"
        )
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(Palette.brass)
            .accessibilityIdentifier(isPending ? "bookpage.previewing" : "bookpage.inMyBooks")
    }

    private func coverSection(_ resolved: BookWithChapters) -> some View {
        let size: CGFloat = dynamicTypeSize >= .accessibility2 ? 160 : (isActiveSession ? 236 : 210)
        return ZStack(alignment: .bottomLeading) {
            coverArtwork(resolved, size: size)
                .shadow(color: .black.opacity(0.55), radius: 24, y: 0)

            if !isActiveSession {
                ProgressRing(progress: progressFor(resolved))
                    .offset(x: 6, y: 6)
                    .frame(width: 44, height: 44, alignment: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
        .accessibilityIdentifier("nowplaying.cover")
    }

    private func compactHeader(_ resolved: BookWithChapters) -> some View {
        HStack(spacing: 10) {
            CoverPlate(title: resolved.book.title, author: resolved.book.authorLine, coverURL: resolved.book.coverURL, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(resolved.book.title).voxType(.body).lineLimit(1)
                Text("\(Int((progressFor(resolved) * 100).rounded()))% · \(TimeFormatting.compactDuration(playback.currentSession?.bookRemaining ?? 0)) left")
                    .voxType(.timecode)
                    .foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 4)
            if let session = playback.currentSession, session.book.id == resolved.book.id {
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("nowplaying.compactHeader")
        .padding(.horizontal, 12)
    }

    private func loadAmbientPalette(for url: URL?) async {
        guard let url else { return }
        let image: UIImage?
        if let cached = ArtworkService.shared.cachedImage(for: url) {
            image = cached
        } else {
            image = await ArtworkService.shared.image(for: url)
        }
        guard let image else { return }
        ambientPalette = ArtworkPaletteProvider.shared.palette(for: image, url: url)
    }

    @ViewBuilder
    private func coverArtwork(_ resolved: BookWithChapters, size: CGFloat) -> some View {
        let plate = CoverPlate(title: resolved.book.title, author: resolved.book.authorLine, coverURL: resolved.book.coverURL, size: size)
        if let zoomNamespace {
            plate.matchedGeometryEffect(id: "book.cover.\(resolved.book.id.uuidString)", in: zoomNamespace)
        } else {
            plate
        }
    }

    private func progressFor(_ resolved: BookWithChapters) -> Double {
        guard let progress = libraryStore.progressByBook[resolved.book.id],
              let totalDuration = resolved.totalDuration, totalDuration > 0 else { return 0 }
        return progress.lastPosition / totalDuration
    }

    private func resumeChapterTitle(for resolved: BookWithChapters) -> String? {
        guard let progress = libraryStore.progressByBook[resolved.book.id],
              !progress.isFinished else { return nil }
        var accumulated: TimeInterval = 0
        for ch in resolved.chapters {
            guard let dur = ch.duration else { return nil }
            if accumulated + dur > progress.lastPosition {
                return ch.title
            }
            accumulated += dur
        }
        return nil
    }

    private func metadataSection(_ resolved: BookWithChapters) -> some View {
        VStack(spacing: 6) {
            Text(resolved.book.title)
                .scaledFont(size: 17, weight: .bold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .foregroundStyle(Palette.ink)

            authorLinks(resolved)

            if let narratorLine = resolved.book.narratorLine {
                narratorsLink(resolved, narratorLine: narratorLine)
            }

            if resolved.narrationKind == .solo {
                Text("Single narrator")
                    .scaledFont(size: 11, weight: .bold)
                    .kerning(0.7)
                    .foregroundStyle(Palette.brass)
                    .padding(.top, 2)
            }

            chapterLine(resolved)
            if let source = libraryStore.source(for: resolved.book) {
                Text("· \(source.kind.displayName)")
                    .voxType(.meta)
                    .foregroundStyle(Palette.ink2)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityIdentifier("nowplaying.title")
    }

    private func authorLinks(_ resolved: BookWithChapters) -> some View {
        VStack(alignment: .center, spacing: 2) {
            ForEach(resolved.book.authors.isEmpty ? ["Unknown author"] : resolved.book.authors, id: \.self) { author in
                if author == "Unknown author" {
                    Text(author)
                        .scaledFont(size: 14)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                } else {
                    NavigationLink {
                        AuthorDetailView(authorName: author, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        Text(author)
                            .scaledFont(size: 14)
                            .foregroundStyle(Palette.brass)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func narratorsLink(_ resolved: BookWithChapters, narratorLine: String) -> some View {
        Group {
            if let narrator = resolved.book.narrators.first,
               narrator != "Unknown author",
               !narrator.isEmpty {
                NavigationLink {
                    NarratorDetailView(narratorName: narrator, showingNowPlaying: $showingNowPlaying)
                } label: {
                    Text(narratorLine)
                        .scaledFont(size: 13)
                        .foregroundStyle(Palette.brass)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else {
                Text(narratorLine)
                    .scaledFont(size: 13)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func chapterLine(_ resolved: BookWithChapters) -> some View {
        if isActiveSession, let session = playback.currentSession {
            let display = ChapterDisplayTitles.make(for: resolved.chapters)[session.chapter.id]
            VStack(spacing: 2) {
                Text(display?.eyebrow.map { "\($0) · \(display?.title ?? session.chapter.title)" } ?? (display?.title ?? session.chapter.title))
                    .scaledFont(size: 12)
                    .foregroundStyle(Color.white.opacity(0.50))
                    .lineLimit(1)
                if let narratorLine = NarratorDisplay.chapterLine(chapter: session.chapter, bookNarrators: resolved.book.narrators) {
                    Text(narratorLine)
                        .scaledFont(size: 11)
                        .foregroundStyle(Color.white.opacity(0.38))
                        .lineLimit(1)
                }
            }
        } else if let resumeChapter = resumeChapterTitle(for: resolved) {
            Text("Resume · \(resumeChapter)")
                .scaledFont(size: 12)
                .foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
        } else {
            Text("\(resolved.chapters.count) chapters")
                .scaledFont(size: 12)
                .foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
        }
    }

    private func chipRow(_ resolved: BookWithChapters) -> some View {
        HStack(spacing: 6) {
            if let genre {
                Text(genre.title)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .accessibilityLabel("Genre: \(genre.title)")
            }

            Text("\(resolved.chapters.count) chapters")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.62))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.07)))

            if offlineState == .cached {
                Text("Available offline")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            } else {
                Text("Public domain")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
        }
        .padding(.top, 9)
    }

    private func scrubber(_ resolved: BookWithChapters) -> some View {
        let session = playback.currentSession
        let isActive = session?.book.id == resolved.book.id
        let savedProgress = libraryStore.progressByBook[resolved.book.id]

        let chapterFallbackPosition: TimeInterval
        let chapterFallbackDuration: TimeInterval
        let elapsedBeforeChapter: TimeInterval

        if let session, session.book.id == resolved.book.id {
            chapterFallbackPosition = session.position
            chapterFallbackDuration = session.chapter.duration ?? session.duration ?? 1
            elapsedBeforeChapter = session.elapsedBeforeCurrentChapter
        } else {
            // For inactive books, derive chapter-relative values from saved progress
            let savedPos = savedProgress?.lastPosition ?? 0
            let sorted = resolved.chapters.naturallySorted()
            var accumulator: TimeInterval = 0
            var foundChapter = sorted.first
            var foundElapsed: TimeInterval = 0
            for ch in sorted {
                guard let dur = ch.duration else { break }
                if accumulator + dur > savedPos {
                    foundChapter = ch
                    foundElapsed = accumulator
                    break
                }
                accumulator += dur
            }
            chapterFallbackPosition = max(0, savedPos - foundElapsed)
            chapterFallbackDuration = foundChapter?.duration ?? sorted.first?.duration ?? 1
            elapsedBeforeChapter = foundElapsed
        }

        return ScrubberView(
            isActiveBook: isActive,
            chapterFallbackPosition: chapterFallbackPosition,
            chapterFallbackDuration: chapterFallbackDuration,
            elapsedBeforeChapter: elapsedBeforeChapter,
            totalBookDuration: session?.totalBookDuration ?? resolved.totalDuration,
            onSeekChapterPosition: { target in
                Task { await playback.seek(to: target) }
            }
        )
    }

    private func transportControls(_ resolved: BookWithChapters) -> some View {
        let controls = HStack(spacing: 0) {
            Button {
                Task { await playback.skipToPreviousChapter() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .raisedSurface()
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .allowsHitTesting(isActiveSession)
            .accessibilityLabel("Previous chapter")
            .accessibilityIdentifier("nowplaying.previousChapter")

            Spacer(minLength: 0)

            Button {
                let configured = UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil
                    ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval) : 15
                Task { await playback.skip(by: -TimeInterval(configured)) }
            } label: {
                let configured = UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil
                    ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval) : 15
                Image(systemName: SkipSymbol.back(configured))
                    .scaledFont(size: 20)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .raisedSurface()
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .allowsHitTesting(isActiveSession)
            .accessibilityLabel("Back \(UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval) : 15) seconds")
            .accessibilityIdentifier("nowplaying.skipBack")

            Spacer(minLength: 0)

            if isActiveSession, let session = playback.currentSession {
                Button {
                    playback.togglePlayPause()
                } label: {
                    Group {
                        // `currentSession` publishes before the engine actually
                        // finishes loading (`playbackPhase == .preparing`), so
                        // without this the button just sat on a static "play"
                        // glyph for however long the load took — for a large
                        // local-files book (bookmark resolution + AVAsset
                        // duration probe) that could be several seconds with
                        // no feedback at all, reading as a frozen/janky UI.
                        if playback.playbackPhase == .preparing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                                .scaledFont(size: 26, weight: .bold)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .disabled(playback.playbackPhase == .preparing)
                .accessibilityLabel(playback.playbackPhase == .preparing ? "Loading" : (session.isPlaying ? "Pause" : "Play"))
                .accessibilityIdentifier("bookpage.togglePlayback")
            } else {
                Button {
                    Task {
                        await playback.play(resolved)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .scaledFont(size: 26, weight: .bold)
                        .foregroundStyle(Palette.onBrass)
                        .frame(width: 66, height: 66)
                        .background(
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Palette.brass, Palette.brassDeep],
                                    startPoint: .top, endPoint: .bottom))
                        )
                }
                .accessibilityLabel("Play")
                .accessibilityIdentifier("bookpage.play")
            }

            Spacer(minLength: 0)

            Button {
                let configured = UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil
                    ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval) : 30
                Task { await playback.skip(by: TimeInterval(configured)) }
            } label: {
                Image(systemName: SkipSymbol.forward(
                    UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil
                        ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval) : 30)
                )
                    .scaledFont(size: 20)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .raisedSurface()
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .allowsHitTesting(isActiveSession)
            .accessibilityLabel("Forward \(UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval) : 30) seconds")
            .accessibilityIdentifier("nowplaying.skipForward")

            Spacer(minLength: 0)

            Button {
                Task { await playback.skipToNextChapter() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .raisedSurface()
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .allowsHitTesting(isActiveSession)
            .accessibilityLabel("Next chapter")
            .accessibilityIdentifier("nowplaying.nextChapter")
        }
        return controls
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .padding(.top, 16)
        .accessibilityIdentifier("nowplaying.details")
    }

    private func actionRow(_ resolved: BookWithChapters) -> some View {
        BookPageActionRow(
            book: resolved,
            showingEQ: $showingEQ,
            showingBookmarks: $showingBookmarks,
            showingOverflow: $showingOverflow,
            showCellularPrompt: $showCellularPrompt,
            showRemoveOfflineConfirm: $showRemoveOfflineConfirm
        )
        .environment(playback)
        .environmentObject(libraryStore)
        .environmentObject(offlineManager)
        .foregroundStyle(Color.white.opacity(0.6))
        .padding(.top, 16)
    }

    @ViewBuilder
    private func aboutSection(_ resolved: BookWithChapters) -> some View {
        if let summary = resolved.book.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "About")
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                        .scaledFont(size: 14)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(isDescriptionExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation {
                            isDescriptionExpanded.toggle()
                        }
                    } label: {
                        Text(isDescriptionExpanded ? "Show less" : "Show more")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                    }
                }
                .padding(14)
                .raisedSurface()
            }
            .padding(.top, 16)
        }
    }

    /// How many chapters to preview inline before handing off to the
    /// dedicated `ChaptersView` — previously this showed *every* chapter
    /// unconditionally and then always appended an "All Chapters" link to
    /// the exact same full list, which for a short book was barely
    /// noticeable but for a many-chapter single-file local book (40+
    /// chapters) meant the whole list rendered twice in a row.
    private static let chapterPreviewLimit = 5

    private func chapterPreview(_ resolved: BookWithChapters) -> [Chapter] {
        let allChapters = resolved.chapters
        guard allChapters.count > Self.chapterPreviewLimit else { return allChapters }

        // Center the preview on whichever chapter is playing, so the page
        // always shows "where you are" rather than always the first few
        // chapters of the book.
        let currentIndex = allChapters.firstIndex { chapter in
            playback.currentSession?.chapter.id == chapter.id
                && playback.currentSession?.book.id == resolved.book.id
        }
        let start = min(
            max(0, (currentIndex ?? 0) - Self.chapterPreviewLimit / 2),
            allChapters.count - Self.chapterPreviewLimit
        )
        return Array(allChapters[start..<(start + Self.chapterPreviewLimit)])
    }

    private func chapterList(_ resolved: BookWithChapters) -> some View {
        let allChapters = resolved.chapters
        let chapters = chapterPreview(resolved)
        let displayTitles = ChapterDisplayTitles.make(for: allChapters)
        return VoxglassGroupedSection(title: "Chapters") {
            ForEach(chapters.indices, id: \.self) { index in
                let chapter = chapters[index]
                let isCurrent = playback.currentSession?.chapter.id == chapter.id
                    && playback.currentSession?.book.id == resolved.book.id
                Button {
                    Task {
                        if let session = playback.currentSession, session.book.id == resolved.book.id {
                            if chapter.id == session.chapter.id {
                                await playback.seek(to: 0)
                            } else {
                                await playback.play(resolved, chapter: chapter)
                            }
                        } else {
                            await playback.play(resolved, chapter: chapter)
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        HStack {
                            let display = displayTitles[chapter.id]
                            Text(display?.eyebrow.map { "\($0) · \(display?.title ?? chapter.title)" } ?? (display?.title ?? chapter.title))
                                .lineLimit(1)
                            Spacer()
                            Text(TimeFormatting.clock(chapter.duration))
                                .scaledFont(size: 11.5, design: .monospaced) // mono-exempt: chapter duration
                                .foregroundStyle(Color.white.opacity(0.58))
                        }
                        if let narrator = NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: resolved.book.narrators) {
                            HStack {
                                Text(narrator)
                                    .scaledFont(size: 11)
                                    .foregroundStyle(Color.white.opacity(0.45))
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                    .scaledFont(size: 14)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(isCurrent ? Palette.brass : Color.white.opacity(0.82))
                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("chapter.row.\(index)")
                                if index < chapters.count - 1 {
                    VoxglassListDivider()
                }
            }

            if !chapters.isEmpty {
                VoxglassListDivider()
            }

            if let count = playback.bookmarkCount ?? bookmarkCount, count > 0 {
                Button {
                    showingBookmarks = true
                } label: {
                    DisclosureListRow(
                        icon: "bookmark.fill",
                        title: "Bookmarks",
                        detail: "\(count) bookmark\(count == 1 ? "" : "s")",
                        count: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bookmarks")
                .accessibilityValue("\(count) bookmark\(count == 1 ? "" : "s")")
                VoxglassListDivider()
            }

            if allChapters.count > Self.chapterPreviewLimit {
                NavigationLink {
                    ChaptersView(book: resolved, showingNowPlaying: $showingNowPlaying)
                } label: {
                    DisclosureListRow(
                        icon: "list.bullet",
                        title: "All Chapters",
                        detail: "\(allChapters.count) total",
                        count: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 16)
        .accessibilityRotor("Chapters") {
            AccessibilityRotorEntry("Chapter list", id: "chapters")
        }
    }

    @ViewBuilder
    private func discoveryLinks(_ resolved: BookWithChapters) -> some View {
        let author = resolved.book.authors.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let narrator = resolved.book.narrators.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasAuthor = !author.isEmpty && author.localizedCaseInsensitiveCompare("Unknown author") != .orderedSame
        let hasNarrator = !narrator.isEmpty

        if hasAuthor || hasNarrator || genre != nil {
            VoxglassGroupedSection(title: "Discover More") {
                if hasAuthor {
                    discoveryLink(
                        label: "More by \(author)",
                        systemImage: "person.fill",
                        destinationTitle: author,
                        query: Self.authorQuery(author)
                    )
                    if hasNarrator || genre != nil {
                        VoxglassListDivider()
                    }
                }
                if hasNarrator {
                    discoveryLink(
                        label: "More read by \(narrator)",
                        systemImage: "mic.fill",
                        destinationTitle: narrator,
                        query: Self.narratorQuery(narrator)
                    )
                    if genre != nil {
                        VoxglassListDivider()
                    }
                }
                if let genre {
                    discoveryLink(
                        label: "More in \(genre.title)",
                        systemImage: genre.systemImage,
                        destinationTitle: genre.title,
                        query: Self.genreQuery(genre)
                    )
                }
            }
            .padding(.top, 16)
        }
    }

    private func discoveryLink(
        label: String,
        systemImage: String,
        destinationTitle: String,
        query: String
    ) -> some View {
        NavigationLink {
            CatalogDiscoveryView(
                title: destinationTitle,
                archiveQuery: query,
                showingNowPlaying: $showingNowPlaying
            )
            .environment(playback)
            .environmentObject(libraryStore)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                Text(label)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadGenre(for resolved: BookWithChapters) async {
        let subjects = await libraryStore.bookSubjects(for: resolved.book.id)
        genre = LibriVoxBrowseCategory.category(forSubjects: subjects)
    }

    private func startOffline(allowCellular: Bool) async {
        guard let book = resolved else { return }
        let decision = await offlineManager.makeAvailableOffline(
            book: book,
            isCellular: NetworkMonitor.shared.isCellular,
            allowCellularOverride: allowCellular
        )
        switch decision {
        case .needsCellularConfirmation:
            showCellularPrompt = true
        case .start:
            break
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

    private static let discoveryScope = " AND \(LibriVoxCatalogScope.query)"

    static func authorQuery(_ author: String) -> String {
        "creator:\"\(escapeQuotes(author))\"\(discoveryScope)"
    }

    static func narratorQuery(_ narrator: String) -> String {
        let escaped = escapeQuotes(narrator)
        return "(creator:\"\(escaped)\" OR description:\"\(escaped)\")\(discoveryScope)"
    }

    static func genreQuery(_ category: LibriVoxBrowseCategory) -> String {
        category.archiveQuery.contains("mediatype:")
            ? category.archiveQuery
            : category.archiveQuery + " AND mediatype:audio"
    }

    private static func escapeQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(Palette.brass, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((progress * 100).rounded()))%")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(Palette.brass)
        }
        .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.surface).shadow(color: .black.opacity(0.5), radius: 6, y: 0))
    }
}
