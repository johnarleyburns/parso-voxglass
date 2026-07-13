import Foundation

struct InternetArchiveSearchResult: Identifiable, Equatable, Sendable {
    var identifier: String
    var title: String
    var creators: [String]
    var description: String?
    var collections: [String]
    var downloads: Int?
    var date: String?
    var languages: [String]

    var id: String { identifier }

    init(
        identifier: String,
        title: String,
        creators: [String],
        description: String?,
        collections: [String],
        downloads: Int?,
        date: String?,
        languages: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.creators = creators
        self.description = description
        self.collections = collections
        self.downloads = downloads
        self.date = date
        self.languages = languages
    }

    var authorLine: String {
        creators.isEmpty ? "Unknown author" : creators.joined(separator: ", ")
    }

    var sourceKind: SourceKind {
        collections.contains { $0.localizedCaseInsensitiveCompare("librivoxaudio") == .orderedSame }
            ? .librivox
            : .internetArchive
    }

    var detailsURL: URL {
        InternetArchiveMetadata.detailsURL(for: identifier)
    }

    var coverURL: URL {
        InternetArchiveMetadata.coverURL(for: identifier)
    }
}

/// A single page of advanced-search results plus the total match count,
/// enabling paginated "See More" loading in Explore.
struct InternetArchivePage: Equatable, Sendable {
    var results: [InternetArchiveSearchResult]
    var numFound: Int
    var page: Int
}

struct InternetArchiveSearchResponse: Decodable, Equatable, Sendable {
    var response: Response

    var results: [InternetArchiveSearchResult] {
        response.docs.map(\.searchResult)
    }

    var numFound: Int {
        response.numFound
    }

    struct Response: Decodable, Equatable, Sendable {
        var docs: [InternetArchiveSearchDocument]
        var numFound: Int

        init(from decoder: Decoder) throws {
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

struct InternetArchiveSearchDocument: Decodable, Equatable, Sendable {
    var identifier: String
    var title: String
    var creators: [String]
    var description: String?
    var collections: [String]
    var downloads: Int?
    var date: String?
    var languages: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decodeFlexibleStringIfPresent(forKey: .title) ?? identifier
        creators = try container.decodeStringListIfPresent(forKey: .creator)
        description = try container.decodeFlexibleStringIfPresent(forKey: .description)
        collections = try container.decodeStringListIfPresent(forKey: .collection)
        downloads = try container.decodeFlexibleIntIfPresent(forKey: .downloads)
        date = try container.decodeFlexibleStringIfPresent(forKey: .date)
        languages = try container.decodeStringListIfPresent(forKey: .language)
    }

    var searchResult: InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: creators,
            description: description?.cleanedInternetArchiveText,
            collections: collections,
            downloads: downloads,
            date: date,
            languages: languages
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
    }
}

struct InternetArchiveMetadata: Decodable, Equatable, Sendable {
    var metadata: InternetArchiveItemMetadata
    var files: [InternetArchiveFile]
    var server: String?
    var dir: String?

    var identifier: String {
        metadata.identifier ?? ""
    }

    var isCollection: Bool {
        metadata.mediatype == "collection"
    }

    var sourceKind: SourceKind {
        metadata.collections.contains { $0.localizedCaseInsensitiveCompare("librivoxaudio") == .orderedSame }
            ? .librivox
            : .internetArchive
    }

    var selectedAudioFiles: [InternetArchiveFile] {
        InternetArchiveAudioSelector.selectedAudioFiles(from: files)
    }

    var title: String {
        metadata.title ?? identifier
    }

    var creators: [String] {
        metadata.creators
    }

    var summary: String? {
        metadata.description?.cleanedInternetArchiveText
    }

    func fileURL(for file: InternetArchiveFile) -> URL? {
        guard !identifier.isEmpty else { return nil }
        let encodedIdentifier = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        let encodedName = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
        return URL(string: "https://archive.org/download/\(encodedIdentifier)/\(encodedName)")
    }

    static func detailsURL(for identifier: String) -> URL {
        URL(string: "https://archive.org/details/\(identifier)")!
    }

    static func coverURL(for identifier: String) -> URL {
        URL(string: "https://archive.org/services/img/\(identifier)")!
    }
}

struct InternetArchiveItemMetadata: Decodable, Equatable, Sendable {
    var identifier: String?
    var title: String?
    var creators: [String]
    var description: String?
    var mediatype: String?
    var collections: [String]
    var subjects: [String]
    var language: String?
    var callNumber: String?

    init(from decoder: Decoder) throws {
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

struct InternetArchiveFile: Decodable, Equatable, Sendable, Identifiable {
    var name: String
    var source: String?
    var format: String?
    var title: String?
    var length: String?
    var track: String?
    var size: String?

    var id: String { name }

    var duration: TimeInterval? {
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

enum IADateFormatting {
    /// "2005-08-01T00:00:00Z" -> "Aug 2005"; "2005-08-01" -> "Aug 2005";
    /// "2005-08" -> "Aug 2005"; "2005" -> "2005"; nil/"" -> nil.
    static func humanReadable(_ raw: String?) -> String? {
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

extension String {
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

extension KeyedDecodingContainer {
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
