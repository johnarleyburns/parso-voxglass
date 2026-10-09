import Foundation
import VoxglassWatchProtocol
import VoxglassWatchCore

/// The phone-side projection boundary. It deliberately accepts the existing
/// repository's value types and emits only the DTOs the Watch is allowed to see.
public enum PhoneWatchProjection {
    /// A single-file audiobook (this app's local-folder import) shares one
    /// `localURL` across every chapter — hashing it per chapter, unmemoized,
    /// meant a 1.2GB local book got SHA-256'd in full once per chapter (42+
    /// times over) on every Watch snapshot rebuild, including on chapter
    /// navigation. That blew past the device's memory limit and got the app
    /// killed. Hash each distinct file only once per `book(from:)` call.
    public static func book(from source: BookWithChapters, revision: Int64 = 0) -> WatchBookDTO {
        var hashCache: [URL: String] = [:]
        let chapters = source.chapters.naturallySorted().map { chapter in
            let local = chapter.resolvedPlayableURL()
            let file = local?.isFileURL == true && FileManager.default.fileExists(atPath: local!.path) ? local : nil
            let bytes = file.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value }
            let hash = file.flatMap { url -> String? in
                if let cached = hashCache[url] { return cached }
                let computed = try? WatchChecksum.sha256(of: url)
                hashCache[url] = computed
                return computed
            }
            let publicURL: URL? = chapter.remoteURL.flatMap { url in
                guard url.scheme?.lowercased() == "https" else { return nil }
                return url
            }
            return WatchChapterDTO(
                id: .init(chapter.id.uuidString), index: chapter.index, title: chapter.title,
                duration: chapter.duration ?? 0, startTime: chapter.startTime,
                expectedBytes: bytes, expectedSHA256: hash,
                durableFilename: "\(chapter.id.uuidString).audio", approvedStreamURL: publicURL
            )
        }
        return WatchBookDTO(
            id: .init(source.book.id.uuidString), title: source.book.title,
            author: source.book.authors.first, narrator: source.book.narrators.first,
            duration: source.totalDuration ?? 0, artworkKey: source.book.coverURL?.absoluteString,
            metadataRevision: revision, chapters: chapters
        )
    }

    public static func applyingResumePosition(
        bookID: WatchBookID,
        chapterID: WatchChapterID,
        position: TimeInterval,
        to snapshot: WatchLibrarySnapshot
    ) -> WatchLibrarySnapshot {
        guard let bookIndex = snapshot.books.firstIndex(where: { $0.id == bookID }),
              let chapterIndex = snapshot.books[bookIndex].chapters.firstIndex(where: { $0.id == chapterID }) else {
            return snapshot
        }

        var result = snapshot
        result.books[bookIndex].chapters[chapterIndex].resumePosition = max(0, position)
        return result
    }

    public static func library(from books: [BookWithChapters], libraryID: WatchPairedLibraryID, revision: Int64) -> WatchLibrarySnapshot {
        .init(pairedLibraryID: libraryID, revision: revision, books: books.map { book(from: $0, revision: revision) })
    }
}

public actor PhoneWatchProjectionStore {
    public struct State: Codable, Equatable, Sendable {
        public var libraryID: WatchPairedLibraryID
        public var revision: Int64
        public var desired: [WatchBookID: WatchDownloadState]
        public var desiredRoots: [WatchBookID: WatchManifest]
        public var acknowledgements: [WatchBookID: WatchManifestAcknowledgement]
        /// Only explicitly selected books; no full-phone library is mirrored.
        public var selectedBooks: [WatchBookID: WatchBookDTO] = [:]
        /// Persistent submission times survive phone relaunch; retries remain user initiated.
        public var submittedAt: [WatchBookID: Date] = [:]
        public init(libraryID: WatchPairedLibraryID, revision: Int64 = 0, desired: [WatchBookID: WatchDownloadState] = [:], desiredRoots: [WatchBookID: WatchManifest] = [:], acknowledgements: [WatchBookID: WatchManifestAcknowledgement] = [:]) {
            self.libraryID = libraryID; self.revision = revision; self.desired = desired; self.desiredRoots = desiredRoots; self.acknowledgements = acknowledgements
        }
        private enum CodingKeys: String, CodingKey { case libraryID, revision, desired, desiredRoots, acknowledgements, selectedBooks, submittedAt }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            libraryID = try values.decode(WatchPairedLibraryID.self, forKey: .libraryID)
            revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
            desired = try values.decodeIfPresent([WatchBookID: WatchDownloadState].self, forKey: .desired) ?? [:]
            desiredRoots = try values.decodeIfPresent([WatchBookID: WatchManifest].self, forKey: .desiredRoots) ?? [:]
            acknowledgements = try values.decodeIfPresent([WatchBookID: WatchManifestAcknowledgement].self, forKey: .acknowledgements) ?? [:]
            selectedBooks = try values.decodeIfPresent([WatchBookID: WatchBookDTO].self, forKey: .selectedBooks) ?? [:]
            submittedAt = try values.decodeIfPresent([WatchBookID: Date].self, forKey: .submittedAt) ?? [:]
        }
    }
    private let url: URL
    private var state: State
    public init(url: URL, libraryID: WatchPairedLibraryID) {
        self.url = url
        if let loaded = try? JSONDecoder().decode(State.self, from: Data(contentsOf: url)), loaded.libraryID == libraryID { self.state = loaded }
        else { self.state = State(libraryID: libraryID) }
    }
    public func current() -> State { state }
    public func nextRevision() throws -> Int64 { state.revision += 1; try persist(); return state.revision }
    public func setDesired(_ value: WatchDownloadState, for bookID: WatchBookID) throws { state.desired[bookID] = value; try persist() }
    public func setDesiredRoot(_ manifest: WatchManifest) throws { state.desiredRoots[manifest.bookID] = manifest; state.desired[manifest.bookID] = .queued; try persist() }
    /// Persist the prepared, URL-free catalog before submitting audio files.
    public func select(_ book: WatchBookDTO) throws { state.selectedBooks[book.id] = book; try persist() }
    /// Save before handing audio to Apple; this does not enqueue or retry files.
    public func markSubmitted(_ bookID: WatchBookID, at date: Date) throws {
        state.submittedAt[bookID] = date
        state.desired[bookID] = .transferring
        try persist()
    }
    /// Only surface a manual retry after 24 hours, including following app relaunch.
    public func expireTransfers(at date: Date) throws {
        var changed = false
        for (id, started) in state.submittedAt where date.timeIntervalSince(started) >= 24 * 60 * 60 {
            if state.desired[id] == .transferring {
                state.desired[id] = .failed("Not installed after 24 hours. Try again from iPhone if needed.")
                changed = true
            }
        }
        if changed { try persist() }
    }
    public func acknowledge(_ acknowledgement: WatchManifestAcknowledgement) throws {
        if let root = state.desiredRoots[acknowledgement.bookID], root.revision > acknowledgement.revision { return }
        if state.desired[acknowledgement.bookID] == .removing {
            guard acknowledgement.isRemoval == true, !acknowledgement.complete,
                  acknowledgement.installedBytes == 0 else { return }
            state.selectedBooks.removeValue(forKey: acknowledgement.bookID)
            state.desiredRoots.removeValue(forKey: acknowledgement.bookID)
            state.desired.removeValue(forKey: acknowledgement.bookID)
            state.acknowledgements.removeValue(forKey: acknowledgement.bookID)
            state.submittedAt.removeValue(forKey: acknowledgement.bookID)
            try persist(); return
        }
        guard acknowledgement.isRemoval != true else { return }
        if let existing = state.acknowledgements[acknowledgement.bookID], existing.revision > acknowledgement.revision { return }
        state.acknowledgements[acknowledgement.bookID] = acknowledgement
        if acknowledgement.complete { state.desired[acknowledgement.bookID] = .downloaded }
        else if let message = acknowledgement.failureMessage { state.desired[acknowledgement.bookID] = .failed(message) }
        else if state.desired[acknowledgement.bookID] == .downloaded {
            state.desired[acknowledgement.bookID] = .failed("Audio is no longer fully installed. Send again from iPhone if needed.")
        }
        try persist()
    }
    /// A full inventory clears stale installation claims without scheduling any transfer.
    public func reconcile(_ catalog: WatchDeviceCatalog) throws {
        let present = Set(catalog.reports.map(\.bookID))
        for id in Array(state.acknowledgements.keys) where !present.contains(id) {
            state.acknowledgements.removeValue(forKey: id)
            if state.desired[id] == .downloaded { state.desired[id] = .failed("No longer installed on Apple Watch. Send again from iPhone if needed.") }
        }
        for report in catalog.reports { try acknowledge(report) }
        try persist()
    }
    /// Keep a durable removal revision so metadata deletion can be sent after activation/relaunch.
    public func remove(bookID: WatchBookID, revision: Int64? = nil) throws {
        state.desired[bookID] = .removing
        if let revision { state.desiredRoots[bookID] = WatchManifest(bookID: bookID, revision: revision, requiredChapterIDs: []) }
        try persist()
    }
    public func isTruthfullyDownloaded(_ bookID: WatchBookID) -> Bool { state.acknowledgements[bookID]?.complete == true }
    private func persist() throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(state).write(to: url, options: .atomic) }
}

public enum PhoneWatchDownloadPlanner {
    public static func plan(for book: BookWithChapters, revision: Int64 = 0) -> WatchDownloadPlan {
        let dto = PhoneWatchProjection.book(from: book, revision: revision)
        let assets = dto.chapters.map { chapter in
            let original = book.chapters.first { $0.id.uuidString == chapter.id.rawValue }
            return WatchDownloadAsset(chapterID: chapter.id, sourceURL: original?.resolvedPlayableURL(), expectedBytes: chapter.expectedBytes, expectedSHA256: chapter.expectedSHA256, filename: chapter.durableFilename)
        }
        return WatchDownloadPlan(bookID: dto.id, revision: revision, assets: assets)
    }
}
