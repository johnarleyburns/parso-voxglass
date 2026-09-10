import SwiftUI
import VoxglassCore

struct ListenView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Binding var showingNowPlaying: Bool
    var selectLibrary: () -> Void

    @EnvironmentObject private var recommendations: HomeRecommendationStore
    @EnvironmentObject private var listeningStats: ListeningStatsStore
    @State private var importingIdentifier: String?
    @State private var showSettings = false
    @State private var showStats = false
    @State private var statsTotalTime: TimeInterval = 0
    @State private var statsLast7DaysTotal: TimeInterval = 0
    @State private var statsDailyBars: [ListeningStatsView.DayBar] = []
    @AppStorage(AppPreferencesStore.Keys.selectedCollectionIDs) private var selectedCollectionIDsRaw = ""
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"
    @AppStorage(AppPreferencesStore.Keys.isSupporter) private var isSupporter = false

    var body: some View {
        VoxglassScreen(title: "Voxglass") {
            VStack(alignment: .leading, spacing: 22) {
                hero
                jumpBackIn
                listeningStatsSummary
                recommended
            }
            .padding(.top, 12)
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
        .alert("Playback Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
        .task {
            await libraryStore.refreshRecentlyPlayed()
            await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
            await loadListeningStatsSummary()
        }
        .onChange(of: selectedCollectionIDsRaw) { _, _ in
            Task {
                await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
            }
        }
        .onChange(of: selectedLanguagesRaw) { _, _ in
            Task {
                await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
            }
        }
        .onChange(of: showingNowPlaying) { wasShowing, isShowing in
            // Reflect just-finished listening immediately: when Now Playing is
            // dismissed, the taste profile may have shifted, so refresh the shelf
            // (and Jump Back In) without waiting for a tab switch.
            guard wasShowing, !isShowing else { return }
            Task {
                await libraryStore.refreshRecentlyPlayed()
                await recommendations.load(selectedCollectionIDs: selectedCollectionIDs, selectedLanguages: selectedLanguages)
                await loadListeningStatsSummary()
            }
        }
    }

    /// Shown only until the user's first listen — a welcome, not a permanent
    /// masthead. Once there's any listening history it gives way to the
    /// content shelves below instead of pushing them down every time.
    @ViewBuilder
    private var hero: some View {
        if statsTotalTime <= 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Good listening")
                    .scaledFont(size: 31, weight: .heavy)
                    .foregroundStyle(Palette.ink)
                Text("Public-domain audiobooks, private by default.")
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    HStack(spacing: 12) {
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

    private func loadListeningStatsSummary() async {
        statsTotalTime = await listeningStats.totalTime()
        let calendar = Calendar.current
        let now = Date()
        let totals = await listeningStats.dailyTotals(days: 7, calendar: calendar, now: now)
        statsLast7DaysTotal = totals.values.reduce(0, +)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        statsDailyBars = (0..<7).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
            return ListeningStatsView.DayBar(label: formatter.string(from: day), seconds: totals[day] ?? 0)
        }
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
                    HStack(spacing: 12) {
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
            catalogStore.catalogError != nil || libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        }
    }

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.present(imported)
            showingNowPlaying = true
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
