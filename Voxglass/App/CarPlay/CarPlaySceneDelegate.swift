import CarPlay
import OSLog
import UIKit
import VoxglassCore

/// The CarPlay scene. On a cold launch straight into CarPlay (phone locked, app
/// never foregrounded) this is the first code that runs, so it bootstraps the
/// shared services itself behind a loading placeholder before building the
/// browse tree (docs/CARPLAY_DESIGN.md §6.3).
///
/// When productions are projected to the phone (S5), the root becomes the
/// production tab bar (Continue / Productions / Review) driven by
/// `CarPlayReviewController`; otherwise the consumer browse tree is shown.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private let logger = Logger(subsystem: "guru.parso.voxglass", category: "CarPlay")
    private var carController: CarPlayInterfaceController?
    private var productionController: CarPlayReviewController?
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var connectionState = CarPlayConnectionStateMachine()

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        connectionTask?.cancel()
        let generation = connectionState.connect()
        connectionGeneration = generation
        logger.info("sceneDidConnect generation=\(generation, privacy: .public)")
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.connectionState.owns(generation) else { return }
            let placeholder = CPListTemplate(
                title: "Voxglass",
                sections: [CPListSection(items: [CPListItem(text: "Loading your library…", detailText: nil)])]
            )
            interfaceController.setRootTemplate(placeholder, animated: false, completion: nil)
            self.logger.info("placeholderInstalled generation=\(generation, privacy: .public)")

            await AppServices.shared.bootstrapOnce()
            guard !Task.isCancelled, self.connectionState.owns(generation) else { return }
            self.logger.info("servicesBootstrapped generation=\(generation, privacy: .public)")

            let productionProvider = LocalCarPlayProductionProvider.shared
            if !productionProvider.productionSummaries().isEmpty {
                let carController = CarPlayInterfaceController(
                    interfaceController: interfaceController,
                    services: .shared
                )
                self.carController = carController

                let controller = CarPlayReviewController(
                    dataProvider: productionProvider,
                    eventSink: PhoneProductionEventSink(),
                    player: ProductionCarPlayPlayer(),
                    interfaceController: interfaceController,
                    continueProvider: { [weak carController] in
                        carController?.continueSections() ?? []
                    }
                )
                self.productionController = controller
                let root = controller.makeRootTemplate()
                guard !Task.isCancelled,
                      self.connectionState.finishConnect(generation: generation, mode: .production),
                      self.connectionState.owns(generation) else { return }
                self.logger.info("productionRootBuilt generation=\(generation, privacy: .public)")
                interfaceController.setRootTemplate(root, animated: false, completion: nil)
            } else {
                self.carController = CarPlayInterfaceController(
                    interfaceController: interfaceController,
                    services: .shared
                )
                guard self.connectionState.finishConnect(generation: generation, mode: .consumer) else { return }
                self.carController?.start()
                self.logger.info("consumerRootBuilt generation=\(generation, privacy: .public)")
            }
        }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        connectionState.disconnect()
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        self.logger.info("sceneDidDisconnect generation=\(self.connectionGeneration, privacy: .public)")
        self.productionController?.stop()
        self.productionController = nil
        self.carController?.stop()
        self.carController = nil
    }
}
