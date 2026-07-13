import SwiftUI

struct SettingsView: View {
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VoxglassScreen(title: "More") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Languages")
                    LanguagesCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Storage & Cache")
                    CacheSettingsCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Sync")
                    SyncSettingsCard()
                }

                settingsGroup("Audio") {
                    EQSettingsRow()
                }

                settingsGroup("Playback") {
                    PrefetchDepthRow()
                    SkipIntervalRow()
                    SkipSilenceRow()
                    VolumeNormalizationRow()
                    SleepTimerDefaultRow()
                }

                settingsGroup("Insights") {
                    ListeningStatsRow()
                }

                settingsGroup("Local Files") {
                    FolderWatchRow()
                }

                settingsGroup("Library") {
                    NavigationLink {
                        SourcesView(showingNowPlaying: $showingNowPlaying)
                    } label: {
                        DisclosureListRow(
                            icon: "externaldrive.fill",
                            title: "Sources",
                            detail: "Add books from Internet Archive URLs",
                            count: nil
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        PlaylistsView(repository: PlaylistRepository(database: AppDatabase.makeApplicationDatabase()))
                    } label: {
                        DisclosureListRow(
                            icon: "text.badge.plus",
                            title: "Playlists",
                            detail: "Group books into shelves",
                            count: nil
                        )
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("About") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        DisclosureListRow(
                            icon: "info.circle.fill",
                            title: "About Voxglass",
                            detail: "How it works and your privacy",
                            count: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title)
            VStack(spacing: 0) {
                content()
            }
            .glassPanel()
        }
    }
}

private struct LanguagesCard: View {
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private var selected: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search, browse, and recommendations are limited to the languages you pick. Leave all off to include every language.")
                .scaledFont(size: 12.5)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(LibriVoxLanguage.all) { language in
                    languageChip(language)
                }
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func languageChip(_ language: LibriVoxLanguage) -> some View {
        let isSelected = selected.contains(language.id)
        return Button {
            toggle(language.id)
        } label: {
            HStack(spacing: 6) {
                Text(language.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 10, weight: .bold)
                }
            }
            .scaledFont(size: 12.5, weight: .semibold)
            .foregroundStyle(isSelected ? Color(hex: 0x221503) : Palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isSelected ? Palette.brass : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ id: String) {
        var codes = selected
        if codes.contains(id) {
            codes.remove(id)
        } else {
            codes.insert(id)
        }
        selectedLanguagesRaw = AppPreferencesStore.encodeLanguages(codes)
    }
}

private struct CacheSettingsCard: View {
    @State private var cacheUsed: Int64 = 0
    @State private var cacheLimit: Int64 = StreamCacheStore.defaultLimit
    @State private var cachedCount: Int = 0
    @State private var showClearConfirm = false
    @State private var showPaywall = false
    @AppStorage(AppPreferencesStore.Keys.cacheFullBooksOnCellular) private var cacheFullBooksOnCellular = false

    var body: some View {
        VStack(spacing: 12) {
            usageCard
            cellularCard
            clearCard
        }
        .task { await refresh() }
        .confirmationDialog(
            "Clear \(ByteFormatting.string(cacheUsed)) of cached audio and artwork?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await CacheManager.shared.clearCache()
                    await refresh()
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                ProPaywallView()
            }
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Streaming Cache")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(ByteFormatting.string(cacheUsed)) of \(ByteFormatting.string(cacheLimit))")
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.bottom, 11)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fillFraction)
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(cachedCount) tracks cached")
                    .scaledFont(size: 10.5)
                Spacer()
                Text("oldest evicted first")
                    .scaledFont(size: 10.5)
            }
            .foregroundStyle(Palette.ink3)
            .padding(.top, 8)

            HStack(spacing: 6) {
                ForEach(CacheManager.CachePreset.allCases, id: \.rawValue) { preset in
                    presetButton(preset)
                }
            }
            .padding(.top, 12)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func presetButton(_ preset: CacheManager.CachePreset) -> some View {
        let selected = preset.rawValue == cacheLimit
        let locked = preset.isProOnly && !ProFeature.isEnabled(.cachePresets)
        return Button {
            if locked {
                showPaywall = true
            } else {
                Task {
                    await CacheManager.shared.setPreset(preset)
                    await refresh()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(preset.displayName)
                if locked {
                    Image(systemName: "lock.fill")
                        .scaledFont(size: 9, weight: .semibold)
                }
            }
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(selected ? .white : Palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                selected ? Palette.brassDeep : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(locked ? "pro.lock.cache.\(preset.accessibilitySuffix)" : "cache.preset.\(preset.accessibilitySuffix)")
    }

    private var cellularCard: some View {
        Toggle(isOn: $cacheFullBooksOnCellular) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cache full books on cellular data")
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                Text("Streaming and next-chapter prefetch always use cellular. This only controls caching whole books offline.")
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Palette.brass)
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var clearCard: some View {
        Button {
            showClearConfirm = true
        } label: {
            HStack {
                Text("Clear Cache")
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Palette.danger)
                Spacer()
                Text(ByteFormatting.string(cacheUsed))
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var fillFraction: Double {
        guard cacheLimit > 0 else { return 0 }
        return min(1, Double(cacheUsed) / Double(cacheLimit))
    }

    private func refresh() async {
        cacheUsed = await CacheManager.shared.currentCacheBytes()
        cacheLimit = await CacheManager.shared.currentBudget
        cachedCount = await StreamCacheStore.shared.cachedTrackCount()
    }
}

struct SourcesView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var archiveURL = ""

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    addArchiveURLPanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Source Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
    }

    private var addArchiveURLPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Add Internet Archive URL")
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(VoxglassTheme.accent)
                    .frame(width: 26)
                TextField("archive.org/details/...", text: $archiveURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await addArchiveURL() }
                    }
                Button {
                    Task { await addArchiveURL() }
                } label: {
                    if catalogStore.isResolvingURL {
                        ProgressView()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoxglassTheme.accent)
                .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
            }
            .padding(12)
            .glassPanel()
        }
    }

    private func addArchiveURL() async {
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            archiveURL = ""
            await playback.play(imported)
            showingNowPlaying = true
        }
        await libraryStore.refresh()
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

struct AboutView: View {
    private let privacyURL = URL(string: "https://parso.guru/voxglass-privacy.html")!

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    aboutSection
                    privacySection
                    detailsList
                    Link(destination: privacyURL) {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(Palette.brass)
                            Text("Read the Privacy Policy")
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .scaledFont(size: 12, weight: .bold)
                                .foregroundStyle(Palette.ink3)
                        }
                        .padding(14)
                        .glassSurface(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voxglass")
                .scaledFont(size: 26, weight: .heavy)
                .kerning(-0.5)
                .foregroundStyle(Palette.ink)
            Text("Public-domain audiobooks with a private, local-first shelf.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "How It Works")
            Text("""
            Voxglass streams free, public-domain audiobooks from the Internet Archive's LibriVox collection. Search by title, author, or subject, or browse curated Featured Collections, then tap any book to start listening.

            There is no import step. When you play a book it is cached to your device automatically, so it keeps working offline. The cache is managed for you — the oldest, least-used audio is evicted first when space is needed.
            """)
                .scaledFont(size: 13.5)
                .foregroundStyle(Palette.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(cornerRadius: 14)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Privacy")
            Text("""
            Voxglass has no accounts, no tracking, and no analytics. Nothing you listen to leaves your device. The only network requests are to the Internet Archive to fetch audio and cover art you ask for. Your library, playback history, and cache live only on your device.
            """)
                .scaledFont(size: 13.5)
                .foregroundStyle(Palette.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(cornerRadius: 14)
        }
    }

    private var detailsList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 28, height: 28)
                Text("License")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("GPLv3")
                    .font(.caption)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            HStack(spacing: 12) {
                Image(systemName: "number")
                    .font(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 28, height: 28)
                Text("Version")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(appVersion)
                    .font(.caption)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .glassPanel()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct SyncSettingsCard: View {
    @EnvironmentObject private var cloudSync: VoxglassCloudSync
    @State private var showPaywall = false

    var body: some View {
        Group {
            if ProFeature.isEnabled(.icloudSync) {
                entitledCard
            } else {
                lockedCard
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .paywallSheet(isPresented: $showPaywall)
    }

    private var entitledCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "icloud.fill")
                    .foregroundStyle(Palette.brass)
                Text("iCloud Sync")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                if cloudSync.isSyncing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            Text("Playback positions, bookmarks, and favorites sync across your devices using your private iCloud account. No app account required.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)

            if let lastSync = cloudSync.lastSyncDate {
                Text("Last sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
            }

            if !cloudSync.isAvailable {
                Text("Sign in to iCloud to sync")
                    .scaledFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(Palette.brass)
            } else if let error = cloudSync.syncError {
                Text(error)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.danger)
            }

            Button {
                Task { await cloudSync.sync() }
            } label: {
                Text(cloudSync.isSyncing ? "Syncing…" : "Sync Now")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(cloudSync.isAvailable ? Palette.brass : Palette.ink3)
            }
            .disabled(cloudSync.isSyncing || !cloudSync.isAvailable)
            .accessibilityIdentifier("sync.now")
        }
    }

    private var lockedCard: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "icloud.fill")
                    .foregroundStyle(Palette.ink3)
                Text("iCloud Sync")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                ProLockBadge()
                Text("Pro")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pro.lock.icloudSync")
    }
}

private struct EQSettingsRow: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var showEQ = false
    @State private var showPaywall = false

    var body: some View {
        Button {
            if ProFeature.isEnabled(.eq) {
                showEQ = true
            } else {
                showPaywall = true
            }
        } label: {
            DisclosureListRow(
                icon: "waveform.path.ecg",
                title: "Equalizer",
                detail: ProFeature.isEnabled(.eq) ? "10-band EQ with presets" : "10-band EQ — a Pro feature",
                count: nil,
                isEnabled: ProFeature.isEnabled(.eq)
            )
            .overlay(alignment: .trailing) {
                if !ProFeature.isEnabled(.eq) {
                    ProLockBadge().padding(.trailing, 34)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(ProFeature.isEnabled(.eq) ? "settings.eq" : "pro.lock.eq")
        .sheet(isPresented: $showEQ) {
            NavigationStack {
                EQView().environmentObject(playback)
            }
            .presentationDragIndicator(.visible)
        }
        .paywallSheet(isPresented: $showPaywall)
    }
}

private struct PrefetchDepthRow: View {
    @AppStorage(AppPreferencesStore.Keys.prefetchDepth) private var depth = 1
    @AppStorage(AppPreferencesStore.Keys.prefetchWifiOnly) private var wifiOnly = true
    @State private var showPaywall = false

    private let whole = PlaybackCoordinator.wholeBookPrefetchDepth

    var body: some View {
        if ProFeature.isEnabled(.prefetchDepth) {
            entitled
        } else {
            locked
        }
    }

    private var entitled: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Prefetch Depth")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Picker("Prefetch Depth", selection: $depth) {
                Text("Next (1)").tag(1)
                Text("Next 3").tag(3)
                Text("Whole book").tag(whole)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $wifiOnly) {
                Text("Prefetch only on Wi-Fi")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)

            Text("Warms upcoming chapters so playback never waits. The next chapter is always prefetched for gapless playback.")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var locked: some View {
        Button {
            showPaywall = true
        } label: {
            DisclosureListRow(
                icon: "arrow.triangle.branch",
                title: "Prefetch Depth",
                detail: "Next chapter (1) — Pro prefetches more",
                count: nil,
                isEnabled: false
            )
            .overlay(alignment: .trailing) {
                ProLockBadge().padding(.trailing, 34)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pro.lock.prefetchDepth")
        .paywallSheet(isPresented: $showPaywall)
    }
}

private struct SkipIntervalRow: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @AppStorage(AppPreferencesStore.Keys.skipForwardInterval) private var forward = 30
    @AppStorage(AppPreferencesStore.Keys.skipBackInterval) private var back = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "forward.frame.fill")
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Skip Intervals")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Forward").scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
                Picker("Forward", selection: $forward) {
                    ForEach(PlaybackCoordinator.allowedSkipForwardValues, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Back").scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
                Picker("Back", selection: $back) {
                    ForEach(PlaybackCoordinator.allowedSkipBackValues, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .onChange(of: forward) { _, _ in playback.reconfigureSkipIntervals() }
        .onChange(of: back) { _, _ in playback.reconfigureSkipIntervals() }
    }
}

private struct SkipSilenceRow: View {
    @AppStorage(AppPreferencesStore.Keys.skipSilenceEnabled) private var skipSilenceEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.slash")
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Skip Silence")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Toggle(isOn: $skipSilenceEnabled) {
                Text("Speed up silent gaps")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)
            .accessibilityIdentifier("settings.skipSilence")

            Text("Long pauses between sentences play back faster, then drop to your chosen speed the moment the narrator resumes.")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct VolumeNormalizationRow: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @AppStorage(AppPreferencesStore.Keys.volumeNormalizationEnabled) private var volumeNormalizationEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill")
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Volume Normalization")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Toggle(isOn: $volumeNormalizationEnabled) {
                Text("Level quiet recordings")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)
            .accessibilityIdentifier("settings.volumeNormalization")

            Text("Automatically boosts quiet recordings so everything stays at a comfortable volume. Especially helpful for older LibriVox audiobooks.")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .onChange(of: volumeNormalizationEnabled) { _, newValue in
            playback.setVolumeNormalizationEnabled(newValue)
        }
    }
}

private struct SleepTimerDefaultRow: View {
    @AppStorage(AppPreferencesStore.Keys.sleepTimerDefaultMinutes) private var minutes = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Default Sleep Timer")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Picker("Default Sleep Timer", selection: $minutes) {
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("45 min").tag(45)
                Text("60 min").tag(60)
            }
            .pickerStyle(.segmented)

            Text("Your preferred sleep-timer length. Pick any duration — or “End of chapter” — from the moon icon while a book is playing.")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct ListeningStatsRow: View {
    @EnvironmentObject private var stats: ListeningStatsStore
    @State private var showStats = false
    @State private var showPaywall = false

    var body: some View {
        Button {
            if ProFeature.isEnabled(.listeningStats) {
                showStats = true
            } else {
                showPaywall = true
            }
        } label: {
            DisclosureListRow(
                icon: "chart.bar.fill",
                title: "Listening Stats",
                detail: ProFeature.isEnabled(.listeningStats) ? "Total time, streaks, and top authors" : "Total time, streaks — a Pro feature",
                count: nil,
                isEnabled: ProFeature.isEnabled(.listeningStats)
            )
            .overlay(alignment: .trailing) {
                if !ProFeature.isEnabled(.listeningStats) {
                    ProLockBadge().padding(.trailing, 34)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(ProFeature.isEnabled(.listeningStats) ? "settings.listeningStats" : "pro.lock.listeningStats")
        .sheet(isPresented: $showStats) {
            NavigationStack {
                ListeningStatsView().environmentObject(stats)
            }
            .presentationDragIndicator(.visible)
        }
        .paywallSheet(isPresented: $showPaywall)
    }
}

private struct FolderWatchRow: View {
    @EnvironmentObject private var folderWatch: FolderWatchService
    @State private var showPaywall = false

    var body: some View {
        if ProFeature.isEnabled(.folderWatch) {
            NavigationLink {
                FolderWatchView().environmentObject(folderWatch)
            } label: {
                DisclosureListRow(
                    icon: "folder.fill.badge.plus",
                    title: "Watch a Folder",
                    detail: folderWatch.folders.isEmpty ? "Import audio files from a folder" : "\(folderWatch.folders.count) watched",
                    count: nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.folderWatch")
        } else {
            Button {
                showPaywall = true
            } label: {
                DisclosureListRow(
                    icon: "folder.fill.badge.plus",
                    title: "Watch a Folder",
                    detail: "Import from a folder — a Pro feature",
                    count: nil,
                    isEnabled: false
                )
                .overlay(alignment: .trailing) {
                    ProLockBadge().padding(.trailing, 34)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pro.lock.folderWatch")
            .paywallSheet(isPresented: $showPaywall)
        }
    }
}




