import SwiftUI
import VoxglassCore

/// A lightweight, self-contained catalog list pushed from Now Playing's
/// discovery links ("More by this Author / Narrator / Genre"). It owns its own
/// `InternetArchiveClient` fetch and results state so it never clobbers the
/// shared `CatalogStore` that drives the Explore/Search tabs. Rows reuse
/// `InternetArchiveResultRow`; tapping a row imports metadata, presents the
/// unified book page, and leaves playback paused.
struct CatalogDiscoveryView: View {
    let title: String
    let archiveQuery: String
    @Binding var showingNowPlaying: Bool

    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CatalogDiscoveryStore()
    @State private var importingIdentifier: String?

    var body: some View {
        ZStack {
            VoxglassBackground()
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(query: archiveQuery) }
        .alert("Couldn't Load", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                store.error = nil
                libraryStore.importError = nil
            }
        } message: {
            Text(store.error ?? libraryStore.importError ?? "")
        }
        .onChange(of: store.results) { _, results in
            ArtworkService.shared.prefetch(urls: results.map(\.coverURL), limit: 18)
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if store.isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching LibriVox")
                            .scaledFont(size: 14)
                            .foregroundStyle(Palette.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .glassSurface(cornerRadius: 14)
                } else if store.results.isEmpty {
                    EmptyStatePanel(
                        title: "Nothing Found",
                        message: "No matching LibriVox recordings turned up. Try another author, narrator, or genre.",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    let results = store.results
                    VStack(spacing: 0) {
                        ForEach(results.indices, id: \.self) { index in
                            let result = results[index]
                            Button {
                                Task { await presentResult(result) }
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
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            store.error != nil || libraryStore.importError != nil
        } set: { isPresented in
            if !isPresented {
                store.error = nil
                libraryStore.importError = nil
            }
        }
    }

    private func presentResult(_ result: InternetArchiveSearchResult) async {
        importingIdentifier = result.identifier
        defer { importingIdentifier = nil }

        if let imported = await store.importResult(result, into: libraryStore) {
            await playback.present(imported)
            showingNowPlaying = true
            dismiss()
        }
    }
}

@MainActor
final class CatalogDiscoveryStore: ObservableObject {
    @Published private(set) var results: [InternetArchiveSearchResult] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let client: InternetArchiveCatalogClient
    private var hasLoaded = false

    init(client: InternetArchiveCatalogClient = InternetArchiveClient()) {
        self.client = client
    }

    func load(query: String) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await client.searchAdvanced(query: query, rows: 25)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func importResult(
        _ result: InternetArchiveSearchResult,
        into libraryStore: LibraryStore
    ) async -> BookWithChapters? {
        do {
            return try await CatalogResultImporter.importResult(result, into: libraryStore, using: client)
        } catch {
            self.error = CatalogResultImporter.importErrorMessage(for: result, underlying: error)
            return nil
        }
    }
}
