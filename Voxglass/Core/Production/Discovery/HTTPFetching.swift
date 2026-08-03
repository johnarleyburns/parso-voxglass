import Foundation

// MARK: - HTTP fetching seam

/// The only I/O seam discovery code may cross (NARRATION_NEEDS_SPEC §4.2, G-17).
/// `Discovery/**` MUST NOT import a URLSession-bearing module directly; the
/// concrete fetcher (`URLSessionFetcher`) lives in the app targets and a
/// `StubFetcher` in the test-support module.
public protocol HTTPFetching: Sendable {
    func get(_ url: URL, timeout: TimeInterval, userAgent: String) async throws -> HTTPFetchResult
}

/// A successful (or at least returned) HTTP exchange.
public struct HTTPFetchResult: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL

    public init(data: Data, statusCode: Int, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public enum HTTPFetchError: Error, Sendable, Equatable {
    case transport
    case timeout
    /// A redirect toward a sign-in wall, or a body that requires auth.
    case authWall
    case httpStatus(Int)
    case invalidURL
}

extension HTTPFetchResult {
    /// Whether the response (final URL + status) looks like a sign-in wall.
    /// L3 in particular MUST yield nothing on a sign-in wall (G-14).
    public var looksLikeAuthWall: Bool {
        statusCode == 401 || statusCode == 403
    }

    public var finalHost: String {
        finalURL.host?.lowercased() ?? ""
    }

    public var finalPath: String {
        finalURL.path.lowercased()
    }
}
