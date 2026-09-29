import Foundation
import VoxglassCore
#if canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<BookActivityAttributes>?
    #endif

    func update(_ content: LiveActivityContent?) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.liveActivity) == nil
                || UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.liveActivity) else {
            if activity != nil {
                Task { @MainActor [weak self] in await self?.activity?.end(nil, dismissalPolicy: .immediate) }
                activity = nil
            }
            return
        }
        guard let content else {
            Task { @MainActor [weak self] in await self?.activity?.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            return
        }
        let interval = LiveActivityUpdatePolicy.progressInterval(for: content)
        let state = BookActivityAttributes.ContentState(
            chapterTitle: content.chapterTitle,
            chapterIndex: content.chapterIndex,
            chapterCount: content.chapterCount,
            isPlaying: content.isPlaying,
            rate: content.rate,
            progressStart: interval?.lowerBound,
            progressEnd: interval?.upperBound,
            chapterFraction: content.chapterDuration.map { content.chapterElapsed / max($0, 1) } ?? 0,
            bookRemaining: content.bookRemaining,
            sleepUntil: { if case let .until(date) = content.sleep { return date }; return nil }(),
            sleepEndOfChapter: content.sleep == .endOfChapter,
            skipBack: 15,
            skipForward: 30
        )
        let activityContent = ActivityContent(state: state, staleDate: LiveActivityUpdatePolicy.staleDate(for: content))
        if let activity {
            Task { @MainActor in await activity.update(activityContent) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: BookActivityAttributes(bookID: content.bookID, title: content.title, author: content.author, narrator: content.narrator), content: activityContent, pushType: nil)
            } catch {
                activity = nil
            }
        }
        #endif
    }
}
