import Foundation
import VoxglassCore

/// Accessibility-identifier registry for the watch production screens (spec §22.1).
/// The UI smoke test keys off these exact strings.
public enum ProductionWatchAccessibility {
    public static func productionRow(_ slug: String) -> String { "watch.production.\(slug)" }
    public static let continueButton = "watch.continue"
    public static let reviewFlagged = "watch.reviewFlagged"
    public static let reviewQueues = "watch.reviewQueues"
    public static func queue(_ label: String) -> String { "watch.queue.\(label)" }
    public static let playerFlag = "watch.player.flag"
    public static let playerApprove = "watch.player.approve"
    public static let playerPickup = "watch.player.pickup"
    public static let playerPrevious = "watch.player.previous"
    public static let playerNext = "watch.player.next"
    public static let playerAutoNext = "watch.player.autoNext"
    public static let paragraphText = "watch.paragraphText"
    public static let confirmationApproved = "watch.confirmation.approved"
    public static let confirmationFlagged = "watch.confirmation.flagged"
    public static let confirmationPickup = "watch.confirmation.pickup"
    public static let playNext = "watch.playNext"
    public static let dictate = "watch.dictate"
    public static func dictationCategory(_ tag: ReviewTag) -> String { "watch.dictation.category.\(tag.rawValue)" }
    public static let dictationSave = "watch.dictation.save"
    public static let dictationRedictate = "watch.dictation.redictate"
    public static let syncStatus = "watch.sync.status"
    public static let offlineStart = "watch.offline.start"
    public static let offlineRemove = "watch.offline.remove"

    // Recording remote (mockup watch-04, §14.3).
    public static let recordingRemote = "watch.remote"
    public static let remoteContext = "watch.remote.context"
    public static let remoteLevel = "watch.remote.level"
    public static let remotePlayTake = "watch.remote.playTake"
    public static let remoteRecord = "watch.remote.record"
    public static let remoteRetake = "watch.remote.retake"
    public static let remoteFlag = "watch.remote.flag"
    public static let remoteAcceptAndNext = "watch.remote.acceptAndNext"
    public static let remoteIdle = "watch.remote.idle"
}
