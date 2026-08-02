import SwiftUI
import VoxglassCore

@main
struct StudioApp: App {
    @State private var environment = StudioEnvironment(licenseProvider: StoreKitLicenseProvider())

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $environment.navigationPath) {
                ProjectLibraryView()
                    .navigationDestination(for: StudioRoute.self) { route in
                        switch route {
                        case .library:
                            ProjectLibraryView()
                        case .newProject:
                            NewProjectView()
                        case .sourceImport:
                            SourceImportView()
                        case .importAudio:
                            ImportAudioView(model: ImportAudioModel(
                                project: environment.currentProject ?? AudiobookProject(
                                    id: UUID(),
                                    metadata: BookMetadata(title: "Untitled", author: "", narrator: "")
                                ),
                                store: environment.store,
                                assets: environment.assetStoreForCurrentProject()
                            ))
                        case .dashboard:
                            if let project = environment.currentProject {
                                ProjectDashboardView(model: ProjectDashboardModel(
                                    project: project,
                                    store: environment.store
                                ))
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .record:
                            PlaceholderView(route: route)
                        case .review:
                            if let project = environment.currentProject {
                                let assets = environment.assetStoreForCurrentProject()
                                ReviewQueueView(model: ReviewQueueModel(
                                    project: project,
                                    store: environment.store,
                                    assets: assets,
                                    player: AVSegmentPlayer(assets: assets)
                                ))
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .metadata:
                            if let project = environment.currentProject {
                                let assets = environment.assetStoreForCurrentProject()
                                MetadataRightsView(
                                    model: MetadataRightsModel(project: project, store: environment.store, assets: assets)
                                ) { updated in
                                    environment.updateProject(updated)
                                }
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .validate:
                            if let project = environment.currentProject {
                                let assets = environment.assetStoreForCurrentProject()
                                ValidationReportView(model: ValidationModel(
                                    project: project,
                                    store: environment.store,
                                    assets: assets,
                                    target: project.profile.intendedDestination
                                ))
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .assembly:
                            if let project = environment.currentProject {
                                let assets = environment.assetStoreForCurrentProject()
                                ChapterAssemblyView(model: AssemblyModel(
                                    project: project,
                                    store: environment.store,
                                    assets: assets,
                                    renderer: AVChapterRenderer(assets: assets),
                                    player: AVSegmentPlayer(assets: assets)
                                ))
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .export:
                            if let project = environment.currentProject {
                                let assets = environment.assetStoreForCurrentProject()
                                let exportsRoot = environment.currentPackageRoot?
                                    .appendingPathComponent("Exports", isDirectory: true)
                                ExportWizardView(model: ExportModel(
                                    project: project,
                                    assets: assets,
                                    renderer: AVChapterRenderer(assets: assets),
                                    transcoder: VoxTranscoder(),
                                    gate: environment.license,
                                    outputRoot: exportsRoot
                                ))
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .devicePreview:
                            if let project = environment.currentProject {
                                let assets = environment.assetStoreForCurrentProject()
                                DevicePreviewView(model: DevicePreviewModel(
                                    coordinator: environment.projection,
                                    project: project,
                                    store: environment.store,
                                    assets: assets,
                                    flagsQueueIDs: project.allParagraphs
                                        .filter { $0.reviewState == .flagged }
                                        .map(\.id)
                                ))
                            } else {
                                PlaceholderView(route: route)
                            }
                        case .settings:
                            SettingsView(model: environment.settings)
                        case .takeCompare:
                            if let project = environment.currentProject {
                                let paragraphsWithTakes = project.allParagraphs.filter { !$0.takes.isEmpty }
                                if let paragraph = paragraphsWithTakes.first {
                                    TakeComparisonView(model: TakeComparisonModel(
                                        paragraphID: paragraph.id,
                                        takes: paragraph.takes,
                                        store: environment.store,
                                        assets: environment.assetStoreForCurrentProject(),
                                        selectedTakeID: paragraph.selectedTakeID
                                    ))
                                } else {
                                    PlaceholderView(route: route)
                                }
                            } else {
                                PlaceholderView(route: route)
                            }
                        }
                    }
            }
            .environment(environment)
            .onChange(of: environment.recoveryPackageRoot) {
                environment.presentRecoveryIfNeeded()
            }
            .sheet(isPresented: Binding(
                get: { environment.showAutosaveRecovery },
                set: { if !$0 { environment.dismissRecovery() } }
            )) {
                if let model = environment.recoveryModel {
                    AutosaveRecoverySheet(model: model) {
                        environment.dismissRecovery()
                    }
                }
            }
        }
        .commands {
            StudioCommands()
        }
    }
}

struct PlaceholderView: View {
    let route: StudioRoute

    var body: some View {
        Text("\(String(describing: route))")
            .frame(minWidth: 400, minHeight: 300)
    }
}
