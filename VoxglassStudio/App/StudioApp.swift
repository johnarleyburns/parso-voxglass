import SwiftUI
import VoxglassCore

@main
struct StudioApp: App {
    @State private var environment = StudioEnvironment()

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
                            DashboardStubView()
                        case .record, .review, .assembly, .export, .settings:
                            PlaceholderView(route: route)
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

struct DashboardStubView: View {
    @Environment(StudioEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 16) {
            Text(env.currentProject?.metadata.title ?? "No Project")
                .font(.title)
            Text("Dashboard")
                .font(.headline)
            Text("\(env.currentProject?.recordedCount ?? 0) of \(env.currentProject?.totalCount ?? 0) paragraphs recorded")
            Button("Record Next") {
                env.navigate(to: .record)
            }
            .accessibilityIdentifier("dashboard.recordNext")
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct PlaceholderView: View {
    let route: StudioRoute

    var body: some View {
        Text("\(String(describing: route))")
            .frame(minWidth: 400, minHeight: 300)
    }
}
