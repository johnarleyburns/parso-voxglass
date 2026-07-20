import Foundation

public struct CollectionContentRules: Sendable {
    public var requireAnySubjects: Set<String>
    public var excludeSubjects: Set<String>
    public var excludeCreators: Set<String>
    public var excludeTitlePatterns: [String]

    public init(
        requireAnySubjects: Set<String> = [],
        excludeSubjects: Set<String> = [],
        excludeCreators: Set<String> = [],
        excludeTitlePatterns: [String] = []
    ) {
        self.requireAnySubjects = requireAnySubjects
        self.excludeSubjects = excludeSubjects
        self.excludeCreators = excludeCreators
        self.excludeTitlePatterns = excludeTitlePatterns
    }

    public func allows(subjects: [String], creator: String?, title: String) -> Bool {
        let normalizedSubjects = Set(subjects.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedCreator = creator?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""

        if !requireAnySubjects.isEmpty {
            let hasRequired = requireAnySubjects.contains { required in
                normalizedSubjects.contains(required.lowercased())
            }
            guard hasRequired else { return false }
        }

        for excluded in excludeSubjects {
            if normalizedSubjects.contains(excluded.lowercased()) {
                return false
            }
        }

        if !normalizedCreator.isEmpty {
            for excludedCreator in excludeCreators {
                if normalizedCreator == excludedCreator.lowercased() {
                    return false
                }
            }
        }

        for pattern in CollectionRulesRegistry.globalExcludeTitlePatterns + excludeTitlePatterns {
            if normalizedTitle.contains(pattern.lowercased()) {
                return false
            }
        }

        return true
    }
}

public enum CollectionRulesRegistry {
    public static let globalExcludeTitlePatterns = [
        "short nonfiction collection",
        "short story collection",
        "coffee break collection",
        "short poetry collection"
    ]

    private static let fictionSubjects: Set<String> = [
        "general fiction", "literary fiction", "science fiction",
        "historical fiction", "romance", "nature & animal fiction",
        "war & military fiction", "horror & supernatural fiction",
        "fantasy fiction", "fantastic fiction", "crime & mystery fiction",
        "detective fiction", "mystery fiction", "crime fiction",
        "action & adventure fiction", "nautical & marine fiction",
        "humorous fiction", "epistolary fiction", "religious fiction",
        "travel fiction", "gothic fiction", "domestic fiction",
        "culture & heritage fiction",
        "novels", "novel", "short stories", "fiction", "comedy"
    ]

    private static let philosophySubjects: Set<String> = [
        "philosophy", "epistemology", "metaphysics", "ontology",
        "political philosophy", "philosophy of mind", "stoicism", "stoic",
        "utilitarianism", "empiricism", "rationalism", "german idealism",
        "history of philosophy", "ancient philosophy", "ancient greek philosophy",
        "moral philosophy", "phenomenology", "existentialism", "natural law",
        "pragmatism", "indian philosophy", "eastern philosophy",
        "chinese philosophy", "islamic philosophy", "confucianism", "taoism",
        "neoplatonism", "medieval philosophy", "jewish philosophy",
        "psychoanalysis", "ethics", "logic"
    ]

    private static let biographySubjects: Set<String> = [
        "biography & autobiography", "biography", "autobiography", "memoirs", "biographical"
    ]

    public static func rules(forCollectionID id: String) -> CollectionContentRules? {
        switch id {
        case "lv-science-nature":
            return CollectionContentRules(
                excludeSubjects: fictionSubjects
            )
        case "lv-general-fiction":
            return CollectionContentRules(
                requireAnySubjects: fictionSubjects,
                excludeSubjects: ["non-fiction"]
            )
        case "lv-history":
            return CollectionContentRules(
                excludeSubjects: fictionSubjects
            )
        case "lv-biography":
            return CollectionContentRules(
                excludeSubjects: fictionSubjects
            )
        case "lv-essays-ideas":
            return CollectionContentRules(
                excludeSubjects: fictionSubjects.union(philosophySubjects)
            )
        case "lv-philosophy-mind":
            return CollectionContentRules(
                excludeSubjects: ["essays", "essays & short works"]
            )
        case "lv-travel":
            return CollectionContentRules(
                excludeSubjects: fictionSubjects.subtracting(["travel fiction"])
            )
        case "lv-religion":
            return CollectionContentRules(
                excludeSubjects: fictionSubjects.subtracting(["religious fiction"])
            )
        case "lv-war-military":
            return CollectionContentRules(
                requireAnySubjects: [
                    "war & military fiction", "war", "military",
                    "world war", "world war i", "world war ii",
                    "world war, 1914-1918", "napoleonic wars", "civil war",
                    "strategy & tactics"
                ],
                excludeSubjects: biographySubjects
            )
        default:
            return nil
        }
    }
}
