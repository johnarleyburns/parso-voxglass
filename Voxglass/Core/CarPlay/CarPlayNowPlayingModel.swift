import Foundation

/// Pure value for the four custom CarPlay Now Playing buttons: their visiblity,
/// label, and active state. Built by `CarPlayNowPlayingModel.config(...)` from
/// coordinator state so the configurator can re-apply buttons on every
/// `objectWillChange` with zero logic (docs/CARPLAY_DESIGN.md §5).
public struct CarPlayNowPlayingConfig: Equatable, Sendable {
    public var showsRateButton: Bool
    public var rateTitle: String
    public var sleepActive: Bool
    public var sleepTitle: String
    public var showsBookmark: Bool
    public var showsChapters: Bool
    public var isUpNextChapters: Bool

    public init(
        showsRateButton: Bool = false,
        rateTitle: String = "1\u{00D7}",
        sleepActive: Bool = false,
        sleepTitle: String = "Sleep",
        showsBookmark: Bool = false,
        showsChapters: Bool = false,
        isUpNextChapters: Bool = false
    ) {
        self.showsRateButton = showsRateButton
        self.rateTitle = rateTitle
        self.sleepActive = sleepActive
        self.sleepTitle = sleepTitle
        self.showsBookmark = showsBookmark
        self.showsChapters = showsChapters
        self.isUpNextChapters = isUpNextChapters
    }
}

public enum CarPlayNowPlayingModel {
    /// The sleep-timer options presented in the CarPlay action sheet, in
    /// canonical order: end-of-chapter leads, followed by the two durations
    /// that survive a driving context, then "Off" (docs/CARPLAY_DESIGN.md §5.2).
    public static let sleepOptions: [SleepTimer.Mode] = [
        .endOfChapter,
        .duration(1800),
        .duration(3600),
        .off
    ]

    public static func config(
        hasSession: Bool,
        chapterCount: Int,
        rate: Float,
        sleepMode: SleepTimer.Mode,
        sleepRemaining: TimeInterval?,
        hasBookmarkStore: Bool
    ) -> CarPlayNowPlayingConfig {
        let sleepActive = sleepMode != .off
        let sleepTitle: String
        if sleepActive {
            switch sleepMode {
            case .endOfChapter:
                sleepTitle = "Ch. end"
            case .duration(let seconds):
                let totalMinutes = Int(ceil(seconds / 60))
                sleepTitle = "\(totalMinutes) min"
            case .off:
                sleepTitle = "Sleep"
            }
        } else {
            sleepTitle = "Sleep"
        }
        return CarPlayNowPlayingConfig(
            showsRateButton: hasSession,
            rateTitle: PlaybackRate.label(rate),
            sleepActive: sleepActive,
            sleepTitle: sleepTitle,
            showsBookmark: hasSession && hasBookmarkStore,
            showsChapters: hasSession && chapterCount > 1,
            isUpNextChapters: hasSession && chapterCount > 1
        )
    }
}
