import SwiftUI
import VoxglassCore
import UniformTypeIdentifiers

/// The library detail pane (spec §18.1.2, mockup `01-project-library`):
/// recents with cached snapshots, New/Open, and Narration Needs. Presented
/// inside `LibrarySplitView`; the split view owns the open panel and the
/// New Project sheet.
struct ProjectLibraryView: View {
    @Environment(StudioEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            List(env.recents.projects) { project in
                ProjectRowView(project: project, isMissing: env.recents.resolvedURL(for: project) == nil) {
                    Task { await env.library.openProject(at: project.lastKnownURL) }
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
        .alert("Already Open", isPresented: Binding(
            get: { env.library.alreadyOpenProjectURL != nil },
            set: { if !$0 { env.library.dismissAlreadyOpen() } }
        )) {
            Button("OK", role: .cancel) { env.library.dismissAlreadyOpen() }
        } message: {
            Text("This project is already open. Its window has been brought to the front.")
        }
        .alert("Open Anyway?", isPresented: Binding(
            get: { env.library.staleLockPrompt != nil },
            set: { if !$0 { env.library.dismissStaleLockPrompt() } }
        )) {
            Button("Open Anyway") {
                Task { await env.library.confirmOpenAnyway() }
            }
            Button("Cancel", role: .cancel) { env.library.dismissStaleLockPrompt() }
        } message: {
            Text("""
            Another machine (or a previous session) still has this project open. \
            Opening it here while it is open elsewhere — for example in iCloud Drive — \
            can lose data. Open anyway?
            """)
        }
    }
}

/// One library row from the cached snapshot: title, path, recorded %, and the
/// "Missing — locate…" state (§8.1, mockup `01`).
struct ProjectRowView: View {
    let project: RecentProject
    let isMissing: Bool
    let onOpen: () -> Void

    var body: some View {
        ProjectRow(project: project, isMissing: isMissing)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
    }
}

struct ProjectRow: View {
    let project: RecentProject
    let isMissing: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
            info
            Spacer()
            if let snapshot = project.summarySnapshot, !isMissing {
                snapshotCounts(snapshot)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("library.project.\(project.id.uuidString)")
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(fillColor)
            Image(systemName: isMissing ? "questionmark.folder" : "book.closed")
                .font(.title2)
                .foregroundStyle(symbolColor)
        }
        .frame(width: 44, height: 44)
    }

    private var fillColor: Color {
        isMissing ? Color.gray.opacity(0.2) : Color.accentColor.opacity(0.18)
    }

    private var symbolColor: Color {
        isMissing ? Color.secondary : Color.accentColor
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .foregroundStyle(titleColor)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            if isMissing {
                Text("Missing — locate…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var titleColor: Color {
        isMissing ? Color.secondary : Color.primary
    }

    private func snapshotCounts(_ snapshot: ProjectSummary) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(snapshot.recordedCount) / \(snapshot.totalCount) recorded")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if snapshot.flaggedCount > 0 {
                Label("\(snapshot.flaggedCount)", systemImage: "flag")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var title: String {
        if let manifest = project.manifest, !manifest.title.isEmpty { return manifest.title }
        if let snapshot = project.summarySnapshot, !snapshot.title.isEmpty { return snapshot.title }
        return project.lastKnownURL.deletingPathExtension().lastPathComponent
    }

    private var subtitle: String {
        project.lastKnownURL.deletingLastPathComponent().path
    }
}
