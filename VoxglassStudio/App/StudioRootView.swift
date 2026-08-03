import SwiftUI
import UniformTypeIdentifiers
import VoxglassCore

/// The shell root (§18.1.1). `reference == nil` renders the library window
/// (split view); a non-nil reference renders that project's window (title bar +
/// segmented tab bar).
struct StudioRootView: View {
    let reference: ProjectReference?

    @Environment(StudioEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let reference {
                if let project = env.currentProject, project.id == reference.projectID {
                    ProjectWindowView(project: project)
                } else {
                    ProgressView("Opening project…")
                        .frame(minWidth: 400, minHeight: 300)
                        .task {
                            await open(reference: reference)
                        }
                }
            } else {
                LibrarySplitView()
            }
        }
        .onAppear {
            env.onRequestProjectWindow = { ref in
                openWindow(value: ref)
            }
            env.onDismissProjectWindow = {
                // Closing the project window returns the user to the library
                // window, which stays open underneath.
                if let ref = env.currentProject.flatMap({ ProjectReference(projectID: $0.id) }) {
                    dismissProjectWindow(value: ref)
                }
            }
        }
    }

    private func open(reference: ProjectReference) async {
        if let url = reference.resolveURL() {
            await env.library.openProject(at: url)
        }
    }

    @Environment(\.dismissWindow) private var dismissWindow
    private func dismissProjectWindow(value: ProjectReference) {
        dismissWindow(value: value)
    }
}

// MARK: - Library window

/// The library window: sidebar sections from mockup `01` over the project
/// grid, plus Narration Needs below.
struct LibrarySplitView: View {
    @Environment(StudioEnvironment.self) private var env
    @State private var selectedSection: StudioSection = .library

    var body: some View {
        NavigationSplitView {
            librarySidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch selectedSection {
            case .library:
                ProjectLibraryView()
            case .settings:
                SettingsView(model: env.settings)
            case .needsReview, .readyToExport, .archive:
                FilteredProjectsView(section: selectedSection)
            }
        }
        .sheet(isPresented: sheetBinding) {
            sheetContent
        }
        .background(Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .studioNewProject)) { _ in
                env.presentedSheet = .newProject
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioOpenProject)) { _ in
                showOpenPanel = true
            }
        )
        .fileImporter(isPresented: $showOpenPanel,
                       allowedContentTypes: [UTType(filenameExtension: "voxproject") ?? .folder]) { result in
            if case .success(let url) = result {
                Task { await env.library.openProject(at: url) }
            }
        }
    }

    @State private var showOpenPanel = false

    private var librarySidebar: some View {
        List(selection: $selectedSection) {
            Section("Library") {
                Label("All Projects", systemImage: "tray.full")
                    .tag(StudioSection.library)
                Label("Needs Review", systemImage: "flag")
                    .tag(StudioSection.needsReview)
                Label("Ready to Export", systemImage: "shippingbox")
                    .tag(StudioSection.readyToExport)
                Label("Archive", systemImage: "archivebox")
                    .tag(StudioSection.archive)
                Label("Settings", systemImage: "gearshape")
                    .tag(StudioSection.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Voxglass")
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: {
                switch env.presentedSheet {
                case .newProject, .needsBrowser: return true
                default: return false
                }
            },
            set: { if !$0 { env.presentedSheet = nil } }
        )
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch env.presentedSheet {
        case .newProject:
            NewProjectView()
        case .needsBrowser:
            NeedsBrowserView(start: { env.beginNarration($0) })
        default:
            EmptyView()
        }
    }
}

// MARK: - Project window

/// A project window: book title bar, segmented tab bar, tab content, and the
/// project-scoped sheets (import, export, take comparison, device preview).
struct ProjectWindowView: View {
    let project: AudiobookProject

    @Environment(StudioEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            tabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(commandHandlers)
        .alert("Verify Project", isPresented: Binding(
            get: { env.settings.integritySummary != nil || env.settings.message != nil },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) {
                env.settings.dismissVerification()
            }
        } message: {
            Text(env.settings.integritySummary ?? env.settings.message ?? "")
        }
        .sheet(isPresented: sheetBinding) {
            sheetContent
        }
    }

    private var titleBar: some View {
        HStack {
            Text(project.metadata.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                env.closeProject()
            } label: {
                Label("Library", systemImage: "folder")
            }
            .help("Return to the library")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Menu-command wiring (§18.1.1)

    private var commandHandlers: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .studioImportSource)) { _ in
                env.presentedSheet = .sourceImport
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioRecord)) { _ in
                env.selectedTab = .record
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioNextParagraph)) { _ in
                NotificationCenter.default.post(name: .studioRecordParagraphAdvance, object: 1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioPreviousParagraph)) { _ in
                NotificationCenter.default.post(name: .studioRecordParagraphAdvance, object: -1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioReviewQueue)) { _ in
                env.selectedTab = .review
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioExport)) { _ in
                env.presentedSheet = .export
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioVerifyProject)) { _ in
                Task {
                    await env.settings.verifyProject(
                        assets: env.assetStoreForCurrentProject(),
                        project: env.currentProject
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .studioRebuildCaches)) { _ in
                env.settings.setMessage("Render caches rebuild automatically as you export.")
            }
    }

    private var tabBar: some View {
        Picker("Section", selection: Binding(
            get: { env.selectedTab },
            set: { env.selectedTab = $0 }
        )) {
            ForEach(ProjectTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch env.selectedTab {
        case .dashboard:
            ProjectDashboardView(model: ProjectDashboardModel(project: project, store: env.store))
        case .script:
            ScriptEditorView(model: ScriptEditorModel(store: env.store, project: project))
        case .record:
            RecordTabView(project: project)
        case .review:
            ReviewQueueView(model: ReviewQueueModel(
                project: project,
                store: env.store,
                assets: env.assetStoreForCurrentProject(),
                player: env.player
            ))
        case .assemble:
            ChapterAssemblyView(model: AssemblyModel(
                project: project,
                store: env.store,
                assets: env.assetStoreForCurrentProject(),
                renderer: AVChapterRenderer(assets: env.assetStoreForCurrentProject()),
                player: env.player
            ))
        case .metadata:
            MetadataRightsView(model: MetadataRightsModel(
                project: project,
                store: env.store,
                assets: env.assetStoreForCurrentProject()
            )) { updated in
                env.updateProject(updated)
            }
        case .validateExport:
            ValidationReportView(model: ValidationModel(
                project: project,
                store: env.store,
                assets: env.assetStoreForCurrentProject(),
                target: project.profile.intendedDestination
            ))
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: {
                switch env.presentedSheet {
                case .sourceImport, .importAudio, .export, .takeCompare, .devicePreview: return true
                default: return false
                }
            },
            set: { if !$0 { env.presentedSheet = nil } }
        )
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch env.presentedSheet {
        case .sourceImport:
            SourceImportView()
        case .importAudio:
            ImportAudioView(model: ImportAudioModel(
                project: env.currentProject ?? project,
                store: env.store,
                assets: env.assetStoreForCurrentProject()
            ))
        case .export:
            let exportsRoot = env.currentPackageRoot?
                .appendingPathComponent("Exports", isDirectory: true)
            ExportWizardView(model: ExportModel(
                project: project,
                assets: env.assetStoreForCurrentProject(),
                renderer: AVChapterRenderer(assets: env.assetStoreForCurrentProject()),
                transcoder: env.transcoder,
                gate: env.license,
                outputRoot: exportsRoot
            ))
        case .takeCompare:
            let paragraphsWithTakes = project.allParagraphs.filter { !$0.takes.isEmpty }
            if let paragraph = paragraphsWithTakes.first {
                TakeComparisonView(model: TakeComparisonModel(
                    paragraphID: paragraph.id,
                    takes: paragraph.takes,
                    store: env.store,
                    assets: env.assetStoreForCurrentProject(),
                    selectedTakeID: paragraph.selectedTakeID
                ))
            } else {
                Text("No takes yet")
                    .frame(minWidth: 400, minHeight: 300)
            }
        case .devicePreview:
            DevicePreviewView(model: DevicePreviewModel(
                coordinator: env.projection,
                project: project,
                store: env.store,
                assets: env.assetStoreForCurrentProject(),
                flagsQueueIDs: project.allParagraphs
                    .filter { $0.reviewState == .flagged }
                    .map(\.id)
            ))
        default:
            EmptyView()
        }
    }
}

// MARK: - Filtered library sections

/// Sidebar sections over the recents list (spec §18.1.2). Computed from the
/// cached recents; a full project database is only opened when the user picks
/// a row.
struct FilteredProjectsView: View {
    let section: StudioSection

    @Environment(StudioEnvironment.self) private var env
    @State private var showOpenPanel = false

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

            Button(action: { showOpenPanel = true }) {
                Label("Open Project…", systemImage: "folder")
            }
            .padding()
            .accessibilityIdentifier("library.openPackage")
        }
        .navigationTitle(sectionTitle)
        .fileImporter(isPresented: $showOpenPanel,
                       allowedContentTypes: [UTType(filenameExtension: "voxproject") ?? .folder]) { result in
            if case .success(let url) = result {
                Task { await env.library.openProject(at: url) }
            }
        }
    }

    private var sectionTitle: String {
        switch section {
        case .library: "All Projects"
        case .needsReview: "Needs Review"
        case .readyToExport: "Ready to Export"
        case .archive: "Archive"
        case .settings: "Settings"
        }
    }
}
