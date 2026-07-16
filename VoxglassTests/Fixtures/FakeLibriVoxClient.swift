import Foundation
@testable import VoxglassCore

final class FakeLibriVoxClient: LibriVoxCatalogClient {
    var sectionsToReturn: [LibriVoxSection] = []
    var shouldThrow: Error?

    func fetchSections(bookID: Int) async throws -> [LibriVoxSection] {
        if let error = shouldThrow { throw error }
        return sectionsToReturn
    }
}
