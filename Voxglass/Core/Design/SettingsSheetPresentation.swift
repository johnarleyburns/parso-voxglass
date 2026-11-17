import Foundation

/// Semantic contract for the Listen gear → Settings sheet. iOS owns dismissal
/// (drag / standard gesture); the app injects no Close button.
struct SettingsSheetPresentation: Equatable, Sendable {
    let title: String
    let showsAppDismissButton: Bool
    let showsDragIndicator: Bool

    static let listenEntry = SettingsSheetPresentation(
        title: "Settings",
        showsAppDismissButton: false,
        showsDragIndicator: true
    )
}

/// Presentation truth, independent of transport and UI. Sending metadata does
/// not mean audio is installed; only per-book watch acknowledgements do.
public struct WatchSyncPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case ready, preparing, requesting, failed, paused, disconnected, transferring, waiting, installed
    }
    public let phase: Phase
    public var showsProgress: Bool { phase == .preparing || phase == .requesting }

    public init(isReachable: Bool, isPreparing: Bool = false, isRequesting: Bool = false,
                selectedCount: Int = 0, pendingCount: Int = 0, installedCount: Int = 0, transferringCount: Int = 0,
                failedCount: Int = 0, pausedCount: Int = 0) {
        if isPreparing { phase = .preparing }
        else if isRequesting { phase = .requesting }
        else if failedCount > 0 { phase = .failed }
        else if pausedCount > 0 { phase = .paused }
        else if !isReachable { phase = .disconnected }
        else if transferringCount > 0 { phase = .transferring }
        else if pendingCount > 0 || selectedCount > installedCount { phase = .waiting }
        else if selectedCount > 0 { phase = .installed }
        else { phase = .ready }
    }
}

/// Merge fresh Watch inventory without losing choices staged by the person.
public enum WatchSyncSelection {
    public static func reconcile(selected: Set<UUID>, baseline: Set<UUID>, latest: Set<UUID>) -> Set<UUID> {
        latest.union(selected.subtracting(baseline)).subtracting(baseline.subtracting(selected))
    }
}

/// Text narration remains an iPhone capability. Reject mixed/text chapters as
/// well as known Read by AI sources, before any watch download side effects.
public enum WatchDownloadEligibility {
    public static func allowsTransfer(isReadByAI: Bool, chapterExtensions: [String]) -> Bool {
        !isReadByAI && !chapterExtensions.contains { $0.lowercased() == "voxtext" }
    }
}
