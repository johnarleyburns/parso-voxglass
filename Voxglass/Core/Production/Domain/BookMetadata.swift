import Foundation

public struct BookMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var author: String
    public var translator: String?
    public var narrator: String
    public var language: String
    public var description: String
    public var subjects: [String]
    public var seriesName: String?
    public var seriesIndex: Int?
    public var publisher: String?
    public var copyrightYear: Int?
    public var productionYear: Int?
    public var rightsHolder: String?
    public var isbn: String?
    public var asin: String?
    public var isAbridged: Bool
    public var coverRef: AudioAssetReference?
    public var archiveIdentifier: String?

    public init(
        title: String,
        subtitle: String? = nil,
        author: String,
        translator: String? = nil,
        narrator: String,
        language: String = "en-US",
        description: String = "",
        subjects: [String] = [],
        seriesName: String? = nil,
        seriesIndex: Int? = nil,
        publisher: String? = nil,
        copyrightYear: Int? = nil,
        productionYear: Int? = nil,
        rightsHolder: String? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        isAbridged: Bool = false,
        coverRef: AudioAssetReference? = nil,
        archiveIdentifier: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.translator = translator
        self.narrator = narrator
        self.language = language
        self.description = description
        self.subjects = subjects
        self.seriesName = seriesName
        self.seriesIndex = seriesIndex
        self.publisher = publisher
        self.copyrightYear = copyrightYear
        self.productionYear = productionYear
        self.rightsHolder = rightsHolder
        self.isbn = isbn
        self.asin = asin
        self.isAbridged = isAbridged
        self.coverRef = coverRef
        self.archiveIdentifier = archiveIdentifier
    }
}
