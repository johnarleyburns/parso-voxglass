import Foundation

/// Navigation destinations within the Productions tab (watch mockups 01–10).
public enum ProductionRoute: Hashable {
    case home(UUID)
    case reviewQueues
    case review
    case paragraphText
    case dictation
    case syncStatus
    case offlineQueue
}
