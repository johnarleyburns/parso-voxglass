import Foundation
import VoxglassWatchProtocol

/// On-watch book storage state machine. Pure model, host-testable.
public enum WatchTransferState: Equatable, Sendable, Codable {
    case notAvailable
    case queued
    case waitingForPhone
    case transferring(progress: Double)
    /// Non-terminal: progress has not moved for the stall threshold. Recoverable in place by a retry.
    case stalled(progress: Double)
    case paused
    case available
    case failed

    private enum CodingKeys: String, CodingKey {
        case kind
        case progress
    }

    private enum Kind: String, Codable {
        case notAvailable
        case queued
        case waitingForPhone
        case transferring
        case stalled
        case paused
        case available
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notAvailable:
            self = .notAvailable
        case .queued:
            self = .queued
        case .waitingForPhone:
            self = .waitingForPhone
        case .transferring:
            self = .transferring(progress: try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0)
        case .stalled:
            self = .stalled(progress: try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0)
        case .paused:
            self = .paused
        case .available:
            self = .available
        case .failed:
            self = .failed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notAvailable:
            try container.encode(Kind.notAvailable, forKey: .kind)
        case .queued:
            try container.encode(Kind.queued, forKey: .kind)
        case .waitingForPhone:
            try container.encode(Kind.waitingForPhone, forKey: .kind)
        case .transferring(let progress):
            try container.encode(Kind.transferring, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .stalled(let progress):
            try container.encode(Kind.stalled, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .paused:
            try container.encode(Kind.paused, forKey: .kind)
        case .available:
            try container.encode(Kind.available, forKey: .kind)
        case .failed:
            try container.encode(Kind.failed, forKey: .kind)
        }
    }

    public var progressFraction: Double? {
        switch self {
        case .transferring(let progress), .stalled(let progress): return progress
        default: return nil
        }
    }
}

/// Pure stall decision for phone→watch sends, separated from the polling task.
public enum WatchTransferStallPolicy {
    /// Zero progress for this long surfaces a recoverable `.stalled` state.
    public static let stallThreshold: TimeInterval = 120
    /// True last-resort give-up regardless of progress.
    public static let absoluteTimeout: TimeInterval = 24 * 60 * 60

    public static func isStalled(lastProgressAt: Date, now: Date, threshold: TimeInterval = stallThreshold) -> Bool {
        now.timeIntervalSince(lastProgressAt) > threshold
    }
}

/// Snapshot of a single chapter's watch-local storage state.
public struct WatchChapterStorageInfo: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let chapterIndex: Int
    public let state: WatchTransferState
    public let byteCount: Int64
    public let bytesExpected: Int64?

    public init(
        id: UUID,
        chapterIndex: Int,
        state: WatchTransferState,
        byteCount: Int64 = 0,
        bytesExpected: Int64? = nil
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.state = state
        self.byteCount = byteCount
        self.bytesExpected = bytesExpected
    }
}

/// Snapshot of a book's on-watch storage.
public struct WatchBookStorageInfo: Equatable, Sendable, Codable {
    public let state: WatchTransferState
    public let byteCount: Int64
    public let chapterCount: Int
    public let completeChapterCount: Int
    public let totalChapterCount: Int
    public let chapters: [WatchChapterStorageInfo]

    public init(
        state: WatchTransferState,
        byteCount: Int64,
        chapterCount: Int,
        completeChapterCount: Int,
        totalChapterCount: Int = 0,
        chapters: [WatchChapterStorageInfo] = []
    ) {
        self.state = state
        self.byteCount = byteCount
        self.chapterCount = chapterCount
        self.completeChapterCount = completeChapterCount
        self.totalChapterCount = totalChapterCount
        self.chapters = chapters
    }

    public static let notAvailable = WatchBookStorageInfo(
        state: .notAvailable,
        byteCount: 0,
        chapterCount: 0,
        completeChapterCount: 0,
        totalChapterCount: 0,
        chapters: []
    )

    public var phoneLibraryStatusText: String? {
        let total = max(totalChapterCount, chapters.count, completeChapterCount)
        switch state {
        case .available:
            return String(localized: "Downloaded on Watch", bundle: .module)
        case .transferring(let progress):
            return String(localized: "Downloading to Watch \(Int(progress * 100))%", bundle: .module)
        case .queued:
            guard completeChapterCount > 0 else { return String(localized: "Queued for Watch", bundle: .module) }
            return String(localized: "\(completeChapterCount)/\(max(total, 1)) chapters on Watch", bundle: .module)
        case .waitingForPhone:
            return String(localized: "Watch download waiting", bundle: .module)
        case .stalled:
            return String(localized: "Watch download stalled", bundle: .module)
        case .paused:
            return String(localized: "Watch download paused", bundle: .module)
        case .failed:
            return String(localized: "Watch download failed", bundle: .module)
        case .notAvailable:
            return nil
        }
    }
}

/// The watch's storage report sent back to the iPhone. This is deliberately
/// separate from the iPhone library snapshot: the watch owns watch-local files.
public struct WatchStorageSnapshot: Equatable, Sendable, Codable {
    public let books: [UUID: WatchBookStorageInfo]
    public let generatedAt: Date

    public init(
        books: [UUID: WatchBookStorageInfo],
        generatedAt: Date = Date()
    ) {
        self.books = books
        self.generatedAt = generatedAt
    }

    public func storageInfo(for bookID: UUID) -> WatchBookStorageInfo? {
        books[bookID]
    }
}

/// Watch storage policy constants. Pure, host-testable.
public enum WatchStoragePolicy {
    public static let maxBooks = 5
    public static let maxBytes: Int64 = 2_000_000_000 // 2 GB

    public static func remainingBookSlots(currentCount: Int) -> Int {
        max(0, maxBooks - currentCount)
    }

    public static func remainingBytes(currentBytes: Int64) -> Int64 {
        max(0, maxBytes - currentBytes)
    }
}

/// Timestamp-based eviction order: older last-played entries evicted first.
/// Never evicts the currently-playing book.
public enum WatchEvictionPolicy {
    public static func evictionOrder(
        books: [(id: UUID, lastPlayedAt: Date)],
        currentBookID: UUID?
    ) -> [UUID] {
        books
            .filter { $0.id != currentBookID }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }
            .map(\.id)
    }
}

/// Time formatting for watch display. Pure, host-testable.
public enum WatchTimeFormat {
    public static func duration(_ seconds: TimeInterval) -> String {
        DurationFormatting.hoursAndMinutes(seconds, minimumMinute: true)
    }

    public static func time(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    /// Formats bytes for display on small screens using Foundation's
    /// locale-aware byte-count formatting. Uses *binary* (1024-based)
    /// semantics, matching on-device storage; curated batch estimates in
    /// `CatalogStore.formattedBatchSize` intentionally use *decimal* units.
    public static func bytes(_ count: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let units: [UnitInformationStorage] = [.bytes, .kilobytes, .megabytes, .gigabytes]
        var value = Double(max(count, 0))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.locale = locale
        formatter.numberFormatter.maximumFractionDigits = index >= 2 ? 1 : 0
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter.string(from: Measurement(value: value, unit: units[index]))
    }
}

/// Adjacent-chapter navigation over a book's chapters in natural (play) order.
/// Pure, host-testable — used by the watch "next/previous chapter" controls.
public enum WatchChapterNavigation {
    public static func next(after chapterID: UUID, in chapters: [Chapter]) -> Chapter? {
        let sorted = chapters.naturallySorted()
        guard let idx = sorted.firstIndex(where: { $0.id == chapterID }),
              idx + 1 < sorted.count else { return nil }
        return sorted[idx + 1]
    }

    public static func previous(before chapterID: UUID, in chapters: [Chapter]) -> Chapter? {
        let sorted = chapters.naturallySorted()
        guard let idx = sorted.firstIndex(where: { $0.id == chapterID }),
              idx - 1 >= 0 else { return nil }
        return sorted[idx - 1]
    }
}

/// Canonical local-cache identity for a chapter's audio on the watch. Thin shim
/// over `ChapterAudioIdentity` so the watch store, the phone→watch transfer, and
/// the phone downloader all agree on one key per chapter (INV-B). Every
/// watch-cache read/write MUST key on this so a file downloaded under one URL
/// variant is still found later. Pure, host-testable.
public enum WatchChapterCache {
    public static func canonicalURL(for chapter: Chapter) -> URL? {
        ChapterAudioIdentity.canonicalURL(for: chapter)
    }

    public static func key(for chapter: Chapter) -> String? {
        ChapterAudioIdentity.cacheKey(for: chapter)
    }
}

/// What `WatchTransferState` an acknowledgement implies, given the phone's current intent for
/// this book and (for progress continuity only) its previously-displayed storage state. Pure,
/// host-testable — extracted so this decision can never again depend on whether some other
/// `@Published` property has been refreshed yet at the call site.
public enum WatchAcknowledgedStorageResolver {
    public static func resolve(
        acknowledgement: WatchManifestAcknowledgement,
        desiredState: WatchDownloadState?,
        priorStorageState: WatchTransferState?
    ) -> WatchTransferState {
        if acknowledgement.complete { return .available }
        if acknowledgement.failureMessage != nil { return .failed }
        if case .failed? = desiredState { return .failed }
        if desiredState == .paused { return .paused }
        if case .transferring(let progress)? = priorStorageState { return .transferring(progress: progress) }
        if case .stalled(let progress)? = priorStorageState { return .stalled(progress: progress) }
        return .queued
    }
}

/// Transfer state machine: determines the visible state for a give set of inputs.
/// Pure, host-testable.
public enum WatchTransferStateResolver {

    /// Resolves the visible transfer state from the current facts.
    /// - Parameters:
    ///   - isDownloaded: all cached chapter bytes are complete
    ///   - isQueued: a download task exists but hasn't started
    ///   - isTransferring: bytes are actively flowing
    ///   - progress: 0...1 fraction complete
    ///   - isFailed: a prior attempt failed
    ///   - isPhoneReachable: WCSession is reachable
    ///   - needsPhoneTransfer: download requires phone as transport
    public static func resolve(
        isDownloaded: Bool,
        isQueued: Bool,
        isTransferring: Bool,
        progress: Double,
        isFailed: Bool,
        isPhoneReachable: Bool,
        needsPhoneTransfer: Bool
    ) -> WatchTransferState {
        if isDownloaded { return .available }
        if isFailed { return .failed }
        if isTransferring { return .transferring(progress: progress) }
        if needsPhoneTransfer && !isPhoneReachable { return .waitingForPhone }
        if isQueued { return .queued }
        return .notAvailable
    }
}

/// Outcome of asking whether the phone may start sending a book to the watch.
public enum WatchSendReadiness: Equatable, Sendable {
    case ready
    case transferAlreadyInProgress
    case sessionNotActivated
    case watchAppNotInstalled
}

/// Whether `PhoneAudioRelay.transferBookToWatch` may proceed. Pure, host-testable.
public enum WatchSendReadinessResolver {

    /// Resolves readiness from a single, coherently-timed reading of connection
    /// state. All three flags must come from the same reading — mixing a cached
    /// flag with a later, independently-timed live read of another flag can
    /// race `WCSession` activation and falsely report `.watchAppNotInstalled`
    /// even when the watch app is genuinely installed.
    /// - Parameters:
    ///   - isAlreadyTransferring: a transfer to the watch is already in flight
    ///   - isActivated: `WCSession.activationState == .activated`
    ///   - isWatchAppInstalled: `WCSession.isWatchAppInstalled`
    public static func resolve(
        isAlreadyTransferring: Bool,
        isActivated: Bool,
        isWatchAppInstalled: Bool
    ) -> WatchSendReadiness {
        if isAlreadyTransferring { return .transferAlreadyInProgress }
        if !isActivated { return .sessionNotActivated }
        if !isWatchAppInstalled { return .watchAppNotInstalled }
        return .ready
    }
}

/// Outcome of deciding whether to reconcile against an incoming whole-device watch catalog report.
public enum WatchCatalogAcceptance: Equatable, Sendable {
    case reconcile
    case skipDuplicate
}

/// Whether `PhoneAudioRelay` should reconcile its watch-projection store against an incoming
/// `.watchCatalog` report. Pure, host-testable.
///
/// The watch's own local report counter lives in its own `UserDefaults` and is wiped by deleting
/// and reinstalling the watch app, so it restarts at 1. A plain `incoming >= lastAccepted`
/// comparison against the phone's durably-remembered high-water mark rejected that first honest
/// "nothing installed" report forever, leaving every previously-downloaded book stuck showing as
/// still installed with no way to self-correct.
///
/// A lower revision is not, on its own, proof of a stale/out-of-order delivery — that is exactly
/// what a legitimate reinstall produces — but it can't be ignored outright either:
/// `PhoneWatchProjectionStore.reconcile` deletes the acknowledgement of any book missing from the
/// catalog with no per-book revision check, so reconciling on every non-repeat revision could wipe
/// out an acknowledgement for a book that installed correctly in between two reports delivered out
/// of order (the watch sends each report over both `updateApplicationContext` and, when reachable,
/// a live `sendMessage`, which are not guaranteed to arrive in the same order). The watch's
/// `installEpoch` — a random ID minted once per fresh install, wiped by the same reinstall that
/// resets the revision counter — tells the two apart: a changed epoch means the lower revision is a
/// legitimate reset, while a matching epoch means the ordering check still applies. An absent
/// incoming epoch (an older watch build that predates this field) falls back to the original,
/// pre-epoch comparison exactly, for compatibility.
public enum WatchCatalogAcceptanceResolver {
    public static func resolve(
        incomingEpoch: String?,
        incomingRevision: Int64,
        lastAcceptedEpoch: String?,
        lastAcceptedRevision: Int64
    ) -> WatchCatalogAcceptance {
        guard let incomingEpoch else {
            return incomingRevision >= lastAcceptedRevision ? .reconcile : .skipDuplicate
        }
        guard incomingEpoch == lastAcceptedEpoch else { return .reconcile }
        return incomingRevision > lastAcceptedRevision ? .reconcile : .skipDuplicate
    }
}

/// The single source of truth for what a book's watch-download status should *display* as,
/// merging the authoritative `WatchDownloadState` the phone currently intends with the cached
/// `WatchTransferState` snapshot (used only for in-flight progress detail). `desiredState`
/// always wins for every terminal state; `storageState` can only ever add progress detail on
/// top of an in-flight desired state, never override a terminal one. Every UI call site that
/// shows or acts on watch-download status must route through this.
public enum WatchDisplayStateResolver {
    public static func resolve(
        desiredState: WatchDownloadState?,
        storageState: WatchTransferState?
    ) -> WatchTransferState {
        guard let desiredState else { return storageState ?? .notAvailable }
        switch desiredState {
        case .failed:
            return .failed
        case .paused:
            return .paused
        case .removing, .notRequested:
            return .notAvailable
        case .downloaded:
            return .available
        case .queued, .preparing, .transferring, .installing:
            if case .transferring(let progress)? = storageState { return .transferring(progress: progress) }
            if case .stalled(let progress)? = storageState { return .stalled(progress: progress) }
            return .queued
        }
    }
}

/// Persistent global-chrome status: how many books are authoritatively downloaded on the watch
/// and how many have failed.
public struct WatchTransferStatusBanner: Equatable, Sendable {
    public let downloadedCount: Int
    public let failedCount: Int
    public var hasFailure: Bool { failedCount > 0 }

    public init(downloadedCount: Int, failedCount: Int) {
        self.downloadedCount = downloadedCount
        self.failedCount = failedCount
    }
}

/// Visible only for terminal authoritative outcomes (downloaded / failed). Entries absent from
/// `desiredStates` (orphaned cache) are never counted, and every state is derived through
/// `WatchDisplayStateResolver` so a stale cached `.available` can never look healthy.
public enum WatchTransferStatusBannerResolver {
    public static func resolve(
        desiredStates: [WatchBookID: WatchDownloadState],
        storageStates: [WatchBookID: WatchTransferState]
    ) -> WatchTransferStatusBanner? {
        var downloaded = 0
        var failed = 0
        for (bookID, desired) in desiredStates {
            switch WatchDisplayStateResolver.resolve(desiredState: desired, storageState: storageStates[bookID]) {
            case .available: downloaded += 1
            case .failed: failed += 1
            default: break
            }
        }
        guard downloaded > 0 || failed > 0 else { return nil }
        return WatchTransferStatusBanner(downloadedCount: downloaded, failedCount: failed)
    }

    public static func label(for banner: WatchTransferStatusBanner) -> String {
        switch (banner.downloadedCount, banner.failedCount) {
        case (let d, 0): return "\(d) downloaded on Apple Watch"
        case (0, let f): return f == 1 ? "1 download failed" : "\(f) downloads failed"
        case (let d, let f): return "\(d) on Apple Watch, \(f) failed"
        }
    }
}

/// Truthful, listener-facing Watch transfer copy. Only a complete Watch acknowledgement may claim installation.
public enum WatchTransferStatusCopy {
    public static let preparing = "Preparing AAC-LC narration for Apple Watch…"
    public static let waitingForWatch = "Sent to Apple Watch; waiting for Watch validation and installation."
    public static let installed = "Installed on Apple Watch."

    public static func sentStatus(title: String) -> String {
        "\(title) sent to Apple Watch; waiting for Watch validation and installation."
    }
    public static func watchRejection(chapterOrdinal: Int, reason: String) -> String {
        "Apple Watch rejected chapter \(chapterOrdinal): \(reason). The book was not installed."
    }
    public static func phoneValidationFailure(reason: String) -> String {
        "Couldn’t prepare Apple Watch audio: generated narration is not a playable AAC-LC M4A. \(reason)"
    }

    /// Status text for a book; `.downloaded` counts only with a complete acknowledgement.
    public static func resolve(state: WatchDownloadState?, acknowledgement: WatchManifestAcknowledgement?) -> String? {
        switch state {
        case .preparing?: return preparing
        case .transferring?, .queued?, .installing?: return waitingForWatch
        case .downloaded?: return acknowledgement?.complete == true ? installed : waitingForWatch
        case .failed(let message)?: return message
        default: return nil
        }
    }

    /// Books that may be counted/listed as on the watch: complete acknowledgement and not failed.
    public static func isInstalled(state: WatchDownloadState?, acknowledgement: WatchManifestAcknowledgement?) -> Bool {
        if case .failed? = state { return false }
        return acknowledgement?.complete == true
    }
}
