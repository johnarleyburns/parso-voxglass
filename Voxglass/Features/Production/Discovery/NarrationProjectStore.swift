import Foundation
import VoxglassCore

// MARK: - Phone narration project (short works, iPhone)

/// A single short-work narration project on the phone (NARRATION_NEEDS_SPEC
/// §11.4). Resumable at any step; paragraph-addressable.
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
        rightsAttested: Bool = false
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
    }

    public var recordedCount: Int { paragraphs.count { $0.state != .notRecorded } }
    public var approvedCount: Int { paragraphs.count { $0.state == .approved } }
    public var flaggedCount: Int { paragraphs.count { $0.state == .flagged } }
    public var readyToAssemble: Bool { flaggedCount == 0 && recordedCount == paragraphs.count && !paragraphs.isEmpty }
    public var needsPickupCount: Int { paragraphs.count { $0.state == .notRecorded } }

    public func duration(of paragraphs: [NarrationParagraph]) -> TimeInterval {
        paragraphs.reduce(0) { $0 + ($1.selectedTake?.duration ?? 0) }
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
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? NeedsJSONCoding.decoder.decode(NarrationProject.self, from: $0) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
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
