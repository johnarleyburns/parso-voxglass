import Combine
import Foundation
import Network

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true
    @Published private(set) var isWiFi = true
    @Published private(set) var isCellular = false

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
