import Foundation

public struct AudioAssetReference: Codable, Sendable, Hashable {
    public let sha256: String
    public let relativePath: String
    public let byteCount: Int
    public let contentType: String

    public init(sha256: String, relativePath: String, byteCount: Int, contentType: String) {
        self.sha256 = sha256
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.contentType = contentType
    }
}
