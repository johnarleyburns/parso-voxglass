import SwiftUI
import VoxglassCore
import UniformTypeIdentifiers

/// The library detail pane (spec §18.1.2, mockup `01-project-library`):
/// recents, New/Open, and Narration Needs. Presented inside `LibrarySplitView`;
/// the split view owns the open panel and the New Project sheet.
struct ProjectLibraryView: View {
    @Environment(StudioEnvironment.self) private var env

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
                Button(action: { env.presentedSheet = .newProject }) {
                    Label("New Project", systemImage: "plus.square")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library.newAudiobook")

                Button(action: { NotificationCenter.default.post(name: .studioOpenProject, object: nil) }) {
                    Label("Open...", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.openPackage")
            }
            .padding()

            Divider()

            ScrollView {
                NarrationSectionView(
                    browse: { env.presentedSheet = .needsBrowser },
                    start: { env.beginNarration($0) }
                )
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Library")
        .frame(minWidth: 500, minHeight: 400)
    }
}
