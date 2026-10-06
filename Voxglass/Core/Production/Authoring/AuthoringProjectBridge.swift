import Foundation

/// Converts the phone's current production model to the portable v2 entity
/// protocol. Recording bytes remain in the local project package; the v2
/// authoring zone carries project metadata, chapter structure, and script text.
public enum AuthoringProjectBridge {
    public static func records(for project: AudiobookProject) throws -> [AuthoringEntitySnapshot] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var portableMetadata = project.metadata
        // Cover references point into the local project package; share the
        // descriptive metadata while keeping device-local paths out of CloudKit.
        portableMetadata.coverRef = nil
        let metadataValue = try authoringValue(portableMetadata, encoder: encoder)
        guard case .object(let metadata) = metadataValue else { throw BridgeError.invalidMetadata }
        var portableProfile = project.profile
        portableProfile.recording.inputDeviceUID = nil
        portableProfile.recording.monitoringDeviceUID = nil
        portableProfile.recording.monitoringEnabled = false

        let extensions: [String: AuthoringValue] = [
            "rights": try authoringValue(project.rights, encoder: encoder),
            "profile": try authoringValue(portableProfile, encoder: encoder),
            "pronunciations": try authoringValue(project.pronunciations, encoder: encoder),
            "createdAt": try authoringValue(project.createdAt, encoder: encoder),
            "schemaVersion": .integer(Int64(project.schemaVersion))
        ]
        let projectPayload = AuthoringProject(
            id: project.id,
            title: project.metadata.title,
            metadata: metadata,
            sourceIds: [],
            capabilityFlags: ["scriptText", "metadata", "mediaLocalOnly"],
            modifiedAt: iso8601(project.modifiedAt),
            extensions: extensions
        )
        var result = [try snapshot(id: project.id, kind: "project", value: projectPayload, fields: ["metadata", "rights", "profile", "pronunciations", "modifiedAt"])]

        for chapter in project.chapters {
            let chapterPayload = AuthoringChapter(
                id: chapter.id,
                projectId: project.id,
                ordinal: UInt32(max(0, chapter.ordinal)),
                title: chapter.title,
                role: chapter.role.rawValue,
                headGapFrames: frames(chapter.headSilenceOverride ?? project.profile.assembly.chapterHeadSilence),
                tailGapFrames: frames(chapter.tailSilenceOverride ?? project.profile.assembly.chapterTailSilence),
                sampleRate: 48_000,
                extensions: [
                    "notes": try authoringValue(chapter.notes, encoder: encoder),
                    "headSilenceOverride": try authoringValue(chapter.headSilenceOverride, encoder: encoder),
                    "tailSilenceOverride": try authoringValue(chapter.tailSilenceOverride, encoder: encoder)
                ]
            )
            result.append(try snapshot(id: chapter.id, kind: "chapter", value: chapterPayload, fields: ["ordinal", "title", "role", "headGapFrames", "tailGapFrames", "notes"]))

            for paragraph in chapter.paragraphs {
                let payload = AuthoringParagraph(
                    id: paragraph.id,
                    projectId: project.id,
                    chapterId: chapter.id,
                    ordinal: UInt32(max(0, paragraph.ordinal)),
                    text: paragraph.text,
                    textSha256: paragraph.textHash,
                    direction: paragraph.directionNote,
                    sourceRange: nil,
                    pronunciationIds: paragraph.pronunciationRefs,
                    selectedTakeId: paragraph.selectedTakeID,
                    selectionRevision: "\(paragraph.textHash):\(paragraph.selectedTakeID?.uuidString ?? "none")",
                    extensions: [
                        "role": .string(paragraph.role.rawValue),
                        "reviewState": .string(paragraph.reviewState.rawValue),
                        "sourceRange": try authoringValue(paragraph.sourceRange, encoder: encoder),
                        "isSceneBreak": .bool(paragraph.isSceneBreak),
                        "updatedAt": try authoringValue(paragraph.updatedAt, encoder: encoder)
                    ]
                )
                result.append(try snapshot(id: paragraph.id, kind: "paragraph", value: payload, fields: ["ordinal", "text", "textSha256", "direction", "sourceRange", "pronunciationIds", "selectedTakeId", "reviewState"]))
            }
        }
        return result
    }

    public static func deletionRecords(for project: AudiobookProject) -> [AuthoringEntitySnapshot] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var ids = [(project.id, "project")]
        for chapter in project.chapters {
            ids.append((chapter.id, "chapter"))
            ids.append(contentsOf: chapter.paragraphs.map { ($0.id, "paragraph") })
        }
        return ids.map { id, kind in
            let payload = AuthoringDeletion(entityId: id, projectId: project.id, entityKind: kind)
            return AuthoringEntitySnapshot(
                id: id,
                kind: "tombstone_\(kind)",
                payload: (try? encoder.encode(payload)) ?? Data("{}".utf8),
                changedFields: ["deleted"]
            )
        }
    }

    public static func deletionRecordsForRemovedChildren(
        in storedEntities: [AuthoringStoredEntity], desiredSnapshots: [AuthoringEntitySnapshot]
    ) -> [AuthoringEntitySnapshot] {
        let desiredIDs = Set(desiredSnapshots.map(\.id))
        let activeProjectIDs = Set(desiredSnapshots.filter { $0.kind == "project" }.map(\.id))
        let decoder = JSONDecoder()
        return storedEntities.compactMap { entity in
            guard !entity.isTombstoned,
                  ["chapter", "paragraph"].contains(entity.kind),
                  !desiredIDs.contains(entity.id) else { return nil }
            let projectID: UUID?
            switch entity.kind {
            case "chapter": projectID = (try? decoder.decode(AuthoringChapter.self, from: entity.payload))?.projectId
            case "paragraph": projectID = (try? decoder.decode(AuthoringParagraph.self, from: entity.payload))?.projectId
            default: projectID = nil
            }
            guard let projectID, activeProjectIDs.contains(projectID) else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let deletion = AuthoringDeletion(entityId: entity.id, projectId: projectID, entityKind: entity.kind)
            return AuthoringEntitySnapshot(
                id: entity.id,
                kind: "tombstone_\(entity.kind)",
                payload: (try? encoder.encode(deletion)) ?? Data("{}".utf8),
                changedFields: ["deleted"]
            )
        }
    }

    /// Applies v2 entities over existing local projects. Local takes and selected
    /// audio remain intact; a remote selected-take pointer is accepted only when
    /// the corresponding audio asset is already present on this device.
    public static func applying(
        _ entities: [AuthoringStoredEntity], to localProjects: [AudiobookProject]
    ) throws -> AuthoringProjectMergeResult {
        let live = entities.filter { !$0.isTombstoned }
        let tombstones = live.filter { $0.kind.hasPrefix("tombstone_") }
        let deletedProjectIDs = Set(tombstones.filter { $0.kind == "tombstone_project" }.map(\.id))
        let deletedChapterIDs = Set(tombstones.filter { $0.kind == "tombstone_chapter" }.map(\.id))
        let existingByID = Dictionary(uniqueKeysWithValues: localProjects.map { ($0.id, $0) })
        let decoder = JSONDecoder()
        var projectWires: [UUID: AuthoringProject] = [:]
        var chapterWires: [UUID: AuthoringChapter] = [:]
        var paragraphWires: [UUID: AuthoringParagraph] = [:]

        for entity in live {
            switch entity.kind {
            case "project": projectWires[entity.id] = try decoder.decode(AuthoringProject.self, from: entity.payload)
            case "chapter":
                guard !deletedChapterIDs.contains(entity.id) else { continue }
                chapterWires[entity.id] = try decoder.decode(AuthoringChapter.self, from: entity.payload)
            case "paragraph": paragraphWires[entity.id] = try decoder.decode(AuthoringParagraph.self, from: entity.payload)
            default: continue
            }
        }

        var result: [UUID: AudiobookProject] = [:]
        for (id, wire) in projectWires {
            let metadataData = try JSONEncoder().encode(AuthoringValue.object(wire.metadata))
            var metadata = try decoder.decode(BookMetadata.self, from: metadataData)
            metadata.title = wire.title
            var project = existingByID[id] ?? AudiobookProject(id: id, metadata: metadata)
            project.metadata = metadata
            // The remote metadata intentionally omits a local cover asset ref.
            project.metadata.coverRef = existingByID[id]?.metadata.coverRef
            project.rights = try decodeExtension("rights", from: wire.extensions, as: RightsEvidence.self, fallback: project.rights)
            var profile = try decodeExtension("profile", from: wire.extensions, as: ProductionProfile.self, fallback: project.profile)
            profile.recording.inputDeviceUID = project.profile.recording.inputDeviceUID
            profile.recording.monitoringDeviceUID = project.profile.recording.monitoringDeviceUID
            profile.recording.monitoringEnabled = project.profile.recording.monitoringEnabled
            project.profile = profile
            project.pronunciations = try decodeExtension("pronunciations", from: wire.extensions, as: [PronunciationNote].self, fallback: project.pronunciations)
            project.createdAt = try decodeExtension("createdAt", from: wire.extensions, as: Date.self, fallback: project.createdAt)
            project.modifiedAt = parseISO8601(wire.modifiedAt) ?? project.modifiedAt
            if case .integer(let schemaVersion)? = wire.extensions["schemaVersion"] { project.schemaVersion = Int(schemaVersion) }
            result[id] = project
        }

        for id in Array(result.keys) {
            guard var project = result[id] else { continue }
            let previous = existingByID[id]
            project.source = previous?.source
            var oldParagraphs: [UUID: Paragraph] = [:]
            for paragraph in previous?.allParagraphs ?? [] { oldParagraphs[paragraph.id] = paragraph }
            let projectChapters = chapterWires.values.filter { $0.projectId == id }.sorted { $0.ordinal < $1.ordinal }
            var chapters: [ProductionChapter] = []
            for chapterWire in projectChapters {
                let oldChapter = previous?.chapters.first(where: { $0.id == chapterWire.id })
                let paraWires = paragraphWires.values.filter { $0.projectId == id && $0.chapterId == chapterWire.id }.sorted { $0.ordinal < $1.ordinal }
                let paragraphs = try paraWires.map { wire in
                    try apply(wire, preserving: oldParagraphs[wire.id], decoder: decoder)
                }
                let head = try decodeOptionalExtension("headSilenceOverride", from: chapterWire.extensions, as: TimeInterval.self, fallback: oldChapter?.headSilenceOverride)
                let tail = try decodeOptionalExtension("tailSilenceOverride", from: chapterWire.extensions, as: TimeInterval.self, fallback: oldChapter?.tailSilenceOverride)
                let notes = try decodeOptionalExtension("notes", from: chapterWire.extensions, as: String.self, fallback: oldChapter?.notes)
                chapters.append(ProductionChapter(
                    id: chapterWire.id,
                    ordinal: Int(chapterWire.ordinal),
                    title: chapterWire.title,
                    role: ChapterRole(rawValue: chapterWire.role) ?? oldChapter?.role ?? .body,
                    paragraphs: paragraphs,
                    headSilenceOverride: head,
                    tailSilenceOverride: tail,
                    notes: notes
                ))
            }
            // A partial v2 zone must not erase local chapters. Once all records
            // are present, the complete chapter set is supplied by the zone.
            if !projectChapters.isEmpty || previous == nil || project.chapters.contains(where: { deletedChapterIDs.contains($0.id) }) {
                project.chapters = chapters
            }
            result[id] = project
        }
        for id in deletedProjectIDs { result.removeValue(forKey: id) }
        return AuthoringProjectMergeResult(
            projects: result.values.sorted { $0.modifiedAt > $1.modifiedAt },
            deletedProjectIDs: deletedProjectIDs
        )
    }

    private static func apply(_ wire: AuthoringParagraph, preserving local: Paragraph?, decoder: JSONDecoder) throws -> Paragraph {
        let role = wire.extensions["role"].flatMap(stringValue).flatMap(ParagraphRole.init(rawValue:)) ?? local?.role ?? .body
        let review = wire.extensions["reviewState"].flatMap(stringValue).flatMap(ReviewState.init(rawValue:)) ?? local?.reviewState ?? .unreviewed
        let sourceRange = try decodeOptionalExtension("sourceRange", from: wire.extensions, as: SourceRange.self, fallback: local?.sourceRange)
        let updatedAt = try decodeExtension("updatedAt", from: wire.extensions, as: Date.self, fallback: local?.updatedAt ?? .distantPast)
        let localTakes = local?.takes ?? []
        let selectedTake = wire.selectedTakeId.flatMap { id in localTakes.contains(where: { $0.id == id }) ? id : nil }
            ?? local?.selectedTakeID
        let isSceneBreak: Bool
        if case .bool(let value)? = wire.extensions["isSceneBreak"] { isSceneBreak = value }
        else { isSceneBreak = local?.isSceneBreak ?? false }
        return Paragraph(
            id: wire.id,
            ordinal: Int(wire.ordinal),
            text: wire.text,
            textHash: wire.textSha256,
            role: role,
            directionNote: wire.direction,
            pronunciationRefs: wire.pronunciationIds,
            takes: localTakes,
            selectedTakeID: selectedTake,
            reviewState: review,
            sourceRange: sourceRange,
            isSceneBreak: isSceneBreak,
            updatedAt: updatedAt
        )
    }

    private static func snapshot<Value: Encodable>(id: UUID, kind: String, value: Value, fields: [String]) throws -> AuthoringEntitySnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AuthoringEntitySnapshot(id: id, kind: kind, payload: try encoder.encode(value), changedFields: fields)
    }

    private static func authoringValue<Value: Encodable>(_ value: Value, encoder: JSONEncoder) throws -> AuthoringValue {
        try JSONDecoder().decode(AuthoringValue.self, from: encoder.encode(value))
    }

    private static func frames(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds * 48_000).rounded())
    }

    private static func decodeExtension<Value: Decodable>(_ key: String, from extensions: [String: AuthoringValue], as type: Value.Type, fallback: Value) throws -> Value {
        guard let value = extensions[key], value != .null else { return fallback }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private static func decodeOptionalExtension<Value: Decodable>(_ key: String, from extensions: [String: AuthoringValue], as type: Value.Type, fallback: Value?) throws -> Value? {
        guard let value = extensions[key] else { return fallback }
        if value == .null { return nil }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private static func stringValue(_ value: AuthoringValue) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    public enum BridgeError: Error { case invalidMetadata }
}

private struct AuthoringDeletion: Codable {
    var entityId: UUID
    var projectId: UUID
    var entityKind: String
}

public struct AuthoringProjectMergeResult: Sendable, Equatable {
    public var projects: [AudiobookProject]
    public var deletedProjectIDs: Set<UUID>

    public init(projects: [AudiobookProject], deletedProjectIDs: Set<UUID>) {
        self.projects = projects; self.deletedProjectIDs = deletedProjectIDs
    }
}

public struct AuthoringEntitySnapshot: Sendable, Equatable {
    public var id: UUID
    public var kind: String
    public var payload: Data
    public var changedFields: [String]

    public init(id: UUID, kind: String, payload: Data, changedFields: [String]) {
        self.id = id; self.kind = kind; self.payload = payload; self.changedFields = changedFields
    }
}
