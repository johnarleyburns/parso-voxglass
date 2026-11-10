import Foundation

/// Display-relevant identity of a `NowPlayingSnapshot`. Deliberately excludes the
/// volatile `updatedAt` so equivalent states can be suppressed.
public struct WidgetSnapshotFingerprint: Equatable, Sendable {
    let bookID: UUID
    let title: String
    let author: String
    let chapterEyebrow: String?
    let chapterTitle: String
    let progressBucket: Int
    let minutesLeftInChapter: Int
    let bookRemainingMinutes: Int?
    let paletteIndex: Int
    let backgroundHex: UInt32?
    let accentHex: UInt32?
    let isPlaying: Bool

    public init(_ snapshot: NowPlayingSnapshot) {
        bookID = snapshot.bookID
        title = snapshot.title
        author = snapshot.author
        chapterEyebrow = snapshot.chapterEyebrow
        chapterTitle = snapshot.chapterTitle
        progressBucket = Int((snapshot.fraction * 100).rounded(.down))
        minutesLeftInChapter = snapshot.minutesLeftInChapter
        bookRemainingMinutes = snapshot.bookRemaining.map { Int(max($0, 0) / 60) }
        paletteIndex = snapshot.paletteIndex
        backgroundHex = snapshot.backgroundHex
        accentHex = snapshot.accentHex
        isPlaying = snapshot.isPlaying
    }
}

/// Durable storage for the widget handoff file. Called only off MainActor.
public protocol SnapshotSink: Sendable {
    func write(_ snapshot: NowPlayingSnapshot) async throws
    func remove() async throws
}

public protocol WidgetTimelineReloader: Sendable {
    func reloadTimelines() async
}

/// Serial, coalescing publisher: only the newest submission is written, writes
/// never overlap, and a reload is requested only after a durable change.
public actor WidgetSnapshotPublisher {
    private enum Request { case write(NowPlayingSnapshot), remove }
    private enum Published: Equatable { case unknown, absent, snapshot(WidgetSnapshotFingerprint) }

    private let sink: any SnapshotSink
    private let reloader: any WidgetTimelineReloader
    private var pending: Request?
    private var draining = false
    private var published: Published = .unknown

    public init(sink: any SnapshotSink, reloader: any WidgetTimelineReloader) {
        self.sink = sink
        self.reloader = reloader
    }

    /// Submits the newest state (`nil` clears). Returns once this submission has
    /// been published, superseded, or suppressed.
    public func submit(_ snapshot: NowPlayingSnapshot?) async {
        pending = snapshot.map(Request.write) ?? .remove
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let request = pending {
            pending = nil
            await publish(request)
        }
    }

    private func publish(_ request: Request) async {
        switch request {
        case .write(let snapshot):
            let fingerprint = WidgetSnapshotFingerprint(snapshot)
            guard published != .snapshot(fingerprint) else { return }
            do { try await sink.write(snapshot) } catch { return }
            published = .snapshot(fingerprint)
        case .remove:
            guard published != .absent else { return }
            do { try await sink.remove() } catch { return }
            published = .absent
        }
        await reloader.reloadTimelines()
    }
}
