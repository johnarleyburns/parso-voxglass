import Foundation

public struct InternetArchiveSearchResult: Identifiable, Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var creators: [String]
    public var description: String?
    public var collections: [String]
    public var downloads: Int?
    public var date: String?
    public var languages: [String]
    public var subjects: [String]

    public var id: String { identifier }

    public init(
        identifier: String,
        title: String,
        creators: [String],
        description: String?,
        collections: [String],
        downloads: Int?,
        date: String?,
        languages: [String] = [],
        subjects: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.creators = creators
        self.description = description
        self.collections = collections
        self.downloads = downloads
        self.date = date
        self.languages = languages
        self.subjects = subjects
    }

    public var authorLine: String {
        creators.isEmpty ? "Unknown author" : creators.joined(separator: ", ")
    }

    /// Best-effort narrator names parsed from the item description. The search
    /// API does not expose a narrator field, so this may be empty.
    public var narrators: [String] {
        NarratorExtractor.extract(from: description)
    }

    public var narratorLine: String? {
        let names = narrators
        return names.isEmpty ? nil : "Read by \(names.joined(separator: ", "))"
    }

    public var sourceKind: SourceKind {
        collections.contains { $0.localizedCaseInsensitiveCompare("librivoxaudio") == .orderedSame }
            ? .librivox
            : .internetArchive
    }

    public var isStrictLibriVoxCatalogCandidate: Bool {
        collections.contains { $0.localizedCaseInsensitiveCompare("librivoxaudio") == .orderedSame }
            && !isLikelyGeneratedTTSAudio
    }

    private var isLikelyGeneratedTTSAudio: Bool {
        if collections.contains(where: { $0.localizedCaseInsensitiveCompare("audio_bookspoetry") == .orderedSame }),
           !collections.contains(where: { $0.localizedCaseInsensitiveCompare("librivoxaudio") == .orderedSame }) {
            return true
        }

        let haystack = ([identifier, title, description ?? ""]
            + creators
            + subjects
            + collections)
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("synapseml_gutenberg")
            || haystack.contains("project gutenberg tts")
            || haystack.contains("text-to-speech")
            || (haystack.contains("microsoft") && haystack.contains("tts"))
    }

    public var detailsURL: URL {
        InternetArchiveMetadata.detailsURL(for: identifier)
    }

    public var coverURL: URL {
        InternetArchiveMetadata.coverURL(for: identifier)
    }
}

/// A single page of advanced-search results plus the total match count,
/// enabling paginated "See More" loading in Explore.
public struct InternetArchivePage: Equatable, Sendable {
    public var results: [InternetArchiveSearchResult]
    public var numFound: Int
    public var page: Int
}

public struct InternetArchiveSearchResponse: Decodable, Equatable, Sendable {
    public var response: Response

    public var results: [InternetArchiveSearchResult] {
        response.docs.map(\.searchResult)
    }

    public var numFound: Int {
        response.numFound
    }

    public struct Response: Decodable, Equatable, Sendable {
        var docs: [InternetArchiveSearchDocument]
        var numFound: Int

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            docs = try container.decode([InternetArchiveSearchDocument].self, forKey: .docs)
            numFound = try container.decodeIfPresent(Int.self, forKey: .numFound) ?? docs.count
        }

        private enum CodingKeys: String, CodingKey {
            case docs
            case numFound
        }
    }
}

public struct InternetArchiveSearchDocument: Decodable, Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var creators: [String]
    public var description: String?
    public var collections: [String]
    public var downloads: Int?
    public var date: String?
    public var languages: [String]
    public var subjects: [String]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decodeFlexibleStringIfPresent(forKey: .title) ?? identifier
        creators = try container.decodeStringListIfPresent(forKey: .creator)
        description = try container.decodeFlexibleStringIfPresent(forKey: .description)
        collections = try container.decodeStringListIfPresent(forKey: .collection)
        downloads = try container.decodeFlexibleIntIfPresent(forKey: .downloads)
        date = try container.decodeFlexibleStringIfPresent(forKey: .date)
        languages = try container.decodeStringListIfPresent(forKey: .language)
        subjects = try container.decodeStringListIfPresent(forKey: .subject)
    }

    public var searchResult: InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: creators,
            description: description?.cleanedInternetArchiveText,
            collections: collections,
            downloads: downloads,
            date: date,
            languages: languages,
            subjects: subjects
        )
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case title
        case creator
        case description
        case collection
        case downloads
        case date
        case language
        case subject
    }
}

public struct InternetArchiveMetadata: Decodable, Equatable, Sendable {
    public var metadata: InternetArchiveItemMetadata
    public var files: [InternetArchiveFile]
    public var server: String?
    public var dir: String?

    public var identifier: String {
        metadata.identifier ?? ""
    }

    public var isCollection: Bool {
        metadata.mediatype == "collection"
    }

    public var sourceKind: SourceKind {
        metadata.collections.contains { $0.localizedCaseInsensitiveCompare("librivoxaudio") == .orderedSame }
            ? .librivox
            : .internetArchive
    }

    public var selectedAudioFiles: [InternetArchiveFile] {
        InternetArchiveAudioSelector.selectedAudioFiles(from: files)
    }

    public var title: String {
        metadata.title ?? identifier
    }

    public var creators: [String] {
        metadata.creators
    }

    public var summary: String? {
        metadata.description?.cleanedInternetArchiveText
    }

    public func fileURL(for file: InternetArchiveFile) -> URL? {
        guard !identifier.isEmpty else { return nil }
        let encodedIdentifier = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        let encodedName = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
        return URL(string: "https://archive.org/download/\(encodedIdentifier)/\(encodedName)")
    }

    public static func detailsURL(for identifier: String) -> URL {
        URL(string: "https://archive.org/details/\(identifier)")!
    }

    public static func coverURL(for identifier: String) -> URL {
        URL(string: "https://archive.org/services/img/\(identifier)?scale=2")!
    }

    public var coverImageFiles: [InternetArchiveFile] {
        files
            .filter { file in
                let name = file.name.lowercased()
                let fmt = (file.format ?? "").lowercased()
                let isImage = (name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png"))
                    && !file.isLikelyAudioVisualization
                let isImageFormat = fmt.hasPrefix("jpeg") || fmt == "png" || fmt == "jpeg thumb"
                return !file.isLikelyAudioVisualization && (isImage || isImageFormat)
            }
            .sorted { a, b in
                let aThumb = a.name.lowercased().contains("thumb")
                let bThumb = b.name.lowercased().contains("thumb")
                if aThumb != bThumb { return aThumb }
                let aSize = Int64(a.size ?? "0") ?? 0
                let bSize = Int64(b.size ?? "0") ?? 0
                return aSize > bSize
            }
    }
}

public struct InternetArchiveItemMetadata: Decodable, Equatable, Sendable {
    public var identifier: String?
    public var title: String?
    public var creators: [String]
    public var description: String?
    public var mediatype: String?
    public var collections: [String]
    public var subjects: [String]
    public var language: String?
    public var callNumber: String?

    public init(
        identifier: String? = nil,
        title: String? = nil,
        creators: [String] = [],
        description: String? = nil,
        mediatype: String? = nil,
        collections: [String] = [],
        subjects: [String] = [],
        language: String? = nil,
        callNumber: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.creators = creators
        self.description = description
        self.mediatype = mediatype
        self.collections = collections
        self.subjects = subjects
        self.language = language
        self.callNumber = callNumber
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeFlexibleStringIfPresent(forKey: .identifier)
        title = try container.decodeFlexibleStringIfPresent(forKey: .title)
        creators = try container.decodeStringListIfPresent(forKey: .creator)
        description = try container.decodeFlexibleStringIfPresent(forKey: .description)
        mediatype = try container.decodeFlexibleStringIfPresent(forKey: .mediatype)
        collections = try container.decodeStringListIfPresent(forKey: .collection)
        subjects = try container.decodeStringListIfPresent(forKey: .subject)
        language = try container.decodeFlexibleStringIfPresent(forKey: .language)
        callNumber = try container.decodeFlexibleStringIfPresent(forKey: .call_number)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case title
        case creator
        case description
        case mediatype
        case collection
        case subject
        case language
        case call_number
    }
}

public struct InternetArchiveFile: Decodable, Equatable, Sendable, Identifiable {
    public var name: String
    public var source: String?
    public var format: String?
    public var title: String?
    public var length: String?
    public var track: String?
    public var size: String?

    public var id: String { name }

    public var isLikelyAudioVisualization: Bool {
        let haystack = [
            name,
            source ?? "",
            format ?? "",
            title ?? ""
        ]
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("spectrogram")
            || haystack.contains("spectral image")
            || haystack.contains("audio visualization")
    }

    public var duration: TimeInterval? {
        guard let length else { return nil }
        return Self.duration(from: length)
    }

    private static func duration(from value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds.isFinite {
            return seconds
        }

        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2, parts.allSatisfy(\.isFinite) else { return nil }
        return parts.reversed().enumerated().reduce(0) { total, part in
            total + part.element * pow(60, Double(part.offset))
        }
    }
}

public enum IADateFormatting {
    /// "2005-08-01T00:00:00Z" -> "Aug 2005"; "2005-08-01" -> "Aug 2005";
    /// "2005-08" -> "Aug 2005"; "2005" -> "2005"; nil/"" -> nil.
    public static func humanReadable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = isoFormatter.date(from: trimmed) {
            return monthYearFormatter.string(from: date)
        }

        for (format, isYearOnly) in Self.parseFormats {
            parseFormatter.dateFormat = format
            if let date = parseFormatter.date(from: trimmed) {
                return isYearOnly
                    ? yearFormatter.string(from: date)
                    : monthYearFormatter.string(from: date)
            }
        }

        return trimmed
    }

    private static let parseFormats: [(String, Bool)] = [
        ("yyyy-MM-dd", false),
        ("yyyy-MM", false),
        ("yyyy", true)
    ]

    private static let isoFormatter = ISO8601DateFormatter()

    private static let parseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy"
        return formatter
    }()
}

public extension String {
    var cleanedInternetArchiveText: String {
        let noTags = replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let decoded = noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public extension KeyedDecodingContainer {
    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return nil
    }

    func decodeStringListIfPresent(forKey key: Key) throws -> [String] {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values.map(Self.cleanListValue).filter { !$0.isEmpty }
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let cleaned = Self.cleanListValue(value)
            return cleaned.isEmpty ? [] : [cleaned]
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return [String(value)]
        }
        return []
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func cleanListValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
