import SwiftUI
import VoxglassCore

struct BookPageView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @Environment(\.dismiss) private var dismiss
    var book: BookWithChapters?
    @Binding var showingNowPlaying: Bool
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var showingEQ = false
    @State private var showingBookmarks = false
    @State private var showingOverflow = false
    @State private var showCellularPrompt = false
    @State private var showRemoveConfirm = false
    @State private var showRemoveOfflineConfirm = false
    @State private var showingPlaylistPicker = false
    @State private var genre: LibriVoxBrowseCategory?
    @State private var bookmarkCount: Int?
    @State private var isDescriptionExpanded = false
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
            VoxglassTheme.warmBackground.ignoresSafeArea()
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x8A5A24).opacity(0.28), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .blur(radius: 30)
                .ignoresSafeArea()

            if let resolved {
                NavigationStack {
                    VStack(spacing: 0) {
                        topBar
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                Spacer().frame(height: 16)
                                coverSection(resolved)
                                Spacer().frame(height: 22)
                                metadataSection(resolved)
                                chipRow(resolved)
                                scrubber(resolved)
                                transportControls(resolved)
                                actionRow(resolved)
                                aboutSection(resolved)
                                chapterList(resolved)
                                discoveryLinks(resolved)
                                Spacer(minLength: 24)
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                }
                .task(id: resolved.book.id) {
                    await loadGenre(for: resolved)
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
                    if let session = playback.currentSession, session.book.id == resolved.book.id {
                        scrubPosition = session.position
                    }
                }
                .onChange(of: playback.currentSession?.position) { _, newValue in
                    if !isScrubbing, let newValue, playback.currentSession?.book.id == resolved.book.id {
                        scrubPosition = newValue
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
        .sheet(isPresented: $showingEQ) {
            NavigationStack {
                EQView()
                    .environmentObject(playback)
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
        .sheet(isPresented: $showingOverflow) {
            BookPageOverflowSheet(
                book: resolved ?? BookWithChapters(book: Book(title: "", authors: [], sourceID: UUID()), chapters: []),
                showingNowPlaying: $showingNowPlaying,
                showRemoveOfflineConfirm: $showRemoveOfflineConfirm,
                showRemoveConfirm: $showRemoveConfirm,
                genre: genre
            )
            .environmentObject(playback)
            .environmentObject(libraryStore)
            .environmentObject(offlineManager)
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
            Text("The book stays in My Books; only the downloaded audio is freed.")
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

    private var topBar: some View {
        HStack {
            if book != nil {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 32, height: 32)
                        .glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.12))
                }
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func coverSection(_ resolved: BookWithChapters) -> some View {
        let size: CGFloat = isActiveSession ? 214 : 190
        return ZStack(alignment: .bottomLeading) {
            BookArtworkView(title: resolved.book.title, size: size, coverURL: resolved.book.coverURL, cornerRadius: 16)
                .shadow(color: .black.opacity(0.55), radius: 24, y: 0)

            if let source = libraryStore.source(for: resolved.book) {
                ProvenanceChip(sourceKind: source.kind)
                    .padding(6)
            }

            if !isActiveSession {
                ProgressRing(progress: progressFor(resolved))
                    .offset(x: 6, y: 6)
                    .frame(width: 44, height: 44, alignment: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
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
                Text("Solo Narration")
                    .scaledFont(size: 11, weight: .bold)
                    .kerning(0.7)
                    .foregroundStyle(Palette.brass)
                    .padding(.top, 2)
            }

            chapterLine(resolved)
        }
        .padding(.horizontal, 16)
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
            Text(session.chapter.title)
                .scaledFont(size: 12)
                .foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
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
                Text("Downloaded")
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
        VStack(spacing: 7) {
            let session = playback.currentSession
            let isActive = session?.book.id == resolved.book.id
            let savedProgress = libraryStore.progressByBook[resolved.book.id]
            let position = isActive ? (isScrubbing ? scrubPosition : (session?.position ?? 0)) : (savedProgress?.lastPosition ?? 0)
            let duration: TimeInterval = {
                if isActive, let d = session?.duration, d > 0 { return d }
                if let total = resolved.totalDuration, total > 0 { return total }
                return resolved.chapters.first?.duration ?? 1
            }()
            let progress = max(duration, 1) > 0 ? position / max(duration, 1) : 0

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 7)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? Color.white.opacity(0.90) : Palette.brass.opacity(0.85))
                        .frame(width: max(geometry.size.width * CGFloat(progress), 0), height: 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            guard isActive else { return }
                            isScrubbing = true
                            let ratio = val.location.x / geometry.size.width
                            scrubPosition = max(0, min(duration, Double(ratio) * duration))
                        }
                        .onEnded { _ in
                            guard isActive else { return }
                            isScrubbing = false
                            Task { await playback.seek(to: scrubPosition) }
                        }
                )
            }
            .frame(height: 32)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormatting.clock(position))

            HStack {
                Text(TimeFormatting.clock(position))
                Spacer()
                if let session = isActive ? session : nil, let bookRemaining = session.bookRemaining {
                    Text("\(TimeFormatting.compactDuration(bookRemaining)) left in book")
                    Spacer()
                }
                Text("-\(TimeFormatting.clock(max(duration - position, 0)))")
            }
            .scaledFont(size: 11, design: .monospaced)
            .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(.horizontal, 2)
        .padding(.top, 20)
    }

    private func transportControls(_ resolved: BookWithChapters) -> some View {
        HStack(spacing: 0) {
            Button {
                Task { await playback.skipToPreviousChapter() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .accessibilityLabel("Previous chapter")

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
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .accessibilityLabel("Back \(UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval) : 15) seconds")

            Spacer(minLength: 0)

            if isActiveSession, let session = playback.currentSession {
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .scaledFont(size: 26, weight: .bold)
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            } else {
                Button {
                    Task {
                        await playback.play(resolved)
                        showingNowPlaying = true
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .scaledFont(size: 26, weight: .bold)
                        .foregroundStyle(Color(hex: 0x221503))
                        .frame(width: 66, height: 66)
                        .background(
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                    startPoint: .top, endPoint: .bottom))
                        )
                }
                .accessibilityLabel("Play")
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
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .accessibilityLabel("Forward \(UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval) : 30) seconds")

            Spacer(minLength: 0)

            Button {
                Task { await playback.skipToNextChapter() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .opacity(isActiveSession ? 1 : 0.42)
            .accessibilityLabel("Next chapter")
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .padding(.top, 16)
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
        .environmentObject(playback)
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
                .glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))
            }
            .padding(.top, 16)
        }
    }

    private func chapterList(_ resolved: BookWithChapters) -> some View {
        VoxglassGroupedSection(title: "Chapters") {
            let chapters = resolved.chapters
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
                            showingNowPlaying = true
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        HStack {
                            Text(chapter.title)
                                .lineLimit(1)
                            Spacer()
                            Text(TimeFormatting.clock(chapter.duration))
                                .scaledFont(size: 11.5, design: .monospaced)
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

            NavigationLink {
                ChaptersView(book: resolved, showingNowPlaying: $showingNowPlaying)
            } label: {
                DisclosureListRow(
                    icon: "list.bullet",
                    title: "All Chapters",
                    detail: "\(resolved.chapters.count) total",
                    count: nil
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
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
            .environmentObject(playback)
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
        .background(Circle().fill(Color(hex: 0x12171A)).shadow(color: .black.opacity(0.5), radius: 6, y: 0))
    }
}
