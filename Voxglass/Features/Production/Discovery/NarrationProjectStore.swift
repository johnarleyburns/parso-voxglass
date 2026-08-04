import Foundation
import VoxglassCore

// MARK: - Phone narration project (short works, iPhone)

/// A single short-work narration project on the phone (NARRATION_NEEDS_SPEC
/// §11.4). Resumable at any step; paragraph-addressable. `needID` ties a
/// project to the Narration Need it came from so starting the same need again
/// resumes this project instead of creating a duplicate.
public struct NarrationProject: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var author: String
    public var sourceText: String
    public var sourceURL: String?
    public var paragraphs: [NarrationParagraph]
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: NarrationMetadata?
    public var rightsAttested: Bool
    public var needID: String?

    public init(
        id: UUID = UUID(),
        title: String,
        author: String,
        sourceText: String = "",
        sourceURL: String? = nil,
        paragraphs: [NarrationParagraph] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: NarrationMetadata? = nil,
        rightsAttested: Bool = false,
        needID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceText = sourceText
        self.sourceURL = sourceURL
        self.paragraphs = paragraphs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
        self.rightsAttested = rightsAttested
        self.needID = needID
    }

    public var recordedCount: Int { paragraphs.count { $0.state != .notRecorded } }
    public var approvedCount: Int { paragraphs.count { $0.state == .approved } }
    public var flaggedCount: Int { paragraphs.count { $0.state == .flagged } }
    public var readyToAssemble: Bool { flaggedCount == 0 && recordedCount == paragraphs.count && !paragraphs.isEmpty }
    public var needsPickupCount: Int { paragraphs.count { $0.state == .notRecorded } }

    public func duration(of paragraphs: [NarrationParagraph]) -> TimeInterval {
        paragraphs.reduce(0) { $0 + ($1.selectedTake?.duration ?? 0) }
    }

    /// Identity used to collapse duplicates: the originating need ID when
    /// known, otherwise the work's title + author + source URL. Projects
    /// created before need IDs existed (all current user data) fall back to
    /// the work key, which is what those duplicates share.
    public var dedupeKey: String {
        if let needID { return "need:\(needID)" }
        return "work:\(Self.normalize(title))|\(Self.normalize(author))|\(Self.normalize(sourceURL ?? ""))"
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public enum NarrationParagraphRole: String, Codable, Sendable, Equatable {
    case disclaimer
    case intro
    case body
    case outro
}

public enum NarrationParagraphState: String, Codable, Sendable, Equatable {
    case notRecorded
    case recorded
    case approved
    case flagged
}

public struct NarrationTake: Codable, Sendable, Equatable {
    public var fileName: String
    public var duration: TimeInterval
    public var peakDBFS: Double?
    public var rmsDBFS: Double?
    public var clipped: Bool

    public init(fileName: String, duration: TimeInterval, peakDBFS: Double? = nil, rmsDBFS: Double? = nil, clipped: Bool = false) {
        self.fileName = fileName
        self.duration = duration
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
        self.clipped = clipped
    }
}

public struct NarrationParagraph: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var role: NarrationParagraphRole
    public var state: NarrationParagraphState
    public var note: String?
    public var selectedTake: NarrationTake?

    public init(
        id: UUID = UUID(),
        text: String,
        role: NarrationParagraphRole = .body,
        state: NarrationParagraphState = .notRecorded,
        note: String? = nil,
        selectedTake: NarrationTake? = nil
    ) {
        self.id = id
        self.text = text
        self.role = role
        self.state = state
        self.note = note
        self.selectedTake = selectedTake
    }
}

public struct NarrationMetadata: Codable, Sendable, Equatable {
    public var narrator: String
    public var language: String
    public var description: String
    public var subjects: [String]
    public var sourceURL: String
    public var year: Int?

    public init(narrator: String, language: String, description: String, subjects: [String], sourceURL: String, year: Int? = nil) {
        self.narrator = narrator
        self.language = language
        self.description = description
        self.subjects = subjects
        self.sourceURL = sourceURL
        self.year = year
    }
}

// MARK: - Store (thread-safe class, JSON + take files)

/// Persists phone narration projects as JSON under Application Support, with
/// recorded takes stored alongside each project directory. Synchronous and
/// lock-guarded (the flows run on the main actor).
public final class NarrationProjectStore: @unchecked Sendable {
    public enum StoreError: Error {
        case notFound
    }

    private let rootURL: URL
    private let lock = NSLock()

    public init(rootURL: URL? = nil) {
        let base = rootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Voxglass/Narrations", isDirectory: true)
        self.rootURL = base
    }

    public var narrationsRoot: URL { rootURL }

    private func projectURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).json")
    }

    public func takesDirectory(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString)-takes", isDirectory: true)
    }

    public func loadAll() -> [NarrationProject] {
        lock.withLock {
            guard let files = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
            let projects = files
                .filter { $0.pathExtension == "json" }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? NeedsJSONCoding.decoder.decode(NarrationProject.self, from: $0) }
                .sorted { $0.updatedAt > $1.updatedAt }
            // Migration for existing installs: duplicate narrations of the same
            // work (created before resume-by-need existed) collapse here, keeping
            // the most complete project. Idempotent; runs on every load.
            return Self.deduplicate(projects) { id in
                try? FileManager.default.removeItem(at: projectURL(id))
                try? FileManager.default.removeItem(at: takesDirectory(for: id))
            }
        }
    }

    /// Collapses projects sharing a `dedupeKey` into the most complete one
    /// (most approved, then most recorded, then most takes, then newest) and
    /// deletes the losers. Returns the survivors in input order.
    private static func deduplicate(_ projects: [NarrationProject], delete: (UUID) -> Void) -> [NarrationProject] {
        var byKey: [String: NarrationProject] = [:]
        var survivors: [NarrationProject] = []
        for project in projects {
            let key = project.dedupeKey
            if let existing = byKey[key] {
                let keep = moreComplete(existing, project)
                delete(keep.id == existing.id ? project.id : existing.id)
                byKey[key] = keep
            } else {
                byKey[key] = project
                survivors.append(project)
            }
        }
        return survivors.compactMap { byKey[$0.dedupeKey] }
    }

    private static func moreComplete(_ a: NarrationProject, _ b: NarrationProject) -> NarrationProject {
        func score(_ p: NarrationProject) -> (approved: Int, recorded: Int, takes: Int, updatedAt: Date) {
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

    public func load(id: UUID) throws -> NarrationProject {
        guard let data = try? Data(contentsOf: projectURL(id)) else { throw StoreError.notFound }
        return try NeedsJSONCoding.decoder.decode(NarrationProject.self, from: data)
    }

    public func save(_ project: NarrationProject) {
        var project = project
        project.updatedAt = Date()
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard let data = try? NeedsJSONCoding.encoder.encode(project) else { return }
        try? data.write(to: projectURL(project.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: projectURL(id))
        try? FileManager.default.removeItem(at: takesDirectory(for: id))
    }

    /// Removes every project and take (UI-test reset hook; also usable as a
    /// user-facing "clear my narrations" if ever needed).
    public func deleteAll() {
        lock.withLock {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    public func writeTake(data: Data, projectID: UUID, take: inout NarrationTake) -> Bool {
        let dir = takesDirectory(for: projectID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(take.fileName)
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    public func takeURL(projectID: UUID, fileName: String) -> URL {
        takesDirectory(for: projectID).appendingPathComponent(fileName)
    }
}
