import Foundation
import WidgetKit
import VoxglassCore

/// Writes the small, on-device playback handoff shared by widgets and controls.
enum WidgetSnapshotWriter {
    static let appGroup = "group.guru.parso.voxglass"
    static let enabledKey = "settings.widgetSnapshot"
    static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    private struct FileSink: SnapshotSink {
        func write(_ snapshot: NowPlayingSnapshot) async throws {
            guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        }

        func remove() async throws {
            guard let url = fileURL else { return }
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }

        private var fileURL: URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotWriter.appGroup)?
                .appendingPathComponent("now-playing.json")
        }
    }

    private struct Reloader: WidgetTimelineReloader {
        func reloadTimelines() async {
            await MainActor.run { WidgetCenter.shared.reloadTimelines(ofKind: "guru.parso.voxglass.continue") }
        }
    }

    private static let publisher = WidgetSnapshotPublisher(sink: FileSink(), reloader: Reloader())

    @MainActor
    static func write(playback: PlaybackCoordinator) {
        guard isEnabled else {
            remove()
            return
        }
        guard let session = playback.currentSession else {
            remove()
            return
        }
        let chapter = ChapterDisplayTitles.make(for: session.chapters)[session.chapter.id]
        let duration = max(session.duration ?? 0, 0)
        let fraction = duration > 0 ? session.position / duration : 0
        let paletteIndex = CoverPaletteIndex.index(title: session.book.title, author: session.book.authorLine)
        let palette = PlatePaletteValues.pairs[paletteIndex]
        func hex(_ rgb: PlateRGB) -> UInt32 {
            let red = UInt32(max(0, min(255, Int(rgb.red * 255))))
            let green = UInt32(max(0, min(255, Int(rgb.green * 255))))
            let blue = UInt32(max(0, min(255, Int(rgb.blue * 255))))
            return (red << 16) | (green << 8) | blue
        }
        let snapshot = NowPlayingSnapshot(
            bookID: session.book.id,
            title: session.book.title,
            author: session.book.authorLine,
            chapterEyebrow: chapter?.eyebrow,
            chapterTitle: chapter?.title ?? session.chapter.title,
            fraction: fraction,
            minutesLeftInChapter: Int(max(duration - session.position, 0) / 60),
            paletteIndex: paletteIndex,
            backgroundHex: hex(palette.background),
            accentHex: hex(palette.ink),
            bookRemaining: session.bookRemaining,
            isPlaying: session.isPlaying,
            updatedAt: .now
        )
        Task { await publisher.submit(snapshot) }
    }

    static func remove() {
        Task { await publisher.submit(nil) }
    }

    private static var isEnabled: Bool {
        guard let value = defaults.object(forKey: enabledKey) as? Bool else { return true }
        return value
    }
}
