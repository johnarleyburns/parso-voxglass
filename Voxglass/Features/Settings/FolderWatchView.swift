import SwiftUI
import UniformTypeIdentifiers
import VoxglassCore

struct FolderWatchView: View {
    @EnvironmentObject private var folderWatch: FolderWatchService
    @State private var showImporter = false

    var body: some View {
        ZStack {
            VoxglassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    addButton
                    if !folderWatch.folders.isEmpty {
                        watchedList
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Watched Folders")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Import Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) { folderWatch.errorMessage = nil }
        } message: {
            Text(folderWatch.errorMessage ?? "")
        }
    }

    private var intro: some View {
        Text("Voxglass watches the folders you add and imports the audio files inside them as local books. New files added to a watched folder appear automatically.")
            .scaledFont(size: 13)
            .foregroundStyle(Palette.ink2)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 14)
    }

    private var addButton: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill.badge.plus")
                    .foregroundStyle(Palette.brass)
                Text("Watch a Folder")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Palette.brass)
            }
            .padding(14)
            .glassSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("folderwatch.add")
    }

    private var watchedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Watching")
            VStack(spacing: 0) {
                ForEach(folderWatch.folders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Palette.brass)
                            .frame(width: 28)
                        Text(folder.name)
                            .scaledFont(size: 14)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            folderWatch.removeFolder(folder.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Palette.danger)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop watching \(folder.name)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .glassPanel()
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await folderWatch.addFolder(url) }
        case .failure(let error):
            folderWatch.errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            folderWatch.errorMessage != nil
        } set: { isPresented in
            if !isPresented { folderWatch.errorMessage = nil }
        }
    }
}
