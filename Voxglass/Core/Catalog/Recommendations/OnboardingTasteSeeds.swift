import Foundation

public enum OnboardingTasteSeeds {
    public struct Seed: Equatable {
        public let axis: String
        public let term: String
        public let weight: Double

        public init(axis: String, term: String, weight: Double) {
            self.axis = axis
            self.term = term
            self.weight = weight
        }
    }

    public static func seeds(for selectedCollectionIDs: Set<String>) -> [Seed] {
        var result: [Seed] = []

        for id in selectedCollectionIDs.sorted() {
            if let category = LibriVoxBrowseCategory.category(withID: id) {
                for subject in category.representativeSubjects {
                    result.append(Seed(
                        axis: "subject",
                        term: subject,
                        weight: RecommendationConstants.onboardingSeedWeight
                    ))
                }
            } else if id == "popular-librivox" {
                continue
            } else {
                let authors = CuratedQueries.representativeCreators(forCollectionID: id)
                for author in authors {
                    result.append(Seed(
                        axis: "author",
                        term: author,
                        weight: RecommendationConstants.onboardingAuthorSeedWeight
                    ))
                }
            }
        }

        return result
    }
}
