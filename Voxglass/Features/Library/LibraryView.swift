import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool
    @State private var showingImporter = false

    var body: some View {
        VoxglassScreen(title: "Library") {
            VStack(alignment: .leading, spacing: 18) {
                importPanel
                booksList
            }
            .padding(.top, 12)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Import audio")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: UTType.voxglassImportTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { await handleImportResult(result) }
        }
        .alert("Import Failed", isPresented: importErrorBinding) {
            Button("OK", role: .cancel) {
                libraryStore.importError = nil
            }
        } message: {
            Text(libraryStore.importError ?? "")
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(VoxglassTheme.accent)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local Audio")
                        .font(.headline)
                        .foregroundStyle(VoxglassTheme.ink)
                    Text("MP3, M4A, M4B, and folders")
                        .font(.caption)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                }
                Spacer()
                Button {
                    showingImporter = true
                } label: {
                    if libraryStore.isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoxglassTheme.accent)
                .accessibilityLabel("Import local audio")
            }
        }
        .padding(14)
        .glassPanel()
    }

    @ViewBuilder
    private var booksList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audiobooks")
                .font(.headline)
                .foregroundStyle(VoxglassTheme.ink)
            if libraryStore.books.isEmpty {
                ContentUnavailableView("No Audiobooks", systemImage: "books.vertical")
                    .padding()
                    .glassPanel()
            } else {
                ForEach(libraryStore.books) { book in
                    BookRowView(
                        book: book,
                        isCurrent: playback.currentSession?.book.id == book.book.id
                    ) {
                        Task {
                            await playback.play(book)
                            showingNowPlaying = true
                        }
                    }
                }
            }
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding {
            libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                libraryStore.importError = nil
            }
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

