import Foundation
import VoxglassCore
#if canImport(ActivityKit)
// ActivityKit's SDK annotations lag its runtime-owned activity handles on the
// current toolchain; the controller is @MainActor and never shares a handle
// across actors, so this import is deliberately scoped to this boundary.
@preconcurrency import ActivityKit
#endif

@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<BookActivityAttributes>?
    private var pausedEndTask: Task<Void, Never>?
    #endif

    func update(_ content: LiveActivityContent?) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.liveActivity) == nil
                || UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.liveActivity) else {
            pausedEndTask?.cancel()
            if activity != nil {
                Task { @MainActor [weak self] in await self?.activity?.end(nil, dismissalPolicy: .immediate) }
                activity = nil
            }
            return
        }
        guard let content else {
            pausedEndTask?.cancel()
            Task { @MainActor [weak self] in await self?.activity?.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            return
        }
        // A paused session may update an existing activity, but it must not
        // create a new one when the app restores a paused book.
        if activity == nil && !content.isPlaying {
            return
        }
        if !content.isPlaying {
            if pausedEndTask == nil {
                pausedEndTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15 * 60))
                    guard !Task.isCancelled else { return }
                    await self?.endCurrentActivity()
                }
            }
        } else {
            pausedEndTask?.cancel()
            pausedEndTask = nil
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
            skipBack: configuredSkipBack,
            skipForward: configuredSkipForward
        )
        let activityContent = ActivityContent(state: state, staleDate: LiveActivityUpdatePolicy.staleDate(for: content))
        if activity == nil {
            let existing = Activity<BookActivityAttributes>.activities
            activity = existing.first(where: { $0.attributes.bookID == content.bookID })
            for stale in existing where stale.id != activity?.id {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }
        }
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

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var configuredSkipBack: Int {
        let value = UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval)
        return value > 0 ? value : 15
    }

    private var configuredSkipForward: Int {
        let value = UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval)
        return value > 0 ? value : 30
    }

    private func endCurrentActivity() async {
        await activity?.end(nil, dismissalPolicy: .default)
        activity = nil
        pausedEndTask = nil
    }
    #endif
}
