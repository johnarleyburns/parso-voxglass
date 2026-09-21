import SwiftUI

@main
struct VoxglassMacApp: App {
    @StateObject private var services = MacAppServices()
    @StateObject private var commandRouter = MacCommandRouter()

    var body: some Scene {
        WindowGroup("Voxglass") {
            VoxglassMacRootView(services: services, router: commandRouter)
                .environmentObject(services.libraryStore)
                .environmentObject(services.catalogStore)
                .environmentObject(services.offlineDownloads)
                .environment(services.playback)
                .preferredColorScheme(.dark)
                .task { await services.bootstrap() }
        }
        .commands { VoxglassMacCommands(router: commandRouter) }

        Settings {
            MacSettingsView(services: services)
                .frame(minWidth: 620, minHeight: 480)
                .preferredColorScheme(.dark)
        }
    }
}
