import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var playingIdentifier: String?

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
                }
            }

            if catalogStore.isSearching {
                ProgressView()
                    .frame(width: 20, height: 20)
            }
        }
        .scaledFont(size: 15)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: 20)
    }

    @ViewBuilder
    private var archiveResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            if normalizedQuery.isEmpty {
                EmptyStatePanel(
                    title: "Search LibriVox",
                    message: "Find public-domain audiobooks by title, author, or subject. Tap any result to start listening — it caches as it plays.",
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
                ForEach(catalogStore.results) { result in
                    Button {
                        Task { await playResult(result) }
                    } label: {
                        InternetArchiveResultRow(
                            result: result,
                            isPlaying: playingIdentifier == result.identifier
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(playingIdentifier == result.identifier)
                }
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

    private func playResult(_ result: InternetArchiveSearchResult) async {
        playingIdentifier = result.identifier
        defer { playingIdentifier = nil }

        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
        }
    }
}

struct InternetArchiveResultRow: View {
    var result: InternetArchiveSearchResult
    var isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            BookArtworkView(title: result.title, size: 56, coverURL: result.coverURL, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.82)
                Text(result.authorLine)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                Text(detailLine)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPlaying {
                ProgressView()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(Palette.ink3.opacity(0.7))
            }
        }
        .frame(minHeight: 72)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Play \(result.title)")
    }

    var detailLine: String {
        var parts: [String] = []
        if let date = IADateFormatting.humanReadable(result.date) {
            parts.append(date)
        }
        if let downloads = result.downloads {
            parts.append("\(downloads) downloads")
        }
        if parts.isEmpty {
            parts.append(result.sourceKind.displayName)
        }
        return parts.joined(separator: " - ")
    }
}
