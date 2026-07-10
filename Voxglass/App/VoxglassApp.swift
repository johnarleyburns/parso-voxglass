import SwiftUI

@main
struct VoxglassApp: App {
    @StateObject private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.libraryStore)
                .environmentObject(services.catalogStore)
                .environmentObject(services.playbackCoordinator)
                .preferredColorScheme(.dark)
                .task {
                    await services.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    services.playbackCoordinator.handleScenePhase(newPhase)
                }
        }
    }
}
