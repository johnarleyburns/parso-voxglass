import Foundation

// MARK: - Legacy narration JSON schema (migration-only, spec §4.3.3)

/// The JSON shape the shipping Narration flow wrote before the single-project
/// model (NARRATION_NEEDS_SPEC §11.4). These types exist ONLY to decode that
/// one-way data; they are never used to create new projects. The encoding
/// strategy matches the old `NeedsJSONCoding` ISO-8601 dates exactly.
struct LegacyNarrationProject: Codable, Sendable {
    var id: UUID
    var title: String
    var author: String
    var sourceText: String
    var sourceURL: String?
    var paragraphs: [LegacyNarrationParagraph]
    var createdAt: Date
    var updatedAt: Date
    var metadata: LegacyNarrationMetadata?
    var rightsAttested: Bool
    var needID: String?
}

struct LegacyNarrationParagraph: Codable, Sendable {
    var id: UUID
    var text: String
    var role: LegacyNarrationParagraphRole
    var state: LegacyNarrationParagraphState
    var note: String?
    var selectedTake: LegacyNarrationTake?
}

enum LegacyNarrationParagraphRole: String, Codable, Sendable {
    case disclaimer
    case intro
    case body
    case outro
}

enum LegacyNarrationParagraphState: String, Codable, Sendable {
    case notRecorded
    case recorded
    case approved
    case flagged
}

struct LegacyNarrationTake: Codable, Sendable {
    var fileName: String
    var duration: TimeInterval
    var peakDBFS: Double?
    var rmsDBFS: Double?
    var clipped: Bool
}

struct LegacyNarrationMetadata: Codable, Sendable {
    var narrator: String
    var language: String
    var description: String
    var subjects: [String]
    var sourceURL: String
    var year: Int?
}

// MARK: - NarrationMigration

/// One-way, idempotent migration from the legacy JSON narration store to the
/// single `AudiobookProject` model in the SQLite production store (spec §4.3.3).
///
/// Runs once at first launch of the release that lands stage P2. It enumerates
/// `Narrations/*.json`, creates an `AudiobookProject` per surviving narration
/// under `ProductionProjects/<newID>/`, copies (never moves) referenced take
/// files into the content-addressed store with a stream hash, writes a receipt
/// mapping old id → new id, and only then deletes the legacy tree. Failure of
/// one project never aborts the others; the failed project stays on disk and is
/// retried on the next launch.
public struct NarrationMigration: Sendable {

    public struct Result: Sendable {
        /// True when this run did any real migration work (vs. a no-op).
        public var didRun: Bool
        /// Number of legacy narrations turned into `AudiobookProject`s this run.
        public var migratedProjectCount: Int
        /// JSON files that could not be decoded (corrupt) or were already migrated.
        public var skippedCount: Int
        /// Old project ids that failed to migrate and remain on disk for retry.
        public var failedProjectIDs: [UUID]
        /// old id → new id. Includes deduplicated losers (which collapse into
        /// the surviving project's new id).
        public var mapping: [UUID: UUID]
        /// Receipt files written this run (`Narrations/.migrated-<date>.json`).
        public var receipts: [URL]

        public init(
            didRun: Bool = false,
            migratedProjectCount: Int = 0,
            skippedCount: Int = 0,
            failedProjectIDs: [UUID] = [],
            mapping: [UUID: UUID] = [:],
            receipts: [URL] = []
        ) {
            self.didRun = didRun
            self.migratedProjectCount = migratedProjectCount
            self.skippedCount = skippedCount
            self.failedProjectIDs = failedProjectIDs
            self.mapping = mapping
            self.receipts = receipts
        }
    }

    /// Sync-state keys the migration and the narration repository share. The
    /// `AudiobookProject` has no home for the need link or the raw source text,
    /// so both ride in the per-project `sync_state` table (spec §4.3.3 carry
    /// list) and are read by the flow's resume and dedupe paths.
    public static let needIDKey = "narration.needID"
    public static let sourceTextKey = "narration.sourceText"

    public let narrationsRoot: URL
    public let projectsRoot: URL
    private let clock: any Clock
    private let ids: any IDGenerator

    public init(
        narrationsRoot: URL,
        projectsRoot: URL,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator()
    ) {
        self.narrationsRoot = narrationsRoot
        self.projectsRoot = projectsRoot
        self.clock = clock
        self.ids = ids
    }

    public func runIfNeeded() async -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: narrationsRoot.path) else { return Result() }

        let migratedIDs = Self.readMigratedIDs(from: narrationsRoot)
        let jsonURLs = ((try? fm.contentsOfDirectory(at: narrationsRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".migrated-")
            }

        var survivors: [LegacyNarrationProject] = []
        var skipped = 0
        for url in jsonURLs {
            guard let oldID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                skipped += 1
                continue
            }
            if migratedIDs.contains(oldID) {
                skipped += 1
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let legacy = Self.decode(data) else {
                skipped += 1
                continue
            }
            survivors.append(legacy)
        }

        var mapping: [UUID: UUID] = [:]
        var migratedCount = 0
        var failed: [UUID] = []
        let (deduped, losers) = Self.deduplicateByNeedID(survivors)
        for legacy in deduped {
            do {
                let newID = try await migrate(legacy)
                mapping[legacy.id] = newID
                migratedCount += 1
            } catch {
                failed.append(legacy.id)
            }
        }
        // Collapsed duplicates map to the survivor's new id, so a receipt can
        // never list an old id that is still on disk and unaccounted for.
        for (loserID, survivorID) in losers {
            if let newID = mapping[survivorID] {
                mapping[loserID] = newID
            }
        }

        var receipts: [URL] = []
        if !mapping.isEmpty, let receiptURL = Self.writeReceipt(
            mapping: mapping,
            at: narrationsRoot,
            now: clock.now
        ) {
            receipts.append(receiptURL)
        }

        // The legacy tree is deleted only once every project has a receipt.
        // A failed (or corrupt-only) batch leaves the tree in place so the
        // remaining files are retried next launch; already-migrated files are
        // skipped by the receipts, so a retry can never duplicate a project.
        var didDeleteTree = false
        if failed.isEmpty && !jsonURLs.isEmpty {
            try? fm.removeItem(at: narrationsRoot)
            didDeleteTree = true
        }

        return Result(
            didRun: didDeleteTree || !mapping.isEmpty,
            migratedProjectCount: migratedCount,
            skippedCount: skipped,
            failedProjectIDs: failed,
            mapping: mapping,
            receipts: receipts
        )
    }

    // MARK: - Single-project migration

    private func migrate(_ legacy: LegacyNarrationProject) async throws -> UUID {
        let newID = ids.next()
        let layout = ProductionProjectLayout(root: projectsRoot.appendingPathComponent(newID.uuidString, isDirectory: true))
        let fm = FileManager.default
        for dir in layout.directories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let store = SQLiteProductionStore(databaseURL: layout.databaseURL, clock: clock)
        let assets: any ContentAddressedStore = FileAssetStore(root: layout.root)

        // Sync-state rows first: neither needs a project row to exist, and they
        // are idempotent (INSERT OR REPLACE), so a mid-migration failure leaves
        // nothing half-written to duplicate on retry.
        if let needID = legacy.needID {
            try await store.setSyncValue(Self.needIDKey, needID)
        }
        if !legacy.sourceText.isEmpty {
            try await store.setSyncValue(Self.sourceTextKey, legacy.sourceText)
        }

        let paragraphs = try await migrateParagraphs(legacy, into: assets)
        let chapter = ProductionChapter(
            id: ids.next(),
            ordinal: 0,
            title: legacy.title,
            role: .body,
            paragraphs: paragraphs
        )

        let narrator = legacy.metadata?.narrator ?? ""
        let metadata = BookMetadata(
            title: legacy.title,
            author: legacy.author,
            narrator: narrator,
            language: legacy.metadata?.language ?? "en-US",
            description: legacy.metadata?.description ?? "",
            subjects: legacy.metadata?.subjects ?? [],
            copyrightYear: legacy.metadata?.year
        )
        let rights = RightsEvidence(
            basis: .publicDomainUS,
            sourceURL: legacy.sourceURL.flatMap(URL.init(string:)),
            editionYear: legacy.metadata?.year,
            attestedAt: legacy.rightsAttested ? legacy.createdAt : nil,
            attestedBy: legacy.rightsAttested ? (narrator.isEmpty ? "narrator" : narrator) : nil
        )
        let project = AudiobookProject(
            id: newID,
            metadata: metadata,
            rights: rights,
            profile: ProductionProfile(
                purpose: .publicDomainCommunity,
                recording: RecordingDefaults(sampleRate: 44_100, bitDepth: 24),
                intendedDestination: .librivox
            ),
            source: nil,
            chapters: [chapter],
            createdAt: legacy.createdAt,
            modifiedAt: legacy.updatedAt
        )
        try await store.save(project)
        return newID
    }

    private func migrateParagraphs(
        _ legacy: LegacyNarrationProject,
        into assets: any ContentAddressedStore
    ) async throws -> [Paragraph] {
        // No paragraphs in the JSON: segment the carried sourceText through the
        // real Segmenter (spec §4.3.3 step 3). Legacy paragraph identity is
        // preserved only when the JSON had paragraphs.
        if legacy.paragraphs.isEmpty {
            let document = Self.extractedDocument(fromSourceText: legacy.sourceText)
            let result = Segmenter().segment(document, ids: ids, clock: clock)
            var paragraphs: [Paragraph] = []
            var ordinal = 0
            for chapter in result.chapters {
                for var paragraph in chapter.paragraphs {
                    paragraph.ordinal = ordinal
                    paragraphs.append(paragraph)
                    ordinal += 1
                }
            }
            return paragraphs
        }

        var paragraphs: [Paragraph] = []
        for (index, legacyParagraph) in legacy.paragraphs.enumerated() {
            let hash = TextNormalizer.hash(legacyParagraph.text)
            var paragraph = Paragraph(
                id: legacyParagraph.id,
                ordinal: index,
                text: legacyParagraph.text,
                textHash: hash,
                role: Self.role(from: legacyParagraph.role),
                reviewState: Self.reviewState(from: legacyParagraph.state),
                updatedAt: legacy.updatedAt
            )
            if let legacyTake = legacyParagraph.selectedTake,
               let ref = try await copyTake(legacyTake, projectID: legacy.id, into: assets) {
                let take = Take(
                    id: ids.next(),
                    paragraphID: paragraph.id,
                    assetRef: ref,
                    origin: .recorded,
                    recordedAt: legacy.createdAt,
                    duration: legacyTake.duration,
                    format: AudioFormatDescription(sampleRate: 44_100, channels: 1, bitDepth: 16, codec: "pcm"),
                    textHashAtRecording: hash
                )
                paragraph.takes = [take]
                paragraph.selectedTakeID = take.id
            }
            paragraphs.append(paragraph)
        }
        return paragraphs
    }

    /// Copies (never moves) one legacy take file into the content-addressed
    /// store, stream-hashing it, and returns the resulting reference. Returns
    /// nil when the referenced file is already gone — the paragraph survives
    /// without its audio rather than the migration failing outright.
    private func copyTake(
        _ take: LegacyNarrationTake,
        projectID: UUID,
        into assets: any ContentAddressedStore
    ) async throws -> AudioAssetReference? {
        let takesDirectory = narrationsRoot.appendingPathComponent("\(projectID.uuidString)-takes", isDirectory: true)
        let url = takesDirectory.appendingPathComponent(take.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ext = url.pathExtension.isEmpty ? "caf" : url.pathExtension
        let contentType = switch ext.lowercased() {
        case "caf": "audio/x-caf"
        case "wav": "audio/wav"
        case "m4a": "audio/mp4"
        default: "audio/wav"
        }
        return try await assets.ingest(fileAt: url, ext: ext, contentType: contentType, subdirectory: .original, moving: false)
    }

    // MARK: - Mapping helpers

    private static func role(from legacy: LegacyNarrationParagraphRole) -> ParagraphRole {
        switch legacy {
        case .disclaimer, .intro: return .libriVoxIntro
        case .outro: return .libriVoxOutro
        case .body: return .body
        }
    }

    private static func reviewState(from legacy: LegacyNarrationParagraphState) -> ReviewState {
        switch legacy {
        case .approved: return .approved
        case .flagged: return .flagged
        case .recorded, .notRecorded: return .unreviewed
        }
    }

    /// Collapses narrations sharing a `needID` into the most complete one
    /// (most approved, then most recorded, then most takes, then newest),
    /// mirroring the legacy store's load-time dedupe. Narrations without a
    /// need ID are never collapsed. Returns the survivors in input order and a
    /// map of collapsed loser id → survivor id.
    private static func deduplicateByNeedID(_ projects: [LegacyNarrationProject]) -> ([LegacyNarrationProject], [UUID: UUID]) {
        var byKey: [String: LegacyNarrationProject] = [:]
        var losers: [UUID: UUID] = [:]
        var order: [String] = []
        for project in projects {
            let key = project.needID.map { "need:\($0)" } ?? project.id.uuidString
            if let existing = byKey[key] {
                let kept = moreComplete(existing, project)
                let loser = kept.id == existing.id ? project : existing
                losers[loser.id] = kept.id
                byKey[key] = kept
            } else {
                byKey[key] = project
                order.append(key)
            }
        }
        return (order.compactMap { byKey[$0] }, losers)
    }

    private static func moreComplete(_ a: LegacyNarrationProject, _ b: LegacyNarrationProject) -> LegacyNarrationProject {
        func score(_ p: LegacyNarrationProject) -> (approved: Int, recorded: Int, takes: Int, updatedAt: Date) {
            (
                p.paragraphs.count { $0.state == .approved },
                p.paragraphs.count { $0.state == .recorded },
                p.paragraphs.count { $0.selectedTake != nil },
                p.updatedAt
            )
        }
        let (aa, ar, at, ad) = score(a)
        let (ba, br, bt, bd) = score(b)
        if aa != ba { return aa > ba ? a : b }
        if ar != br { return ar > br ? a : b }
        if at != bt { return at > bt ? a : b }
        return ad >= bd ? a : b
    }

    /// Builds an `ExtractedDocument` from raw source text so the Segmenter can
    /// be run on a legacy narration that never built paragraphs. Blank lines
    /// are paragraph breaks, matching how the old flow grouped body text.
    private static func extractedDocument(fromSourceText sourceText: String) -> ExtractedDocument {
        var blocks: [ExtractedBlock] = []
        var current: [String] = []
        for rawLine in sourceText.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    blocks.append(ExtractedBlock(kind: .paragraph, text: current.joined(separator: "\n"), sourceRange: 0..<0))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(ExtractedBlock(kind: .paragraph, text: current.joined(separator: "\n"), sourceRange: 0..<0))
        }
        return ExtractedDocument(sections: [ExtractedSection(blocks: blocks, sourceStart: 0)], plainText: sourceText)
    }

    // MARK: - Receipts

    private static func decode(_ data: Data) -> LegacyNarrationProject? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LegacyNarrationProject.self, from: data)
    }

    private static func readMigratedIDs(from narrationsRoot: URL) -> Set<UUID> {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: narrationsRoot, includingPropertiesForKeys: nil) else { return [] }
        var migrated: Set<UUID> = []
        for url in files where url.lastPathComponent.hasPrefix(".migrated-") {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any],
                  let projects = dict["projects"] as? [String: String] else { continue }
            for (old, _) in projects {
                if let id = UUID(uuidString: old) { migrated.insert(id) }
            }
        }
        return migrated
    }

    private static func writeReceipt(mapping: [UUID: UUID], at narrationsRoot: URL, now: Date) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: narrationsRoot, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "migratedAt": ISO8601DateFormatter().string(from: now),
            "projects": Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.uuidString, $0.value.uuidString) })
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = narrationsRoot.appendingPathComponent(".migrated-\(formatter.string(from: now)).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
