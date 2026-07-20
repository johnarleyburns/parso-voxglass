import Foundation

// ── CSV parsing ────────────────────────────────────────────────────────

struct CSVRow {
    let rank: Int
    let author: String
    let title: String
    let identifierOverride: String?
}

func parseCSV(at url: URL) throws -> [CSVRow] {
    let content = try String(contentsOf: url, encoding: .utf8)
    let lines = content.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let header = lines.first, header.contains("rank") else {
        throw NSError(domain: "CSV", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing header row"])
    }
    return lines.dropFirst().compactMap { line in
        let fields = parseCSVLine(line)
        guard fields.count >= 2, let rank = Int(fields[0]) else { return nil }
        return CSVRow(
            rank: rank,
            author: fields[1].trimmingCharacters(in: .whitespaces),
            title: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : "",
            identifierOverride: fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces).nilIfEmpty : nil
        )
    }
}

func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    for char in line {
        switch char {
        case "\"":
            inQuotes.toggle()
        case "," where !inQuotes:
            fields.append(current)
            current = ""
        default:
            current.append(char)
        }
    }
    fields.append(current)
    return fields
}

// ── Archive.org search ────────────────────────────────────────────────

struct SearchHit: Decodable {
    let identifier: String
    let title: String
    let creator: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decode(String.self, forKey: .title)
        if let arr = try? container.decodeIfPresent([String].self, forKey: .creator) {
            creator = arr.first ?? ""
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .creator) {
            creator = str
        } else {
            creator = ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case identifier, title, creator
    }
}

struct SearchResponse: Decodable {
    struct Inner: Decodable {
        let docs: [SearchHit]
    }
    let response: Inner
}

func resolveRow(_ row: CSVRow) async -> CuratedEntry? {
    if let ov = row.identifierOverride {
        return CuratedEntry(rank: row.rank, title: row.title, author: row.author, identifier: ov)
    }
    let query: String
    if row.title.isEmpty {
        query = "collection:librivoxaudio AND creator:\"\(row.author)\""
    } else {
        query = "collection:librivoxaudio AND creator:\"\(row.author)\" AND title:\"\(row.title)\""
    }
    let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    let urlStr = "https://archive.org/advancedsearch.php?q=\(escaped)&fl[]=identifier,title,creator&sort[]=downloads+desc&rows=1&output=json"
    guard let url = URL(string: urlStr) else { return nil }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let sr = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let hit = sr.response.docs.first else {
            print("  SKIPPED \(row.author) — no LibriVox recording found")
            return nil
        }
        print("  MATCHED  \(row.author) -> \(hit.title) (\(hit.identifier))")
        return CuratedEntry(rank: row.rank, title: hit.title, author: hit.creator.isEmpty ? row.author : hit.creator, identifier: hit.identifier)
    } catch {
        // FIXME - need to investigate why we're getting this error
        print("  ERROR    \(row.author): \(error.localizedDescription)")
        return nil
    }
}

// ── Manifest types ─────────────────────────────────────────────────────

struct CuratedEntry: Codable {
    let rank: Int
    let title: String
    let author: String
    let identifier: String
}

func generateManifest(name: String, csvPath: String, outputPath: String) async throws {
    let csvURL = URL(fileURLWithPath: csvPath)
    let rows = try parseCSV(at: csvURL)
    let withOverride = rows.filter { $0.identifierOverride != nil }
    let withoutOverride = rows.filter { $0.identifierOverride == nil }
    print("\(name): resolving \(rows.count) rows (\(withoutOverride.count) need archive.org lookup, \(withOverride.count) have overrides)...")
    var matched = 0
    var overridden = 0
    var skipped = 0
    var entries: [CuratedEntry] = []
    for row in rows {
        if let entry = await resolveRow(row) {
            entries.append(entry)
            if row.identifierOverride != nil {
                overridden += 1
                print("  OVERRIDE  \(row.author) -> \(entry.identifier)")
            } else {
                matched += 1
            }
        } else {
            skipped += 1
        }
        // Rate limit: 1 second per request to be polite to archive.org
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    guard !entries.isEmpty else {
        print("\(name): no entries resolved — exiting")
        exit(1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(entries)
    let outputURL = URL(fileURLWithPath: outputPath)
    try data.write(to: outputURL)
    print("""
    \(name) resolution report:
      Rows       : \(rows.count)
      Matched    : \(matched)
      Overridden : \(overridden)
      Skipped    : \(skipped)
      Written to : \(outputPath)
    """)
}

// ── Main ───────────────────────────────────────────────────────────────

let sourceDir = "Tools/CuratedLists"
let outputDir = "Voxglass/Core/Resources/CuratedLists"

await withTaskGroup(of: Void.self) { group in
    group.addTask {
        try? await generateManifest(
            name: "Great Books",
            csvPath: "\(sourceDir)/great-books-source.csv",
            outputPath: "\(outputDir)/great-books.json"
        )
    }
    group.addTask {
        try? await generateManifest(
            name: "Greater Books",
            csvPath: "\(sourceDir)/greater-books-source.csv",
            outputPath: "\(outputDir)/greater-books.json"
        )
    }
}

// ── Helpers ────────────────────────────────────────────────────────────

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
