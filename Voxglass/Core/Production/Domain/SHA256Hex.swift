import Foundation
import CryptoKit

public enum SHA256Hex {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func hex(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func hex(joining parts: [String]) -> String {
        let concatenated = parts.joined(separator: "|")
        return hex(Data(concatenated.utf8))
    }
}
