import SwiftUI

private struct VoxglassZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var voxglassZoomNamespace: Namespace.ID? {
        get { self[VoxglassZoomNamespaceKey.self] }
        set { self[VoxglassZoomNamespaceKey.self] = newValue }
    }
}
