import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var catalogStore: CatalogStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var showingImporter = false
    @State private var archiveURL = ""

    var body: some View {
        VoxglassScreen(title: "My Books") {
            VStack(alignment: .leading, spacing: 18) {
                addArchiveURLPanel
                importPanel
                bookList
            }
            .padding(.top, 12)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: UTType.voxglassImportTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { await handleImportResult(result) }
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                libraryStore.importError = nil
                catalogStore.catalogError = nil
            }
        } message: {
            Text(libraryStore.importError ?? catalogStore.catalogError ?? "")
        }
        .task {
            await libraryStore.refresh()
            await libraryStore.refreshRecentlyPlayed()
        }
    }

    private var addArchiveURLPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Add from Internet Archive")
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 28)

                TextField("", text: $archiveURL, prompt: Text("archive.org book, list, or collection URL").foregroundStyle(Palette.ink3))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .foregroundStyle(Palette.ink)
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
                .foregroundStyle(Palette.brass)
                .accessibilityLabel("Add archive URL")
                .disabled(archiveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalogStore.isResolvingURL)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 14)

            if !catalogStore.results.isEmpty {
                Text("\(catalogStore.results.count) items found — tap to add to your library")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                ForEach(catalogStore.results) { result in
                    Button {
                        Task { await playResult(result) }
                    } label: {
                        InternetArchiveResultRow(result: result, isPlaying: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var importPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.brass)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Add Local Audio")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("MP3, M4A, M4B, and folders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            Button {
                showingImporter = true
            } label: {
                if libraryStore.isImporting {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.brass)
            .accessibilityLabel("Import local audio")
        }
        .padding(14)
        .glassSurface(cornerRadius: 14)
    }

    @ViewBuilder
    private var bookList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "My Audiobooks")

            if libraryStore.books.isEmpty {
                EmptyStatePanel(
                    title: "No Audiobooks Yet",
                    message: "Search LibriVox or add an Internet Archive URL to build your shelf. Everything you play is cached here automatically.",
                    systemImage: "books.vertical"
                )
            } else {
                ForEach(libraryStore.books) { book in
                    NavigationLink {
                        BookDetailView(book: book, showingNowPlaying: $showingNowPlaying)
                    } label: {
                        CompactBookRowView(
                            book: book,
                            sourceTitle: libraryStore.source(for: book.book)?.title
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            libraryStore.importError != nil || catalogStore.catalogError != nil
        } set: { isPresented in
            if !isPresented {
                libraryStore.importError = nil
                catalogStore.catalogError = nil
            }
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

    private func playResult(_ result: InternetArchiveSearchResult) async {
        if let imported = await catalogStore.importResult(result, into: libraryStore) {
            await playback.play(imported)
            showingNowPlaying = true
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            let imported = await libraryStore.importLocalAudio(from: urls)
            if let first = imported.first {
                await playback.play(first)
                showingNowPlaying = true
            }
        case .failure(let error):
            libraryStore.importError = error.localizedDescription
        }
    }
}
