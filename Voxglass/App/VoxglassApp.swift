import SwiftUI

@main
struct VoxglassApp: App {
    @StateObject private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferencesStore.Keys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.libraryStore)
                .environmentObject(services.catalogStore)
                .environmentObject(services.playbackCoordinator)
                .preferredColorScheme(AppAppearanceMode(rawValue: appearanceModeRaw)?.preferredColorScheme)
                .task {
                    await services.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    services.playbackCoordinator.handleScenePhase(newPhase)
                }
        }
    }
}
