import Foundation

/// L2 — Wikisource (NARRATION_NEEDS_SPEC §3.4): short works + featured alt.
/// `GET <lang>.wikisource.org/w/api.php?action=query&format=json&list=categorymembers&cmtitle=Category:<short-works cat>&cmlimit=…`.
/// The `<poem>` extension gives structured verse. Prefer a Gutenberg source
/// for `.submittable`; otherwise `.practice`.
public struct WikisourceNeedsSource: NeedsSource {
    public var id: NeedSourceID { .wikisource }

    public let categoryEndpoint: URL
    public let shortWorksCategory: String

    public init(shortWorksCategory: String = "Poems") {
        self.shortWorksCategory = shortWorksCategory
        var components = URLComponents(string: "https://en.wikisource.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "list", value: "categorymembers"),
            URLQueryItem(name: "cmtitle", value: "Category:\(shortWorksCategory)"),
            URLQueryItem(name: "cmlimit", value: "100")
        ]
        categoryEndpoint = components?.url ?? URL(string: "https://en.wikisource.org/w/api.php")!
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        let descriptor = NeedsSourceDescriptors.descriptor(for: id)
        let result = try await fetcher.get(categoryEndpoint, timeout: descriptor.defaultTimeout, userAgent: NeedsSourceDescriptors.userAgent(for: id))
        guard result.statusCode == 200 else { throw HTTPFetchError.httpStatus(result.statusCode) }
        return try decodeCategory(result.data, clock: clock)
    }

    public func decodeCategory(_ data: Data, clock: any Clock) throws -> [NarrationNeed] {
        let response = try NeedsJSONCoding.decoder.decode(WikisourceCategoryResponse.self, from: data)
        let now = clock.now
        return response.query.categorymembers.compactMap { member in
            guard !member.title.contains(":") else { return nil } // skip Category:/Page:/Author: namespaces
            let work = NarratableWork(
                title: member.title,
                author: "Unknown",
                subject: "short work",
                grade: .practice,
                estSeconds: 150
            )
            return NarrationNeed(
                work: work,
                signal: .evergreen,
                strength: 35,
                provenance: NeedProvenance(
                    sources: [.wikisource],
                    firstSeen: now,
                    lastConfirmed: now,
                    pdBasis: .unverified
                )
            )
        }
    }
}

// MARK: - Decodables

public struct WikisourceCategoryResponse: Sendable, Codable {
    public var query: WikisourceQuery

    public init(query: WikisourceQuery) {
        self.query = query
    }
}

public struct WikisourceQuery: Sendable, Codable {
    public var categorymembers: [WikisourceMember]

    public init(categorymembers: [WikisourceMember]) {
        self.categorymembers = categorymembers
    }
}

public struct WikisourceMember: Sendable, Codable {
    public var pageid: Int
    public var title: String

    public init(pageid: Int, title: String) {
        self.pageid = pageid
        self.title = title
    }
}
