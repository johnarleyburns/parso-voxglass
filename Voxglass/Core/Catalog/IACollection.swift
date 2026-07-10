import Foundation

struct IACollection: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var archiveIdentifier: String?
    var listURL: URL?
    var archiveQuery: String
    var systemImage: String
    var assetName: String?
    var remoteImageURL: URL?

    init(
        id: String,
        title: String,
        subtitle: String,
        archiveIdentifier: String? = nil,
        listURL: URL? = nil,
        archiveQuery: String,
        systemImage: String,
        assetName: String? = nil,
        remoteImageURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.archiveIdentifier = archiveIdentifier
        self.listURL = listURL
        self.archiveQuery = archiveQuery
        self.systemImage = systemImage
        self.assetName = assetName
        self.remoteImageURL = remoteImageURL
    }
}

enum IACollectionStore {
    static let popular = IACollection(
        id: "popular-librivox",
        title: "Popular LibriVox",
        subtitle: "Frequently downloaded public-domain audio",
        archiveIdentifier: "librivoxaudio",
        listURL: URL(string: "https://archive.org/details/librivoxaudio"),
        archiveQuery: LibriVoxBrowseCategory.popular.archiveQuery,
        systemImage: "waveform",
        assetName: "lv-popular",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "librivoxaudio")
    )

    static let featured: [IACollection] = [
        popular,
        collection(for: LibriVoxTaste.all[0], subtitle: "Canonical fiction, drama, and ancient works", assetName: "lv-classics"),
        collection(for: LibriVoxTaste.all[1], subtitle: "Detectives, clues, and crimes", assetName: "lv-mystery"),
        collection(for: LibriVoxTaste.all[2], subtitle: "Speculative fiction from early audio catalogs", assetName: "lv-sci-fi"),
        collection(for: LibriVoxTaste.all[3], subtitle: "Gothic and supernatural shelves", assetName: "lv-horror")
    ]

    static func collections(for selectedTasteIDs: Set<String>) -> [IACollection] {
        let selected = LibriVoxTaste.selected(from: selectedTasteIDs)
        guard !selected.isEmpty else {
            return featured
        }

        let preferenceCollections = selected.map { taste in
            collection(for: taste, subtitle: "Based on your \(taste.title.lowercased()) preference")
        }
        return [popular] + preferenceCollections
    }

    static func collection(
        for taste: LibriVoxTaste,
        subtitle: String,
        assetName: String? = nil
    ) -> IACollection {
        IACollection(
            id: "taste-\(taste.id)",
            title: taste.title,
            subtitle: subtitle,
            archiveQuery: taste.archiveQuery,
            systemImage: taste.systemImage,
            assetName: assetName ?? "lv-\(taste.id)",
            remoteImageURL: representativeCoverURL(for: taste.id)
        )
    }

    private static func representativeCoverURL(for tasteID: String) -> URL? {
        switch tasteID {
        case "classics":
            return InternetArchiveMetadata.coverURL(for: "iliad_librivox")
        case "mystery":
            return InternetArchiveMetadata.coverURL(for: "adventuresofsherlockholmes_1110_librivox")
        case "sci-fi":
            return InternetArchiveMetadata.coverURL(for: "time_machine_librivox")
        case "horror":
            return InternetArchiveMetadata.coverURL(for: "dracula_librivox")
        case "romance":
            return InternetArchiveMetadata.coverURL(for: "pride_and_prejudice_librivox")
        case "history":
            return InternetArchiveMetadata.coverURL(for: "history_of_the_decline_and_fall_01_librivox")
        case "philosophy":
            return InternetArchiveMetadata.coverURL(for: "republic_librivox")
        case "poetry":
            return InternetArchiveMetadata.coverURL(for: "poems_every_child_should_know_librivox")
        case "short-stories":
            return InternetArchiveMetadata.coverURL(for: "shortstorycollection001_librivox")
        case "biography":
            return InternetArchiveMetadata.coverURL(for: "autobiography_benjamin_franklin_librivox")
        default:
            return nil
        }
    }
}
