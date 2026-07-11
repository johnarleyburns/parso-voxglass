import SwiftUI

struct SettingsView: View {
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VoxglassScreen(title: "More") {
            VStack(alignment: .leading, spacing: 16) {
                settingsGroup("Library") {
                    NavigationLink {
                        SourcesView(showingNowPlaying: $showingNowPlaying)
                    } label: {
                        DisclosureListRow(
                            icon: "externaldrive.fill",
                            title: "Sources",
                            detail: "Local files, LibriVox, and archive URLs",
                            count: nil
                        )
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("Playback") {
                    MoreInfoRow(icon: "speaker.wave.2.fill", title: "Background Audio", detail: "Enabled")
                    MoreInfoRow(icon: "airplayaudio", title: "AirPlay", detail: "System controls")
                    MoreInfoRow(icon: "timer", title: "Sleep Timer", detail: "Coming later", isEnabled: false)
                    MoreInfoRow(icon: "speedometer", title: "Playback Speed", detail: "1x", isEnabled: false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Downloads & Cache")
                    CacheSettingsCard()
                }

                settingsGroup("Tips & Support") {
                    MoreInfoRow(icon: "heart.fill", title: "Tip Jar", detail: "StoreKit later", isEnabled: false)
                    MoreInfoRow(icon: "questionmark.circle.fill", title: "Support", detail: "Not configured", isEnabled: false)
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
                    MoreInfoRow(icon: "doc.text.fill", title: "License", detail: "GPLv3")
                    MoreInfoRow(icon: "number", title: "Version", detail: "1.1")
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

private struct CacheSettingsCard: View {
    @State private var cacheUsed: Int64 = 0
    @State private var cacheLimit: Int64 = StreamCacheStore.defaultLimit
    @State private var cachedCount: Int = 0
    @State private var showClearConfirm = false
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 12) {
            usageCard
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(ByteFormatting.string(cacheUsed)) of \(ByteFormatting.string(cacheLimit))")
                    .font(.system(size: 11))
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
                    .font(.system(size: 10.5))
                Spacer()
                Text("oldest evicted first")
                    .font(.system(size: 10.5))
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
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .white : Palette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                selected ? Palette.brassDeep : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
    }

    private var clearCard: some View {
        Button {
            showClearConfirm = true
        } label: {
            HStack {
                Text("Clear Cache")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                Spacer()
                Text(ByteFormatting.string(cacheUsed))
                    .font(.system(size: 13))
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
                    sourceList
                    placeholders
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
        .task {
            await libraryStore.refresh()
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

    @ViewBuilder
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Connected Sources")
            if libraryStore.sources.isEmpty {
                EmptyStatePanel(
                    title: "No Sources Yet",
                    message: "Imported local files and archive items will create source records.",
                    systemImage: "externaldrive"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(libraryStore.sources) { source in
                        SourceRow(source: source, bookCount: bookCount(for: source))
                    }
                }
                .glassPanel()
            }
        }
    }

    private var placeholders: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Available Later")
            VStack(spacing: 0) {
                DisclosureListRow(
                    icon: "folder.fill",
                    title: "Local Files",
                    detail: "Use Library import for now",
                    count: nil,
                    isEnabled: false
                )
                DisclosureListRow(
                    icon: "icloud.fill",
                    title: "iCloud Drive",
                    detail: "Folder sync is not implemented",
                    count: nil,
                    isEnabled: false
                )
            }
            .glassPanel()
        }
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

    private func bookCount(for source: Source) -> Int {
        libraryStore.books.filter { $0.book.sourceID == source.id }.count
    }

    private func addArchiveURL() async {
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            archiveURL = ""
            await playback.play(imported)
            showingNowPlaying = true
        }
        await libraryStore.refresh()
    }
}

private struct SourceRow: View {
    var source: Source
    var bookCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VoxglassTheme.accent)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.paperRaised)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(bookCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(VoxglassTheme.secondaryInk)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background {
                    Capsule()
                        .fill(VoxglassTheme.paperRaised)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var icon: String {
        switch source.kind {
        case .librivox:
            return "waveform"
        case .internetArchive, .internetArchiveURL:
            return "building.columns.fill"
        case .localFiles:
            return "folder.fill"
        }
    }

    private var detail: String {
        if let url = source.url {
            return url.host() ?? source.kind.displayName
        }
        return source.kind.displayName
    }
}

private struct MoreInfoRow: View {
    var icon: String
    var title: String
    var detail: String
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(isEnabled ? VoxglassTheme.accent : VoxglassTheme.secondaryInk.opacity(0.55))
                .frame(width: 28, height: 28)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isEnabled ? VoxglassTheme.ink : VoxglassTheme.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(VoxglassTheme.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(isEnabled ? 1 : 0.62)
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
                    Link(destination: privacyURL) {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(Palette.brass)
                            Text("Read the Privacy Policy")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .bold))
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
                .font(.system(size: 26, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(Palette.ink)
            Text("Public-domain audiobooks with a private, local-first shelf.")
                .font(.system(size: 14))
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
                .font(.system(size: 13.5))
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
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(cornerRadius: 14)
        }
    }
}
