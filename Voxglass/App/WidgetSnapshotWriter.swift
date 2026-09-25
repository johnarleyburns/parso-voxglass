import Foundation
import WidgetKit
import VoxglassCore

/// Writes the small, on-device playback handoff shared by widgets and controls.
@MainActor
enum WidgetSnapshotWriter {
    static let appGroup = "group.guru.parso.voxglass"
    static let enabledKey = "settings.widgetSnapshot"
    static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    static func write(playback: PlaybackCoordinator) {
        guard isEnabled else {
            remove()
            return
        }
        guard let session = playback.currentSession,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            remove()
            return
        }
        let chapter = ChapterDisplayTitles.make(for: session.chapters)[session.chapter.id]
        let duration = max(session.duration ?? 0, 0)
        let fraction = duration > 0 ? session.position / duration : 0
        let snapshot = NowPlayingSnapshot(
            bookID: session.book.id,
            title: session.book.title,
            author: session.book.authorLine,
            chapterEyebrow: chapter?.eyebrow,
            chapterTitle: chapter?.title ?? session.chapter.title,
            fraction: fraction,
            minutesLeftInChapter: Int(max(duration - session.position, 0) / 60),
            paletteIndex: CoverPaletteIndex.index(title: session.book.title, author: session.book.authorLine)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = container.appendingPathComponent("now-playing.json")
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: "guru.parso.voxglass.continue")
    }

    static func remove() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent("now-playing.json"))
        WidgetCenter.shared.reloadTimelines(ofKind: "guru.parso.voxglass.continue")
    }

    private static var isEnabled: Bool {
        guard let value = defaults.object(forKey: enabledKey) as? Bool else { return true }
        return value
    }
}
