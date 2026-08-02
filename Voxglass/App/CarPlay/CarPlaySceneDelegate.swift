import CarPlay
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

    private var carController: CarPlayInterfaceController?
    private var productionController: CarPlayReviewController?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            let placeholder = CPListTemplate(
                title: "Voxglass",
                sections: [CPListSection(items: [CPListItem(text: "Loading your library…", detailText: nil)])]
            )
            interfaceController.setRootTemplate(placeholder, animated: false, completion: nil)

            await AppServices.shared.bootstrapOnce()

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
                productionController = controller
                interfaceController.setRootTemplate(controller.makeRootTemplate(), animated: false, completion: nil)
            } else {
                carController = CarPlayInterfaceController(
                    interfaceController: interfaceController,
                    services: .shared
                )
                carController?.start()
            }
        }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        productionController?.stop()
        productionController = nil
        carController?.stop()
        carController = nil
    }
}
