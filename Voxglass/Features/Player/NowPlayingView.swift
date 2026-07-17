import SwiftUI
import VoxglassCore

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var showingEQ = false
    @State private var showingBookmarks = false
    @State private var showPaywall = false
    @State private var genre: LibriVoxBrowseCategory?

    /// Favorite state derived from the live library store (source of truth),
    /// falling back to the session's snapshot captured at play time.
    static func resolveFavorite(storeBook: BookWithChapters?, session: PlaybackSession) -> Bool {
        storeBook?.book.isFavorite ?? session.book.isFavorite
    }

    private func isFavorite(_ session: PlaybackSession) -> Bool {
        Self.resolveFavorite(storeBook: libraryStore.book(withID: session.book.id), session: session)
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

            if let session = playback.currentSession {
                NavigationStack {
                    VStack(spacing: 0) {
                        grabber
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                Spacer().frame(height: 16)
                                BookArtworkView(title: session.book.title, size: 240, coverURL: session.book.coverURL)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .shadow(color: .black.opacity(0.55), radius: 24, y: 0)
                                Spacer().frame(height: 22)
                                metadata(session)
                                scrubber(session)
                                controls(session)
                                actionBar(session)
                                chapterList(session)
                                discoveryLinks(session)
                                Spacer(minLength: 24)
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                }
                .task(id: session.book.id) {
                    await loadGenre(for: session)
                }
                .onAppear {
                    scrubPosition = session.position
                }
                .onChange(of: session.position) { _, newValue in
                    if !isScrubbing {
                        scrubPosition = newValue
                    }
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
        .paywallSheet(isPresented: $showPaywall)
    }

    private func loadGenre(for session: PlaybackSession) async {
        let subjects = await libraryStore.bookSubjects(for: session.book.id)
        genre = LibriVoxBrowseCategory.category(forSubjects: subjects)
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
    }

    private func metadata(_ session: PlaybackSession) -> some View {
        VStack(spacing: 6) {
            Text(session.book.title)
                .scaledFont(size: 17, weight: .bold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .foregroundStyle(Palette.ink)
            Text(session.book.authorLine)
                .scaledFont(size: 14)
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
            Text(session.book.narratorLine ?? "Narrator unknown")
                .scaledFont(size: 13)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
            Text(session.chapter.title)
                .scaledFont(size: 12)
                .foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
            if let genre {
                Text(genre.title)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .accessibilityLabel("Genre: \(genre.title)")
            }
        }
        .padding(.horizontal, 16)
    }

    private func scrubber(_ session: PlaybackSession) -> some View {
        VStack(spacing: 7) {
            let duration = max(session.duration ?? session.position, 1)
            let progress = scrubPosition / duration

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 7)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.90))
                        .frame(width: max(geometry.size.width * CGFloat(progress), 0), height: 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isScrubbing = true
                            let ratio = val.location.x / geometry.size.width
                            scrubPosition = max(0, min(duration, Double(ratio) * duration))
                        }
                        .onEnded { _ in
                            isScrubbing = false
                            Task { await playback.seek(to: scrubPosition) }
                        }
                )
            }
            .frame(height: 32)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormatting.clock(isScrubbing ? scrubPosition : session.position))

            HStack {
                Text(TimeFormatting.clock(isScrubbing ? scrubPosition : session.position))
                Spacer()
                if let bookRemaining = session.bookRemaining {
                    Text("\(TimeFormatting.compactDuration(bookRemaining)) left in book")
                    Spacer()
                }
                Text("-\(TimeFormatting.clock(max((session.duration ?? 0) - (isScrubbing ? scrubPosition : session.position), 0)))")
            }
            .scaledFont(size: 11, design: .monospaced)
            .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(.horizontal, 2)
        .padding(.top, 20)
    }

    private func controls(_ session: PlaybackSession) -> some View {
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
            .accessibilityLabel("Back \(UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval) : 15) seconds")

            Spacer(minLength: 0)

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
            .accessibilityLabel("Next chapter")
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .padding(.top, 16)
    }

    private func actionBar(_ session: PlaybackSession) -> some View {
        HStack(spacing: 0) {
            speedMenu

            Spacer(minLength: 0)

            bookmarkButton

            Spacer(minLength: 0)

            favoriteButton(session)

            Spacer(minLength: 0)

            equalizerButton

            Spacer(minLength: 0)

            sleepTimerMenu

            Spacer(minLength: 0)

            ShareLink(item: "\(session.book.title) by \(session.book.authorLine)") {
                Image(systemName: "square.and.arrow.up")
                    .scaledFont(size: 16)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color.white.opacity(0.6))
        .padding(.top, 16)
    }

    private var sleepTimerMenu: some View {
        Menu {
            Button {
                playback.setSleepTimer(.off)
            } label: {
                sleepMenuLabel("Off", active: playback.sleepMode == .off)
            }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    playback.setSleepTimer(.duration(TimeInterval(minutes * 60)))
                } label: {
                    sleepMenuLabel("\(minutes) minutes", active: playback.sleepMode == .duration(TimeInterval(minutes * 60)))
                }
            }
            Button {
                playback.setSleepTimer(.endOfChapter)
            } label: {
                sleepMenuLabel("End of chapter", active: playback.sleepMode == .endOfChapter)
            }
        } label: {
            sleepTimerIcon
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepTimerAccessibilityValue)
        .accessibilityIdentifier("nowplaying.sleepTimer")
    }

    private var sleepTimerAccessibilityValue: String {
        switch playback.sleepMode {
        case .off:
            return "Off"
        case .endOfChapter:
            return "End of chapter"
        case .duration:
            if let remaining = playback.sleepRemaining {
                return "\(Int(remaining / 60)) minutes remaining"
            }
            return "On"
        }
    }

    @ViewBuilder
    private func sleepMenuLabel(_ title: String, active: Bool) -> some View {
        if active {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var sleepTimerIcon: some View {
        switch playback.sleepMode {
        case .off:
            Image(systemName: "moon.zzz")
                .scaledFont(size: 16)
        case .endOfChapter:
            Image(systemName: "moon.zzz.fill")
                .scaledFont(size: 16)
                .foregroundStyle(Palette.brass)
        case .duration:
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                if let remaining = playback.sleepRemaining {
                    Text(sleepCountdown(remaining))
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                }
            }
            .foregroundStyle(Palette.brass)
        }
    }

    private func sleepCountdown(_ remaining: TimeInterval) -> String {
        let totalMinutes = Int((remaining / 60).rounded(.up))
        return "\(max(totalMinutes, 0))m"
    }

    private var bookmarkButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            playback.addBookmark()
            showingBookmarks = true
        } label: {
            Image(systemName: "bookmark")
                .scaledFont(size: 16)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Bookmark")
        .accessibilityIdentifier("nowplaying.bookmark")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlaybackRate.menuLadder, id: \.self) { rate in
                Button {
                    playback.setPlaybackRate(rate)
                } label: {
                    if playback.playbackRate == rate {
                        Label(PlaybackRate.label(rate), systemImage: "checkmark")
                    } else {
                        Text(PlaybackRate.label(rate))
                    }
                }
            }
        } label: {
            Text(PlaybackRate.label(playback.playbackRate))
                .scaledFont(size: 13, weight: .bold, design: .monospaced)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PlaybackRate.label(playback.playbackRate))
        .accessibilityIdentifier("nowplaying.speed")
    }

    private func favoriteButton(_ session: PlaybackSession) -> some View {
        let favorited = isFavorite(session)
        return Button {
            Task { await libraryStore.setFavorite(!favorited, for: session.book.id) }
        } label: {
            Image(systemName: favorited ? "heart.fill" : "heart")
                .scaledFont(size: 16)
                .foregroundStyle(favorited ? Palette.brass : Color.white.opacity(0.6))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(favorited ? "Unfavorite" : "Favorite")
        .accessibilityIdentifier("nowplaying.favorite")
        .accessibilityAddTraits(favorited ? .isSelected : [])
    }

    @ViewBuilder
    private var equalizerButton: some View {
        if ProFeature.isEnabled(.eq) {
            Button {
                showingEQ = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .scaledFont(size: 16)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Equalizer")
            .accessibilityIdentifier("nowplaying.eq")
        } else {
            Button {
                showPaywall = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .scaledFont(size: 16)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "lock.fill")
                            .scaledFont(size: 8, weight: .bold)
                            .offset(x: 6, y: -6)
                    }
            }
            .accessibilityLabel("Equalizer (Pro)")
            .accessibilityIdentifier("pro.lock.eq")
        }
    }

    private func chapterList(_ session: PlaybackSession) -> some View {
        VoxglassGroupedSection(title: "Chapters") {
            let chapters = session.chapters
            ForEach(chapters.indices, id: \.self) { index in
                let chapter = chapters[index]
                Button {
                    Task {
                        if chapter.id == session.chapter.id {
                            await playback.seek(to: 0)
                        } else {
                            await playback.play(BookWithChapters(book: session.book, chapters: session.chapters), chapter: chapter)
                        }
                    }
                } label: {
                    HStack {
                        Text(chapter.title)
                            .lineLimit(1)
                        Spacer()
                        Text(TimeFormatting.clock(chapter.duration))
                            .scaledFont(size: 11.5, design: .monospaced)
                            .foregroundStyle(Color.white.opacity(0.58))
                    }
                    .scaledFont(size: 14)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .foregroundStyle(chapter.id == session.chapter.id ? Palette.brass : Color.white.opacity(0.82))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < chapters.count - 1 {
                    VoxglassListDivider()
                }
            }
        }
        .padding(.top, 16)
    }

    // MARK: - Discovery links (catalog-wide)

    @ViewBuilder
    private func discoveryLinks(_ session: PlaybackSession) -> some View {
        let author = session.book.authors.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let narrator = session.book.narrators.first?.trimmingCharacters(in: .whitespaces) ?? ""
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
                showingNowPlaying: .constant(true)
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

    private static let discoveryScope = " AND collection:librivoxaudio AND mediatype:audio"

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
