import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var selectedCategory: LibriVoxBrowseCategory?
    @State private var importingIdentifier: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VoxglassScreen(title: "Browse") {
            VStack(alignment: .leading, spacing: 18) {
                subjectGrid
                sourceEntryPoints
                localSourceSections
                catalogResults
            }
            .padding(.top, 12)
        }
        .alert("Browse Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                catalogStore.catalogError = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(catalogStore.catalogError ?? libraryStore.importError ?? "")
        }
    }

    private var subjectGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Genres & Subjects")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(LibriVoxBrowseGroup.all) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VoxglassTheme.secondaryInk)
                            .textCase(.uppercase)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(group.categories) { category in
                                Button {
                                    search(category)
                                } label: {
                                    BrowseTile(
                                        title: category.title,
                                        systemImage: category.systemImage,
                                        isSelected: selectedCategory == category
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sourceEntryPoints: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Sources")
            VStack(spacing: 0) {
                Button {
                    search(.popular)
                } label: {
                    DisclosureListRow(
                        icon: "waveform",
                        title: "LibriVox",
                        detail: "Popular public-domain audiobooks",
                        count: nil
                    )
                }
                .buttonStyle(.plain)

                Button {
                    search(.generalFiction)
                } label: {
                    DisclosureListRow(
                        icon: "building.columns.fill",
                        title: "Internet Archive",
                        detail: "Curated IA subject search",
                        count: nil
                    )
                }
                .buttonStyle(.plain)
            }
            .glassPanel()
        }
    }

    @ViewBuilder
    private var localSourceSections: some View {
        if !libraryStore.sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "On This Device")
                ForEach(libraryStore.sources) { source in
                    let books = libraryStore.books.filter { $0.book.sourceID == source.id }
                    if !books.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(VoxglassTheme.ink)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(books.prefix(8)) { book in
                                        NavigationLink {
                                            BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                                        } label: {
                                            HorizontalBookCard(book: book)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var catalogResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: selectedCategory?.title ?? "Browse Results")

            if catalogStore.isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching LibriVox")
                        .font(.subheadline)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassPanel()
            } else if catalogStore.results.isEmpty {
                EmptyStatePanel(
                    title: "Choose a Subject",
                    message: "Semantic LibriVox subjects search Internet Archive public-domain audiobooks.",
                    systemImage: "square.grid.2x2"
                )
            } else {
                ForEach(catalogStore.results) { result in
                    InternetArchiveResultRow(
                        result: result,
                        isImporting: importingIdentifier == result.identifier
                    ) {
                        Task { await importResult(result) }
                    }
                }
            }
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

    private func importResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
        }
    }

    private func search(_ category: LibriVoxBrowseCategory) {
        selectedCategory = category
        Task { await catalogStore.searchAdvanced(category.archiveQuery) }
    }
}

private struct BrowseTile: View {
    var title: String
    var systemImage: String
    var isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(isSelected ? .white : VoxglassTheme.accent)
                .frame(width: 42, height: 42)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : VoxglassTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? VoxglassTheme.ink : VoxglassTheme.paperRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VoxglassTheme.softLine, lineWidth: 1)
        }
    }
}
