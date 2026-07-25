import Foundation
import CloudKit
import Compression
import CryptoKit

public enum CloudKitRecordMapper {
    public enum RecordType: String {
        case source = "Source"
        case book = "Book"
        case playbackPosition = "PlaybackPosition"
        case bookmark = "Bookmark"
    }

    public enum Field {
        public static let kind = "kind"
        public static let title = "title"
        public static let url = "url"
        public static let createdAt = "createdAt"
        public static let updatedAt = "updatedAt"
        public static let authorsJSON = "authorsJSON"
        public static let narratorsJSON = "narratorsJSON"
        public static let summary = "summary"
        public static let sourceRef = "sourceRef"
        public static let coverURL = "coverURL"
        public static let isFavorite = "isFavorite"
        public static let contentKey = "contentKey"
        public static let chaptersData = "chaptersData"
        public static let bookRef = "bookRef"
        public static let chapterID = "chapterID"
        public static let positionSeconds = "positionSeconds"
        public static let durationSeconds = "durationSeconds"
        public static let isFinished = "isFinished"
        public static let note = "note"
        public static let isDeleted = "isDeleted"
    }

    public static let libraryZoneName = "Library"

    // MARK: - Record names

    public static func sourceRecordName(sourceURL: URL?, kind: SourceKind) -> String? {
        let identity: String
        switch kind {
        case .librivox, .internetArchive, .internetArchiveURL:
            guard let url = sourceURL,
                  let detailsIndex = url.pathComponents.firstIndex(of: "details"),
                  url.pathComponents.indices.contains(detailsIndex + 1) else { return nil }
            identity = url.pathComponents[detailsIndex + 1]
        case .localFiles:
            guard let url = sourceURL else { return nil }
            identity = sha256First12(url.absoluteString)
        }
        return "source-\(identity)"
    }

    public static func bookRecordName(contentKey: String) -> String {
        "book-\(sha256First12(contentKey))"
    }

    public static func positionRecordName(positionID: UUID) -> String {
        "pos-\(positionID.uuidString)"
    }

    public static func bookmarkRecordName(bookmarkID: UUID) -> String {
        "bm-\(bookmarkID.uuidString)"
    }

    // MARK: - Source <-> CKRecord

    public static func sourceRecord(from source: Source, sourceKey: String) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: "source-\(sourceKey)",
            zoneID: libraryZoneID
        )
        let record = CKRecord(recordType: RecordType.source.rawValue, recordID: recordID)
        record[Field.kind] = source.kind.rawValue
        record[Field.title] = source.title
        record[Field.url] = source.url?.absoluteString
        record[Field.createdAt] = source.createdAt
        return record
    }

    public static func sourceIdentity(from recordID: CKRecord.ID) -> String? {
        let name = recordID.recordName
        guard name.hasPrefix("source-") else { return nil }
        return String(name.dropFirst(7))
    }

    public static func sourceIdentity(from sourceRef: CKRecord.Reference) -> String? {
        sourceIdentity(from: sourceRef.recordID)
    }

    public static func stableUUID(from identity: String) -> UUID {
        let hash = SHA256.hash(data: Data(identity.utf8))
        return hash.withUnsafeBytes { ptr in
            UUID(uuid: (ptr[0], ptr[1], ptr[2], ptr[3], ptr[4], ptr[5], ptr[6], ptr[7],
                        ptr[8], ptr[9], ptr[10], ptr[11], ptr[12], ptr[13], ptr[14], ptr[15]))
        }
    }

    public static func source(from record: CKRecord) -> Source? {
        guard let kindRaw = record[Field.kind] as? String,
              let kind = SourceKind(rawValue: kindRaw),
              let title = record[Field.title] as? String else { return nil }
        return Source(
            kind: kind,
            title: title,
            url: (record[Field.url] as? String).flatMap(URL.init(string:)),
            createdAt: (record[Field.createdAt] as? Date) ?? Date()
        )
    }

    // MARK: - Book <-> CKRecord

    public static func bookRecord(
        from book: Book,
        chapters: [Chapter],
        contentKey: String,
        sourceKey: String
    ) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: bookRecordName(contentKey: contentKey),
            zoneID: libraryZoneID
        )
        let record = CKRecord(recordType: RecordType.book.rawValue, recordID: recordID)

        record[Field.title] = book.title
        record[Field.authorsJSON] = ModelMapping.authorsJSON(book.authors)
        record[Field.narratorsJSON] = ModelMapping.narratorsJSON(book.narrators)
        record[Field.summary] = book.summary
        record[Field.coverURL] = book.coverURL?.absoluteString
        record[Field.createdAt] = book.createdAt
        record[Field.updatedAt] = book.updatedAt
        record[Field.isFavorite] = book.isFavorite ? 1 : 0
        record[Field.contentKey] = contentKey

        let sourceRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "source-\(sourceKey)", zoneID: libraryZoneID),
            action: .deleteSelf
        )
        record[Field.sourceRef] = sourceRef

        let strippedChapters = chapters.map { chapter -> Chapter in
            var c = chapter
            c.localURL = nil
            return c
        }
        if let encoded = try? JSONEncoder().encode(strippedChapters),
           let compressed = gzipCompress(encoded) {
            if compressed.count < 900_000 {
                record[Field.chaptersData] = compressed
            } else {
                let tempDir = FileManager.default.temporaryDirectory
                let assetFile = tempDir.appendingPathComponent("\(sha256First12(contentKey))-chapters.gz")
                try? compressed.write(to: assetFile)
                record[Field.chaptersData] = CKAsset(fileURL: assetFile)
            }
        }

        return record
    }

    public static func book(from record: CKRecord) -> Book? {
        guard let title = record[Field.title] as? String else { return nil }
        let authors = (record[Field.authorsJSON] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? ["Unknown"]
        let narrators = (record[Field.narratorsJSON] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let sourceID: UUID = {
            if let ref = record[Field.sourceRef] as? CKRecord.Reference,
               let identity = sourceIdentity(from: ref) {
                return stableUUID(from: identity)
            }
            return UUID()
        }()
        return Book(
            title: title,
            authors: authors,
            narrators: narrators,
            summary: record[Field.summary] as? String,
            sourceID: sourceID,
            coverURL: (record[Field.coverURL] as? String).flatMap(URL.init(string:)),
            createdAt: (record[Field.createdAt] as? Date) ?? Date(),
            updatedAt: (record[Field.updatedAt] as? Date) ?? Date(),
            isFavorite: (record[Field.isFavorite] as? Int) == 1
        )
    }

    public static func contentKey(from record: CKRecord) -> String? {
        record[Field.contentKey] as? String
    }

    public static func chaptersData(from record: CKRecord) throws -> [Chapter] {
        let data: Data
        if let asset = record[Field.chaptersData] as? CKAsset,
           let fileURL = asset.fileURL,
           let assetData = try? Data(contentsOf: fileURL) {
            data = assetData
        } else if let raw = record[Field.chaptersData] as? Data {
            data = raw
        } else {
            return []
        }
        guard let decompressed = gzipDecompress(data),
              let chapters = try? JSONDecoder().decode([Chapter].self, from: decompressed) else {
            return []
        }
        return chapters.map { chapter in
            var c = chapter
            c.localURL = nil
            return c
        }
    }

    // MARK: - PlaybackPosition <-> CKRecord

    public static func positionRecord(from position: PlaybackPosition, bookContentKey: String) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: positionRecordName(positionID: position.id),
            zoneID: libraryZoneID
        )
        let record = CKRecord(recordType: RecordType.playbackPosition.rawValue, recordID: recordID)
        record[Field.chapterID] = position.chapterID.uuidString
        record[Field.positionSeconds] = position.position
        record[Field.durationSeconds] = position.duration
        record[Field.updatedAt] = position.updatedAt
        record[Field.isFinished] = position.isFinished ? 1 : 0
        let bookRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: bookRecordName(contentKey: bookContentKey), zoneID: libraryZoneID),
            action: .deleteSelf
        )
        record[Field.bookRef] = bookRef
        return record
    }

    public static func position(from record: CKRecord) -> PlaybackPosition? {
        guard let chapterIDStr = record[Field.chapterID] as? String,
              let chapterID = UUID(uuidString: chapterIDStr) else { return nil }
        return PlaybackPosition(
            bookID: UUID(),
            chapterID: chapterID,
            position: record[Field.positionSeconds] as? Double ?? 0,
            duration: record[Field.durationSeconds] as? Double,
            updatedAt: (record[Field.updatedAt] as? Date) ?? Date(),
            isFinished: (record[Field.isFinished] as? Int) == 1
        )
    }

    // MARK: - Bookmark <-> CKRecord

    public static func bookmarkRecord(from bookmark: Bookmark, bookContentKey: String) -> CKRecord? {
        guard let id = bookmark.id else { return nil }
        let recordID = CKRecord.ID(
            recordName: bookmarkRecordName(bookmarkID: id),
            zoneID: libraryZoneID
        )
        let record = CKRecord(recordType: RecordType.bookmark.rawValue, recordID: recordID)
        record[Field.chapterID] = bookmark.chapterID.uuidString
        record[Field.positionSeconds] = bookmark.position
        record[Field.note] = bookmark.note
        record[Field.createdAt] = bookmark.createdAt
        record[Field.updatedAt] = bookmark.updatedAt
        record[Field.isDeleted] = bookmark.isDeleted ? 1 : 0
        let bookRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: bookRecordName(contentKey: bookContentKey), zoneID: libraryZoneID),
            action: .deleteSelf
        )
        record[Field.bookRef] = bookRef
        return record
    }

    public static func bookmark(from record: CKRecord) -> Bookmark? {
        guard let chapterIDStr = record[Field.chapterID] as? String,
              let chapterID = UUID(uuidString: chapterIDStr) else { return nil }
        let bookmarkID = record.recordID.recordName.hasPrefix("bm-")
            ? UUID(uuidString: String(record.recordID.recordName.dropFirst(3)))
            : UUID()
        return Bookmark(
            id: bookmarkID,
            bookID: UUID(),
            chapterID: chapterID,
            position: record[Field.positionSeconds] as? Double ?? 0,
            note: record[Field.note] as? String,
            createdAt: (record[Field.createdAt] as? Date) ?? Date(),
            updatedAt: (record[Field.updatedAt] as? Date) ?? Date(),
            isDeleted: (record[Field.isDeleted] as? Int) == 1
        )
    }

    // MARK: - Helpers

    public static var libraryZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: libraryZoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func sha256First12(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private static func gzipCompress(_ data: Data) -> Data? {
        data.withUnsafeBytes { sourcePtr in
            let sourceBuffer = sourcePtr.bindMemory(to: UInt8.self)
            let destCapacity = data.count + 64
            var destBuffer = [UInt8](repeating: 0, count: destCapacity)
            let compressedSize = compression_encode_buffer(
                &destBuffer, destCapacity,
                sourceBuffer.baseAddress!, sourceBuffer.count,
                nil, COMPRESSION_ZLIB
            )
            guard compressedSize > 0 else { return nil }
            return Data(destBuffer.prefix(compressedSize))
        }
    }

    private static func gzipDecompress(_ data: Data) -> Data? {
        data.withUnsafeBytes { sourcePtr in
            let sourceBuffer = sourcePtr.bindMemory(to: UInt8.self)
            let destCapacity = data.count * 10
            var destBuffer = [UInt8](repeating: 0, count: max(destCapacity, 1024))
            let decompressedSize = compression_decode_buffer(
                &destBuffer, destCapacity,
                sourceBuffer.baseAddress!, sourceBuffer.count,
                nil, COMPRESSION_ZLIB
            )
            guard decompressedSize > 0 else { return nil }
            return Data(destBuffer.prefix(decompressedSize))
        }
    }
}
