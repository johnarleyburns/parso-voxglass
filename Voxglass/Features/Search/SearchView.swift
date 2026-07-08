import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var query = ""
    @State private var archiveURL = ""
    @State private var importingIdentifier: String?

    var body: some View {
        VoxglassScreen(title: "Search") {
            VStack(alignment: .leading, spacing: 18) {
                searchPanel
                archiveURLPanel
                localResults
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
    }

    private var searchPanel: some View {
        HStack(spacing: 10) {
            TextField("Title or author", text: $query)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit {
                    Task { await catalogStore.searchLibriVox(query) }
                }

            Button {
                Task { await catalogStore.searchLibriVox(query) }
            } label: {
                if catalogStore.isSearching {
                    ProgressView()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoxglassTheme.accent)
            .accessibilityLabel("Search LibriVox")
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isSearching)
        }
    }

    private var archiveURLPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.headline)
                .foregroundStyle(VoxglassTheme.accent)
                .frame(width: 28)

            TextField("archive.org URL", text: $archiveURL)
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
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoxglassTheme.accent)
            .accessibilityLabel("Add archive URL")
            .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
        }
        .padding(12)
        .glassPanel()
    }

    @ViewBuilder
    private var localResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On This Device")
                .font(.headline)
                .foregroundStyle(VoxglassTheme.ink)

            if results.isEmpty {
                ContentUnavailableView("No Local Results", systemImage: "books.vertical")
                    .padding()
                    .glassPanel()
            } else {
                ForEach(results) { book in
                    BookRowView(
                        book: book,
                        isCurrent: playback.currentSession?.book.id == book.book.id
                    ) {
                        Task { await playback.play(book) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var archiveResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LibriVox")
                .font(.headline)
                .foregroundStyle(VoxglassTheme.ink)

            if catalogStore.isSearching {
                HStack {
                    ProgressView()
                    Text("Searching")
                        .font(.subheadline)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .glassPanel()
            } else if catalogStore.results.isEmpty {
                ContentUnavailableView("No Archive Results", systemImage: "globe")
                    .padding()
                    .glassPanel()
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

    private var results: [BookWithChapters] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return libraryStore.books }
        return libraryStore.books.filter { book in
            book.book.title.localizedCaseInsensitiveContains(trimmed)
                || book.book.authorLine.localizedCaseInsensitiveContains(trimmed)
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
        }
    }

    private func addArchiveURL() async {
        if let imported = await catalogStore.addArchiveURL(archiveURL, into: libraryStore) {
            archiveURL = ""
            await playback.play(imported)
        }
    }
}

private struct InternetArchiveResultRow: View {
    var result: InternetArchiveSearchResult
    var isImporting: Bool
    var importAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookArtworkView(title: result.title, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .foregroundStyle(VoxglassTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(result.authorLine)
                    .font(.subheadline)
                    .foregroundStyle(VoxglassTheme.secondaryInk)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(VoxglassTheme.secondaryInk.opacity(0.78))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: importAction) {
                if isImporting {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(VoxglassTheme.accent)
            .accessibilityLabel("Import \(result.title)")
        }
        .padding(12)
        .glassPanel()
    }

    private var detailLine: String {
        var parts: [String] = []
        if let date = result.date, !date.isEmpty {
            parts.append(date)
        }
        if let downloads = result.downloads {
            parts.append("\(downloads) downloads")
        }
        return parts.isEmpty ? result.identifier : parts.joined(separator: " · ")
    }
}
