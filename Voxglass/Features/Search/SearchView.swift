import SwiftUI
import VoxglassCore

struct SearchView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var importingIdentifier: String?
    @State private var searchScope: SearchScope = .all

    var body: some View {
        VoxglassScreen(title: "Search") {
            VStack(alignment: .leading, spacing: 18) {
                searchPanel
                scopePicker
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
        .onChange(of: searchScope) { _, _ in
            guard !normalizedQuery.isEmpty else { return }
            Task { await runSearch() }
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

    private var scopePicker: some View {
        Picker("Scope", selection: $searchScope) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .tint(Palette.brass)
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
                        Button {
                            Task { await playResult(result) }
                        } label: {
                            InternetArchiveResultRow(
                                result: result,
                                style: .grouped
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(importingIdentifier == result.identifier)

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

        switch searchScope {
        case .all:
            await catalogStore.searchLibriVox(normalizedQuery)
        case .title, .author, .narrator:
            await catalogStore.searchAdvanced(scopedQuery(normalizedQuery), sort: .popularity)
        }
    }

    private func scopedQuery(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "")
        let scopeClause = " AND \(LibriVoxCatalogScope.query)"

        switch searchScope {
        case .all:
            return text
        case .title:
            return "title:\"\(escaped)\"\(scopeClause)"
        case .author:
            return "creator:\"\(escaped)\"\(scopeClause)"
        case .narrator:
            return "(creator:\"\(escaped)\" OR description:\"\(escaped)\")\(scopeClause)"
        }
    }

    private func playResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
        }
    }
}

private enum SearchScope: CaseIterable, Identifiable, Hashable {
    case all
    case title
    case author
    case narrator

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .title: return "Title"
        case .author: return "Author"
        case .narrator: return "Narrator"
        }
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
