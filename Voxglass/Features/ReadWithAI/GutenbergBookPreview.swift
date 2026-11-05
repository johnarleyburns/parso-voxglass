import SwiftUI
import VoxglassCore

struct GutenbergBookPreview: View {
    let book: GutenbergBook
    @Binding var showingNowPlaying: Bool
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var isPreparing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(.largeTitle)).foregroundStyle(Palette.brass)
                Text(book.title).voxFont(.title, weight: .bold).foregroundStyle(Palette.ink)
                Text(book.authorLine).voxFont(.body).foregroundStyle(Palette.ink2)
                Label("Read with AI", systemImage: "waveform")
                    .voxFont(.caption, weight: .bold).foregroundStyle(Palette.brass)
                Text("Voxglass will download the EPUB once, keep its text on this iPhone, and read it aloud with your selected system voice.")
                    .voxFont(.body).foregroundStyle(Palette.ink2)
                Spacer()
                Button { Task { await addAndPreview() } } label: {
                    HStack { if isPreparing { ProgressView() }; Text(isPreparing ? "Preparing…" : "Preview with Read with AI") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Palette.brass).disabled(isPreparing || book.epubURL == nil)
            }
            .padding(24)
            .navigationTitle("Book Preview")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("Couldn't Prepare Book", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func addAndPreview() async {
        guard let epubURL = book.epubURL else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let request = try await ReadWithAIImporter.downloadAndPrepare(
                epubURL: epubURL, sourceTitle: "Project Gutenberg", sourceURL: book.detailsURL,
                stableIdentifier: "gutenberg-\(book.id)", title: book.title, authors: book.authors.map(\.name),
                isPending: true
            )
            guard let imported = await libraryStore.importReadWithAI(request) else { throw URLError(.cannotCreateFile) }
            await playback.present(imported)
            showingNowPlaying = true
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
