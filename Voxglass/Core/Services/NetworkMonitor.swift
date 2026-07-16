import Combine
import Foundation
import Network

public final class NetworkMonitor: ObservableObject {
    public static let shared = NetworkMonitor()

    @Published public private(set) var isOnline = true
    @Published public private(set) var isWiFi = true
    @Published public private(set) var isCellular = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "guru.parso.voxglass.networkmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let cell = path.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                self?.isOnline = online
                self?.isWiFi = wifi
                self?.isCellular = cell
            }
        }
        monitor.start(queue: queue)
    }
}
