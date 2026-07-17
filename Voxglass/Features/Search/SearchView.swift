import SwiftUI
import VoxglassCore

struct SearchView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VoxglassScreen(title: "Search") {
            VStack(alignment: .leading, spacing: 18) {
                searchPanel
                archiveResults
            }
            .padding(.top, 12)
        }
        .alert("Search Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
        .onChange(of: catalogStore.results) { _, results in
            ArtworkService.shared.prefetch(urls: results.map(\.coverURL), limit: 18)
        }
    }

    private var searchPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.ink3)

            TextField("", text: $catalogStore.query, prompt: Text("Search LibriVox audiobooks").foregroundStyle(Palette.ink3))
                .foregroundStyle(Palette.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit {
                    Task { await runSearch() }
                }

            if !catalogStore.query.isEmpty {
                Button {
                    catalogStore.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.ink3)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Clear search")
            }

            if catalogStore.isSearching {
                ProgressView()
                    .frame(width: 20, height: 20)
            }
        }
        .scaledFont(size: 15)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: 20)
    }

    @ViewBuilder
    private var archiveResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            if normalizedQuery.isEmpty {
                EmptyStatePanel(
                    title: "Search LibriVox",
                    message: "Find public-domain audiobooks by title, author, or subject.",
                    systemImage: "waveform"
                )
            } else if catalogStore.isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching LibriVox")
                        .scaledFont(size: 14)
                        .foregroundStyle(Palette.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .glassSurface(cornerRadius: 14)
            } else if catalogStore.results.isEmpty {
                EmptyStatePanel(
                    title: "No Results",
                    message: "Try a different author, title, or subject. LibriVox has thousands of public-domain recordings.",
                    systemImage: "magnifyingglass"
                )
            } else {
                let results = catalogStore.results
                VStack(spacing: 0) {
                    ForEach(results.indices, id: \.self) { index in
                        let result = results[index]
                        NavigationLink {
                            CatalogBookDetailView(
                                result: result,
                                showingNowPlaying: $showingNowPlaying
                            ) { result, libraryStore in
                                await catalogStore.importResult(result, into: libraryStore)
                            }
                        } label: {
                            InternetArchiveResultRow(
                                result: result,
                                style: .grouped
                            )
                        }
                        .buttonStyle(.plain)

                        if index < results.count - 1 {
                            VoxglassListDivider()
                        }
                    }
                }
                .glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))
            }
        }
    }

    private var normalizedQuery: String {
        catalogStore.query.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func runSearch() async {
        guard !normalizedQuery.isEmpty else { return }
        await catalogStore.searchLibriVox(normalizedQuery)
    }
}

struct InternetArchiveResultRow: View {
    var result: InternetArchiveSearchResult
    var style: BookListRowStyle = .card

    var body: some View {
        BookListRow(
            title: result.title,
            subtitle: result.authorLine,
            tertiary: result.narratorLine,
            metadata: nil,
            coverURL: result.coverURL,
            accessory: .navigation,
            style: style,
            accessibilityLabel: "\(result.title) by \(result.authorLine)"
        )
    }
}

struct CatalogBookDetailView: View {
    var result: InternetArchiveSearchResult
    @Binding var showingNowPlaying: Bool
    var importResult: (InternetArchiveSearchResult, LibraryStore) async -> BookWithChapters?
    var onPlaybackStarted: () -> Void = {}

    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var isImporting = false

    var body: some View {
        ZStack {
            VoxglassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailHeader
                    summarySection
                    discoverySection
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ArtworkService.shared.prefetch(urls: [result.coverURL], limit: 1)
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    BookArtworkView(title: result.title, size: 112, coverURL: result.coverURL)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

                    ProvenanceChip(sourceKind: result.sourceKind)
                        .padding(6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(result.title)
                        .scaledFont(size: 20, weight: .heavy)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(4)
                        .minimumScaleFactor(0.72)

                    Text(result.authorLine)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(2)

                    if let narratorLine = result.narratorLine {
                        Text(narratorLine)
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(Palette.brass)
                            .lineLimit(2)
                    }
                }
            }

            PrimaryActionButton(
                title: isImporting ? "Loading" : "Play",
                systemImage: isImporting ? "hourglass" : "play.fill"
            ) {
                guard !isImporting else { return }
                Task { await play() }
            }
            .disabled(isImporting)
            .opacity(isImporting ? 0.7 : 1)
        }
        .padding(16)
        .glassSurface(cornerRadius: 18)
    }

    private var summarySection: some View {
        VoxglassGroupedSection(title: "Summary") {
            Text(result.description?.isEmpty == false ? result.description! : "No summary is available for this audiobook yet.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        let items = discoveryItems
        if !items.isEmpty {
            VoxglassGroupedSection(title: "Discover More") {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    NavigationLink {
                        CatalogDiscoveryView(
                            title: item.destinationTitle,
                            archiveQuery: item.query,
                            showingNowPlaying: $showingNowPlaying
                        )
                    } label: {
                        DisclosureListRow(
                            icon: item.systemImage,
                            title: item.label,
                            detail: nil,
                            count: nil
                        )
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        VoxglassListDivider()
                    }
                }
            }
        }
    }

    private var discoveryItems: [CatalogDiscoveryItem] {
        var items: [CatalogDiscoveryItem] = []

        for author in result.creators.map(Self.cleanedName) {
            guard !author.isEmpty,
                  author.localizedCaseInsensitiveCompare("Unknown author") != .orderedSame,
                  author.localizedCaseInsensitiveCompare("Various") != .orderedSame else { continue }
            items.append(CatalogDiscoveryItem(
                label: "More by \(author)",
                systemImage: "person.fill",
                destinationTitle: author,
                query: Self.authorQuery(author)
            ))
        }

        for narrator in result.narrators.map(Self.cleanedName) where !narrator.isEmpty {
            items.append(CatalogDiscoveryItem(
                label: "More read by \(narrator)",
                systemImage: "mic.fill",
                destinationTitle: narrator,
                query: Self.narratorQuery(narrator)
            ))
        }

        if let genre = LibriVoxBrowseCategory.category(forSubjects: result.subjects) {
            items.append(CatalogDiscoveryItem(
                label: "More in \(genre.title)",
                systemImage: genre.systemImage,
                destinationTitle: genre.title,
                query: Self.genreQuery(genre)
            ))
        }

        return Array(items.prefix(8))
    }

    private func play() async {
        isImporting = true
        defer { isImporting = false }

        if let imported = await importResult(result, libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
            onPlaybackStarted()
        }
    }

    private static let discoveryScope = " AND \(LibriVoxCatalogScope.query)"

    private static func authorQuery(_ author: String) -> String {
        "creator:\"\(escapeQuotes(author))\"\(discoveryScope)"
    }

    private static func narratorQuery(_ narrator: String) -> String {
        let escaped = escapeQuotes(narrator)
        return "(creator:\"\(escaped)\" OR description:\"\(escaped)\")\(discoveryScope)"
    }

    private static func genreQuery(_ category: LibriVoxBrowseCategory) -> String {
        category.archiveQuery.contains("mediatype:")
            ? category.archiveQuery
            : category.archiveQuery + " AND mediatype:audio"
    }

    private static func cleanedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CatalogDiscoveryItem {
    var label: String
    var systemImage: String
    var destinationTitle: String
    var query: String
}
