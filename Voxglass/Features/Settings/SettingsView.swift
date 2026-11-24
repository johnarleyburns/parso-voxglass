import ParsoAudioStreaming
import SwiftUI
import AVFoundation
import VoxglassCore
import VoxglassWatchProtocol

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SettingsView: View {
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VoxglassScreen(title: "Settings", embedsNavigationStack: false) {
            VStack(alignment: .leading, spacing: 16) {
                settingsGroup("Support") {
                    SupportDevelopmentCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Languages")
                    LanguagesCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Storage & Cache")
                    CacheSettingsCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SyncSettingsSection()
                }

                settingsGroup("Audio") {
                    ReadWithAIVoiceRow()
                    EQSettingsRow()
                }

                settingsGroup("Playback") {
                    PrefetchDepthRow()
                    SkipIntervalRow()
                    // SkipSilenceRow()
                    VolumeNormalizationRow()
                    SleepTimerDefaultRow()
                    WidgetSnapshotSettingsRow()
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

                    LibraryBackupRow()
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.root")
        }
    }

    private func settingsGroup<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VoxglassGroupedSection(title: title) {
            content()
        }
    }
}

private struct ReadWithAIVoiceRow: View {
    // Observe the legacy mirror so this row refreshes immediately after the
    // picker updates the structured preference.
    @AppStorage(AppPreferencesStore.Keys.readWithAIVoiceIdentifier) private var selectedIdentifier = ""

    private var selectedVoiceName: String {
        _ = selectedIdentifier
        return ReadWithAISpeechAudioEngine.voiceDisplayName(for: ReadWithAIVoicePreferences.defaultPreference())
    }

    var body: some View {
        NavigationLink {
            ReadWithAIVoicePicker()
        } label: {
            DisclosureListRow(
                icon: "waveform.and.mic",
                title: "Read with AI Voice",
                detail: LocalizedStringKey(selectedVoiceName),
                count: nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.readWithAIVoice")
    }
}

struct ReadWithAIVoicePicker: View {
    let bookID: UUID?
    let onSelection: ((ReadWithAIVoicePreference) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(bookID: UUID? = nil, onSelection: ((ReadWithAIVoicePreference) -> Void)? = nil) {
        self.bookID = bookID
        self.onSelection = onSelection
    }

    private var selectedPreference: ReadWithAIVoicePreference {
        if let bookID { return ReadWithAIVoicePreferences.preference(for: bookID) }
        return ReadWithAIVoicePreferences.defaultPreference()
    }

    private var voices: [AVSpeechSynthesisVoice] {
        let languageCode = Locale.autoupdatingCurrent.language.languageCode?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { Locale(identifier: $0.language).language.languageCode?.identifier == languageCode }
            .sorted { lhs, rhs in
                if qualityScore(lhs) != qualityScore(rhs) { return qualityScore(lhs) > qualityScore(rhs) }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        VoxglassScreen(title: "Read with AI Voice") {
            VStack(alignment: .leading, spacing: 16) {
                Text(bookID == nil
                    ? "Choose the default installed voice for new Read with AI books. Best available automatically uses the highest-quality Premium or Enhanced voice for your language."
                    : "Choose this book's voice. The book pauses, saves your choice, then resumes at the same spot with the new voice.")
                    .voxFont(.footnote)
                    .foregroundStyle(Palette.ink2)

                VoxglassGroupedSection(title: "Voice") {
                    voiceButton(preference: .automatic, name: "Best available", detail: "Automatically chooses Premium or Enhanced")
                    ForEach(voices, id: \.identifier) { voice in
                        VoxglassListDivider()
                        voiceButton(
                            preference: ReadWithAIVoicePreference(identifier: voice.identifier, name: voice.name, language: voice.language),
                            name: voice.name,
                            detail: "\(languageName(voice.language)) · \(qualityName(voice.quality))"
                        )
                    }
                }

                Text("Download more voices in iPhone Settings > Accessibility > Read & Speak > System Voice, then return here.")
                    .voxFont(.caption)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.top, 12)
        }
    }

    private func voiceButton(preference: ReadWithAIVoicePreference, name: String, detail: String) -> some View {
        Button {
            if bookID != nil {
                onSelection?(preference)
            } else {
                ReadWithAIVoicePreferences.setDefault(preference)
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).voxFont(.body, weight: .semibold).foregroundStyle(Palette.ink)
                    Text(detail).voxFont(.caption).foregroundStyle(Palette.ink2)
                }
                Spacer()
                if selectedPreference.identifier == preference.identifier {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brass)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(preference.identifier.isEmpty ? "settings.readWithAIVoice.automatic" : "settings.readWithAIVoice.\(preference.identifier)")
    }

    private func qualityScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: 3
        case .enhanced: 2
        default: 1
        }
    }

    private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }

    private func languageName(_ identifier: String) -> String {
        Locale.autoupdatingCurrent.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Every feature in the app is free. This is the only purchase surface
/// left — a purely optional, one-time "thank you" consumable, purchasing
/// which sets `AppPreferencesStore.Keys.isSupporter` and shows a small
/// Supporter badge on the home view. It never gates anything.
private struct SupportDevelopmentCard: View {
    @AppStorage(AppPreferencesStore.Keys.isSupporter) private var isSupporter = false
    @State private var isPurchasing = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Task { await purchase() }
            } label: {
                DisclosureListRow(
                    icon: "heart.fill",
                    title: isSupporter ? "Thanks for supporting Voxglass" : "Contribute to Development",
                    detail: isSupporter ? "You have the Supporter badge" : "A one-time, optional $9.99 — every feature is already free",
                    count: nil,
                    isEnabled: !isPurchasing
                )
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing)
            .accessibilityIdentifier("settings.support")

            if let resultMessage {
                VoxglassListDivider()
                Text(resultMessage)
                    .voxFont(.caption2)
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .raisedSurface()
    }

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let purchased = try await SupportDevelopmentStore.shared.purchase()
            if purchased {
                resultMessage = String(localized: "Thank you for supporting Voxglass!")
            }
        } catch {
            resultMessage = String(localized: "Purchase failed: \(error.localizedDescription)")
        }
    }
}

private struct LanguagesCard: View {
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    private var selection: Binding<Set<String>> {
        Binding(
            get: { AppPreferencesStore.decodeLanguages(selectedLanguagesRaw) },
            set: { selectedLanguagesRaw = AppPreferencesStore.encodeLanguages($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search, browse, and recommendations are limited to the languages you pick. Leave all off to include every language.")
                .voxFont(.caption)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            LanguageFilterPicker(selection: selection)
        }
        .padding(15)
        .raisedSurface()
    }
}

private struct CacheSettingsCard: View {
    private enum ClearTarget: String, Identifiable {
        case streaming
        case offline
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .streaming: return String(localized: "Streaming Cache")
            case .offline: return String(localized: "Offline Downloads")
            case .all: return String(localized: "All Cached Data")
            }
        }
    }

    @EnvironmentObject private var offlineDownloadManager: OfflineDownloadManager
    @State private var usage = AudioCache.StorageUsage(
        streamingBytes: 0,
        durableBytes: 0,
        streamingAudioCount: 0,
        durableAudioCount: 0
    )
    @State private var cacheLimit: Int64 = SparseCacheStore.defaultLimit
    @State private var clearTarget: ClearTarget?
    @AppStorage(AppPreferencesStore.Keys.cacheFullBooksOnCellular) private var cacheFullBooksOnCellular = false

    var body: some View {
        VStack(spacing: 12) {
            usageCard
            cellularCard
            clearCard
        }
        .task { await refresh() }
        .confirmationDialog(
            clearConfirmationTitle,
            isPresented: clearDialogPresented,
            titleVisibility: .visible
        ) {
            if let clearTarget {
                Button("Clear \(clearTarget.title)", role: .destructive) {
                    let target = clearTarget
                    self.clearTarget = nil
                    Task {
                        await clear(target)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                clearTarget = nil
            }
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cached Storage")
                    .voxFont(.footnote, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(ByteFormatting.string(usage.totalBytes))
                    .voxFont(.caption2, weight: .semibold)
                    .foregroundStyle(Palette.ink2)
            }
            .padding(.bottom, 13)

            storageRow(
                title: "Streaming cache",
                bytes: usage.streamingBytes,
                detail: "\(usage.streamingAudioCount) tracks · oldest evicted first",
                limit: cacheLimit
            )

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
            .padding(.top, 9)

            storageRow(
                title: "Offline downloads",
                bytes: usage.durableBytes,
                detail: "\(usage.durableAudioCount) tracks · kept until cleared",
                limit: nil
            )
            .padding(.top, 15)

            Divider()
                .overlay(Color.white.opacity(0.1))
                .padding(.vertical, 13)

            HStack {
                Text("Total cached storage")
                    .voxFont(.caption2, weight: .semibold)
                Spacer()
                Text(ByteFormatting.string(usage.totalBytes))
                    .voxFont(.caption2, weight: .semibold)
            }
            .foregroundStyle(Palette.ink2)

            HStack(spacing: 6) {
                ForEach(AudioCache.CachePreset.allCases, id: \.rawValue) { preset in
                    presetButton(preset)
                }
            }
            .padding(.top, 12)
        }
        .padding(15)
        .raisedSurface()
    }

    private func storageRow(title: LocalizedStringKey, bytes: Int64, detail: LocalizedStringKey, limit: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .voxFont(.caption, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .voxFont(.caption2)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormatting.string(bytes))
                    .voxFont(.caption, weight: .semibold)
                    .foregroundStyle(Palette.ink2)
                if let limit {
                    Text("of \(ByteFormatting.string(limit))")
                        .voxFont(.caption2)
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
    }

    private func presetButton(_ preset: AudioCache.CachePreset) -> some View {
        let selected = preset.rawValue == cacheLimit
        return Button {
            Task {
                await AudioCache.CachePreset.select(preset)
                await refresh()
            }
        } label: {
            HStack(spacing: 4) {
                Text(preset.displayName)
            }
            .voxFont(.caption2, weight: .semibold)
            .foregroundStyle(selected ? .white : Palette.ink2)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(
                selected ? Palette.brassDeep : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cache.preset.\(preset.accessibilitySuffix)")
    }

    private var cellularCard: some View {
        Toggle(isOn: $cacheFullBooksOnCellular) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cache full books on cellular data")
                    .voxFont(.footnote, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                Text("Streaming and next-chapter prefetch always use cellular. This only controls caching whole books offline.")
                    .voxFont(.caption2)
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Palette.brass)
        .padding(15)
        .raisedSurface()
    }

    private var clearCard: some View {
        VStack(spacing: 0) {
            clearButton(.streaming, bytes: usage.streamingBytes, detail: "Audio and artwork that can be downloaded again")
            VoxglassListDivider()
            clearButton(.offline, bytes: usage.durableBytes, detail: "Books saved for offline listening")
            VoxglassListDivider()
            clearButton(.all, bytes: usage.totalBytes, detail: "Streaming cache and offline downloads")
        }
        .padding(.horizontal, 15)
        .raisedSurface()
    }

    private func clearButton(_ target: ClearTarget, bytes: Int64, detail: LocalizedStringKey) -> some View {
        Button {
            clearTarget = target
        } label: {
            HStack(spacing: 11) {
                Image(systemName: target == .all ? "trash.fill" : "trash")
                    .foregroundStyle(Palette.danger)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clear \(target.title)")
                        .voxFont(.footnote, weight: .semibold)
                        .foregroundStyle(Palette.danger)
                    Text(detail)
                        .voxFont(.caption2)
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 8)
                Text(ByteFormatting.string(bytes))
                    .voxFont(.caption2, weight: .semibold)
                    .foregroundStyle(Palette.ink2)
            }
            .frame(minHeight: 54)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cache.clear.\(target.rawValue)")
    }

    private var fillFraction: Double {
        guard cacheLimit > 0 else { return 0 }
        return min(1, Double(usage.streamingBytes) / Double(cacheLimit))
    }

    private var clearConfirmationTitle: String {
        guard let clearTarget else { return String(localized: "Clear cached data?") }
        let size = ByteFormatting.string(bytes(for: clearTarget))
        switch clearTarget {
        case .streaming: return String(localized: "Clear \(size) of streaming cache?")
        case .offline: return String(localized: "Clear \(size) of offline downloads?")
        case .all: return String(localized: "Clear \(size) of all cached data?")
        }
    }

    private var clearDialogPresented: Binding<Bool> {
        Binding(
            get: { clearTarget != nil },
            set: { if !$0 { clearTarget = nil } }
        )
    }

    private func bytes(for target: ClearTarget) -> Int64 {
        switch target {
        case .streaming: return usage.streamingBytes
        case .offline: return usage.durableBytes
        case .all: return usage.totalBytes
        }
    }

    private func clear(_ target: ClearTarget) async {
        switch target {
        case .streaming:
            await AudioCache.clearStreamingCache()
            ArtworkService.shared.clearMemory()
        case .offline:
            await offlineDownloadManager.removeAllOffline()
        case .all:
            await offlineDownloadManager.removeAllOffline()
            await AudioCache.clearCache()
            ArtworkService.shared.clearMemory()
        }
        await refresh()
    }

    private func refresh() async {
        usage = await AudioCache.storageUsage()
        cacheLimit = AudioCache.CachePreset.selected.rawValue
    }
}

struct SourcesView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(CatalogStore.self) private var catalogStore
    @Environment(PlaybackCoordinator.self) private var playback
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
                .accessibilityLabel("Add source")
                .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
            }
            .padding(12)
            .raisedSurface()
        }
    }

    private func addArchiveURL() async {
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            archiveURL = ""
            await playback.present(imported)
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
    private let privacyURL = URL(string: "https://johnarleyburns.github.io/parso-voxglass/privacy.html")!
    private let sourceURL = URL(string: "https://github.com/johnarleyburns/parso-voxglass")!

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    NavigationLink {
                        SyncDiagnosticsView()
                    } label: {
                        Label("Sync Details", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("about.syncDetails")
                    aboutSection
                    languagesSection
                    privacySection
                    licenseSection
                    detailsList
                    Link(destination: sourceURL) {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(Palette.brass)
                            Text("View Source (GPLv3)")
                                .voxFont(.subheadline, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .voxFont(.caption, weight: .bold)
                                .foregroundStyle(Palette.ink3)
                        }
                        .padding(14)
                        .raisedSurface()
                    }
                    .buttonStyle(.plain)
                    Link(destination: privacyURL) {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(Palette.brass)
                            Text("Read the Privacy Policy")
                                .voxFont(.subheadline, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .voxFont(.caption, weight: .bold)
                                .foregroundStyle(Palette.ink3)
                        }
                        .padding(14)
                        .raisedSurface()
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
                .voxFont(.title, weight: .heavy)
                .foregroundStyle(Palette.ink)
            Text("Public-domain audiobooks with a private, local-first shelf.")
                .voxFont(.subheadline)
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
                .voxFont(.footnote)
                .foregroundStyle(Palette.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raisedSurface()
        }
    }

    /// The languages this build actually ships, read from the bundle so the list
    /// can never drift from the String Catalogs. Each name is shown in its own
    /// language, the way the system language picker shows them.
    private static var shippedLanguageNames: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted()
            .map { code in
                let locale = Locale(identifier: code)
                let name = locale.localizedString(forIdentifier: code) ?? code
                return name.prefix(1).uppercased(with: locale) + name.dropFirst()
            }
    }

    private var languagesSection: some View {
        let names = Self.shippedLanguageNames
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Languages")
            VStack(alignment: .leading, spacing: 10) {
                Text("Voxglass is available in \(names.count) languages. It follows your iPhone’s language, or you can choose a language just for Voxglass in Settings.")
                    .voxFont(.footnote)
                    .foregroundStyle(Palette.ink2)
                Text(verbatim: names.joined(separator: " · "))
                    .voxFont(.footnote, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("settings.about.languages")
                Button("Change Language") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .voxFont(.footnote, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .accessibilityIdentifier("settings.about.changeLanguage")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedSurface()
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Privacy")
            Text("""
            Voxglass has no app accounts, tracking, or analytics. It contacts LibriVox, Project Gutenberg, and Internet Archive only when you search their catalogs or choose audio, text, or artwork to download or play. Internet Archive serves the LibriVox audio and associated artwork.

            Your library, listening history, bookmarks, playback position, and cache stay on your device. There is no app account and no server that stores your library; nothing you listen to leaves your device except requests for public catalog audio from the Internet Archive.
            """)
                .voxFont(.footnote)
                .foregroundStyle(Palette.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raisedSurface()
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "License")
            Text("""
            Voxglass is free software, licensed under the GNU General Public License v3.0 or later (GPLv3+). The complete source code is public. Because the GPL's own terms conflict with the App Store's distribution terms, an additional permission under GPLv3 §7 specifically allows distributing Voxglass through the App Store, provided the source of the exact version distributed stays publicly available under this License — which it does, at the link below.
            """)
                .voxFont(.footnote)
                .foregroundStyle(Palette.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raisedSurface()
        }
    }

    @ViewBuilder private var detailsList: some View {
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
                Text("GPLv3+")
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
        .raisedSurface()

        Text("Voxglass is free, has no ads or tracking, and is open source. Books come from LibriVox volunteers and the Internet Archive.")
            .voxFont(.caption2)
            .foregroundStyle(Palette.ink3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("settings.about.mission")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct WatchSyncDiagnosticsCard: View {
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose books in Settings to listen on Apple Watch.")
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)

            Text("\(phoneAudioRelay.watchStoredBookCount) downloaded books · \(ByteCountFormatter.string(fromByteCount: phoneAudioRelay.watchStoredBytes, countStyle: .file)) on Watch")
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)
                .accessibilityIdentifier("watchsync.storageSummary")

            if !phoneAudioRelay.watchStalledBookIDs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sync needs attention").foregroundStyle(Palette.danger)
                    ForEach(phoneAudioRelay.watchStalledBookTitles, id: \.self) { Text($0) }
                    Text("Open Sync to retry")
                }
                .voxFont(.caption2)
                .accessibilityIdentifier("watchsync.stalled")
            }
            if let status = phoneAudioRelay.watchSyncStatus {
                Text(status)
                    .voxFont(.caption2)
                    .foregroundStyle(status.localizedCaseInsensitiveContains("failed") ? Palette.danger : Palette.ink3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("watchsync.result")
            }


        }
        .padding(15)
        .raisedSurface()
    }
}

private struct EQSettingsRow: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var showEQ = false

    var body: some View {
        Button {
            showEQ = true
        } label: {
            DisclosureListRow(
                icon: "waveform.path.ecg",
                title: "Equalizer",
                detail: "10-band EQ with presets",
                count: nil,
                isEnabled: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.eq")
        .sheet(isPresented: $showEQ) {
            NavigationStack {
                EQView().environment(playback)
            }
            .presentationDragIndicator(.visible)
        }
    }
}

private struct WidgetSnapshotSettingsRow: View {
    @State private var enabled: Bool

    init() {
        let defaults = UserDefaults(suiteName: "group.guru.parso.voxglass") ?? .standard
        _enabled = State(initialValue: defaults.object(forKey: AppPreferencesStore.Keys.widgetSnapshot) as? Bool ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: $enabled) {
                Label("Show on widgets", systemImage: "rectangle.on.rectangle")
                    .voxType(.body)
                    .foregroundStyle(Palette.ink)
            }
            .onChange(of: enabled) { _, value in
                UserDefaults.standard.set(value, forKey: AppPreferencesStore.Keys.widgetSnapshot)
                (UserDefaults(suiteName: "group.guru.parso.voxglass") ?? .standard)
                    .set(value, forKey: AppPreferencesStore.Keys.widgetSnapshot)
                if !value { WidgetSnapshotWriter.remove() }
            }
            Text("Writes the current title and progress to this device's Voxglass widget every minute while listening.")
                .voxType(.meta)
                .foregroundStyle(Palette.ink3)
        }
        .padding(14)
        .raisedSurface()
        .accessibilityIdentifier("settings.widgetSnapshot")
    }
}

private struct PrefetchDepthRow: View {
    @AppStorage(AppPreferencesStore.Keys.prefetchDepth) private var depth = 1
    @AppStorage(AppPreferencesStore.Keys.prefetchWifiOnly) private var wifiOnly = true

    private let whole = PlaybackCoordinator.wholeBookPrefetchDepth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .voxFont(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Prefetch Depth")
                    .voxFont(.subheadline, weight: .medium)
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
                    .voxFont(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)

            Text("Warms upcoming chapters so playback never waits. The next chapter is always prefetched for gapless playback.")
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct SkipIntervalRow: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @AppStorage(AppPreferencesStore.Keys.skipForwardInterval) private var forward = 30
    @AppStorage(AppPreferencesStore.Keys.skipBackInterval) private var back = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "forward.frame.fill")
                    .voxFont(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Skip Intervals")
                    .voxFont(.subheadline, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Forward").voxFont(.caption2).foregroundStyle(Palette.ink3)
                Picker("Forward", selection: $forward) {
                    ForEach(PlaybackCoordinator.allowedSkipForwardValues, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Back").voxFont(.caption2).foregroundStyle(Palette.ink3)
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
                    .voxFont(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Skip Silence")
                    .voxFont(.subheadline, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Toggle(isOn: $skipSilenceEnabled) {
                Text("Speed up silent gaps")
                    .voxFont(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)
            .accessibilityIdentifier("settings.skipSilence")

            Text("Long pauses between sentences play back faster, then drop to your chosen speed the moment the narrator resumes.")
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct VolumeNormalizationRow: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @AppStorage(AppPreferencesStore.Keys.volumeNormalizationEnabled) private var volumeNormalizationEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill")
                    .voxFont(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Volume Normalization")
                    .voxFont(.subheadline, weight: .medium)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Toggle(isOn: $volumeNormalizationEnabled) {
                Text("Level quiet recordings")
                    .voxFont(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)
            .accessibilityIdentifier("settings.volumeNormalization")

            Text("Automatically boosts quiet recordings so everything stays at a comfortable volume. Especially helpful for older LibriVox audiobooks.")
                .voxFont(.caption2)
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
                    .voxFont(.subheadline)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    }
                Text("Default Sleep Timer")
                    .voxFont(.subheadline, weight: .medium)
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
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct ListeningStatsRow: View {
    @EnvironmentObject private var stats: ListeningStatsStore
    @State private var showStats = false

    var body: some View {
        Button {
            showStats = true
        } label: {
            DisclosureListRow(
                icon: "chart.bar.fill",
                title: "Listening Stats",
                detail: "Total time, streaks, and top authors",
                count: nil,
                isEnabled: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.listeningStats")
        .sheet(isPresented: $showStats) {
            NavigationStack {
                ListeningStatsView().environmentObject(stats)
            }
            .presentationDragIndicator(.visible)
        }
    }
}

private struct FolderWatchRow: View {
    @EnvironmentObject private var folderWatch: FolderWatchService

    var body: some View {
        NavigationLink {
            FolderWatchView().environmentObject(folderWatch)
        } label: {
            DisclosureListRow(
                icon: "folder.fill.badge.plus",
                title: "Watch a Folder",
                detail: folderWatch.folders.isEmpty ? "Import from a folder" : "\(folderWatch.folders.count) watched",
                count: nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.folderWatch")
    }
}

struct ExportedBackup: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LibraryBackupRow: View {
    @EnvironmentObject private var backupService: LibraryBackupService
    @State private var showImporter = false
    @State private var exportedBackup: ExportedBackup?
    @State private var showExportError = false
    @State private var importedCount: Int?

    var body: some View {
        Button {
            showImporter = true
        } label: {
            DisclosureListRow(
                icon: "externaldrive.badge.timemachine",
                title: "Backup & Restore",
                detail: "Save your library to a file and restore it later",
                count: nil
            )
        }
        .buttonStyle(.plain)
        .confirmationDialog("Would you like to export or import?", isPresented: $showImporter, titleVisibility: .visible) {
            Button(backupService.isExporting ? "Exporting…" : "Export Backup") { // l10n-exempt: state-dependent accessibility or status copy
                Task { await exportBackup() }
            }
            .disabled(backupService.isExporting)
            Button("Import Backup") {
                showImportSheet = true
            }
        }
        .sheet(isPresented: $showImportSheet, onDismiss: {
            if importedCount != nil {
                importAlert = true
            }
        }) {
            BackupImportSheet(backupService: backupService) { count in
                importedCount = count
                showImportSheet = false
            }
        }
        .sheet(item: $exportedBackup) { backup in
            ShareSheet(items: [backup.url])
        }
        .alert("Import Complete", isPresented: $importAlert) {
            Button("OK", role: .cancel) { importedCount = nil }
        } message: {
            if let count = importedCount {
                Text("\(count) books restored from backup.")
            }
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) { backupService.exportError = nil }
        } message: {
            Text(backupService.exportError ?? String(localized: "Could not write the backup file."))
        }
        .overlay {
            if backupService.isExporting {
                ProgressView()
            }
        }
    }

    @State private var showImportSheet = false
    @State private var importAlert = false

    private func exportBackup() async {
        backupService.exportError = nil
        if let url = await backupService.exportToFile() {
            exportedBackup = ExportedBackup(url: url)
        } else {
            showExportError = true
        }
    }
}

private struct BackupImportSheet: View {
    let backupService: LibraryBackupService
    let onComplete: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .scaledFont(size: 48) // type-exempt: settings statistic numeral
                    .foregroundStyle(Palette.brass)
                    .padding(.top, 32)

                Text("Import Library Backup")
                    .voxFont(.title3, weight: .heavy)
                    .foregroundStyle(Palette.ink)

                Text("Select a Voxglass backup file (.json, or legacy .voxglassbackup) from another device. Books that already exist in your library will be skipped.")
                    .voxFont(.subheadline)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    showFilePicker = true
                } label: {
                    Text("Choose Backup File")
                        .voxFont(.subheadline, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(Color(hex: 0x221503))
                        .background {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                    startPoint: .top, endPoint: .bottom))
                        }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json, BackupPayload.utType]) { result in
                switch result {
                case .success(let url):
                    Task {
                        let count = await backupService.importFromFile(url)
                        onComplete(count)
                    }
                case .failure:
                    dismiss()
                }
            }
        }
    }
}

// One control surface for manual sync, explicit audio selection and recovery.
private struct SyncSettingsSection: View {
    @EnvironmentObject private var relay: PhoneAudioRelay
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var selectedIDs = Set<UUID>()
    @State private var loadedSelection = false
    @State private var baselineIDs = Set<UUID>()
    @State private var showingBooks = false
    @State private var confirmChanges = false
    @State private var confirmCellular = false
    @State private var isRunning = false
    @State private var isPausing = false
    @State private var startedAt: Date?
    @State private var syncTask: Task<Void, Never>?
    @State private var operationError: String?

    private var libraryBooks: [BookWithChapters] { libraryStore.books.filter { !$0.book.isPending } }

    private var candidates: [BookWithChapters] {
        libraryBooks.filter { book in
            guard selectedIDs.contains(book.book.id), watchDownloadSupported(book) else { return false }
            switch relay.watchState(for: book.book.id) {
            case .notAvailable, .failed, .stalled, .paused: return true
            default: return false
            }
        }
    }
    private func watchDownloadSupported(_ book: BookWithChapters) -> Bool {
        WatchDownloadEligibility.allowsTransfer(
            isReadByAI: libraryStore.source(for: book.book)?.kind == .readWithAI,
            chapterExtensions: book.chapters.flatMap { [$0.localURL?.pathExtension, $0.remoteURL?.pathExtension].compactMap { $0 } })
    }

    private var removals: Set<UUID> {
        Set(relay.watchSelectedBookIDs.subtracting(selectedIDs).filter {
            relay.watchDesiredStates[WatchBookID($0.uuidString)] != .removing
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VoxglassGroupedSection(title: "Sync") {
                HStack(alignment: .top) {
                    SyncStatusSummary(isRequesting: isRunning)
                    Spacer(minLength: 12)
                    Button {
                        operationError = nil
                        if candidates.isEmpty && removals.isEmpty { startSync(allowCellular: false) }
                        else { confirmChanges = true }
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isRunning || isPausing || relay.isTransferringToWatch)
                    .accessibilityIdentifier("sync.now")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if let startedAt, isRunning {
                    LabeledContent("Started", value: startedAt.formatted(date: .omitted, time: .shortened))
                        .voxFont(.caption2)
                        .padding(.horizontal, 14)
                }
                if let operationError {
                    Text(operationError).foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                }
                if isRunning || relay.isPreparingWatchAudio || hasActiveTransfers {
                    Button("Pause") { pause() }
                        .disabled(isPausing)
                        .accessibilityIdentifier("sync.pause")
                        .padding(.horizontal, 14)
                }
            }
            VoxglassGroupedSection(title: "Apple Watch") {
                DisclosureGroup("Apple Watch", isExpanded: $showingBooks) {
                    Text("Choose books to keep on Apple Watch, then tap Sync. Turn a book off to remove only its watch copy.")
                        .voxFont(.caption)
                    if !relay.isPaired || !relay.isWatchAppInstalled {
                        Text(relay.connectionStatusText).voxFont(.caption)
                    }
                    ForEach(libraryBooks) { book in
                        if !watchDownloadSupported(book) {
                            HStack {
                                Text(book.book.title)
                                Spacer()
                                ReadByAIWatchInfoButton()
                            }
                            if relay.watchSelectedBookIDs.contains(book.book.id) {
                                Toggle("On My Watch", isOn: Binding(
                                    get: { selectedIDs.contains(book.book.id) },
                                    set: { if $0 { selectedIDs.insert(book.book.id) } else { selectedIDs.remove(book.book.id) } }
                                ))
                                .disabled(isRunning)
                            }
                        } else {
                            Toggle(isOn: Binding(
                                get: { selectedIDs.contains(book.book.id) },
                                set: { if $0 { selectedIDs.insert(book.book.id) } else { selectedIDs.remove(book.book.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(book.book.title)
                                    Text(relay.watchBookStatus(for: book.book.id))
                                        .voxFont(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isRunning || relay.isTransferringToWatch || !relay.isPaired || !relay.isWatchAppInstalled)
                            .accessibilityIdentifier("sync.book.\(book.book.id.uuidString)")
                        }
                    }
                    // Selected books deleted from the phone must remain removable.
                    ForEach(relay.watchCatalogBooks.filter { dto in
                        !libraryStore.books.contains { $0.book.id.uuidString == dto.id.rawValue }
                    }, id: \.id) { book in
                        if let id = UUID(uuidString: book.id.rawValue) {
                            Toggle(book.title, isOn: Binding(
                                get: { selectedIDs.contains(id) },
                                set: { if $0 { selectedIDs.insert(id) } else { selectedIDs.remove(id) } }
                            ))
                            .disabled(isRunning)
                        }
                    }
                    if libraryStore.books.isEmpty && relay.watchCatalogBooks.isEmpty {
                        Text("No Audiobooks Yet")
                    }
                }
                .accessibilityIdentifier("sync.books")
            }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: relay.watchSelectedBookIDs) { _, _ in reconcileSelection() }
        .confirmationDialog("Sync selected books?", isPresented: $confirmChanges, titleVisibility: .visible) {
            Button("Sync") { startSync(allowCellular: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(estimate)
        }
        .confirmationDialog("Send to Apple Watch on cellular data?", isPresented: $confirmCellular, titleVisibility: .visible) {
            Button("Send now on cellular") { startSync(allowCellular: true) }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("Sending a book to the watch can use significant cellular data.")
        }
    }

    private func reconcileSelection() {
        let latest = Set(relay.watchSelectedBookIDs.filter {
            relay.watchDesiredStates[WatchBookID($0.uuidString)] != .removing
        })
        selectedIDs = loadedSelection
            ? WatchSyncSelection.reconcile(selected: selectedIDs, baseline: baselineIDs, latest: latest)
            : latest
        baselineIDs = latest
        loadedSelection = true
    }

    private var hasActiveTransfers: Bool {
        relay.watchDesiredStates.values.contains { [.queued, .preparing, .transferring, .installing].contains($0) }
    }

    private var estimate: String {
        let bytes = candidates.reduce(Int64(0)) { total, book in
            total + ByteFormatting.estimatedAudiobookBytes(duration: book.chapters.reduce(0) { $0 + ($1.duration ?? 0) })
        }
        var message = String(localized: "This will use approximately \(ByteFormatting.string(bytes)) of storage on your Apple Watch.")
        if !removals.isEmpty { message += "\n" + String(localized: "Unselected books will be removed from Apple Watch. The iPhone originals are kept.") }
        return message
    }

    private func startSync(allowCellular: Bool) {
        guard !isRunning else { return }
        let books = candidates
        let removed = removals
        isRunning = true
        relay.watchTransferError = nil
        startedAt = SystemClock().now
        syncTask = Task { @MainActor in
            defer { isRunning = false; syncTask = nil }
            for id in removed {
                await relay.removeBookFromWatch(bookID: id)
                guard !Task.isCancelled else { return }
            }
            for book in books {
                let result = await relay.transferBookToWatch(book, allowCellularOverride: allowCellular)
                guard !Task.isCancelled else { return }
                switch result {
                case .started: break
                case .needsCellularConfirmation:
                    confirmCellular = true
                    return
                case .failed(let message):
                    operationError = message
                    return
                }
            }
            if relay.isPaired && relay.isWatchAppInstalled { await relay.syncWatchNow() }
        }
    }

    private func pause() {
        guard !isPausing else { return }
        isPausing = true
        syncTask?.cancel()
        relay.cancelWatchPreparation()
        // Include preparation waiting on a phone download, not just handed-off files.
        let ids = relay.watchSelectedBookIDs.union(relay.watchPreparationByBook.keys).filter { id in
            relay.watchPreparationByBook[id] != nil || {
                switch relay.watchDesiredStates[WatchBookID(id.uuidString)] {
                case .queued, .preparing, .transferring, .installing: return true
                default: return false
                }
            }()
        }
        Task {
            defer { isPausing = false }
            for id in ids { await relay.pauseBookTransferToWatch(bookID: id) }
        }
    }
}

struct SyncStatusSummary: View {
    @EnvironmentObject private var relay: PhoneAudioRelay
    var isRequesting = false
    var showsDetails = true

    private var isWorking: Bool { isRequesting }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if relay.syncPresentation(isRequesting: isWorking).showsProgress { ProgressView() }
                Text(relay.syncStatusText(isRequesting: isWorking))
            }
            .accessibilityIdentifier("sync.status")
            if showsDetails, let status = relay.watchSyncStatus, relay.isPreparingWatchAudio {
                Text(status).voxFont(.caption2)
            }
            if showsDetails, let error = relay.watchSyncError { Text(error).voxFont(.caption2).foregroundStyle(Palette.danger) }
            if showsDetails, let error = relay.watchTransferError { Text(error).voxFont(.caption2).foregroundStyle(Palette.danger) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SyncDiagnosticsView: View {
    @EnvironmentObject private var relay: PhoneAudioRelay
    var body: some View {
        List {
            DisclosureGroup("Connection") {
                Text(relay.connectionStatusText)
                if let date = relay.lastWatchReportDate { LabeledContent("Last watch report", value: date.formatted()) }
                if let date = relay.lastCatalogSentDate { LabeledContent("Last iPhone catalog sent", value: date.formatted()) }
                Text("Sent does not mean installed. Apple Watch confirms each completed book.")
            }
            DisclosureGroup("Apple Watch") { WatchSyncDiagnosticsCard() }
        }
        .navigationTitle("Sync Details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sync.diagnostics")
    }
}

// Internal (not private): BookPageOverflowSheet.swift reuses watchState/
// watchBookStatus for the single-book quick action, instead of duplicating
// this state-to-text mapping.
extension PhoneAudioRelay {
    func watchState(for id: UUID) -> WatchTransferState {
        WatchDisplayStateResolver.resolve(desiredState: watchDesiredStates[WatchBookID(id.uuidString)], storageState: watchStorageInfo(for: id)?.state)
    }

    func syncPresentation(isRequesting: Bool = false) -> WatchSyncPresentation {
        let states = watchSelectedBookIDs.map { watchState(for: $0) }
        return WatchSyncPresentation(isReachable: isReachable,
            isPreparing: isTransferringToWatch || isPreparingWatchAudio, isRequesting: isRequesting,
            selectedCount: states.count,
            pendingCount: states.filter { [.queued, .waitingForPhone].contains($0) }.count,
            installedCount: states.filter { $0 == .available }.count,
            transferringCount: states.filter { if case .transferring = $0 { return true }; return false }.count,
            failedCount: states.filter { if case .stalled = $0 { return true }; return $0 == .failed }.count,
            pausedCount: states.filter { $0 == .paused }.count)
    }

    func syncStatusText(isRequesting: Bool = false) -> String {
        if watchSyncError != nil, !isRequesting, !isTransferringToWatch { return String(localized: "Sync needs attention") }
        if case .downloadingOnPhone(let fraction)? = watchPreparationByBook.values.first {
            return String(localized: "Downloading \(Int(fraction * 100))%")
        }
        if !isPaired { return isRequesting ? String(localized: "Syncing…") : String(localized: "Ready to sync") }
        if !isWatchAppInstalled { return connectionStatusText }
        switch syncPresentation(isRequesting: isRequesting).phase {
        case .ready: return String(localized: "Ready to sync")
        case .preparing: return String(localized: "Preparing audio")
        case .requesting: return String(localized: "Syncing…")
        case .failed: return String(localized: "Sync needs attention")
        case .paused: return String(localized: "Download paused.")
        case .disconnected: return String(localized: "Waiting for Apple Watch")
        case .transferring: return String(localized: "Transferring audio to Apple Watch")
        case .waiting: return String(localized: "Waiting for Apple Watch to confirm books")
        case .installed: return String(localized: "Selected books are on Apple Watch")
        }
    }

    func watchBookStatus(for id: UUID) -> String {
        if let preparation = watchPreparationByBook[id] {
            switch preparation {
            case .preparingAudio: return watchSyncStatus ?? String(localized: "Preparing audio")
            case .downloadingOnPhone(let fraction): return String(localized: "Downloading \(Int(fraction * 100))%")
            }
        }
        if case .failed(let message)? = watchDesiredStates[WatchBookID(id.uuidString)] { return message }
        if watchDesiredStates[WatchBookID(id.uuidString)] == .removing { return String(localized: "Removal sent to Apple Watch.") }
        switch watchState(for: id) {
        case .available: return String(localized: "On My Watch")
        case .notAvailable: return String(localized: "Not on this watch")
        case .paused: return String(localized: "Download paused.")
        case .stalled: return String(localized: "Sync needs attention")
        case .failed: return String(localized: "Sync needs attention")
        case .transferring(let fraction): return String(localized: "Sending \(Int(fraction * 100))%")
        case .queued, .waitingForPhone: return String(localized: "Waiting for Apple Watch")
        }
    }
}

struct ReadByAIWatchInfoButton: View {
    @State private var showingExplanation = false
    var body: some View {
        Button { showingExplanation = true } label: {
            Image(systemName: "info.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Apple Watch")
        .accessibilityIdentifier("watch.readByAI.info")
        .alert("Apple Watch", isPresented: $showingExplanation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Read by AI books play on iPhone. Apple Watch downloads are available for books with recorded audio.")
        }
    }
}
