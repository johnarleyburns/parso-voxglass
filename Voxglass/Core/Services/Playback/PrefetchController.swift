import Foundation

actor PrefetchController {
    static let shared = PrefetchController()

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let defaults = UserDefaults.standard
    private let depthKey = "voxglass.prefetchDepth"
    private let wifiOnlyKey = "voxglass.prefetchWifiOnly"

    var depth: Int {
        if ProFeature.isEnabled(.prefetchDepth) {
            let configured = defaults.integer(forKey: depthKey)
            return configured > 0 ? configured : 3
        }
        return 1
    }

    var wifiOnly: Bool {
        ProFeature.isEnabled(.prefetchDepth) && defaults.bool(forKey: wifiOnlyKey)
    }

    func setDepth(_ newDepth: Int) {
        guard ProFeature.isEnabled(.prefetchDepth) else { return }
        defaults.set(newDepth, forKey: depthKey)
    }

    func setWifiOnly(_ enabled: Bool) {
        guard ProFeature.isEnabled(.prefetchDepth) else { return }
        defaults.set(enabled, forKey: wifiOnlyKey)
    }

    func prefetch(chapters: [Chapter], startingFrom index: Int) async {
        let count = min(depth, chapters.count - index - 1) // exclude current
        guard count > 0 else { return }

        if wifiOnly && !NetworkMonitor.shared.isWiFi { return }

        let budget = await CacheManager.shared.currentBudget
        let currentBytes = await CacheManager.shared.currentCacheBytes()
        let remaining = budget - currentBytes
        guard remaining > 10_485_760 else { return } // at least 10MB headroom

        for offset in 1...count {
            let chapter = chapters[index + offset]
            guard let opusURL = chapter.opusURL else { continue }

            let key = opusURL.absoluteString
            if activeTasks[key] != nil { continue }

            let task = Task<Void, Never> {
                _ = await OpusCacheService.shared.fetchAndRemux(opusURL: opusURL, chapterID: chapter.id.uuidString)
            }
            activeTasks[key] = task
        }
    }

    func cancelAll() {
        for (key, task) in activeTasks {
            task.cancel()
            if let url = URL(string: key) {
                Task { await OpusCacheService.shared.cancelFetch(for: url) }
            }
        }
        activeTasks.removeAll()
    }

    func cancel(for opusURL: URL) {
        let key = opusURL.absoluteString
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
        Task { await OpusCacheService.shared.cancelFetch(for: opusURL) }
    }
}
