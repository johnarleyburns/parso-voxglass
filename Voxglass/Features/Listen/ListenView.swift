import SwiftUI
import os
import VoxglassCore

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(CatalogStore.self) private var catalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var showingNowPlaying: Bool
    @Environment(MiniPlayerPresentationRouter.self) private var miniPlayerRouter
    @State private var heroHandoff = ListenHeroHandoffState()
    @State private var handoffBook: BookWithChapters?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @EnvironmentObject private var recommendations: HomeRecommendationStore
    @EnvironmentObject private var listeningStats: ListeningStatsStore
    @State private var importingIdentifier: String?
    @State private var showSettings = false
    @AppStorage(AppPreferencesStore.Keys.readWithAIVoiceIdentifier) private var selectedReadWithAIVoiceIdentifier = ""
    @State private var showStats = false
    @State private var statsTotalTime: TimeInterval = 0
    @State private var statsLast7DaysTotal: TimeInterval = 0
    @State private var statsDailyBars: [ListeningStatsView.DayBar] = []
    /// A catalog result that isn't in My Books yet: its preview page opens as a
    /// dismissable sheet instead of a pushed page (real report: tapping a
    /// recommended title showed a back arrow it shouldn't have).
    @State private var previewBook: BookWithChapters?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = 0
    private let performanceLogger = Logger(subsystem: "guru.parso.voxglass", category: "ListenPerformance")
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"
    @AppStorage(AppPreferencesStore.Keys.isSupporter) private var isSupporter = false

    var body: some View {
        content
            .onChange(of: showingNowPlaying) { _, presented in
                if presented { heroHandoff.didPresentNowPlayingSheet(); handoffBook = nil }
            }
            .onChange(of: miniPlayerRouter.pendingNowPlayingBookID) { _, pending in
                if pending == nil, !showingNowPlaying { heroHandoff.didCancel(); handoffBook = nil }
            }
    }

    private var content: some View {
        VoxglassScreen(title: "Listen", headerTrailingContent: AnyView(
            HStack(spacing: 14) {
                if isSupporter { supporterBadge }
                settingsButton
            }
        )) {
            VStack(alignment: .leading, spacing: 22) {
                Button { showSettings = true } label: {
                    HStack {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        SyncStatusSummary(showsDetails: false)
                            .voxFont(.caption)
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(14)
                    .raisedSurface()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("listen.sync")
                continueListening
                weekStrip
                jumpBackIn
                recommended
            }
            .padding(.top, 12)
        }
        .sheet(item: $previewBook) { book in
            BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(showingNowPlaying: $showingNowPlaying)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showStats) {
            NavigationStack {
                ListeningStatsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showStats = false }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .alert(errorTitle, isPresented: errorBinding) {
            if let failure = playbackFailure, failure.isRetryable {
                Button("Try Again") {
                    playback.playbackError = nil
                    playback.retryPlayback()
                }
            }
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
                playback.playbackError = nil
            }
        } message: {
            Text(errorMessage)
        }
        .task {
            scheduleHomeRefresh()
        }
        .onChange(of: selectedCollectionIDsRaw) { _, _ in
            scheduleHomeRefresh()
        }
        .onChange(of: selectedLanguagesRaw) { _, _ in
            scheduleHomeRefresh()
        }
        .onChange(of: showingNowPlaying) { wasShowing, isShowing in
            // Reflect just-finished listening immediately: when Now Playing is
            // dismissed, the taste profile may have shifted, so refresh the shelf
            // (and Jump Back In) without waiting for a tab switch.
            guard wasShowing, !isShowing else { return }
            scheduleHomeRefresh()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            refreshGeneration += 1
        }
    }

    private var heroPresentation: ListenHeroPresentation {
        ListenHeroPresentation(
            session: playback.currentSession,
            phase: playback.playbackPhase,
            recentBookID: libraryStore.recentlyPlayed.first?.book.id
        )
    }

    @ViewBuilder
    private var continueListening: some View {
        let hero = heroPresentation
        if heroHandoff.isHandingOff, let pinned = handoffBook {
            // Keep the tapped card mounted until the root sheet covers it.
            continueCard(book: pinned, resumeLabel: String(localized: "Resume"))
        } else if hero.showsNowPlaying, let session = playback.currentSession {
            nowPlayingCard(session: session, kind: hero.kind)
        } else if hero.kind == .paused, let session = playback.currentSession {
            continueCard(book: BookWithChapters(book: session.book, chapters: session.chapters), resumeLabel: String(localized: "Resume"))
        } else if let book = libraryStore.recentlyPlayed.first {
            continueCard(book: book, resumeLabel: continueActionLabel(for: book))
        }
    }

    private func nowPlayingCard(session: PlaybackSession, kind: ListenHeroPresentation.Kind) -> some View {
        let title = session.book.title
        let status: String
        switch kind {
        case .playing: status = String(localized: "Playing")
        default: status = String(localized: "Preparing…")
        }
        let failureMessage: String? = {
            if case .failed(let failure) = playback.playbackPhase { return failure.message }
            return nil
        }()
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Now Playing", usesThreeSizeTypography: true)
            HStack(spacing: 10) {
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 14) {
                        CoverPlate(
                            title: title,
                            author: session.book.displayAuthorLine,
                            coverURL: session.book.coverURL,
                            size: 84,
                            shape: .portrait
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title)
                                .voxFont(LibraryScreenTypography.card, weight: .medium)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(failureMessage ?? session.book.displayAuthorLine ?? String(localized: "Imported"))
                                .voxFont(LibraryScreenTypography.card)
                                .foregroundStyle(Palette.ink2)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                if kind == .playing {
                                    ActivityBars(animating: !reduceMotion)
                                        .accessibilityHidden(true)
                                }
                                Text(status)
                                    .voxFont(LibraryScreenTypography.card)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Palette.onBrass)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Palette.brass, in: Capsule())
                            .accessibilityIdentifier("listen.nowPlaying.status")
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tactileTap()
                .accessibilityIdentifier("listen.nowPlaying.open")
                .accessibilityLabel("\(String(localized: "Now Playing")), \(title), \(session.chapter.title), \(status)")
                .accessibilityHint("Opens the player")

                if kind == .playing {
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: "pause.fill")
                            .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("listen.nowPlaying.pause")
                    .accessibilityLabel("\(String(localized: "Pause")) \(title)")
                }
            }
            .padding(14)
            .raisedSurface(tint: Palette.brass.opacity(0.20))
        }
    }

    /// Decorative three-bar activity mark; static under Reduce Motion.
    private struct ActivityBars: View {
        let animating: Bool
        @State private var phase = false

        var body: some View {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .frame(width: 3, height: animating && phase ? CGFloat(6 + ((index + 1) % 3) * 4) : CGFloat(6 + index * 4))
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
            .animation(animating ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : nil, value: phase)
            .onAppear { if animating { phase = true } }
        }
    }


    private func resumeFromListen(_ book: BookWithChapters) {
        // Idempotent: a second tap while the same request is pending is ignored.
        if miniPlayerRouter.pendingNowPlayingBookID == book.book.id { return }
        handoffBook = book
        heroHandoff.didTapResume()
        miniPlayerRouter.requestNowPlayingAfterSelection(bookID: book.book.id)
        playback.selectAndPlay(book)
        miniPlayerRouter.presentWhenSessionIsReady(bookID: playback.currentSession?.book.id)
    }

    private func continueCard(book: BookWithChapters, resumeLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Continue Listening", usesThreeSizeTypography: true)
            Button {
                resumeFromListen(book)
            } label: {
                HStack(spacing: 14) {
                    CoverPlate(
                        title: book.book.title,
                        author: book.book.displayAuthorLine,
                        coverURL: book.book.coverURL,
                        size: 84,
                        shape: .portrait
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.book.title)
                            .voxFont(LibraryScreenTypography.card, weight: .medium)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Text(book.book.displayAuthorLine ?? String(localized: "Imported"))
                            .voxFont(LibraryScreenTypography.card)
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                        if let narrator = continueNarrator(for: book) {
                            Text(narrator)
                                .voxFont(LibraryScreenTypography.card)
                                .foregroundStyle(Palette.ink2)
                                .lineLimit(1)
                                .accessibilityIdentifier("listen.continueListening.narrator")
                        }
                    }

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                        .foregroundStyle(Palette.brass)
                        .frame(width: 44, height: 44)
                }
                .padding(14)
                .raisedSurface(tint: Palette.brass.opacity(0.20))
            }
            .buttonStyle(.plain)
            .tactileTap()
            .accessibilityIdentifier("listen.continueListening")
            .accessibilityLabel("\(resumeLabel) \(book.book.title)")
            .accessibilityHint("Resumes playback and opens Now Playing")
        }
    }

    private func continueNarrator(for book: BookWithChapters) -> String? {
        _ = selectedReadWithAIVoiceIdentifier
        if libraryStore.source(for: book.book)?.kind == .readWithAI {
            let voice = ReadWithAISpeechAudioEngine.voiceDisplayName(
                for: ReadWithAIVoicePreferences.preference(for: book.book.id))
            return String(localized: "Read by AI ‘\(voice)’")
        }
        return book.book.narratorLine
    }

    private var weekStrip: some View {
        Button { showStats = true } label: {
            HStack(spacing: 12) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<7, id: \.self) { index in
                        Capsule().fill(index == 6 ? Palette.brass : Palette.ink3.opacity(0.45)).frame(width: 5, height: CGFloat(8 + (index % 4) * 5))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("This week").voxFont(LibraryScreenTypography.card, weight: .semibold)
                    Text("\(durationString(statsLast7DaysTotal)) · Longest day: \(statsDailyBars.last?.label ?? "—")").voxFont(LibraryScreenTypography.card).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.ink3)
            }
            .padding(14)
            .raisedSurface()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("listen.weekStrip")
    }

    /// Replaces the old "…" more-menu: Equalizer already lives in Settings
    /// (Audio section), About lives in Settings, and Listening Stats has its
    /// own "Show more…" from the home summary — so a direct link is enough.
    /// Shown after a "Contribute to Development" purchase (Settings ›
    /// Support). Purely a thank-you — nothing in the app checks this to
    /// unlock anything.
    private var supporterBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .voxFont(LibraryScreenTypography.card, weight: .bold)
            Text("Supporter")
                .voxFont(LibraryScreenTypography.card, weight: .semibold)
        }
        .foregroundStyle(Palette.brass)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityIdentifier("home.supporterBadge")
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .voxFont(LibraryScreenTypography.controls, weight: .semibold)
                .foregroundStyle(Palette.ink2)
                .frame(width: 40, height: 40)
        }
        .accessibilityIdentifier("home.settingsButton")
        .accessibilityLabel("Settings")
    }

    private var jumpBackInBooks: [BookWithChapters] {
        let heroBookID = heroPresentation.sessionBookID ?? libraryStore.recentlyPlayed.first?.book.id
        return JumpBackInPresenter.books(recentlyPlayed: libraryStore.recentlyPlayed, heroBookID: heroBookID)
    }

    @ViewBuilder
    private var jumpBackIn: some View {
        let books = jumpBackInBooks
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Jump Back In", usesThreeSizeTypography: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(books) { book in
                            // Tapping a Jump Back In book starts/resumes it and
                            // opens the shared Now Playing sheet (the same path
                            // My Books rows use) instead of pushing a detail page
                            // with a back arrow.
                            Button {
                                playback.selectAndPlay(book)
                                showingNowPlaying = true
                            } label: {
                                ListenBookCard(
                                    book: book,
                                    sourceTitle: libraryStore.source(for: book.book)?.title
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Continue \(book.book.title) by \(book.book.displayAuthorLine)")
                            .accessibilityHint("Opens Now Playing")
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    /// Replaces the old "Recently Added" shelf: a compact roll-up of the same
    /// stats the full Listening Stats screen shows, with a link to it.
    @ViewBuilder
    private var listeningStatsSummary: some View {
        if statsTotalTime > 0 {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Listening Stats", actionTitle: "Show more…", action: { showStats = true }, usesThreeSizeTypography: true)
                HStack(spacing: 12) {
                    statTile(value: durationString(statsTotalTime), label: "Total time")
                    statTile(value: durationString(statsLast7DaysTotal), label: "Last 7 days")
                }
                weeklyChart
            }
        }
    }

    private func statTile(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .voxFont(LibraryScreenTypography.card, weight: .heavy)
                .foregroundStyle(Palette.ink)
            Text(label)
                .voxFont(LibraryScreenTypography.card)
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
                .raisedSurface()
    }

    private var weeklyChart: some View {
        let maxSeconds = max(statsDailyBars.map(\.seconds).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(statsDailyBars) { bar in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Palette.brass, Palette.brassDeep],
                            startPoint: .top, endPoint: .bottom))
                        .frame(height: max(3, CGFloat(bar.seconds / maxSeconds) * 44))
                    Text(bar.label)
                        .voxFont(LibraryScreenTypography.card, weight: .semibold)
                        .foregroundStyle(Palette.ink3)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 58, alignment: .bottom)
        .padding(14)
                .raisedSurface()
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "0m" : TimeFormatting.compactDuration(seconds)
    }

    private func continueActionLabel(for book: BookWithChapters) -> String {
        guard let progress = libraryStore.progressByBook[book.book.id],
              progress.lastPosition > 0,
              !progress.isFinished else {
            return String(localized: "Play")
        }
        return String(localized: "Resume")
    }

    private struct ListeningStatsSnapshot {
        var totalTime: TimeInterval
        var last7DaysTotal: TimeInterval
        var dailyBars: [ListeningStatsView.DayBar]
    }

    private func loadListeningStatsSummary() async -> ListeningStatsSnapshot {
        let totalTime = await listeningStats.totalTime()
        let calendar = Calendar.current
        let now = Date()
        let totals = await listeningStats.dailyTotals(days: 7, calendar: calendar, now: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        let dailyBars = (0..<7).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
            return ListeningStatsView.DayBar(label: formatter.string(from: day), seconds: totals[day] ?? 0)
        }
        return ListeningStatsSnapshot(
            totalTime: totalTime,
            last7DaysTotal: totals.values.reduce(0, +),
            dailyBars: dailyBars
        )
    }

    private func scheduleHomeRefresh() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task {
            // Coalesce preference and Now Playing changes that arrive
            // together so a scroll gesture never competes with overlapping
            // store refreshes.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            await refreshHome(generation: generation)
        }
    }

    private func refreshHome(generation: Int) async {
        let startedAt = Date()
        performanceLogger.debug("listenRefreshStarted generation=\(generation, privacy: .public)")
        await libraryStore.refreshRecentlyPlayed()
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        let stats = await loadListeningStatsSummary()
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        statsTotalTime = stats.totalTime
        statsLast7DaysTotal = stats.last7DaysTotal
        statsDailyBars = stats.dailyBars
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        performanceLogger.debug("listenRefreshCompleted generation=\(generation, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public)")
    }

    @ViewBuilder
    private var recommended: some View {
        let results = visibleRecommendations
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Recommended for You", usesThreeSizeTypography: true)

            if results.isEmpty {
                EmptyStatePanel(
                    title: "Finding LibriVox Picks",
                    message: "Popular public-domain audiobooks will appear here.",
                    systemImage: "sparkles",
                    usesThreeSizeTypography: true
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(results) { result in
                            Button {
                                Task { await presentResult(result) }
                            } label: {
                                HorizontalCatalogCard(result: result, usesThreeSizeTypography: true)
                            }
                            .buttonStyle(.plain)
                            .tactileTap()
                            .accessibilityLabel("\(result.title) by \(result.authorLine)")
                            .disabled(importingIdentifier == result.identifier)
                            .overlay {
                                if importingIdentifier == result.identifier {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.black.opacity(0.48))
                                        .overlay {
                                            ProgressView()
                                                .tint(Palette.brass)
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .overlay(alignment: .topTrailing) {
                    if recommendations.isRefreshing {
                        ProgressView()
                            .padding(8)
                            .raisedSurface()
                            .padding(4)
                    }
                }
            }
        }
    }

    /// The active/paused Listen hero is a continuation, never a discovery
    /// recommendation. This also covers a catalog preview that has not yet
    /// been added to My Books, for which the library-level ownership filter
    /// intentionally has no entry.
    private var visibleRecommendations: [InternetArchiveSearchResult] {
        guard let continuing = continueListeningBook else {
            return recommendations.recommendations
        }
        return RecommendationPipeline.filterExcluded(
            recommendations.recommendations,
            excludeKeys: recommendationExclusionKeys(for: continuing.book)
        )
    }

    private var continueListeningBook: BookWithChapters? {
        let hero = heroPresentation
        if (hero.showsNowPlaying || hero.kind == .paused), let session = playback.currentSession {
            return BookWithChapters(book: session.book, chapters: session.chapters)
        }
        return libraryStore.recentlyPlayed.first
    }

    private func recommendationExclusionKeys(for book: Book) -> Set<String> {
        var keys: Set<String> = [
            book.id.uuidString,
            WorkKey.normalized(author: book.authorLine, title: book.title)
        ]
        if let source = libraryStore.source(for: book),
           let contentKey = ContentKey.book(forSourceURL: source.url, kind: source.kind) {
            keys.insert(contentKey)
            if contentKey.hasPrefix("ia:") {
                keys.insert(String(contentKey.dropFirst(3)))
            }
        }
        return keys
    }

    private var selectedCollectionIDs: Set<String> {
        AppPreferencesStore.decodeCollectionIDs(selectedCollectionIDsRaw)
    }

    private var selectedLanguages: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            catalogStore.catalogError != nil || libraryStore.importError != nil || playback.playbackError != nil
        } set: { isPresented in
            if !isPresented {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
                playback.playbackError = nil
            }
        }
    }

    private var playbackFailure: PlaybackFailure? {
        guard case .failed(let failure) = playback.playbackPhase else { return nil }
        return failure
    }

    private var errorTitle: String {
        playbackFailure == nil ? String(localized: "Playback Failed") : String(localized: "Playback Interrupted")
    }

    private var errorMessage: String {
        playback.playbackError ?? catalogStore.catalogError ?? libraryStore.importError ?? ""
    }

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }
        if let resolved = await catalogStore.resolveForNavigation(result, into: libraryStore) {
            if CatalogResultImporter.opensNowPlayingDirectly(resolved) {
                // Already in My Books: behave like tapping it in My Books.
                playback.selectAndPlay(resolved)
                showingNowPlaying = true
            } else {
                previewBook = resolved
            }
        }
    }
}

struct ListenBookCard: View {
    let book: BookWithChapters
    let sourceTitle: String?

    var body: some View {
        HorizontalBookCard(
            title: book.book.title,
            author: book.book.displayAuthorLine,
            coverURL: book.book.coverURL,
            usesThreeSizeTypography: true
        )
    }
}
