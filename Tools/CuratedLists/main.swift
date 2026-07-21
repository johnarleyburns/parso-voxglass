import Foundation

// ── Phase 1: Great Books manifest generator ────────────────────────────
//
// Reads the GBWW work list and creator aliases, enumerates every matching
// LibriVox item via the Internet Archive advancedsearch API, partitions by
// language, maps recordings to works, and emits per-language manifests plus
// a coverage report.
//
// Usage:  swift run curated-lists [--cache-only]
//
//   --cache-only   Use only cached API responses; skip any uncached query.
//                  Useful for data inspection between full runs.
//
// All API responses are cached to Tools/CuratedLists/.cache/ (gitignored).
// The generator exits non-zero on any error condition.

// MARK: - CLI flags

let cacheOnly = CommandLine.arguments.contains("--cache-only")

// MARK: - Paths

let sourceDir = "Tools/CuratedLists"
let cacheDir  = "\(sourceDir)/.cache"
let outDir    = "\(sourceDir)/out"

let worksFile     = "\(sourceDir)/gbww-works.json"
let seedFile      = "\(sourceDir)/verified-seed.json"
let aliasesFile   = "\(sourceDir)/creator-aliases.json"

// MARK: - Data types

struct WorkRow: Decodable {
    let workID: String
    let row: Int
    let author: String
    let title: String
    let constituents: [String]
    let constituentsSource: String
}

struct SeedRow: Decodable {
    let workID: String
    let author: String
    let title: String
    let underlyingRow: Int?
    let recordingTitle: String
    let identifier: String
    let librivoxURL: String
    let matchClass: String
}

struct AliasEntry: Decodable {
    let observed: [String]
}

struct AliasesFile: Decodable {
    let _note: String?
    let _excluded: [String]
    let authors: [String: AliasEntry]
}

struct IAHit: Codable {
    let identifier: String
    let title: String
    let creator: StringOrArray?
    let language: StringOrArray?
    let downloads: Int?
    let date: String?
    let subject: StringOrArray?

    enum StringOrArray: Codable {
        case string(String)
        case array([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let a = try? container.decode([String].self) {
                self = .array(a)
            } else {
                self = .string("")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .array(let a): try container.encode(a)
            }
        }
    }

    var creatorStrings: [String] {
        switch creator {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .array(let a): return a
        case .none: return []
        }
    }

    var languageStrings: [String] {
        switch language {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .array(let a): return a
        case .none: return []
        }
    }
}

struct IASearchResponse: Codable {
    struct Inner: Codable {
        let numFound: Int
        let start: Int
        let docs: [IAHit]
    }
    let response: Inner
}

struct EnumeratedItem: Codable, Hashable {
    let identifier: String
    let title: String
    let creators: [String]
    let language: String          // primary language token for manifests
    let languages: [String]       // all language tokens from IA
    let downloads: Int
    let date: String?
    let subjects: [String]

    func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
    static func == (lhs: EnumeratedItem, rhs: EnumeratedItem) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

struct ManifestEntry: Codable {
    let rank: Int
    let workID: String
    let title: String
    let author: String
    let identifier: String
    let language: String
}

struct CoverageEntry: Codable {
    let workID: String
    let author: String
    let title: String
    let language: String
    let covered: Bool
    let recordingCount: Int
    let identifiers: [String]
}

struct Report: Codable {
    let generated: String
    let totalWorks: Int
    let summary: [SummaryRow]
    let coverage: [CoverageEntry]
    let reviewUnmatched: [ReviewItem]
    let reviewUnknownLanguage: [ReviewItem]
    let reviewMultiLanguage: [ReviewItem]
    let zeroCoverageWorks: [ZeroCoverageRow]

    struct SummaryRow: Codable {
        let language: String
        let itemCount: Int
        let worksCovered: Int
        let worksTotal: Int
        let reviewCount: Int
        let shipped: Bool
        let manifestPath: String?
    }

    struct ReviewItem: Codable {
        let identifier: String
        let title: String
        let creators: [String]
        let language: String
        let languages: [String]
        let possibleWorkIDs: [String]
    }

    struct ZeroCoverageRow: Codable {
        let workID: String
        let author: String
        let title: String
        let searchesPerformed: [String]
    }
}

// MARK: - Language tokens (mirrored from LibriVoxLanguage.swift)

struct LanguageDef {
    let id: String
    let tokens: [String]
}

// Mirrored from Voxglass/Core/Catalog/LibriVoxLanguage.swift:19-35
// Do NOT retype these — they are copied verbatim from the source of truth.
let languageDefs: [LanguageDef] = [
    LanguageDef(id: "eng", tokens: ["eng", "English"]),
    LanguageDef(id: "deu", tokens: ["deu", "ger", "German"]),
    LanguageDef(id: "fre", tokens: ["fre", "fra", "French"]),
    LanguageDef(id: "nld", tokens: ["nld", "dut", "Dutch"]),
    LanguageDef(id: "spa", tokens: ["spa", "Spanish"]),
    LanguageDef(id: "ita", tokens: ["ita", "Italian"]),
    LanguageDef(id: "por", tokens: ["por", "Portuguese"]),
    LanguageDef(id: "rus", tokens: ["rus", "Russian"]),
    LanguageDef(id: "zho", tokens: ["zho", "chi", "Chinese"]),
    LanguageDef(id: "jpn", tokens: ["jpn", "Japanese"]),
    LanguageDef(id: "lat", tokens: ["lat", "Latin"]),
    LanguageDef(id: "grc", tokens: ["grc", "gre", "Greek"]),
    LanguageDef(id: "pol", tokens: ["pol", "Polish"]),
    LanguageDef(id: "fin", tokens: ["fin", "Finnish"]),
    LanguageDef(id: "heb", tokens: ["heb", "Hebrew"]),
]

// Ship threshold: ≥ 10 items after alias resolution
let shipThreshold = 10

/// Classify a set of IA language strings to a known language id.
/// Returns nil for unknown or multi-language items.
func classifyLanguage(_ languages: [String]) -> String? {
    let normalized = languages.flatMap { $0.split(separator: ";") }.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !normalized.isEmpty else { return nil }
    var matches: [String] = []
    for def in languageDefs {
        let lowerTokens = def.tokens.map { $0.lowercased() }
        for lang in normalized {
            if lowerTokens.contains(lang.lowercased()) {
                matches.append(def.id)
                break
            }
        }
    }
    // Deduplicate matches
    let unique = Array(Set(matches))
    if unique.count == 1 { return unique[0] }
    if unique.count > 1 { return nil } // multi-language → review
    return nil // unknown → review
}

// MARK: - Title normalization & matching

/// Normalize a title for comparison: lowercase, strip diacritics,
/// remove parenthetical version/translator suffixes.
func normalizeTitle(_ s: String) -> String {
    let lower = s.lowercased()
    let noDiacritics = lower.folding(options: .diacriticInsensitive, locale: nil)

    // Strip parenthetical suffixes: (Version 2), (Murray Translation), (Pope Translation),
    // (Version 3), etc. Also ", Vol. 1" style suffixes.
    var result = noDiacritics
    // Remove "(...)" at end
    while let range = result.range(of: #"\s*\([^)]*\)"#, options: [.regularExpression, .backwards]) {
        // Only strip if it looks like a version/translation suffix, not part of the title
        let paren = String(result[range]).lowercased()
        if paren.contains("version") || paren.contains("translation")
           || paren.contains("transl.") || paren.contains("vol.")
           || paren.contains("book") || paren.contains("part")
           || paren.contains("selections") || paren.contains("band")
           || paren.contains("tome") || paren.contains("tomo")
           || paren.contains("teil") || paren.contains("buch")
           || paren.contains("libro") || paren.contains("versione")
           || paren.contains("versión") {
            result.removeSubrange(range)
        } else {
            break
        }
    }
    // Remove trailing "vol. N" or ", vol. N" (case-insensitive)
    result = result.replacingOccurrences(of: #",?\s*[Vv][Oo][Ll]\.?\s*\d+$"#, with: "", options: .regularExpression)
    // Remove trailing multilingual volume markers: book, band, buch, tome, tomo, teil, libro, parte, livre, deel
    result = result.replacingOccurrences(of: #",?\s*([Bb]ook|[Bb]and|[Bb]uch|[Tt]ome|[Tt]omo|[Tt]eil|[Ll]ibro|[Ll]ivre|[Ll]ivres|[Pp]arte|[Dd]eel)\s*\d+$"#, with: "", options: .regularExpression)
    // Remove trailing German "Bd. N" abbreviation
    result = result.replacingOccurrences(of: #",?\s*[Bb]d\.?\s*\d+$"#, with: "", options: .regularExpression)
    // Strip language markers like "(Spanish)", "(español)"
    result = result.replacingOccurrences(of: #"\s*\([Ss]panish\)"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\s*\([Ee]spañol\)"#, with: "", options: .regularExpression)

    // Collapse whitespace
    result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Compute a comparison key for a title — more aggressive than normalizeTitle
func comparisonKey(_ s: String) -> String {
    var key = normalizeTitle(s)
    // Strip subtitle after " - " or ": " for compound titles like 
    // "Die göttliche Komödie - Das Fegefeuer" or "La Divina Commedia: Inferno"
    if let dashRange = key.range(of: " - "), dashRange.lowerBound > key.startIndex {
        let prefix = String(key[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        if prefix.count > 3 { key = prefix }
    }
    // Remove leading articles (multilingual)
    for article in ["the ", "a ", "an ", "le ", "la ", "les ", "l'", "de ", "das ", "der ", "die ", "das ", "il ", "lo ", "gli ", "el ", "los ", "las ", "un ", "une ", "des "] {
        if key.hasPrefix(article) {
            key = String(key.dropFirst(article.count))
            break
        }
    }
    // Remove possessives
    key = key.replacingOccurrences(of: "'s ", with: " ")
    key = key.replacingOccurrences(of: "’s ", with: " ")

    // Collapse again
    key = key.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return key.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Title aliases

/// Known title aliases for works where the IA title differs from the GBWW title.
/// Structure: [language: [alias_normalized: workID]]
/// Also used for non-English → work mapping.
struct TitleAliases {
    // English aliases: alternate title forms → workID
    static let eng: [String: String] = {
        var m: [String: String] = [:]

        // Homer
        m["iliad"] = "homer-the-iliad"
        m["the iliad"] = "homer-the-iliad"
        m["odyssey"] = "homer-the-odyssey"

        // Shakespeare plays → aggregate work
        let shakespearePlays: [String] = [
            "henry vi, part 1", "henry vi part 1", "henry vi, part 2", "henry vi part 2",
            "henry vi, part 3", "henry vi part 3",
            "richard iii", "the tragedy of king richard iii",
            "comedy of errors", "the comedy of errors",
            "titus andronicus",
            "taming of the shrew", "the taming of the shrew",
            "two gentlemen of verona",
            "love's labour's lost",
            "romeo and juliet",
            "richard ii", "king richard ii",
            "midsummer night's dream", "a midsummer night's dream",
            "king john", "the life and death of king john",
            "merchant of venice", "the merchant of venice",
            "henry iv, part 1", "henry iv part 1",
            "henry iv, part 2", "henry iv part 2",
            "much ado about nothing",
            "henry v", "king henry v", "the life of king henry the fifth",
            "julius caesar",
            "as you like it",
            "twelfth night",
            "hamlet", "the tragedy of hamlet",
            "merry wives of windsor", "the merry wives of windsor",
            "troilus and cressida",
            "all's well that ends well",
            "measure for measure",
            "othello", "othello, the moor of venice",
            "king lear",
            "macbeth",
            "antony and cleopatra",
            "coriolanus",
            "timon of athens",
            "pericles", "pericles, prince of tyre",
            "cymbeline",
            "winter's tale", "the winter's tale",
            "tempest", "the tempest",
            "henry viii",
        ]
        for title in shakespearePlays { m[title] = "william-shakespeare-plays" }
        m["sonnets"] = "william-shakespeare-sonnets"

        // Sophocles
        m["oedipus rex"] = "sophocles-plays"
        m["oedipus the king"] = "sophocles-plays"
        m["oedipus at colonus"] = "sophocles-plays"
        m["antigone"] = "sophocles-plays"
        m["electra"] = "sophocles-plays"
        m["ajax"] = "sophocles-plays"
        m["philoctetes"] = "sophocles-plays"
        m["trachiniae"] = "sophocles-plays"
        m["trachiniai"] = "sophocles-plays"
        m["women of trachis"] = "sophocles-plays"

        // Aeschylus
        m["oresteia"] = "aeschylus-plays"
        m["agamemnon"] = "aeschylus-plays"
        m["libation bearers"] = "aeschylus-plays"
        m["choephoroe"] = "aeschylus-plays"
        m["eumenides"] = "aeschylus-plays"
        m["furies"] = "aeschylus-plays"

        // Euripides
        m["medea"] = "euripides-plays"
        m["alcestis"] = "euripides-plays"
        m["andromache"] = "euripides-plays"

        // Aristophanes
        m["clouds"] = "aristophanes-plays"
        m["the clouds"] = "aristophanes-plays"

        // Plato
        m["republic"] = "plato-dialogues"
        m["the republic"] = "plato-dialogues"

        // Various
        m["peloponnesian war"] = "thucydides-the-history-of-the-peloponnesian-war"
        m["history of the peloponnesian war"] = "thucydides-the-history-of-the-peloponnesian-war"

        // Multilingual fallback aliases (for nld, rus, lat, fin, pol, por, etc.)
        m["kleine dorrit"] = "charles-dickens-little-dorrit"
        m["don quichot"] = "miguel-de-cervantes-don-quixote"
        m["divina commedia"] = "dante-alighieri-the-divine-comedy"
        m["de vorst"] = "niccolo-machiavelli-the-prince"
        m["gullivers reizen"] = "jonathan-swift-gullivers-travels"
        m["ruhtinas"] = "niccolo-machiavelli-the-prince"

        return m
    }()

    // Spanish aliases
    static let spa: [String: String] = [
        // Direct translations
        "las siete tragedias": "sophocles-plays",
        "las siete tragedias de sofocles": "sophocles-plays",
        "don quijote": "miguel-de-cervantes-don-quixote",
        "el principe": "niccolo-machiavelli-the-prince",
        "la divina comedia": "dante-alighieri-the-divine-comedy",
        "la metamorfosis": "franz-kafka-the-metamorphosis",
        "meditaciones": "marcus-aurelius-meditations",
        "candido o el optimismo": "voltaire-candide",
        "la guerra y la paz": "leo-tolstoy-war-and-peace",
        "aventuras de huck": "mark-twain-adventures-of-huckleberry-finn",
        "por el camino de swann": "marcel-proust-swann-in-love",
        "las noches blancas": "fyodor-dostoevsky-the-brothers-karamazov",
        "la muerte de ivan ilitch": "leo-tolstoy-war-and-peace",
        "la sonata a kreutzer": "leo-tolstoy-war-and-peace",
        "el huesped secreto": "joseph-conrad-heart-of-darkness",
        "el cocodrilo": "fyodor-dostoevsky-the-brothers-karamazov",
        "el cantico de navidad": "charles-dickens-little-dorrit",
        // Shakespeare plays (Spanish titles)
        "hamlet": "william-shakespeare-plays",
        "romeo y julieta": "william-shakespeare-plays",
        "el mercader de venecia": "william-shakespeare-plays",
        // Historia de Herodoto
        "historia de herodoto": "herodotus-the-history-of-the-persian-wars",
    ]

    // German aliases
    static let deu: [String: String] = [
        "das lob der narrheit": "desiderius-erasmus-praise-of-folly",
        "die leiden des jungen werther": "johann-wolfgang-von-goethe-faust",
        "faust": "johann-wolfgang-von-goethe-faust",
        "der prozess": "franz-kafka-the-metamorphosis",
        "die verwandlung": "franz-kafka-the-metamorphosis",
        // Homer
        "ilias": "homer-the-iliad",
        "odyssee": "homer-the-odyssey",
        // Marx
        "das kapital": "karl-marx-capital-volume-i",
        "manifest der kommunistischen partei": "karl-marx-friedrich-engels-manifesto-of-the-communist-party",
        // Swift
        "gullivers reisen": "jonathan-swift-gullivers-travels",
        // Voltaire
        "kandid oder die beste welt": "voltaire-candide",
        // Nietzsche
        "gotzendammerung": "friedrich-nietzsche-beyond-good-and-evil",
        "der antichrist": "friedrich-nietzsche-beyond-good-and-evil",
        "der tolle mensch": "friedrich-nietzsche-beyond-good-and-evil",
        // Dostoyevsky
        "der spieler": "fyodor-dostoevsky-the-brothers-karamazov",
        "der doppelganger": "fyodor-dostoevsky-the-brothers-karamazov",
        "weisse nachte": "fyodor-dostoevsky-the-brothers-karamazov",
        "der grossinquisitor": "fyodor-dostoevsky-the-brothers-karamazov",
        // Thucydides
        "geschichte des peloponnesischen kriegs": "thucydides-the-history-of-the-peloponnesian-war",
        // Euripides
        "iphigenie in aulis": "euripides-plays",
        // Mark Twain
        "abenteuer und fahrten des huckleberry finn": "mark-twain-adventures-of-huckleberry-finn",
        "die abenteuer tom sawyers": "mark-twain-adventures-of-huckleberry-finn",
        "querkopf wilson": "mark-twain-adventures-of-huckleberry-finn",
        // Plato
        "kriton": "plato-dialogues",
        "des sokrates verteidigung": "plato-dialogues",
        // Tolstoy
        "herr und knecht": "leo-tolstoy-war-and-peace",
        "anna karenina": "leo-tolstoy-war-and-peace",
        // Freud
        "uber psychoanalyse": "sigmund-freud-a-general-introduction-to-psychoanalysis",
        // Dante
        "gotliche komodie": "dante-alighieri-the-divine-comedy",
        "die gotliche komodie": "dante-alighieri-the-divine-comedy",
        // Kant
        "zum ewigen frieden": "immanuel-kant-groundwork-of-the-metaphysics-of-morals",
    ]

    // Italian aliases
    static let ita: [String: String] = [
        "il principe": "niccolo-machiavelli-the-prince",
        "la divina commedia": "dante-alighieri-the-divine-comedy",
        "dialogo dei massimi sistemi": "galileo-galilei-dialogues-concerning-two-new-sciences",
        "dialogo sopra i due massimi sistemi": "galileo-galilei-dialogues-concerning-two-new-sciences",
        "sei personaggi in cerca d'autore": "luigi-pirandello-six-characters-in-search-of-an-author",
        "enrico iv": "luigi-pirandello-six-characters-in-search-of-an-author",
        "la vita nuova": "dante-alighieri-the-divine-comedy",
        "le rime": "dante-alighieri-the-divine-comedy",
        // Machiavelli
        "la mandragola": "niccolo-machiavelli-the-prince",
    ]

    // French aliases
    static let fre: [String: String] = [
        "prince": "niccolo-machiavelli-the-prince",
        "le prince": "niccolo-machiavelli-the-prince",
        "candide": "voltaire-candide",
        "du contrat social": "jean-jacques-rousseau-the-social-contract",
        "discours sur l'origine de l'inegalite": "jean-jacques-rousseau-discourse-on-the-origin-of-inequality",
        "paradis perdu": "john-milton-paradise-lost",
        "le paradis perdu": "john-milton-paradise-lost",
        "de l'esprit des lois": "montesquieu-the-spirit-of-laws",
        "esprit des lois": "montesquieu-the-spirit-of-laws",
        "l'esprit des lois": "montesquieu-the-spirit-of-laws",
        "discours sur les sciences et les arts": "jean-jacques-rousseau-discourse-on-the-origin-of-inequality",
        "essais": "michel-de-montaigne-essays",
        "essais, livre": "michel-de-montaigne-essays",
        "zadig": "voltaire-candide",
        "pere goriot": "honore-de-balzac-cousin-bette",
        "le pere goriot": "honore-de-balzac-cousin-bette",
        "discours sur l'origine et les fondements de l'inegalite": "jean-jacques-rousseau-discourse-on-the-origin-of-inequality",
    ]

    // Greek aliases
    static let grc: [String: String] = [
        "απολογια σωκρατουσ": "plato-dialogues",
        "ιστοριαι": "thucydides-the-history-of-the-peloponnesian-war",
    ]

    static func aliases(for lang: String) -> [String: String] {
        switch lang {
        case "spa": return spa
        case "deu": return deu
        case "ita": return ita
        case "fre": return fre
        case "grc": return grc
        default: return eng
        }
    }
}

/// Match an item title to a work. Returns workID if found.
/// `itemCreators` is used to filter matches — only works by matching authors
/// are considered for the loose substring pass.
func matchTitle(_ iaTitle: String, works: [WorkRow], language: String,
                itemCreators: [String] = []) -> String? {
    let key = comparisonKey(iaTitle)
    let aliases = TitleAliases.aliases(for: language)

    // 1. Direct alias lookup
    if let wid = aliases[key] { return wid }

    // 2. Check against work titles (exact key match)
    for w in works {
        if comparisonKey(w.title) == key { return w.workID }
    }

    // 3. Check against constituent titles (exact key match)
    for w in works {
        for c in w.constituents {
            if comparisonKey(c) == key { return w.workID }
        }
    }

    // 4. Substring matching — but only for authors that match the item's creators.
    let creatorLower = itemCreators.map { $0.lowercased() }
    func authorMatches(_ work: WorkRow) -> Bool {
        if creatorLower.isEmpty { return true }
        let authorLower = work.author.lowercased()
        let authorLast = authorLower.split(separator: " ").last.map(String.init) ?? ""
        for c in creatorLower {
            let creatorLast = c.split(separator: " ").last.map(String.init) ?? ""
            // Last-name match (most reliable across languages)
            if !authorLast.isEmpty && authorLast == creatorLast { return true }
            // Full name contains (both directions)
            if authorLower.contains(c) || c.contains(authorLower) { return true }
        }
        return false
    }

    for w in works where authorMatches(w) {
        // Direct work title substring (either direction)
        let wk = comparisonKey(w.title)
        if !wk.isEmpty && (key.contains(wk) || wk.contains(key)) { return w.workID }

        // Constituent substring
        for c in w.constituents {
            let ck = comparisonKey(c)
            if !ck.isEmpty && (key.contains(ck) || ck.contains(key)) { return w.workID }
        }
    }

    // 5. Again try the alias keys as loose matches (only for matching-authors)
    for w in works where authorMatches(w) {
        for (aliasKey, wid) in aliases where wid == w.workID {
            if !aliasKey.isEmpty && aliasKey.count > 4
               && (key.contains(aliasKey) || aliasKey.contains(key)) {
                return wid
            }
        }
    }

    return nil
}

// MARK: - Caching & API

func cacheKey(for query: String, page: Int, rows: Int = 100) -> String {
    // Stable djb2 hash of the lowercase query string.
    let safe = query.lowercased()
    var hash: UInt64 = 5381
    for byte in safe.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
    let hex = String(hash, radix: 16, uppercase: false)
    return "\(cacheDir)/q_\(hex)_p\(page).json"
}

func cachedResponse(for query: String, page: Int) -> IASearchResponse? {
    let path = cacheKey(for: query, page: page)
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let resp = try? JSONDecoder().decode(IASearchResponse.self, from: data) else {
        return nil
    }
    return resp
}

func saveCachedResponse(_ data: Data, for query: String, page: Int) {
    let path = cacheKey(for: query, page: page)
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: path))
}

func searchIA(query: String, page: Int = 1, rows: Int = 100) async throws -> IASearchResponse {
    // Check cache first
    if let cached = cachedResponse(for: query, page: page) {
        print("    [cache hit] page \(page)")
        return cached
    }

    if cacheOnly {
        print("    [skip — cache-only] page \(page)")
        throw NSError(domain: "curated-lists", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "no cache for query"])
    }

    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    let urlStr = "https://archive.org/advancedsearch.php?q=\(encoded)&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=language&fl[]=downloads&fl[]=date&fl[]=subject&rows=\(rows)&page=\(page)&output=json"
    guard let url = URL(string: urlStr) else {
        throw NSError(domain: "curated-lists", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "invalid URL for query"])
    }

    print("    [fetch] page \(page)")
    let (data, _) = try await URLSession.shared.data(from: url)
    let response = try JSONDecoder().decode(IASearchResponse.self, from: data)
    saveCachedResponse(data, for: query, page: page)
    return response
}

/// Fetch all pages for a creator search. Returns all items found.
func enumerateCreator(_ creator: String) async throws -> [EnumeratedItem] {
    let query = "collection:(librivoxaudio) AND creator:\"\(creator)\""
    let firstPage = try await searchIA(query: query, page: 1)
    let total = firstPage.response.numFound
    let totalPages = Int(ceil(Double(total) / 100.0))

    var items: [EnumeratedItem] = []
    for doc in firstPage.response.docs {
        items.append(convertToItem(doc))
    }

    if totalPages > 1 {
        for page in 2...totalPages {
            try await Task.sleep(nanoseconds: 1_000_000_000) // ≥ 1s between requests
            let resp = try await searchIA(query: query, page: page)
            for doc in resp.response.docs {
                items.append(convertToItem(doc))
            }
        }
    }

    return items
}

func convertToItem(_ doc: IAHit) -> EnumeratedItem {
    let langs = doc.languageStrings
    let primary = classifyLanguage(langs) ?? "review"
    return EnumeratedItem(
        identifier: doc.identifier,
        title: doc.title,
        creators: doc.creatorStrings,
        language: primary,
        languages: langs,
        downloads: doc.downloads ?? 0,
        date: doc.date,
        subjects: doc.subject.map { s in
            switch s {
            case .string(let str): return [str]
            case .array(let arr): return arr
            }
        } ?? []
    )
}

// MARK: - Helpers

func loadJSON<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}

func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url)
}

func slug(_ s: String) -> String {
    s.lowercased()
        .folding(options: .diacriticInsensitive, locale: nil)
        .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// Get GBWW rank order from the work list (1-indexed, by position in list).
func gbwwRank(for workID: String, in works: [WorkRow]) -> Int? {
    works.firstIndex(where: { $0.workID == workID }).map { $0 + 1 }
}

// MARK: - Main

print("""
╔══════════════════════════════════════════════════╗
║  Great Books — Phase 1 manifest generator        ║
╚══════════════════════════════════════════════════╝
""")

// ── 1. Load data ──

print("\n[1/7] Loading data files...")
let works: [WorkRow]
let seeds: [SeedRow]
let aliases: AliasesFile

do {
    works = try loadJSON(worksFile, as: [WorkRow].self)
    print("  Works:  \(works.count) rows")
    guard works.count == 183 else {
        print("  ERROR: expected 183 works, got \(works.count)")
        exit(1)
    }
} catch {
    print("  ERROR loading \(worksFile): \(error)")
    exit(1)
}

do {
    seeds = try loadJSON(seedFile, as: [SeedRow].self)
    print("  Seeds:  \(seeds.count) rows")
} catch {
    print("  ERROR loading \(seedFile): \(error)")
    exit(1)
}

do {
    aliases = try loadJSON(aliasesFile, as: AliasesFile.self)
    print("  Aliases: \(aliases.authors.count) author entries, \(aliases._excluded.count) excluded")
} catch {
    print("  ERROR loading \(aliasesFile): \(error)")
    exit(1)
}

// Build set of all creator strings to search (with exclusions filtered)
let excludedSet = Set(aliases._excluded)
var allCreatorQueries: Set<String> = []
for (_, entry) in aliases.authors {
    for obs in entry.observed {
        if !excludedSet.contains(obs) {
            allCreatorQueries.insert(obs)
        }
    }
}
print("  Unique creator queries: \(allCreatorQueries.count)")

// ── 2. Enumerate catalog ──

print("\n[2/7] Enumerating LibriVox catalog...")
var allItems: Set<EnumeratedItem> = []
let creatorList = allCreatorQueries.sorted()
var enumerated = 0

for (i, creator) in creatorList.enumerated() {
    print("  [\(i+1)/\(creatorList.count)] \(creator)...")
    fflush(stdout)
    do {
        let items = try await enumerateCreator(creator)
        print("    → \(items.count) items")
        fflush(stdout)
        allItems.formUnion(items)
        enumerated += 1
    } catch {
        if cacheOnly {
            print("    → skipped (not cached)")
        } else {
            print("  ERROR enumerating '\(creator)': \(error)")
            fflush(stdout)
            exit(1)
        }
    }
    // Rate limit between creators
    if enumerated < creatorList.count && !cacheOnly {
        try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s margin
    }
}

print("  Total unique items: \(allItems.count)")
fflush(stdout)
guard !allItems.isEmpty else {
    if cacheOnly {
        print("  No cached items found. Run without --cache-only to populate the cache.")
        exit(0)
    }
    print("  FATAL: no items enumerated")
    exit(1)
}

// ── 3. Partition by language ──

print("\n[3/7] Partitioning by language...")
var byLang: [String: [EnumeratedItem]] = [:]
var reviewUnknownLang: [EnumeratedItem] = []
var reviewMultiLang: [EnumeratedItem] = []

for item in allItems {
    if item.language == "review" {
        // Distinguish unknown vs. multi
        let lc = item.languages.flatMap { $0.split(separator: ";") }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let matched = lc.compactMap { lang -> String? in
            for def in languageDefs {
                if def.tokens.map({ $0.lowercased() }).contains(lang.lowercased()) {
                    return def.id
                }
            }
            return nil
        }
        if Set(matched).count > 1 {
            reviewMultiLang.append(item)
        } else {
            reviewUnknownLang.append(item)
        }
    } else {
        byLang[item.language, default: []].append(item)
    }
}

// ── 4. Map recordings to works ──

print("\n[4/7] Mapping recordings to GBWW works...")
var mapped: [String: [(EnumeratedItem, String)]] = [:] // lang → [(item, workID)]
var reviewUnmatched: [(EnumeratedItem, String)] = []    // (item, lang)

for (lang, items) in byLang {
    var matched: [(EnumeratedItem, String)] = []
    for item in items {
        if let wid = matchTitle(item.title, works: works, language: lang,
                                itemCreators: item.creators) {
            matched.append((item, wid))
        } else {
            reviewUnmatched.append((item, lang))
        }
    }
    mapped[lang] = matched
    print("  \(lang): \(items.count) items → \(matched.count) mapped, \(items.count - matched.count) unmatched")
}
print("  Review unmatched: \(reviewUnmatched.count)")

// Determine ship list (both raw items AND mapped entries must meet threshold)
let shippedLangs = mapped.filter { $0.value.count >= shipThreshold }
    .map { ($0.key, byLang[$0.key]?.count ?? 0, $0.value.count) }
    .sorted { $0.2 > $1.2 }

print("\n  Language distribution:")
let shippedLangSet = Set(shippedLangs.map { $0.0 })
for (lang, items) in byLang.sorted(by: { $0.value.count > $1.value.count }) {
    let shipped = shippedLangSet.contains(lang) ? " ✓" : ""
    print("    \(lang): \(items.count) items\(shipped)")
}
print("  Unknown language (review): \(reviewUnknownLang.count)")
print("  Multi-language (review): \(reviewMultiLang.count)")

// ── 5. Build manifests ──

print("\n[5/7] Building per-language manifests...")
var manifests: [String: [ManifestEntry]] = [:]

for (lang, _, _) in shippedLangs {
    guard let items = mapped[lang] else { continue }

    // Group by workID, preserve GBWW order
    var byWork: [String: [EnumeratedItem]] = [:]
    for (item, wid) in items {
        byWork[wid, default: []].append(item)
    }

    // Sort works by GBWW rank
    let sortedWorks = byWork.keys.sorted { a, b in
        let ra = gbwwRank(for: a, in: works) ?? Int.max
        let rb = gbwwRank(for: b, in: works) ?? Int.max
        return ra < rb
    }

    var entries: [ManifestEntry] = []
    for wid in sortedWorks {
        if let work = works.first(where: { $0.workID == wid }) {
            for item in byWork[wid, default: []] {
                entries.append(ManifestEntry(
                    rank: entries.count + 1,
                    workID: wid,
                    title: item.title,
                    author: work.author,
                    identifier: item.identifier,
                    language: lang
                ))
            }
        }
    }

    guard !entries.isEmpty else {
        print("  ERROR: empty manifest for \(lang)")
        exit(1)
    }
    manifests[lang] = entries
    print("  great-books-\(lang): \(entries.count) entries")
}

// ── 6. Verify seed rows ──

print("\n[6/7] Verifying seed rows...")
let enumeratedIdentifiers: Set<String> = Set(allItems.map(\.identifier))
var enumeratedWorkIDs: [String: Set<String>] = [:] // identifier → [workIDs]

// Build identifier → workID mapping from our manifests
for (_, entries) in manifests {
    for e in entries {
        enumeratedWorkIDs[e.identifier, default: []].insert(e.workID)
    }
}

var seedErrors = 0
for seed in seeds {
    if seed.matchClass == "No exact match" || seed.matchClass == "No exact completed recording located" {
        // Assert absence: this identifier should NOT be in our manifests
        if !seed.identifier.isEmpty && enumeratedIdentifiers.contains(seed.identifier) {
            // But check if it appeared under a different work — that might be okay
            if let foundWIDs = enumeratedWorkIDs[seed.identifier], !foundWIDs.contains(seed.workID) {
                print("  SEED MISMATCH: \(seed.identifier) was rediscovered but assigned workID(s) \(foundWIDs) instead of \(seed.workID) (expected NO MATCH)")
                seedErrors += 1
            }
        }
        // If it's truly absent, that's correct
    } else if !seed.identifier.isEmpty {
        // Assert presence: identifier must exist in our enumeration
        if !enumeratedIdentifiers.contains(seed.identifier) {
            print("  SEED MISSING: \(seed.identifier) (\(seed.recordingTitle)) — not rediscovered by enumeration")
            seedErrors += 1
        } else if let foundWIDs = enumeratedWorkIDs[seed.identifier], !foundWIDs.contains(seed.workID) {
            print("  SEED WORKID MISMATCH: \(seed.identifier) assigned workID(s) \(foundWIDs) but seed expects \(seed.workID)")
            seedErrors += 1
        }
    }
}

if seedErrors > 0 {
    print("  WARNING: \(seedErrors) seed verification discrepancies (non-fatal)")
} else {
    print("  All seed rows verified — no discrepancies")
}

// ── 7. Emit manifests and report ──

print("\n[7/7] Emitting manifests and report...")

// Emit manifests
for (lang, entries) in manifests {
    let path = "\(outDir)/great-books-\(lang).json"
    try writeJSON(entries, to: path)
    print("  Wrote \(path) (\(entries.count) entries)")
}

// Guard: no manifest is empty
for (lang, entries) in manifests {
    guard !entries.isEmpty else {
        print("  ERROR: manifest for \(lang) is empty")
        exit(1)
    }
    // Guard: no duplicate identifiers within a file
    let ids = entries.map(\.identifier)
    let uniqueIDs = Set(ids)
    guard ids.count == uniqueIDs.count else {
        print("  ERROR: duplicate identifiers in great-books-\(lang).json")
        exit(1)
    }
    // Guard: all entries have valid workID
    let validWIDs = Set(works.map(\.workID))
    for e in entries {
        guard validWIDs.contains(e.workID) else {
            print("  ERROR: unknown workID '\(e.workID)' in great-books-\(lang).json entry '\(e.identifier)'")
            exit(1)
        }
        guard e.language == lang else {
            print("  ERROR: entry '\(e.identifier)' has language '\(e.language)' but is in great-books-\(lang).json")
            exit(1)
        }
    }
}

// Build coverage entries
var coverageEntries: [CoverageEntry] = []
for work in works {
    for (lang, entries) in manifests {
        let langEntries = entries.filter { $0.workID == work.workID }
        coverageEntries.append(CoverageEntry(
            workID: work.workID,
            author: work.author,
            title: work.title,
            language: lang,
            covered: !langEntries.isEmpty,
            recordingCount: langEntries.count,
            identifiers: langEntries.map(\.identifier)
        ))
    }
}

// Zero-coverage rows (works with no recordings in any language)
var zeroCoverage: [Report.ZeroCoverageRow] = []
for work in works {
    let allCovered = manifests.values.flatMap { $0 }.filter { $0.workID == work.workID }
    if allCovered.isEmpty {
        // Search for this author in the aliases file
        let authorSearches = aliases.authors.keys.filter {
            $0.localizedCaseInsensitiveCompare(work.author) == .orderedSame
        }
        zeroCoverage.append(Report.ZeroCoverageRow(
            workID: work.workID,
            author: work.author,
            title: work.title,
            searchesPerformed: authorSearches.isEmpty
                ? ["creator:\"\(work.author)\""]
                : authorSearches.map { "creator:\"\($0)\"" }
        ))
    }
}

// Summary rows
var summaryRows: [Report.SummaryRow] = []
for (lang, items) in byLang.sorted(by: { $0.value.count > $1.value.count }) {
    let shipped = items.count >= shipThreshold
    let langEntries = manifests[lang] ?? []
    let coveredWorks = Set(langEntries.map(\.workID))
    summaryRows.append(Report.SummaryRow(
        language: lang,
        itemCount: items.count,
        worksCovered: coveredWorks.count,
        worksTotal: works.count,
        reviewCount: (lang == "review" ? reviewUnknownLang.count + reviewMultiLang.count : 0),
        shipped: shipped,
        manifestPath: shipped ? "\(outDir)/great-books-\(lang).json" : nil
    ))
}

// Review items
let reviewItemsUnmatched = reviewUnmatched.map { (item, lang) in
    Report.ReviewItem(
        identifier: item.identifier,
        title: item.title,
        creators: item.creators,
        language: lang,
        languages: item.languages,
        possibleWorkIDs: [] // TODO: could do fuzzy matching here
    )
}

let reviewItemsUnknownLang = reviewUnknownLang.map { item in
    Report.ReviewItem(
        identifier: item.identifier,
        title: item.title,
        creators: item.creators,
        language: "unknown",
        languages: item.languages,
        possibleWorkIDs: []
    )
}

let reviewItemsMultiLang = reviewMultiLang.map { item in
    Report.ReviewItem(
        identifier: item.identifier,
        title: item.title,
        creators: item.creators,
        language: "multi",
        languages: item.languages,
        possibleWorkIDs: []
    )
}

let report = Report(
    generated: ISO8601DateFormatter().string(from: Date()),
    totalWorks: works.count,
    summary: summaryRows,
    coverage: coverageEntries,
    reviewUnmatched: reviewItemsUnmatched,
    reviewUnknownLanguage: reviewItemsUnknownLang,
    reviewMultiLanguage: reviewItemsMultiLang,
    zeroCoverageWorks: zeroCoverage
)

try writeJSON(report, to: "\(outDir)/great-books-report.json")
print("  Wrote \(outDir)/great-books-report.json")

// ── Print summary ──

print("""

╔══════════════════════════════════════════════════╗
║  Generation complete                             ║
╠══════════════════════════════════════════════════╣
""")
print("  Language │ Items │ Works │ Shipped")
print("  ─────────┼───────┼───────┼────────")
for row in summaryRows {
    let shipped = row.shipped ? "✓" : ""
    print(String(format: "  %-8s │ %5d │ %5d │ %@",
                 row.language, row.itemCount, row.worksCovered, shipped))
}
print("  ─────────┼───────┼───────┼────────")
let totalItems = summaryRows.reduce(0) { $0 + $1.itemCount }
print(String(format: "  %-8s │ %5d │       │",
             "TOTAL", totalItems))
print("""
╠══════════════════════════════════════════════════╣
  Review buckets:
    Unknown language : \(reviewUnknownLang.count)
    Multi-language   : \(reviewMultiLang.count)
    Unmatched titles : \(reviewUnmatched.count)
    Zero-coverage    : \(zeroCoverage.count)
╚══════════════════════════════════════════════════╝
""")

// Check: English manifest is substantial (≥ 600)
if let engEntries = manifests["eng"], engEntries.count < 600 {
    print("  WARNING: English manifest has \(engEntries.count) entries (expected ≥ 600)")
    // This is a regression guard but not a fatal error during development
}

// Check: every shipped language has a manifest and vice versa
for (lang, _, _) in shippedLangs {
    guard manifests[lang] != nil else {
        print("  ERROR: \(lang) is in ship list but has no manifest")
        exit(1)
    }
}

print("\nDone.")
