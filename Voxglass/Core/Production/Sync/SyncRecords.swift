import Foundation

// MARK: - Record vocabulary

/// CloudKit record types in the production zone (spec §5). Kept in Core as the
/// shared vocabulary between the iPhone writer and the watch companion.
public enum ProductionRecordType: String, Sendable, Equatable {
    case project = "VGProductionProject"
    case chapter = "VGProductionChapter"
    case paragraph = "VGProductionParagraph"
    case event = "VGReviewEvent"

    public static func recordName(prefix: String, id: UUID) -> String {
        "\(prefix)-\(id.uuidString)"
    }
}

/// Field names for each record type (spec §13.2).
public enum ProductionField {
    // Project
    public static let projectID = "projectID"
    public static let title = "title"
    public static let author = "author"
    public static let narrator = "narrator"
    public static let language = "language"
    public static let purpose = "purpose"
    public static let percentRecorded = "percentRecorded"
    public static let recordedCount = "recordedCount"
    public static let totalCount = "totalCount"
    public static let flaggedCount = "flaggedCount"
    public static let needsPickupCount = "needsPickupCount"
    public static let unapprovedCount = "unapprovedCount"
    public static let revision = "revision"
    public static let isHidden = "isHidden"
    public static let modifiedAt = "modifiedAt"
    public static let narrationOrigin = "narrationOrigin"
    public static let intendedDestination = "intendedDestination"
    public static let pinnedIDs = "pinnedIDs"
    // Chapter
    public static let chapterID = "chapterID"
    public static let ordinal = "ordinal"
    public static let role = "role"
    public static let paragraphCount = "paragraphCount"
    public static let duration = "duration"
    // Paragraph
    public static let paragraphID = "paragraphID"
    public static let globalOrdinal = "globalOrdinal"
    public static let text = "text"
    public static let reviewState = "reviewState"
    public static let takeID = "takeID"
    public static let proxySHA = "proxySHA"
    public static let latestNoteText = "latestNoteText"
    public static let latestNoteTag = "latestNoteTag"
    public static let originKind = "originKind"
    // Event
    public static let eventID = "eventID"
    public static let type = "type"
    public static let noteText = "noteText"
    public static let tag = "tag"
    public static let device = "device"
    public static let createdAt = "createdAt"
}

// MARK: - SyncFieldValue

/// A typed, CloudKit-agnostic record field value. Absence of a key means nil.
public enum SyncFieldValue: Codable, Sendable, Equatable {
    case string(String)
    case int64(Int64)
    case double(Double)
    case date(Date)
    case stringList([String])

    public func stringValue() -> String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public func int64Value() -> Int64? {
        if case let .int64(value) = self { return value }
        return nil
    }
}

// MARK: - SyncRecord

/// One CloudKit record in the production zone, decoded into a value type so the
/// engine, its tests, and both app transports share one shape. `parentName` is the
/// record name of the parent (chapter's parent is the project, paragraph's parent
/// is the chapter). `recordChangeTag` mirrors `CKRecord.recordChangeTag` and is set
/// only on a server-record conflict retry. `assetFields` carries downloaded proxy
/// audio (phone side) keyed by the field name that holds the `CKAsset`.
public struct SyncRecord: Codable, Sendable, Equatable {
    public var recordType: String
    public var recordName: String
    public var parentName: String?
    public var fields: [String: SyncFieldValue]
    public var recordChangeTag: String?
    public var assetFields: [String: Data]

    public init(
        recordType: String,
        recordName: String,
        parentName: String? = nil,
        fields: [String: SyncFieldValue] = [:],
        recordChangeTag: String? = nil,
        assetFields: [String: Data] = [:]
    ) {
        self.recordType = recordType
        self.recordName = recordName
        self.parentName = parentName
        self.fields = fields
        self.recordChangeTag = recordChangeTag
        self.assetFields = assetFields
    }
}

/// The field a `CKAsset` proxy is carried under; mirrors `proxySHA` for change
/// detection (spec §13.2).
public enum ProductionAssetField {
    public static let proxy = "proxyAsset"
}

// MARK: - ProjectionRecordCodec

/// Encodes/decodes `SyncProjection` and `ReviewEvent` to/from `SyncRecord`
/// (spec §13.2 field tables). Pure and exhaustively round-trip tested.
public struct ProjectionRecordCodec: Sendable {

    public init() {}

    // MARK: Projection → records

    public func records(from projection: SyncProjection) -> [SyncRecord] {
        let projectName = ProductionRecordType.recordName(prefix: "project", id: projection.project.id)

        let projectRecord = SyncRecord(
            recordType: ProductionRecordType.project.rawValue,
            recordName: projectName,
            fields: projectFields(projection)
        )

        var records = [projectRecord]
        for chapter in projection.chapters {
            records.append(SyncRecord(
                recordType: ProductionRecordType.chapter.rawValue,
                recordName: ProductionRecordType.recordName(prefix: "chapter", id: chapter.id),
                parentName: projectName,
                fields: chapterFields(chapter)
            ))
        }
        for paragraph in projection.paragraphs {
            records.append(SyncRecord(
                recordType: ProductionRecordType.paragraph.rawValue,
                recordName: ProductionRecordType.recordName(prefix: "para", id: paragraph.id),
                parentName: ProductionRecordType.recordName(prefix: "chapter", id: paragraph.chapterID),
                fields: paragraphFields(paragraph)
            ))
        }
        return records
    }

    private func projectFields(_ projection: SyncProjection) -> [String: SyncFieldValue] {
        let summary = projection.project
        var fields: [String: SyncFieldValue] = [
            ProductionField.projectID: .string(summary.id.uuidString),
            ProductionField.title: .string(summary.title),
            ProductionField.author: .string(summary.author),
            ProductionField.narrator: .string(summary.narrator),
            ProductionField.language: .string(""),
            ProductionField.purpose: .string(summary.purpose.rawValue),
            ProductionField.percentRecorded: .double(summary.percentRecorded),
            ProductionField.recordedCount: .int64(Int64(summary.recordedCount)),
            ProductionField.totalCount: .int64(Int64(summary.totalCount)),
            ProductionField.flaggedCount: .int64(Int64(summary.flaggedCount)),
            ProductionField.needsPickupCount: .int64(Int64(summary.needsPickupCount)),
            ProductionField.unapprovedCount: .int64(Int64(summary.unapprovedCount)),
            ProductionField.revision: .int64(Int64(projection.revision)),
            ProductionField.isHidden: .int64(summary.isHiddenFromDevices ? 1 : 0),
            ProductionField.modifiedAt: .date(summary.modifiedAt),
            ProductionField.narrationOrigin: .string(projection.narrationOrigin.rawValue),
            ProductionField.intendedDestination: .string("")
        ]
        if !projection.watchPinnedParagraphIDs.isEmpty {
            fields[ProductionField.pinnedIDs] = .stringList(projection.watchPinnedParagraphIDs.map(\.uuidString))
        }
        return fields
    }

    private func chapterFields(_ chapter: ChapterProjection) -> [String: SyncFieldValue] {
        [
            ProductionField.chapterID: .string(chapter.id.uuidString),
            ProductionField.projectID: .string(chapter.projectID.uuidString),
            ProductionField.ordinal: .int64(Int64(chapter.ordinal)),
            ProductionField.title: .string(chapter.title),
            ProductionField.role: .string(chapter.role.rawValue),
            ProductionField.paragraphCount: .int64(Int64(chapter.paragraphCount)),
            ProductionField.recordedCount: .int64(Int64(chapter.recordedCount)),
            ProductionField.duration: .double(chapter.duration)
        ]
    }

    private func paragraphFields(_ paragraph: ParagraphProjection) -> [String: SyncFieldValue] {
        var fields: [String: SyncFieldValue] = [
            ProductionField.paragraphID: .string(paragraph.id.uuidString),
            ProductionField.chapterID: .string(paragraph.chapterID.uuidString),
            ProductionField.projectID: .string(paragraph.projectID.uuidString),
            ProductionField.ordinal: .int64(Int64(paragraph.ordinal)),
            ProductionField.globalOrdinal: .int64(Int64(paragraph.globalOrdinal)),
            ProductionField.reviewState: .string(paragraph.reviewState.rawValue),
            ProductionField.duration: .double(paragraph.duration),
            ProductionField.originKind: .string(paragraph.originKind)
        ]
        if let text = paragraph.text { fields[ProductionField.text] = .string(text) }
        if let takeID = paragraph.takeID { fields[ProductionField.takeID] = .string(takeID.uuidString) }
        if let sha = paragraph.proxySourceSHA { fields[ProductionField.proxySHA] = .string(sha) }
        if let note = paragraph.latestNoteText { fields[ProductionField.latestNoteText] = .string(note) }
        if let tag = paragraph.latestNoteTag { fields[ProductionField.latestNoteTag] = .string(tag.rawValue) }
        return fields
    }

    public func eventRecord(from event: ReviewEvent) -> SyncRecord {
        var fields: [String: SyncFieldValue] = [
            ProductionField.eventID: .string(event.id.uuidString),
            ProductionField.projectID: .string(event.projectID.uuidString),
            ProductionField.paragraphID: .string(event.paragraphID.uuidString),
            ProductionField.type: .string(event.type.rawValue),
            ProductionField.device: .string(event.device.rawValue),
            ProductionField.createdAt: .date(event.createdAt)
        ]
        if let note = event.noteText { fields[ProductionField.noteText] = .string(note) }
        if let tag = event.tag { fields[ProductionField.tag] = .string(tag.rawValue) }
        return SyncRecord(
            recordType: ProductionRecordType.event.rawValue,
            recordName: ProductionRecordType.recordName(prefix: "event", id: event.id),
            fields: fields
        )
    }

    // MARK: Records → projection

    /// Reassembles a projection from fetched records. Returns `nil` when the project
    /// record is missing. Paragraph records not backed by a project record are
    /// ignored, so an incomplete fetch degrades gracefully.
    public func projection(from records: [SyncRecord]) -> SyncProjection? {
        guard let projectRecord = records.first(where: { $0.recordType == ProductionRecordType.project.rawValue }) else {
            return nil
        }
        guard let summary = projectSummary(from: projectRecord) else { return nil }

        let chapters = records
            .filter { $0.recordType == ProductionRecordType.chapter.rawValue }
            .sorted { ($0.fields[ProductionField.ordinal]?.int64Value() ?? 0) < ($1.fields[ProductionField.ordinal]?.int64Value() ?? 0) }
            .compactMap(chapterProjection(from:))

        let paragraphs = records
            .filter { $0.recordType == ProductionRecordType.paragraph.rawValue }
            .compactMap { paragraphProjection(from: $0, projectID: summary.id) }
            .sorted { $0.globalOrdinal < $1.globalOrdinal }

        let revision = projectRecord.fields[ProductionField.revision]?.int64Value().map(Int.init) ?? 0
        let origin = projectRecord.fields[ProductionField.narrationOrigin]?.stringValue()
            .flatMap(NarrationOrigin.init(rawValue:)) ?? .humanOnly
        let pinned = projectRecord.fields[ProductionField.pinnedIDs]?.stringListValue().compactMap(UUID.init(uuidString:)) ?? []

        return SyncProjection(
            project: summary,
            chapters: chapters,
            paragraphs: paragraphs,
            revision: revision,
            narrationOrigin: origin,
            watchPinnedParagraphIDs: pinned
        )
    }

    private func projectSummary(from record: SyncRecord) -> ProjectSummary? {
        let f = record.fields
        guard let idString = f[ProductionField.projectID]?.stringValue(),
              let id = UUID(uuidString: idString) else { return nil }
        let hidden = (f[ProductionField.isHidden]?.int64Value() ?? 0) != 0
        return ProjectSummary(
            id: id,
            title: f[ProductionField.title]?.stringValue() ?? "",
            author: f[ProductionField.author]?.stringValue() ?? "",
            narrator: f[ProductionField.narrator]?.stringValue() ?? "",
            percentRecorded: f[ProductionField.percentRecorded]?.doubleValue() ?? 0,
            recordedCount: Int(f[ProductionField.recordedCount]?.int64Value() ?? 0),
            totalCount: Int(f[ProductionField.totalCount]?.int64Value() ?? 0),
            flaggedCount: Int(f[ProductionField.flaggedCount]?.int64Value() ?? 0),
            needsPickupCount: Int(f[ProductionField.needsPickupCount]?.int64Value() ?? 0),
            unapprovedCount: Int(f[ProductionField.unapprovedCount]?.int64Value() ?? 0),
            readyToExport: false,
            purpose: f[ProductionField.purpose]?.stringValue().flatMap(ProjectPurpose.init(rawValue:)) ?? .personal,
            modifiedAt: f[ProductionField.modifiedAt]?.dateValue() ?? Date(timeIntervalSince1970: 0),
            coverRef: nil,
            isHiddenFromDevices: hidden,
            projectionRevision: Int(f[ProductionField.revision]?.int64Value() ?? 0)
        )
    }

    private func chapterProjection(from record: SyncRecord) -> ChapterProjection? {
        let f = record.fields
        guard let id = f[ProductionField.chapterID]?.stringValue().flatMap(UUID.init(uuidString:)),
              let projectID = f[ProductionField.projectID]?.stringValue().flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return ChapterProjection(
            id: id,
            projectID: projectID,
            ordinal: Int(f[ProductionField.ordinal]?.int64Value() ?? 0),
            title: f[ProductionField.title]?.stringValue() ?? "",
            role: f[ProductionField.role]?.stringValue().flatMap(ChapterRole.init(rawValue:)) ?? .body,
            paragraphCount: Int(f[ProductionField.paragraphCount]?.int64Value() ?? 0),
            recordedCount: Int(f[ProductionField.recordedCount]?.int64Value() ?? 0),
            duration: f[ProductionField.duration]?.doubleValue() ?? 0
        )
    }

    private func paragraphProjection(from record: SyncRecord, projectID: UUID) -> ParagraphProjection? {
        let f = record.fields
        guard let id = f[ProductionField.paragraphID]?.stringValue().flatMap(UUID.init(uuidString:)),
              let chapterID = f[ProductionField.chapterID]?.stringValue().flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return ParagraphProjection(
            id: id,
            chapterID: chapterID,
            projectID: projectID,
            ordinal: Int(f[ProductionField.ordinal]?.int64Value() ?? 0),
            globalOrdinal: Int(f[ProductionField.globalOrdinal]?.int64Value() ?? 0),
            text: f[ProductionField.text]?.stringValue(),
            reviewState: f[ProductionField.reviewState]?.stringValue().flatMap(ReviewState.init(rawValue:)) ?? .unreviewed,
            takeID: f[ProductionField.takeID]?.stringValue().flatMap(UUID.init(uuidString:)),
            duration: f[ProductionField.duration]?.doubleValue() ?? 0,
            proxySourceSHA: f[ProductionField.proxySHA]?.stringValue(),
            latestNoteText: f[ProductionField.latestNoteText]?.stringValue(),
            latestNoteTag: f[ProductionField.latestNoteTag]?.stringValue().flatMap(ReviewTag.init(rawValue:)),
            originKind: f[ProductionField.originKind]?.stringValue() ?? "none"
        )
    }

    public func event(from record: SyncRecord) -> ReviewEvent? {
        guard record.recordType == ProductionRecordType.event.rawValue else { return nil }
        let f = record.fields
        guard let id = f[ProductionField.eventID]?.stringValue().flatMap(UUID.init(uuidString:)),
              let projectID = f[ProductionField.projectID]?.stringValue().flatMap(UUID.init(uuidString:)),
              let paragraphID = f[ProductionField.paragraphID]?.stringValue().flatMap(UUID.init(uuidString:)),
              let type = f[ProductionField.type]?.stringValue().flatMap(ReviewEventType.init(rawValue:)),
              let device = f[ProductionField.device]?.stringValue().flatMap(DeviceKind.init(rawValue:)) else {
            return nil
        }
        return ReviewEvent(
            id: id,
            projectID: projectID,
            paragraphID: paragraphID,
            type: type,
            noteText: f[ProductionField.noteText]?.stringValue(),
            tag: f[ProductionField.tag]?.stringValue().flatMap(ReviewTag.init(rawValue:)),
            device: device,
            createdAt: f[ProductionField.createdAt]?.dateValue() ?? Date(timeIntervalSince1970: 0),
            appliedAt: nil,
            origin: .cloud
        )
    }
}

extension SyncFieldValue {
    fileprivate func doubleValue() -> Double? {
        if case let .double(value) = self { return value }
        return nil
    }

    fileprivate func dateValue() -> Date? {
        if case let .date(value) = self { return value }
        return nil
    }

    fileprivate func stringListValue() -> [String] {
        if case let .stringList(value) = self { return value }
        return []
    }
}

// MARK: - ProjectionDiff

/// Delta between the last published projection snapshot and the next one
/// (spec §13.5: "Delta only"). A single re-recorded paragraph must produce exactly
/// one paragraph record modification, not a full republish.
public struct ProjectionDiff: Sendable {

    public enum Kind: String, Sendable, Equatable {
        case upsert
        case delete
    }

    public struct Change: Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var recordType: String
        public var recordName: String
        public var fields: [String: SyncFieldValue]
        /// True when this paragraph's proxy audio changed and a new asset upload is
        /// required (spec §13.5: ≤ 20 assets per operation).
        public var proxyNeeded: Bool

        public var id: String { recordName }

        public init(
            kind: Kind,
            recordType: String,
            recordName: String,
            fields: [String: SyncFieldValue] = [:],
            proxyNeeded: Bool = false
        ) {
            self.kind = kind
            self.recordType = recordType
            self.recordName = recordName
            self.fields = fields
            self.proxyNeeded = proxyNeeded
        }
    }

    public init() {}

    public static func diff(old: SyncProjection?, new: SyncProjection) -> [Change] {
        let oldRecords = old.map { ProjectionRecordCodec().records(from: $0) } ?? []
        let newRecords = ProjectionRecordCodec().records(from: new)

        var byName: [String: SyncRecord] = [:]
        for record in oldRecords { byName[record.recordName] = record }

        var changes: [Change] = []

        for record in newRecords {
            if let existing = byName[record.recordName] {
                byName[record.recordName] = nil
                if existing.fields != record.fields {
                    changes.append(.init(
                        kind: .upsert,
                        recordType: record.recordType,
                        recordName: record.recordName,
                        fields: record.fields,
                        proxyNeeded: proxyChanged(existing: existing, new: record)
                    ))
                }
            } else {
                changes.append(.init(
                    kind: .upsert,
                    recordType: record.recordType,
                    recordName: record.recordName,
                    fields: record.fields,
                    proxyNeeded: isParagraph(record) && record.fields[ProductionField.proxySHA] != nil
                ))
            }
        }

        // Records present in the old snapshot but gone from the new one are deletes.
        for (recordName, record) in byName {
            changes.append(.init(
                kind: .delete,
                recordType: record.recordType,
                recordName: recordName,
                fields: record.fields,
                proxyNeeded: false
            ))
        }

        return changes.sorted {
            if $0.recordType != $1.recordType {
                return $0.recordType < $1.recordType
            }
            return $0.recordName < $1.recordName
        }
    }

    private static func proxyChanged(existing: SyncRecord, new: SyncRecord) -> Bool {
        guard isParagraph(new) else { return false }
        let oldSHA = existing.fields[ProductionField.proxySHA]?.stringValue()
        let newSHA = new.fields[ProductionField.proxySHA]?.stringValue()
        return oldSHA != newSHA
    }

    private static func isParagraph(_ record: SyncRecord) -> Bool {
        record.recordType == ProductionRecordType.paragraph.rawValue
    }
}
