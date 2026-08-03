import SwiftUI
import VoxglassCore
import UniformTypeIdentifiers

struct ProjectLibraryView: View {
    @Environment(StudioEnvironment.self) private var env
    @State private var showOpenPanel = false
    @State private var showNewProject = false

    var body: some View {
        VStack(spacing: 0) {
            List(env.recents.recentURLs, id: \.absoluteString) { url in
                HStack {
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await env.library.openProject(at: url) }
                }
            }

            HStack(spacing: 12) {
                Button(action: { showNewProject = true }) {
                    Label("New Project", systemImage: "plus.square")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library.newAudiobook")

                Button(action: { showOpenPanel = true }) {
                    Label("Open...", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.openPackage")
            }
            .padding()

            Divider()

            ScrollView {
                NarrationSectionView(
                    browse: { env.push(to: .needsBrowser) },
                    start: { env.beginNarration($0) }
                )
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Library")
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            Task { await env.library.seedIfNeeded() }
        }
        .fileImporter(isPresented: $showOpenPanel,
                       allowedContentTypes: [UTType(filenameExtension: "voxproject") ?? .folder]) { result in
            if case .success(let url) = result {
                Task { await env.library.openProject(at: url) }
            }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectView()
        }
    }
}
