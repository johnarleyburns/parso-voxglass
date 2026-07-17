#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

struct CollectionArtworkSpec {
    let id: String
    let query: String

    var assetName: String { "collection-\(id)" }
}

struct AdvancedSearchResponse: Decodable {
    struct Response: Decodable {
        struct Doc: Decodable {
            let identifier: String
        }

        let docs: [Doc]
    }

    let response: Response
}

enum ArtworkUpdateError: Error, CustomStringConvertible {
    case invalidSearchURL(String)
    case invalidImageURL(String)
    case noValidArtwork(String)

    var description: String {
        switch self {
        case .invalidSearchURL(let id):
            return "Could not build advanced-search URL for \(id)"
        case .invalidImageURL(let identifier):
            return "Could not build cover URL for \(identifier)"
        case .noValidArtwork(let id):
            return "No valid square artwork found for \(id)"
        }
    }
}

enum CollectionArtworkUpdater {
    static let assetCatalog = URL(fileURLWithPath: "Voxglass/Resources/Assets.xcassets", isDirectory: true)
    static let session = URLSession.shared

    static func run() async throws {
        for spec in specs {
            let identifiers = try await searchIdentifiers(query: spec.query, rows: 40)
            var selected: (identifier: String, data: Data, fileExtension: String)?

            for identifier in identifiers {
                guard let imageURL = URL(string: "https://archive.org/services/img/\(identifier)?scale=2") else {
                    throw ArtworkUpdateError.invalidImageURL(identifier)
                }
                do {
                    let data = try await fetch(imageURL)
                    guard isValidSquareImage(data) else { continue }
                    selected = (identifier, data, fileExtension(for: data))
                    break
                } catch {
                    continue
                }
            }

            guard let selected else {
                throw ArtworkUpdateError.noValidArtwork(spec.id)
            }

            try writeImageset(
                assetName: spec.assetName,
                data: selected.data,
                fileExtension: selected.fileExtension
            )
            print("\(spec.assetName): \(selected.identifier)")
        }
    }

    static func searchIdentifiers(query: String, rows: Int) async throws -> [String] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "archive.org"
        components.path = "/advancedsearch.php"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "sort[]", value: "downloads desc"),
            URLQueryItem(name: "fl[]", value: "identifier")
        ]
        guard let url = components.url else {
            throw ArtworkUpdateError.invalidSearchURL(query)
        }
        let data = try await fetch(url)
        let decoded = try JSONDecoder().decode(AdvancedSearchResponse.self, from: data)
        return decoded.response.docs.map(\.identifier)
    }

    static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func isValidSquareImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }
        return width >= 120 && height >= 120 && abs(width - height) <= 2
    }

    static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        return "jpg"
    }

    static func writeImageset(assetName: String, data: Data, fileExtension: String) throws {
        let imageset = assetCatalog.appendingPathComponent("\(assetName).imageset", isDirectory: true)
        let filename = "\(assetName).\(fileExtension)"
        let imageURL = imageset.appendingPathComponent(filename)
        let contentsURL = imageset.appendingPathComponent("Contents.json")

        if FileManager.default.fileExists(atPath: imageset.path) {
            try FileManager.default.removeItem(at: imageset)
        }
        try FileManager.default.createDirectory(at: imageset, withIntermediateDirectories: true)
        try data.write(to: imageURL, options: [.atomic])

        let contents = """
        {
          "images" : [
            {
              "filename" : "\(filename)",
              "idiom" : "universal",
              "scale" : "1x"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
        try contents.data(using: .utf8)?.write(to: contentsURL, options: [.atomic])
    }

    static let specs: [CollectionArtworkSpec] = [
        CollectionArtworkSpec(
            id: "popular-librivox",
            query: "mediatype:audio AND collection:librivoxaudio AND downloads:[50 TO *]"
        ),
        CollectionArtworkSpec(
            id: "great-books",
            query: "collection:librivoxaudio AND (creator:\"Homer\" OR creator:\"Aeschylus\" OR creator:\"Sophocles\" OR creator:\"Euripides\" OR creator:\"Aristophanes\" OR creator:\"Plato\" OR creator:\"Aristotle\" OR creator:\"Virgil\" OR creator:\"Dante Alighieri\" OR creator:\"Geoffrey Chaucer\" OR creator:\"William Shakespeare\" OR creator:\"Miguel de Cervantes\" OR creator:\"John Milton\" OR creator:\"Jonathan Swift\" OR creator:\"Jane Austen\" OR creator:\"Herman Melville\" OR creator:\"Charles Darwin\" OR creator:\"Leo Tolstoy\" OR creator:\"Fyodor Dostoevsky\")"
        ),
        CollectionArtworkSpec(
            id: "greater-books",
            query: "collection:librivoxaudio AND (creator:\"Homer\" OR creator:\"Dante Alighieri\" OR creator:\"Geoffrey Chaucer\" OR creator:\"Miguel de Cervantes\" OR creator:\"William Shakespeare\" OR creator:\"John Milton\" OR creator:\"Daniel Defoe\" OR creator:\"Jonathan Swift\" OR creator:\"Jane Austen\" OR creator:\"Mary Shelley\" OR creator:\"Walter Scott\" OR creator:\"Edgar Allan Poe\" OR creator:\"Herman Melville\" OR creator:\"Emily Bronte\" OR creator:\"Charlotte Bronte\" OR creator:\"Charles Dickens\" OR creator:\"George Eliot\" OR creator:\"Oscar Wilde\" OR creator:\"Arthur Conan Doyle\" OR creator:\"Mark Twain\" OR creator:\"Victor Hugo\" OR creator:\"Fyodor Dostoevsky\" OR creator:\"Leo Tolstoy\")"
        ),
        CollectionArtworkSpec(
            id: "ancient-greece",
            query: "collection:librivoxaudio AND (creator:\"Homer\" OR creator:\"Hesiod\" OR creator:\"Aeschylus\" OR creator:\"Sophocles\" OR creator:\"Euripides\" OR creator:\"Aristophanes\" OR creator:\"Herodotus\" OR creator:\"Thucydides\" OR creator:\"Plato\" OR creator:\"Aristotle\" OR creator:\"Sappho\" OR creator:\"Plutarch\" OR creator:\"Xenophon\" OR creator:\"Epictetus\" OR creator:\"Plotinus\")"
        ),
        CollectionArtworkSpec(
            id: "lv-general-fiction",
            query: "collection:librivoxaudio AND (subject:\"General Fiction\" OR subject:\"Culture & Heritage Fiction\" OR subject:\"Family Life\")"
        ),
        CollectionArtworkSpec(
            id: "lv-literary-fiction",
            query: "collection:librivoxaudio AND (subject:\"Literary Fiction\" OR subject:\"Epistolary Fiction\" OR subject:Literature OR subject:\"Literary Collections\")"
        ),
        CollectionArtworkSpec(
            id: "lv-science-fiction",
            query: "collection:librivoxaudio AND (subject:\"Science Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-horror-gothic",
            query: "collection:librivoxaudio AND (subject:\"Horror & Supernatural Fiction\" OR subject:Horror OR subject:Gothic OR subject:\"Ghost stories\" OR subject:Supernatural OR subject:\"Gothic Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-mystery-crime",
            query: "collection:librivoxaudio AND (subject:\"Crime & Mystery Fiction\" OR subject:\"Detective Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-adventure",
            query: "collection:librivoxaudio AND (subject:\"Action & Adventure Fiction\" OR subject:\"Historical Fiction\" OR subject:\"Nautical & Marine Fiction\" OR subject:\"Sagas\" OR subject:Westerns)"
        ),
        CollectionArtworkSpec(
            id: "lv-fantasy-mythology",
            query: "collection:librivoxaudio AND (subject:\"Fantasy Fiction\" OR subject:Fantasy OR subject:\"Fairy tales\" OR subject:Mythology OR subject:Myths OR subject:Legends OR subject:Folklore OR subject:\"Fantastic Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-romance",
            query: "collection:librivoxaudio AND (subject:Romance)"
        ),
        CollectionArtworkSpec(
            id: "lv-satire-humor",
            query: "collection:librivoxaudio AND (subject:\"Humorous Fiction\" OR subject:Satire OR subject:Humor)"
        ),
        CollectionArtworkSpec(
            id: "lv-war-military",
            query: "collection:librivoxaudio AND (subject:\"War & Military Fiction\" OR subject:War OR subject:\"World War\" OR subject:Military OR subject:\"World War I\" OR subject:\"World War, 1914-1918\" OR subject:Espionage OR subject:Thrillers)"
        ),
        CollectionArtworkSpec(
            id: "lv-short-stories",
            query: "collection:librivoxaudio AND (subject:\"Short Stories\")"
        ),
        CollectionArtworkSpec(
            id: "lv-drama-plays",
            query: "collection:librivoxaudio AND (subject:Plays OR subject:\"Dramatic Readings\")"
        ),
        CollectionArtworkSpec(
            id: "lv-travel",
            query: "collection:librivoxaudio AND (subject:\"Travel & Geography\" OR subject:Travel OR subject:\"Voyages and travels\" OR subject:Geography OR subject:Exploration OR subject:\"Travel Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-ancient-world",
            query: "collection:librivoxaudio AND (subject:\"Classics (Greek & Latin Antiquity)\" OR subject:Antiquity)"
        ),
        CollectionArtworkSpec(
            id: "lv-poetry",
            query: "collection:librivoxaudio AND (subject:Poetry)"
        ),
        CollectionArtworkSpec(
            id: "lv-philosophy-mind",
            query: "collection:librivoxaudio AND (subject:epistemology OR subject:metaphysics OR subject:ontology OR subject:\"political philosophy\" OR subject:\"philosophy of mind\" OR subject:stoicism OR subject:stoic OR subject:utilitarianism OR subject:empiricism OR subject:rationalism OR subject:\"german idealism\" OR subject:\"history of philosophy\" OR subject:\"ancient philosophy\" OR subject:\"ancient Greek philosophy\" OR subject:\"moral philosophy\" OR subject:phenomenology OR subject:existentialism OR subject:\"natural law\" OR subject:pragmatism OR subject:\"Indian philosophy\" OR subject:\"eastern philosophy\" OR subject:\"Chinese philosophy\" OR subject:\"Islamic philosophy\" OR subject:Confucianism OR subject:Taoism OR subject:neoplatonism OR subject:\"medieval philosophy\" OR subject:\"jewish philosophy\" OR subject:psychoanalysis OR (creator:(Plato OR Aristotle OR Kant OR Descartes OR Hume OR Locke OR Spinoza OR Hegel OR Nietzsche OR Schopenhauer OR Leibniz OR \"John Stuart Mill\" OR Rousseau OR Epicurus OR Epictetus OR \"Marcus Aurelius\" OR Seneca OR Cicero OR Fichte OR Bergson OR Bentham OR \"Francis Bacon\" OR \"Thomas Hobbes\" OR Voltaire OR \"John Dewey\" OR Russell OR Plotinus OR Boethius OR \"Thomas Aquinas\" OR Confucius OR \"Lao Tzu\" OR Maimonides OR Avicenna OR Freud) AND (subject:philosophy OR subject:ethics OR subject:logic OR subject:nonfiction OR subject:\"non-fiction\" OR subject:metaphysics OR subject:epistemology))) AND NOT (subject:poetry OR subject:fiction OR subject:\"science fiction\" OR subject:\"fairy tales\" OR subject:children OR subject:Christmas OR subject:novel OR subject:biography OR subject:autobiography OR subject:\"self-help\" OR subject:\"New Thought\" OR subject:\"true crime\" OR subject:thriller OR subject:mystery OR subject:romance OR subject:adventure OR subject:supernatural OR subject:occult OR subject:mysticism OR subject:hermeticism OR subject:thelema OR subject:yoga OR subject:hypnosis)"
        ),
        CollectionArtworkSpec(
            id: "lv-history",
            query: "collection:librivoxaudio AND (subject:History OR subject:\"Middle Ages/Middle History\")"
        ),
        CollectionArtworkSpec(
            id: "lv-biography",
            query: "collection:librivoxaudio AND (subject:\"Biography & Autobiography\" OR subject:Biography OR subject:Autobiography OR subject:Memoirs OR subject:Biographical)"
        ),
        CollectionArtworkSpec(
            id: "lv-science-nature",
            query: "collection:librivoxaudio AND (subject:Science OR subject:Nature OR subject:\"Life Sciences\" OR subject:\"Astronomy, Physics & Mechanics\" OR subject:\"Nature & Animal Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-religion",
            query: "collection:librivoxaudio AND (subject:Religion OR subject:Bibles OR subject:\"Religious Fiction\")"
        ),
        CollectionArtworkSpec(
            id: "lv-essays-ideas",
            query: "collection:librivoxaudio AND (subject:\"Essays & Short Works\" OR subject:\"Literary Criticism\" OR subject:\"Political Science\")"
        )
    ]
}

try await CollectionArtworkUpdater.run()
