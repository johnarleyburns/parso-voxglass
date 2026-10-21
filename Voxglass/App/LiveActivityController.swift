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
    private var generation: UInt64 = 0
    #endif

    /// True while a Voxglass Live Activity owns the lock screen, so the system
    /// Now Playing card would only duplicate it.
    var isShowingActivity: Bool {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return activity != nil
        #else
        return false
        #endif
    }

    func update(_ content: LiveActivityContent?) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        // Every call supersedes delayed work from earlier calls.
        generation &+= 1
        let currentGeneration = generation
        let enabled = UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.liveActivity) == nil
            || UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.liveActivity)
        // Reconcile against ActivityKit itself so activities restored after a relaunch are seen.
        let existing = Activity<BookActivityAttributes>.activities
        let plan = LiveActivityLifecyclePolicy.plan(
            existing: existing.map { .init(id: $0.id, bookID: $0.attributes.bookID) },
            content: content, enabled: enabled)
        for stale in existing where plan.end.contains(stale.id) {
            Task { @MainActor in await stale.end(nil, dismissalPolicy: .immediate) }
        }
        activity = plan.reuse.flatMap { id in existing.first(where: { $0.id == id }) }
        guard enabled, let content else {
            pausedEndTask?.cancel()
            pausedEndTask = nil
            activity = nil
            return
        }
        if activity == nil && !plan.create {
            pausedEndTask?.cancel()
            pausedEndTask = nil
            return
        }
        if !plan.end.isEmpty || plan.create {
            pausedEndTask?.cancel()
            pausedEndTask = nil
        }
        if !content.isPlaying {
            if pausedEndTask == nil {
                pausedEndTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15 * 60))
                    guard !Task.isCancelled, self?.activity?.attributes.bookID == content.bookID else { return }
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
            rate: LiveActivityUpdatePolicy.safeRate(content.rate),
            progressStart: interval?.lowerBound,
            progressEnd: interval?.upperBound,
            chapterFraction: LiveActivityUpdatePolicy.chapterFraction(elapsed: LiveActivityUpdatePolicy.safeElapsed(content.chapterElapsed),
                                                                      duration: content.chapterDuration),
            bookRemaining: LiveActivityUpdatePolicy.bookRemaining(content.bookRemaining),
            sleepUntil: { if case let .until(date) = content.sleep { return date }; return nil }(),
            sleepEndOfChapter: content.sleep == .endOfChapter,
            skipBack: configuredSkipBack,
            skipForward: configuredSkipForward
        )
        let activityContent = ActivityContent(state: state, staleDate: LiveActivityUpdatePolicy.staleDate(for: content))
        if let activity {
            Task { @MainActor [weak self] in
                guard self?.generation == currentGeneration else { return }
                await activity.update(activityContent)
            }
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
