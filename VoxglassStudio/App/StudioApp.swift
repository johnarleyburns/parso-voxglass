import SwiftUI
import VoxglassCore

@main
struct StudioApp: App {
    @State private var environment: StudioEnvironment
    @State private var discoveryModel = StudioDiscoveryModel()

    init() {
        // Composition root (§4.3). `-uiTestSeed` wins (and implies
        // `-useTemporaryStore` semantics); otherwise `-useTemporaryStore`
        // avoids touching real user data; otherwise restore the last project.
        let args = ProcessInfo.processInfo.arguments
        let env: StudioEnvironment
        if let seed = UITestSeed(arguments: args) {
            env = .test(seed: seed)
        } else if args.contains("-useTemporaryStore") {
            env = try! .live(
                package: .temporary(),
                transcoder: VoxTranscoder(),
                encoderAvailability: { VoxTranscoder().availableEncoders.map(\.rawValue).sorted() }
            )
        } else {
            env = try! .live(
                package: .lastOpenedOrNone(),
                transcoder: VoxTranscoder(),
                encoderAvailability: { VoxTranscoder().availableEncoders.map(\.rawValue).sorted() }
            )
        }
        _environment = State(initialValue: env)
    }

    var body: some Scene {
        WindowGroup(for: ProjectReference.self) { $reference in
            StudioRootView(reference: reference)
                .environment(environment)
                .environment(discoveryModel)
                .task {
                    await environment.library.seedIfNeeded()
                    if let url = environment.initialPackageURL {
                        await environment.library.openProject(at: url)
                        environment.initialPackageURL = nil
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            StudioCommands()
        }

        Settings {
            SettingsView(model: environment.settings)
                .environment(environment)
        }
    }
}
