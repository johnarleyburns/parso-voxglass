import CarPlay
import UIKit
import VoxglassCore

/// The CarPlay scene. On a cold launch straight into CarPlay (phone locked, app
/// never foregrounded) this is the first code that runs, so it bootstraps the
/// shared services itself behind a loading placeholder before building the
/// browse tree (docs/CARPLAY_DESIGN.md §6.3).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var carController: CarPlayInterfaceController?

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
            carController = CarPlayInterfaceController(
                interfaceController: interfaceController,
                services: .shared
            )
            carController?.start()
        }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        carController?.stop()
        carController = nil
    }
}
