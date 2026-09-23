import SwiftUI
import os
import VoxglassCore

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var showingNowPlaying: Bool

    @EnvironmentObject private var recommendations: HomeRecommendationStore
    @EnvironmentObject private var listeningStats: ListeningStatsStore
    @State private var importingIdentifier: String?
    @State private var showSettings = false
    @State private var showStats = false
    @State private var statsTotalTime: TimeInterval = 0
    @State private var statsLast7DaysTotal: TimeInterval = 0
    @State private var statsDailyBars: [ListeningStatsView.DayBar] = []
    @State private var selectedCatalogBookID: UUID?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = 0
    private let performanceLogger = Logger(subsystem: "guru.parso.voxglass", category: "ListenPerformance")
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"
    @AppStorage(AppPreferencesStore.Keys.isSupporter) private var isSupporter = false

    var body: some View {
        VoxglassScreen(title: "Listen") {
            VStack(alignment: .leading, spacing: 22) {
                continueListening
                jumpBackIn
                recommended
                listeningStatsSummary
            }
            .padding(.top, 12)
            .navigationDestination(item: $selectedCatalogBookID) { bookID in
                BookPageView(book: libraryStore.book(withID: bookID), showingNowPlaying: $showingNowPlaying)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if isSupporter {
                    supporterBadge
                }
                settingsButton
            }
            .padding(.trailing, 16)
            .padding(.top, 6)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(showingNowPlaying: $showingNowPlaying)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showSettings = false }
                        }
                    }
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

    @ViewBuilder
    private var continueListening: some View {
        if let book = libraryStore.recentlyPlayed.first {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Continue Listening")
                Button {
                    Task {
                        await playback.play(book)
                        showingNowPlaying = true
                    }
                } label: {
                    HStack(spacing: 14) {
                        BookArtworkView(
                            title: book.book.title,
                            size: 84,
                            coverURL: book.book.coverURL,
                            cornerRadius: 14
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.book.title)
                                .scaledFont(size: 17, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(book.book.authorLine)
                                .scaledFont(size: 12)
                                .foregroundStyle(Palette.ink2)
                                .lineLimit(1)
                            Text(continueActionLabel(for: book))
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(Palette.brass)
                        }

                        Spacer(minLength: 4)
                        Image(systemName: "play.circle.fill")
                            .scaledFont(size: 30, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                    }
                    .padding(14)
                    .glassSurface(cornerRadius: 18, fill: Color.white.opacity(0.08))
                }
                .buttonStyle(.plain)
                .tactileTap()
                .accessibilityIdentifier("listen.continueListening")
                .accessibilityLabel("\(continueActionLabel(for: book)) \(book.book.title)")
                .accessibilityHint("Opens the player")
            }
        }
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
                .scaledFont(size: 10, weight: .bold)
            Text("Supporter")
                .scaledFont(size: 11, weight: .semibold)
        }
        .foregroundStyle(Palette.brass)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.07))
        .accessibilityIdentifier("home.supporterBadge")
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .scaledFont(size: 19, weight: .semibold)
                .foregroundStyle(Palette.ink2)
                .frame(width: 40, height: 40)
                .glassSurface(cornerRadius: 12, fill: Color.white.opacity(0.07))
        }
        .accessibilityIdentifier("home.settingsButton")
        .accessibilityLabel("Settings")
    }

    @ViewBuilder
    private var jumpBackIn: some View {
        if !libraryStore.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Jump Back In")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(libraryStore.recentlyPlayed) { book in
                            NavigationLink {
                                BookPageView(book: book, showingNowPlaying: $showingNowPlaying)
                            } label: {
                                ListenBookCard(
                                    book: book,
                                    sourceTitle: libraryStore.source(for: book.book)?.title
                                )
                            }
                            .buttonStyle(.plain)
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
                SectionTitle(title: "Listening Stats", actionTitle: "Show more…", action: { showStats = true })
                HStack(spacing: 12) {
                    statTile(value: durationString(statsTotalTime), label: "Total time")
                    statTile(value: durationString(statsLast7DaysTotal), label: "Last 7 days")
                }
                weeklyChart
            }
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .scaledFont(size: 22, weight: .heavy)
                .foregroundStyle(Palette.ink)
            Text(label)
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private var weeklyChart: some View {
        let maxSeconds = max(statsDailyBars.map(\.seconds).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(statsDailyBars) { bar in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(height: max(3, CGFloat(bar.seconds / maxSeconds) * 44))
                    Text(bar.label)
                        .scaledFont(size: 8.5, weight: .semibold)
                        .foregroundStyle(Palette.ink3)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 58, alignment: .bottom)
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "0m" : TimeFormatting.compactDuration(seconds)
    }

    private func continueActionLabel(for book: BookWithChapters) -> String {
        guard let progress = libraryStore.progressByBook[book.book.id],
              progress.lastPosition > 0,
              !progress.isFinished else {
            return "Play"
        }
        return "Resume"
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
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Recommended for You")

            if recommendations.recommendations.isEmpty {
                EmptyStatePanel(
                    title: "Finding LibriVox Picks",
                    message: "Popular public-domain audiobooks will appear here.",
                    systemImage: "sparkles"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(recommendations.recommendations) { result in
                            Button {
                                Task { await presentResult(result) }
                            } label: {
                                HorizontalCatalogCard(result: result)
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
                            .glassSurface(cornerRadius: 18)
                            .padding(4)
                    }
                }
            }
        }
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
        playbackFailure == nil ? "Playback Failed" : "Playback Interrupted"
    }

    private var errorMessage: String {
        playback.playbackError ?? catalogStore.catalogError ?? libraryStore.importError ?? ""
    }

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }
        let existingBookIDs = Set(libraryStore.books.map(\.book.id))

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            if !existingBookIDs.contains(imported.book.id) {
                await libraryStore.markBookPending(imported.book.id)
            }
            selectedCatalogBookID = imported.book.id
        }
    }
}

struct ListenBookCard: View {
    let book: BookWithChapters
    let sourceTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookArtworkView(title: book.book.title, size: 132, coverURL: book.book.coverURL, cornerRadius: 14, showBorder: false)
            Text(book.book.title)
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 7)
            Text(book.book.authorLine)
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
            if book.narrationKind == .solo {
                SoloNarrationBadge()
                    .padding(.top, 4)
            } else {
                SoloNarrationBadge()
                    .opacity(0)
                    .padding(.top, 4)
            }
        }
        .frame(width: 132)
    }
}
