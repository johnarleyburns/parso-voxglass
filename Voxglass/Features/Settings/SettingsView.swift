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

                settingsGroup("Downloads & Cache") {
                    MoreInfoRow(icon: "arrow.down.circle.fill", title: "Offline Downloads", detail: "Coming later", isEnabled: false)
                    MoreInfoRow(icon: "internaldrive.fill", title: "Storage", detail: "On-device only")
                }

                settingsGroup("Appearance") {
                    MoreInfoRow(icon: "circle.lefthalf.filled", title: "Theme", detail: "System")
                    MoreInfoRow(icon: "accessibility", title: "Accessibility", detail: "System settings")
                }

                settingsGroup("Data & Privacy") {
                    MoreInfoRow(icon: "person.crop.circle.badge.xmark", title: "Accounts", detail: "None")
                    MoreInfoRow(icon: "chart.bar.xaxis", title: "Analytics", detail: "None")
                    MoreInfoRow(icon: "network.slash", title: "Network", detail: "Archive sources only")
                }

                settingsGroup("Tips & Support") {
                    MoreInfoRow(icon: "heart.fill", title: "Tip Jar", detail: "StoreKit later", isEnabled: false)
                    MoreInfoRow(icon: "questionmark.circle.fill", title: "Support", detail: "Not configured", isEnabled: false)
                }

                settingsGroup("About") {
                    MoreInfoRow(icon: "doc.text.fill", title: "License", detail: "GPLv3")
                    MoreInfoRow(icon: "info.circle.fill", title: "Version", detail: "0.1.0")
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
